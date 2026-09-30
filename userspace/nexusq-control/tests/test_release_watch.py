"""Tests for the release watch (PROTOCOL §12c).

What is pinned: a release is announced when one of its packages is installed
here at a lower version, and only then; the Q knows the last release it saw
after a restart without the network; a failed or malformed check keeps the
last good release and says why; an unchanged manifest costs a 304; clients
hear about a change once, not at every check; the mute LED's two reasons
(release, daemons) and an install's hold do not fight over it.
"""

import importlib.machinery
import importlib.util
import json
import os
import tempfile
import threading
import unittest
from unittest import mock

HERE = os.path.dirname(os.path.abspath(__file__))
DAEMON = os.path.join(HERE, "..", "nexusq-control")


def load_daemon():
    spec = importlib.util.spec_from_loader(
        "nexusq_control", importlib.machinery.SourceFileLoader("nexusq_control", DAEMON)
    )
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


MOD = load_daemon()


def manifest(version="2.0.0", **pkgs):
    return {
        "schema": 1,
        "version": version,
        "date": "2026-10-01",
        "headline": "Quieter when nothing plays",
        "items": [
            {"icon": "power", "title": "Sleeps in silence", "text": "USB audio dozes while the TV sends silence."},
            {"icon": "sparkles", "title": "Something new", "text": "An icon the app does not know is shown as new."},
        ],
        "packages": pkgs or {"nexusqd": "0.1.0-r25", "nexusq-control": "0.1.0-r62"},
    }


def vcmp(a, b):
    """apk's answer for the versions these tests use: 0.1.0-rN by N."""
    ra, rb = int(a.rsplit("-r", 1)[1]), int(b.rsplit("-r", 1)[1])
    return "<" if ra < rb else "=" if ra == rb else ">"


class Net:
    """A manifest server that remembers what it was asked."""

    def __init__(self, body=None, etag='"a"'):
        self.body, self.etag = body, etag
        self.calls = []
        self.fail = None

    def set(self, obj, etag):
        self.body, self.etag = json.dumps(obj).encode(), etag

    def __call__(self, url, etag):
        self.calls.append(etag)
        if self.fail:
            raise self.fail
        if etag is not None and etag == self.etag:
            return 304, b"", etag
        return 200, self.body, self.etag


class Rig:
    def __init__(self, path, installed=None):
        self.net = Net()
        self.installed = dict(installed or {"nexusqd": "0.1.0-r24", "nexusq-control": "0.1.0-r61"})
        self.events, self.led = [], []
        self.busy = False
        self.now = 1_790_000_000.0
        self.path = path

    def watch(self):
        return MOD.ReleaseWatch(
            fetch=self.net,
            installed=lambda: dict(self.installed),
            vcmp=vcmp,
            busy=lambda: self.busy,
            notify=self.events.append,
            led=self.led.append,
            url="https://example.invalid/release.json",
            path=self.path,
            clock=lambda: self.now,
            device_id=lambda: "nexusq_f88fca2048e1",
        )


class TestParse(unittest.TestCase):
    def test_a_good_manifest(self):
        rel = MOD.parse_release(manifest())
        self.assertEqual(rel["version"], "2.0.0")
        self.assertEqual([i["icon"] for i in rel["items"]], ["power", "new"])  # unknown icon -> new
        self.assertEqual(rel["packages"]["nexusqd"], "0.1.0-r25")

    def test_what_is_refused(self):
        bad = [
            {**manifest(), "schema": 2},
            {**manifest(), "version": "v2"},
            {**manifest(), "date": "1.10.2026"},
            {**manifest(), "headline": ""},
            {**manifest(), "headline": "x" * 81},
            {**manifest(), "items": []},
            {**manifest(), "items": [manifest()["items"][0]] * 6},
            {**manifest(), "items": [{"icon": "new", "title": "t" * 41, "text": "x"}]},
            {**manifest(), "items": [{"icon": "new", "title": "t", "text": "x" * 141}]},
            {**manifest(), "packages": {}},
            {**manifest(), "packages": {"nexusqd": 25}},
            [],
        ]
        for obj in bad:
            with self.subTest(obj=str(obj)[:60]), self.assertRaises(ValueError):
                MOD.parse_release(obj)

    def test_clients_are_not_sent_the_package_list(self):
        pub = MOD.release_public(MOD.parse_release(manifest()))
        self.assertEqual(set(pub), {"version", "date", "headline", "items"})


class TestPending(unittest.TestCase):
    def test_lower_is_pending_equal_or_higher_or_absent_is_not(self):
        rel = MOD.parse_release(manifest(**{"a": "0.1.0-r5", "b": "0.1.0-r5", "c": "0.1.0-r5", "d": "0.1.0-r5"}))
        installed = {"a": "0.1.0-r4", "b": "0.1.0-r5", "c": "0.1.0-r6"}  # d not installed here
        self.assertEqual(MOD.release_pending(rel, installed, vcmp), ["a"])


class TestWatch(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.path = os.path.join(self.tmp.name, "release-status.json")
        self.rig = Rig(self.path)
        self.rig.net.set(manifest(), '"v1"')

    def tearDown(self):
        self.tmp.cleanup()

    def test_a_newer_release_is_announced_once_and_lights_the_led(self):
        w = self.rig.watch()
        w.evaluate()  # the start: nothing known yet
        v = w.check()
        self.assertEqual(v["available"]["version"], "2.0.0")
        self.assertIsNone(v["current"])
        self.assertEqual(v["checkedAt"], int(self.rig.now))
        self.assertEqual(self.rig.led[-1], True)
        self.assertEqual(len(self.rig.events), 1)
        self.rig.now += 6 * 3600
        w.check()  # same release, 304
        self.assertEqual(len(self.rig.events), 1, "an unchanged answer is not an event")
        self.assertEqual(self.rig.net.calls, [None, '"v1"'], "the second check asks with the ETag")

    def test_after_the_update_the_release_is_current_and_the_led_goes_out(self):
        w = self.rig.watch()
        w.evaluate()
        w.check()
        self.rig.installed.update({"nexusqd": "0.1.0-r25", "nexusq-control": "0.1.0-r62"})
        v = w.evaluate()
        self.assertIsNone(v["available"])
        self.assertEqual(v["current"]["version"], "2.0.0")
        self.assertEqual(self.rig.led[-1], False)
        self.assertEqual(len(self.rig.events), 2)

    def test_a_restart_knows_the_release_without_the_network(self):
        w = self.rig.watch()
        w.evaluate()
        w.check()
        again = self.rig.watch()
        self.rig.net.fail = OSError("no network yet")
        v = again.evaluate()
        self.assertEqual(v["available"]["version"], "2.0.0")
        self.assertEqual(again.st["etag"], '"v1"')

    def test_a_failed_check_keeps_the_last_release_and_says_why(self):
        w = self.rig.watch()
        w.evaluate()
        w.check()
        self.rig.net.fail = OSError("timed out")
        v = w.check()
        self.assertEqual(v["available"]["version"], "2.0.0")
        self.assertIn("timed out", v["error"])
        self.rig.net.fail = None
        self.assertIsNone(w.check()["error"])

    def test_a_malformed_manifest_does_not_replace_a_good_one(self):
        w = self.rig.watch()
        w.evaluate()
        w.check()
        self.rig.net.set({**manifest("2.1.0"), "items": []}, '"v2"')
        v = w.check()
        self.assertEqual(v["available"]["version"], "2.0.0")
        self.assertIsNotNone(v["error"])
        self.assertEqual(w.st["etag"], '"v1"', "the bad manifest's ETag must not stick")

    def test_nothing_is_read_while_an_install_runs(self):
        w = self.rig.watch()
        w.evaluate()
        w.check()
        calls = []
        w.installed = lambda: calls.append(1) or {}
        self.rig.busy = True
        w.evaluate()
        self.assertEqual(calls, [])

    def test_no_release_known_means_nothing_to_say(self):
        v = self.rig.watch().evaluate()
        self.assertEqual((v["available"], v["current"], v["checkedAt"]), (None, None, None))
        self.assertEqual(self.rig.led, [False])

    def test_a_damaged_state_file_is_a_fresh_start(self):
        with open(self.path, "w") as f:
            f.write("{not json")
        self.assertIsNone(self.rig.watch().st["release"])

    def test_first_check_waits_for_the_boot_later_ones_follow_the_last(self):
        w = self.rig.watch()
        self.assertEqual(w._due_in(), MOD.RELEASE_FIRST_CHECK_S)
        w.check()
        self.rig.now += 3600
        self.assertEqual(w._due_in(), MOD.RELEASE_CHECK_EVERY_S - 3600)


class TestReviewFixes(unittest.TestCase):
    """The fleet-safety review of r63's first version (2026-09-30)."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.path = os.path.join(self.tmp.name, "release-status.json")
        self.rig = Rig(self.path)
        self.rig.net.set(manifest(), '"v1"')

    def tearDown(self):
        self.tmp.cleanup()

    def test_a_clock_behind_the_last_check_does_not_push_the_next_one_away(self):
        # The RTC does not keep time: before NTP the clock sits weeks behind.
        w = self.rig.watch()
        w.check()
        self.rig.now -= 30 * 86400
        self.assertEqual(w._due_in(), MOD.RELEASE_FIRST_CHECK_S)
        self.rig.now += 60 * 86400  # and far ahead: due now, not negative
        self.assertEqual(w._due_in(), MOD.RELEASE_FIRST_CHECK_S)

    def test_any_damage_to_the_state_file_is_a_fresh_start(self):
        for body in ("[]", "null", '"x"', '{"checkedAt": "yesterday"}', '{"release": 5}', '{"etag": 1}'):
            with self.subTest(body=body):
                with open(self.path, "w") as f:
                    f.write(body)
                w = self.rig.watch()
                self.assertEqual(w.st, {"checkedAt": None, "etag": None, "release": None})
                self.assertEqual(w._due_in(), MOD.RELEASE_FIRST_CHECK_S)

    def test_any_failure_of_a_check_is_recorded_not_raised(self):
        w = self.rig.watch()
        for exc in (RuntimeError("truncated"), RecursionError("maximum recursion depth")):
            self.rig.net.fail = exc
            self.assertIsNotNone(w.check()["error"])

    def test_a_failed_comparison_is_not_read_as_installed(self):
        w = self.rig.watch()
        w.check()

        def broken(a, b):
            raise MOD.Err("unavailable", "apk version -t failed")

        w.vcmp = broken
        v = w.evaluate()
        self.assertIsNone(v["current"], "an unknown answer must not say the release is installed")
        self.assertIsNone(v["available"])

    def test_the_kernel_is_never_pending(self):
        rel = MOD.parse_release(manifest(**{"linux-google-steelhead": "6.18.48-r99", "nexusqd": "0.1.0-r25"}))
        installed = {"linux-google-steelhead": "6.18.48-r19", "nexusqd": "0.1.0-r25"}
        self.assertEqual(MOD.release_pending(rel, installed, lambda a, b: "<" if a != b else "="), [])

    def test_a_refresh_right_after_a_check_does_not_fetch_again(self):
        w = self.rig.watch()
        w.check()
        self.rig.now += 10
        w.check(min_age=MOD.RELEASE_REFRESH_MIN_S)
        self.assertEqual(len(self.rig.net.calls), 1)
        self.rig.now += MOD.RELEASE_REFRESH_MIN_S
        w.check(min_age=MOD.RELEASE_REFRESH_MIN_S)
        self.assertEqual(len(self.rig.net.calls), 2)

    def test_the_answer_says_whose_it_is(self):
        self.assertEqual(self.rig.watch().view()["id"], "nexusq_f88fca2048e1")

    def test_after_an_install_the_led_waits_for_the_new_comparison(self):
        order = []
        b = object.__new__(MOD.Bridge)
        b.release = mock.Mock(evaluate=mock.Mock(side_effect=lambda: order.append("evaluate")))
        b.update_led = mock.Mock(hold=mock.Mock(side_effect=lambda h: order.append(f"hold {h}")))
        with mock.patch.object(MOD.threading, "Thread") as T:
            b._after_install()
            T.call_args.kwargs["target"]()
        self.assertEqual(order, ["evaluate", "hold False"])


class TestUpdateLed(unittest.TestCase):
    def test_two_reasons_and_an_install_hold(self):
        sent = []
        led = MOD.UpdateLed(sent.append)
        led.set("release", True)
        led.set("daemons", True)
        led.set("release", False)
        self.assertEqual(sent[-1], "mblink 255 140 0", "one reason left still blinks")
        led.hold(True)
        self.assertEqual(sent[-1], "mblink stop")
        led.set("release", True)
        self.assertEqual(sent[-1], "mblink stop", "held while installing")
        led.hold(False)
        self.assertEqual(sent[-1], "mblink 255 140 0")
        led.set("release", False)
        led.set("daemons", False)
        self.assertEqual(sent[-1], "mblink stop")


class TestMethod(unittest.TestCase):
    def bridge(self):
        b = object.__new__(MOD.Bridge)
        b.lock = threading.Lock()
        b.state = {"theme": "blue"}
        b.release = mock.Mock(
            view=mock.Mock(return_value={"v": "cached"}), check=mock.Mock(return_value={"v": "fresh"})
        )
        return b

    def test_get_update_status_is_the_cached_view_unless_asked_to_refresh(self):
        b = self.bridge()
        self.assertEqual(b.handle("getUpdateStatus", {}), ({"v": "cached"}, []))
        b.release.check.assert_not_called()
        self.assertEqual(b.handle("getUpdateStatus", {"refresh": True}), ({"v": "fresh"}, []))

    def test_refresh_must_be_a_bool(self):
        with self.assertRaises(MOD.Err):
            self.bridge().handle("getUpdateStatus", {"refresh": "yes"})


class TestDeviceId(unittest.TestCase):
    """The key the app remembers a unit by: the factory WiFi MAC, as in HA."""

    def test_from_the_mac(self):
        with tempfile.NamedTemporaryFile("w", suffix="address") as f:
            f.write("F8:8F:CA:20:48:E1\n")
            f.flush()
            self.assertEqual(MOD._device_id(f.name), "nexusq_f88fca2048e1")

    def test_no_interface_or_no_mac_is_no_id(self):
        self.assertIsNone(MOD._device_id("/nonexistent/address"))
        with tempfile.NamedTemporaryFile("w") as f:
            f.write("\n")
            f.flush()
            self.assertIsNone(MOD._device_id(f.name))


if __name__ == "__main__":
    unittest.main()
