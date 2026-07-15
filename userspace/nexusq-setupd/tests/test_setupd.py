import importlib.util
import importlib.machinery
import json
import os
import unittest
from unittest import mock

HERE = os.path.dirname(os.path.abspath(__file__))
DAEMON = os.path.join(HERE, "..", "nexusq-setupd")
VECTORS = os.path.join(HERE, "..", "..", "..", "companion", "pairing-color-vectors.json")


def load_daemon():
    spec = importlib.util.spec_from_loader(
        "nexusq_setupd", importlib.machinery.SourceFileLoader("nexusq_setupd", DAEMON))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


class TestPairingColor(unittest.TestCase):
    def test_shared_vectors(self):
        mod = load_daemon()
        with open(VECTORS) as f:
            vectors = json.load(f)["vectors"]
        for v in vectors:
            self.assertEqual(list(mod.pairing_color(v["mac"])), v["rgb"], v["mac"])


class TestSanitizeHostname(unittest.TestCase):
    def test_diacritics_and_spaces(self):
        mod = load_daemon()
        self.assertEqual(mod.sanitize_hostname("Obývák Q"), "obyvak-q")

    def test_empty_falls_back(self):
        mod = load_daemon()
        self.assertEqual(mod.sanitize_hostname("---"), "nexusq")

    def test_length_cap(self):
        mod = load_daemon()
        self.assertLessEqual(len(mod.sanitize_hostname("x" * 100)), 63)


class TestNmErrorClassification(unittest.TestCase):
    def test_wrong_password(self):
        mod = load_daemon()
        self.assertEqual(mod.classify_nm_error(
            "Error: Connection activation failed: Secrets were required, but not provided."),
            "wrong_password")

    def test_not_found(self):
        mod = load_daemon()
        self.assertEqual(mod.classify_nm_error(
            "Error: No network with SSID 'foo' found."), "not_found")

    def test_timeout(self):
        mod = load_daemon()
        self.assertEqual(mod.classify_nm_error(
            "Error: Timeout expired (90) seconds"), "timeout")

    def test_unknown_is_internal(self):
        mod = load_daemon()
        self.assertEqual(mod.classify_nm_error("something odd"), "internal")


class TestScanParsing(unittest.TestCase):
    def test_parse_dedupe_and_security(self):
        mod = load_daemon()
        out = "MyNet:72:WPA2\nMyNet:55:WPA2\nOpenNet:40:\n:30:WPA2\n"
        nets = mod.parse_wifi_list(out)
        self.assertEqual(nets, [
            {"ssid": "MyNet", "signal": 72, "security": "wpa-psk"},
            {"ssid": "OpenNet", "signal": 40, "security": "open"},
        ])


class TestSetupCore(unittest.TestCase):
    def _core(self, mod):
        return mod.SetupCore(run=mock.Mock(), led=mock.Mock(), bt_mac="F8:8F:CA:20:49:E5")

    def test_get_device_info(self):
        mod = load_daemon()
        core = self._core(mod)
        info = core.handle("getDeviceInfo", {})
        self.assertEqual(info["model"], "steelhead")
        self.assertEqual(info["btMac"], "F8:8F:CA:20:49:E5")
        self.assertIn("provisioned", info)

    def test_confirm_color_drives_led_and_returns_rgb(self):
        mod = load_daemon()
        core = self._core(mod)
        r = core.handle("confirmColor", {})
        self.assertEqual(r["rgb"], [0, 183, 255])
        core.led.send.assert_called_with("set 0 183 255")

    def test_confirm_color_unknown_mac_is_unavailable_not_crash(self):
        # mainline kernels have no sysfs BT address; an empty/garbage MAC must
        # surface as the protocol error, never a ValueError from pairing_color
        mod = load_daemon()
        for bad in ("", "not-a-mac", "F8:8F:CA:20:49"):
            core = mod.SetupCore(run=mock.Mock(), led=mock.Mock(), bt_mac=bad)
            with self.assertRaises(mod.Err) as cm:
                core.handle("confirmColor", {})
            self.assertEqual(cm.exception.code, "unavailable")

    def test_set_wifi_success(self):
        mod = load_daemon()
        core = self._core(mod)
        # run() mock: every nmcli call succeeds; IP lookup returns an address
        def fake_run(args, **kw):
            m = mock.Mock(returncode=0, stderr="")
            m.stdout = "192.168.20.195/24\n" if "IP4.ADDRESS" in args else ""
            return m
        core.run = fake_run
        r = core.handle("setWifi", {"ssid": "MyNet", "psk": "secret", "security": "wpa-psk"})
        self.assertTrue(r["ok"])
        self.assertEqual(r["ip"], "192.168.20.195")
        self.assertTrue(r["mdns"].endswith(".local"))

    def test_set_wifi_wrong_password_cleans_up(self):
        mod = load_daemon()
        core = self._core(mod)
        calls = []
        def fake_run(args, **kw):
            calls.append(args)
            if args[:3] == ["nmcli", "connection", "up"]:
                return mock.Mock(returncode=4,
                                 stderr="Error: Connection activation failed: Secrets were required, but not provided.")
            return mock.Mock(returncode=0, stdout="", stderr="")
        core.run = fake_run
        with self.assertRaises(mod.Err) as cm:
            core.handle("setWifi", {"ssid": "MyNet", "psk": "wrong", "security": "wpa-psk"})
        self.assertEqual(cm.exception.code, "wrong_password")
        # the failed profile must be deleted
        self.assertIn(["nmcli", "connection", "delete", "wifi"], calls)

    def test_set_wifi_missing_ssid(self):
        mod = load_daemon()
        core = self._core(mod)
        with self.assertRaises(mod.Err) as cm:
            core.handle("setWifi", {"psk": "x"})
        self.assertEqual(cm.exception.code, "bad_request")

    def test_set_wifi_missing_psk_has_no_side_effects(self):
        mod = load_daemon()
        core = self._core(mod)
        calls = []
        def fake_run(args, **kw):
            calls.append(args)
            return mock.Mock(returncode=0, stdout="", stderr="")
        core.run = fake_run
        with self.assertRaises(mod.Err) as cm:
            core.handle("setWifi", {"ssid": "X", "security": "wpa-psk"})
        self.assertEqual(cm.exception.code, "bad_request")
        self.assertEqual(calls, [])
        core.led.send.assert_not_called()

    def test_set_wifi_timeout_never_embeds_psk(self):
        mod = load_daemon()
        core = self._core(mod)
        calls = []
        def fake_run(args, **kw):
            calls.append(args)
            if args[:3] == ["nmcli", "connection", "add"]:
                raise mod.subprocess.TimeoutExpired(
                    cmd=["nmcli", "connection", "add", "wifi-sec.psk", "SECRETPSK"],
                    timeout=20)
            return mock.Mock(returncode=0, stdout="", stderr="")
        core.run = fake_run
        with self.assertRaises(mod.Err) as cm:
            core.handle("setWifi", {"ssid": "MyNet", "psk": "SECRETPSK",
                                     "security": "wpa-psk"})
        self.assertNotIn("SECRETPSK", cm.exception.message)
        self.assertIn(cm.exception.code, ("internal", "timeout"))
        self.assertIn(["nmcli", "connection", "delete", "wifi"], calls)
        # cleanup must happen after the failing add call (last call in the list)
        self.assertEqual(calls[-1], ["nmcli", "connection", "delete", "wifi"])

    def test_finish_setup_sets_finished(self):
        mod = load_daemon()
        core = self._core(mod)
        # provisioned: `nmcli -t -f TYPE connection show` lists a wifi profile
        core.run = lambda *a, **k: mock.Mock(
            returncode=0, stdout="802-11-wireless\n", stderr="")
        r = core.handle("finishSetup", {})
        self.assertTrue(r["done"])
        self.assertTrue(core.finished)

    def test_finish_setup_refused_before_wifi_joined(self):
        # REGRESSION (live 2026-07-15): the app reached finishSetup with no wifi
        # profile. `finished` makes us exit 0, so Restart=on-failure does NOT
        # restart us and nothing re-arms setup mode until a reboot -> the device
        # is stranded off-network with the wizard gone.
        mod = load_daemon()
        core = self._core(mod)
        core.run = lambda *a, **k: mock.Mock(returncode=0, stdout="", stderr="")
        with self.assertRaises(mod.Err) as cm:
            core.handle("finishSetup", {})
        self.assertEqual(cm.exception.code, "bad_request")
        self.assertFalse(core.finished)

    def test_unknown_method(self):
        mod = load_daemon()
        core = self._core(mod)
        with self.assertRaises(mod.Err) as cm:
            core.handle("nonsense", {})
        self.assertEqual(cm.exception.code, "unknown_method")


class TestFraming(unittest.TestCase):
    def _core(self, mod):
        core = mod.SetupCore(run=mock.Mock(), led=mock.Mock(), bt_mac="F8:8F:CA:20:49:E5")
        return core

    def test_ok_response(self):
        mod = load_daemon()
        core = self._core(mod)
        resp = mod.handle_line(core, '{"id": 3, "method": "confirmColor"}')
        obj = json.loads(resp)
        self.assertEqual(obj, {"id": 3, "ok": True, "result": {"rgb": [0, 183, 255]}})

    def test_error_response(self):
        mod = load_daemon()
        core = self._core(mod)
        resp = mod.handle_line(core, '{"id": 4, "method": "nonsense"}')
        obj = json.loads(resp)
        self.assertFalse(obj["ok"])
        self.assertEqual(obj["error"]["code"], "unknown_method")

    def test_fire_and_forget_no_response(self):
        mod = load_daemon()
        core = self._core(mod)
        self.assertIsNone(mod.handle_line(core, '{"method": "confirmColor"}'))

    def test_garbage_line_ignored(self):
        mod = load_daemon()
        core = self._core(mod)
        self.assertIsNone(mod.handle_line(core, "{not json"))

    def test_valid_json_non_object_ignored(self):
        mod = load_daemon()
        core = self._core(mod)
        # Valid JSON but not an object should be ignored, not raise AttributeError
        self.assertIsNone(mod.handle_line(core, "42"))
        self.assertIsNone(mod.handle_line(core, "null"))
        self.assertIsNone(mod.handle_line(core, '"x"'))
        self.assertIsNone(mod.handle_line(core, "[1, 2]"))


if __name__ == "__main__":
    unittest.main()


class TestBtAdapterMac(unittest.TestCase):
    def _fake_dbus(self, address):
        fake = mock.MagicMock()
        fake.Interface.return_value.Get.return_value = address
        return fake

    def test_dbus_fallback_when_sysfs_absent(self):
        # mainline kernels have no /sys/class/bluetooth/hci0/address ->
        # the BlueZ Adapter1.Address D-Bus fallback must kick in, uppercased
        mod = load_daemon()
        with mock.patch("builtins.open", side_effect=OSError), \
             mock.patch.dict("sys.modules", {"dbus": self._fake_dbus("f8:8f:ca:20:49:e5")}):
            self.assertEqual(mod.bt_adapter_mac(), "F8:8F:CA:20:49:E5")

    def test_no_sysfs_no_dbus_degrades_to_empty(self):
        mod = load_daemon()
        broken = mock.MagicMock()
        broken.SystemBus.side_effect = RuntimeError("no bus")
        with mock.patch("builtins.open", side_effect=OSError), \
             mock.patch.dict("sys.modules", {"dbus": broken}):
            self.assertEqual(mod.bt_adapter_mac(), "")
