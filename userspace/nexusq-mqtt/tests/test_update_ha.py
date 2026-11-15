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


def job(phase="downloading", percent=30, state="running", kind="system", **progress):
    p = {"percent": percent, "phasePercent": 50, "packagesDone": 0, "packagesTotal": 0, "current": None}
    p.update(progress)
    return {"id": "j1", "kind": kind, "state": state, "phase": phase, "stalled": False, "resumed": False, "progress": p}


class TestJobPayload(unittest.TestCase):
    """A running job (control r70+): its percent and its phase in words."""

    def test_percent_and_the_last_check_stay(self):
        st = MOD.update_state_payload("1.0-r116", {"packages": [DEV]}, job=job(percent=42))
        self.assertTrue(st["in_progress"])
        self.assertEqual(st["update_percentage"], 42)
        self.assertEqual(st["latest_version"], "1.0-r116", "the device package's new version, from the check")

    def test_the_phases_in_words(self):
        dl = job(bytesDone=45 << 20, bytesTotal=120 << 20, etaS=240)
        self.assertEqual(MOD.job_summary(dl), "Downloading: 45 MB of 120 MB, about 4 min left.")
        inst = job("installing", 70, packagesDone=125, packagesTotal=393, current="pulseaudio", etaS=30)
        self.assertEqual(MOD.job_summary(inst), "Installing 125 of 393 packages (pulseaudio), about a minute left.")
        self.assertEqual(MOD.job_summary(job("applying")), "Restarting the Q's services.")
        self.assertEqual(MOD.job_summary(job("preparing")), "Preparing the update.")

    def test_stalled_and_resumed_are_said(self):
        j = job("installing", stalled=None)
        j["stalled"], j["resumed"] = True, True
        text = MOD.job_summary(j)
        self.assertTrue(text.startswith("Finishing an interrupted update."))
        self.assertIn("no progress for a while", text)

    def test_no_job_no_percentage(self):
        self.assertNotIn("update_percentage", MOD.update_state_payload("1.0-r116", {"packages": []}))


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

    def test_install_as_it_arrives_from_the_broker(self):
        # The receive path hands over bytes: an Install press in HA arrives as
        # b"install", and until r17 it was logged as ignored, every time.
        f = Fake(install={"ok": True, "changed": ["nexusq-control"], "rebootRecommended": False})
        self.assertTrue(f.link.submit(f.link.topics["install"], b"install"))
        f.link.step()
        self.assertEqual([c for c, _ in f.calls], ["installSystemUpdate", "checkSystemUpdate"])

    def test_a_foreign_install_payload_is_still_ignored(self):
        f = Fake()
        self.assertTrue(f.link.submit(f.link.topics["install"], b"please"))
        f.link.step()
        self.assertNotIn("installSystemUpdate", [c for c, _ in f.calls])

    def test_a_retained_install_never_installs(self):
        # The broker replays a retained message at every subscribe; obeyed, a
        # stray `mosquitto_pub -r .../update/install` would install at every
        # reconnect. route_message drops retained commands (r17).
        f = Fake(install={"ok": True, "changed": ["nexusq-control"], "rebootRecommended": False})
        guard = MOD.DiscoveryGuard("homeassistant", NODE)
        answered = []
        MOD.route_message(f.link.topics["install"], b"install", True, guard, answered.append, [f.link])
        f.link.step()
        self.assertNotIn("installSystemUpdate", [c for c, _ in f.calls])
        # the same press, live, does
        MOD.route_message(f.link.topics["install"], b"install", False, guard, answered.append, [f.link])
        f.link.step()
        self.assertIn("installSystemUpdate", [c for c, _ in f.calls])
        self.assertEqual(answered, [])

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

    def test_an_async_install_shows_the_job_and_then_its_progress(self):
        f = Fake(install={"started": True, "job": job("preparing", 0)})
        f.link.submit(f.link.topics["install"], "install")
        f.link.step()
        self.assertEqual(f.calls, [("installSystemUpdate", MOD.UPDATE_INSTALL_TIMEOUT_S)])
        self.assertEqual(f.states()[-1]["update_percentage"], 0)
        f.now += 5
        f.link.apply_event("updateProgress", job("installing", 70, packagesDone=10, packagesTotal=20))
        self.assertEqual(f.states()[-1]["update_percentage"], 70)
        self.assertIn("Installing 10 of 20", f.states()[-1]["release_summary"])

    def test_progress_reaches_home_assistant_at_a_bounded_rate(self):
        f = Fake()
        f.link.apply_event("updateProgress", job(percent=10))
        f.link.apply_event("updateProgress", job(percent=11))  # same phase, too soon
        self.assertEqual([s["update_percentage"] for s in f.states()], [10])
        f.link.apply_event("updateProgress", job("installing", 61))  # a new phase: at once
        f.now += MOD.UPDATE_PROGRESS_EVERY_S
        f.link.apply_event("updateProgress", job("installing", 70))
        self.assertEqual([s["update_percentage"] for s in f.states()], [10, 61, 70])

    def test_the_version_is_read_once_per_job(self):
        f = Fake()
        reads = []
        f.link.version = lambda: reads.append(1) or "1.0-r116"
        for pct in range(10, 60, 5):
            f.now += MOD.UPDATE_PROGRESS_EVERY_S
            f.link.apply_event("updateProgress", job(percent=pct))
        self.assertEqual(len(reads), 1)

    def test_the_end_of_a_job_checks_or_says_it_reboots(self):
        f = Fake()
        f.link.apply_event("updateProgress", job(percent=50))
        f.link.apply_event("updateFinished", job("done", 100, state="done"))
        f.link.step()
        self.assertEqual([c for c, _ in f.calls], ["checkSystemUpdate"])
        self.assertFalse(f.states()[-1]["in_progress"])
        g = Fake()
        done = job("rebooting", 100, state="done")
        done["result"] = {"rebootRecommended": True}
        g.link.apply_event("updateFinished", done)
        self.assertIn("rebooting", g.states()[-1]["release_summary"])

    def test_a_daemons_job_is_not_this_entity_s_install_but_its_end_checks(self):
        f = Fake()
        f.link.apply_event("updateProgress", job(kind="daemons"))
        self.assertEqual(f.states(), [])
        f.link.apply_event("updateFinished", job("done", 100, state="done", kind="daemons"))
        f.link.step()
        self.assertEqual([c for c, _ in f.calls], ["checkSystemUpdate"])

    def test_a_job_running_when_the_feed_connects_is_shown(self):
        f = Fake()
        f.link.call = lambda method, params, timeout=5: (
            f.calls.append((method, timeout)) or {"job": job("installing", 80)}
        )
        f.link.set_state({})
        f.link.step()
        self.assertEqual(f.calls[0][0], "getUpdateJob")
        self.assertEqual(f.states()[-1]["update_percentage"], 80)

    def test_a_bridge_without_jobs_is_quiet(self):
        f = Fake()

        def call(method, params, timeout=5):
            raise MOD.ControlError("unknown_method", method)

        f.link.call = call
        f.link.set_state({})
        f.link.step()
        self.assertEqual(f.states(), [])

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
