import importlib.util
import importlib.machinery
import json
import os
import unittest
from unittest import mock

HERE = os.path.dirname(os.path.abspath(__file__))
DAEMON = os.path.join(HERE, "..", "nexusq-nfc-send")


def load_daemon():
    spec = importlib.util.spec_from_loader(
        "nq_nfc", importlib.machinery.SourceFileLoader("nq_nfc", DAEMON))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


class TestReadBtMac(unittest.TestCase):
    def test_bluetoothctl_fallback_when_sysfs_absent(self):
        # mainline kernels have no /sys/class/bluetooth/hci0/address ->
        # parse `bluetoothctl show`, uppercased
        mod = load_daemon()
        out = "Controller f8:8f:ca:20:49:e5 (public)\n\tName: Google Nexus Q\n"
        with mock.patch("builtins.open", side_effect=OSError), \
             mock.patch.object(mod.subprocess, "run",
                               return_value=mock.Mock(returncode=0, stdout=out)):
            self.assertEqual(mod._read_bt_mac(), "F8:8F:CA:20:49:E5")

    def test_no_sysfs_no_bluetoothctl_degrades_to_empty(self):
        mod = load_daemon()
        with mock.patch("builtins.open", side_effect=OSError), \
             mock.patch.object(mod.subprocess, "run", side_effect=OSError):
            self.assertEqual(mod._read_bt_mac(), "")


class TestPayload(unittest.TestCase):
    def test_provisioned_with_ip(self):
        mod = load_daemon()
        def run(args, **kw):
            if "IP4.ADDRESS" in args:
                return mock.Mock(returncode=0, stdout="192.168.20.195/24\n")
            return mock.Mock(returncode=0, stdout="802-11-wireless\n")
        raw = mod.build_payload(run=run, gethostname=lambda: "steelhead",
                                read_bt_mac=lambda: "F8:8F:CA:20:49:E5")
        obj = json.loads(raw.decode())
        self.assertEqual(obj, {"v": 1, "bt": "F8:8F:CA:20:49:E5",
                               "host": "steelhead", "ip": "192.168.20.195",
                               "prov": True})
        self.assertLessEqual(len(raw), 250)

    def test_unprovisioned_no_ip(self):
        mod = load_daemon()
        def run(args, **kw):
            return mock.Mock(returncode=0, stdout="")
        obj = json.loads(mod.build_payload(
            run=run, gethostname=lambda: "steelhead",
            read_bt_mac=lambda: "F8:8F:CA:20:49:E5").decode())
        self.assertIsNone(obj["ip"])
        self.assertFalse(obj["prov"])

    def test_resilient_to_failures(self):
        mod = load_daemon()
        def run(args, **kw):
            raise OSError("no nmcli")
        obj = json.loads(mod.build_payload(
            run=run, gethostname=lambda: "steelhead",
            read_bt_mac=lambda: "").decode())
        self.assertEqual(obj["v"], 1)   # still a valid payload


if __name__ == "__main__":
    unittest.main()
