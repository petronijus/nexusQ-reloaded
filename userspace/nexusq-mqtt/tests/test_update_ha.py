"""The system update from Home Assistant (nexusq-mqtt r10).

HA's `update` entity mirrors the app's "Update system" (PROTOCOL §12b): check,
install, and an honest in-progress state, including the reboot after which
this process is gone. The link runs here with a fake bridge call, a fake apk
version and a fake clock.
"""

import importlib.machinery
import importlib.util
import json
import os
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
DAEMON = os.path.join(HERE, "..", "nexusq-mqtt")


def load_daemon():
    spec = importlib.util.spec_from_loader("nexusq_mqtt", importlib.machinery.SourceFileLoader("nexusq_mqtt", DAEMON))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


MOD = load_daemon()
NODE, PREFIX = "nexusq_f88fca2048e1", "nexusq"

CTRL = {"name": "nexusq-control", "installed": "0.1.0-r50", "available": "0.1.0-r53"}
MQTT = {"name": "nexusq-mqtt", "installed": "0.1.0-r7", "available": "0.1.0-r10"}
DEV = {"name": "device-google-steelhead", "installed": "1.0-r114", "available": "1.0-r116"}


class TestPayload(unittest.TestCase):
    def test_up_to_date(self):
        p = MOD.update_state_payload("1.0-r116", {"packages": [], "updateAvailable": False})
        self.assertEqual(p["installed_version"], p["latest_version"])
        self.assertEqual(p["release_summary"], "Up to date.")
        self.assertFalse(p["in_progress"])

    def test_other_packages_only(self):
        p = MOD.update_state_payload("1.0-r116", {"packages": [CTRL, MQTT]})
        self.assertEqual(p["latest_version"], "1.0-r116 + 2 updates")
        self.assertIn("nexusq-control 0.1.0-r50 → 0.1.0-r53", p["release_summary"])
        # not a version: HA cannot order it, so a differing pair is an update
        self.assertIn(" ", p["latest_version"])

    def test_device_package_moves(self):
        p = MOD.update_state_payload("1.0-r114", {"packages": [DEV]})
        self.assertEqual(p["latest_version"], "1.0-r116")
        p = MOD.update_state_payload("1.0-r114", {"packages": [DEV, CTRL]})
        self.assertEqual(p["latest_version"], "1.0-r116 + 1 update")

    def test_phases_and_busy(self):
        p = MOD.update_state_payload("1.0-r114", None, "installing")
        self.assertTrue(p["in_progress"])
        p = MOD.update_state_payload("1.0-r116", None, "rebooting")
        self.assertTrue(p["in_progress"])
        self.assertIn("rebooting", p["release_summary"])
        # the app is installing: the bridge's check says busy
        p = MOD.update_state_payload("1.0-r114", {"packages": [], "busy": True})
        self.assertTrue(p["in_progress"])

    def test_summary_fits_home_assistant(self):
        many = [{"name": f"package-number-{i}", "installed": "1.0-r1", "available": "1.0-r2"} for i in range(30)]
        p = MOD.update_state_payload("1.0-r116", {"packages": many})
        self.assertLessEqual(len(p["release_summary"]), MOD.HA_SUMMARY_MAX)
        self.assertEqual(p["latest_version"], "1.0-r116 + 30 updates")

    def test_garbage(self):
        p = MOD.update_state_payload(None, {"packages": ["x", {"name": 3}]})
        self.assertEqual(p["installed_version"], "unknown")
        self.assertEqual(p["latest_version"], "unknown")


class Fake:
    def __init__(self, check=None, install=None):
        self.now = 1000.0
        self.published = []
        self.calls = []
        self.check_result = check if check is not None else {"packages": [CTRL]}
        self.install_result = install
        self.installed = "1.0-r116"
        self.link = MOD.UpdateLink(
            PREFIX, NODE, self.publish, call=self.call, version=lambda: self.installed, clock=lambda: self.now
        )

    def publish(self, topic, payload, retain=False):
        self.published.append((topic, json.loads(payload), retain))

    def call(self, method, params, timeout=5):
        self.calls.append((method, timeout))
        if method == "checkSystemUpdate":
            return self.check_result
        r = self.install_result
        if isinstance(r, Exception):
            raise r
        self.check_result = {"packages": []}
        return r

    def states(self):
        return [p for t, p, _ in self.published if t.endswith("/update/state")]


class TestLink(unittest.TestCase):
    def test_timed_checks(self):
        f = Fake()
        f.link.step()
        self.assertEqual(f.calls, [])  # not before the first delay
        f.now += MOD.UPDATE_FIRST_CHECK_S
        f.link.step()
        self.assertEqual([c for c, _ in f.calls], ["checkSystemUpdate"])
        self.assertEqual(f.states()[-1]["latest_version"], "1.0-r116 + 1 update")
        self.assertTrue(all(r for _, _, r in f.published))  # retained
        f.now += 60
        f.link.step()
        self.assertEqual(len(f.calls), 1)  # then only every six hours
        f.now += MOD.UPDATE_CHECK_EVERY_S
        f.link.step()
        self.assertEqual(len(f.calls), 2)

    def test_button_checks_now(self):
        f = Fake()
        self.assertTrue(f.link.submit(f.link.topics["check"], "PRESS"))
        f.link.step()
        self.assertEqual([c for c, _ in f.calls], ["checkSystemUpdate"])

    def test_install_then_check(self):
        f = Fake(install={"ok": True, "changed": ["nexusq-control"], "rebootRecommended": False})
        self.assertTrue(f.link.submit(f.link.topics["install"], "install"))
        f.link.step()
        self.assertEqual([c for c, _ in f.calls], ["installSystemUpdate", "checkSystemUpdate"])
        self.assertEqual(f.calls[0][1], MOD.UPDATE_INSTALL_TIMEOUT_S)
        st = f.states()
        self.assertTrue(st[0]["in_progress"])  # said before apk runs
        self.assertFalse(st[-1]["in_progress"])
        self.assertEqual(st[-1]["release_summary"], "Up to date.")

    def test_install_that_reboots_says_so(self):
        f = Fake(install={"ok": True, "changed": ["musl"], "rebootRecommended": True})
        f.link.submit(f.link.topics["install"], "install")
        f.link.step()
        self.assertEqual([c for c, _ in f.calls], ["installSystemUpdate"])
        self.assertTrue(f.states()[-1]["in_progress"])
        self.assertIn("rebooting", f.states()[-1]["release_summary"])

    def test_app_already_installing(self):
        f = Fake(install=MOD.ControlError("busy", "an update is already installing"))
        f.link.submit(f.link.topics["install"], "install")
        f.link.step()
        self.assertTrue(f.states()[-1]["in_progress"])

    def test_failed_install_falls_back_to_a_check(self):
        f = Fake(install=MOD.ControlError("unavailable", "apk upgrade failed"))
        f.link.submit(f.link.topics["install"], "install")
        f.link.step()
        self.assertEqual([c for c, _ in f.calls], ["installSystemUpdate", "checkSystemUpdate"])
        self.assertFalse(f.states()[-1]["in_progress"])
        self.assertIn("nexusq-control", f.states()[-1]["release_summary"])

    def test_bridge_down_publishes_nothing_new(self):
        f = Fake()
        f.check_result = None

        def down(method, params, timeout=5):
            raise OSError("connection refused")

        f.link.call = down
        f.link.submit(f.link.topics["check"], "PRESS")
        f.link.step()
        self.assertEqual(f.states(), [])

    def test_foreign_and_malformed_commands(self):
        f = Fake()
        self.assertFalse(f.link.submit("nexusq/other/topic", "install"))
        self.assertTrue(f.link.submit(f.link.topics["install"], "please"))
        f.link.step()
        self.assertNotIn("installSystemUpdate", [c for c, _ in f.calls])

    def test_republish_after_reconnect(self):
        f = Fake()
        f.link.republish()
        self.assertEqual(f.published, [])  # nothing known yet
        f.link.submit(f.link.topics["check"], "PRESS")
        f.link.step()
        n = len(f.published)
        f.link.republish()
        self.assertEqual(len(f.published), n + 1)
        self.assertEqual(f.published[-1], f.published[-2])


class TestDiscovery(unittest.TestCase):
    def test_entities(self):
        cfgs = dict(MOD.update_discovery_configs(NODE, "Obývák Q", PREFIX))
        upd = cfgs[f"update/{NODE}/system/config"]
        self.assertEqual(upd["device_class"], "firmware")
        self.assertEqual(upd["command_topic"], f"{PREFIX}/{NODE}/update/install")
        self.assertEqual(upd["payload_install"], "install")
        self.assertEqual(upd["state_topic"], f"{PREFIX}/{NODE}/update/state")
        self.assertEqual(upd["availability_topic"], f"{PREFIX}/{NODE}/status")
        btn = cfgs[f"button/{NODE}/update_check/config"]
        self.assertEqual(btn["command_topic"], f"{PREFIX}/{NODE}/update/check")
        for c in cfgs.values():
            self.assertEqual(c["device"]["identifiers"], [NODE])
            json.dumps(c)


if __name__ == "__main__":
    unittest.main()
