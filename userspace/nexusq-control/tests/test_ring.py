import datetime
import importlib.machinery
import importlib.util
import json
import os
import tempfile
import unittest
from unittest import mock

HERE = os.path.dirname(os.path.abspath(__file__))
DAEMON = os.path.join(HERE, "..", "nexusq-control")


def load_daemon():
    spec = importlib.util.spec_from_loader(
        "nexusq_control", importlib.machinery.SourceFileLoader("nexusq_control", DAEMON))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def at(hh, mm, ss=0):
    return datetime.datetime(2026, 9, 22, hh, mm, ss)


class FakeNexusqd:
    """Records what the bridge sends; `knows_dark=False` is a pre-ring nexusqd,
    which answers `err` to a verb it does not have."""

    def __init__(self, knows_dark=True):
        self.sent = []
        self.knows_dark = knows_dark

    def __call__(self, line):
        self.sent.append(line)
        return self.knows_dark or not line.startswith("dark")


class RingBase(unittest.TestCase):
    def setUp(self):
        self.mod = load_daemon()
        self.tmp = tempfile.TemporaryDirectory()
        self.path = os.path.join(self.tmp.name, "nexusq", "ring.json")
        self.now = at(12, 0)
        self.is_synced = True
        self.nq = FakeNexusqd()
        self.events = []

    def tearDown(self):
        self.tmp.cleanup()

    def ring(self):
        return self.mod.Ring(path=self.path, send=self.nq,
                             clock=lambda: self.now,
                             synced=lambda: self.is_synced,
                             on_change=self.events.append)

    def stored(self):
        with open(self.path) as f:
            return json.load(f)


class TestScheduleWindow(RingBase):
    def wants(self, off, on, now):
        return self.mod.ring_schedule_wants_on({"off": off, "on": on}, now)

    def test_overnight_window_wraps_midnight(self):
        # 23:00 -> 07:00, the night-mode case
        self.assertTrue(self.wants("23:00", "07:00", at(22, 59)))
        self.assertFalse(self.wants("23:00", "07:00", at(23, 0)))
        self.assertFalse(self.wants("23:00", "07:00", at(3, 0)))
        self.assertFalse(self.wants("23:00", "07:00", at(6, 59)))
        self.assertTrue(self.wants("23:00", "07:00", at(7, 0)))

    def test_daytime_window(self):
        self.assertTrue(self.wants("09:00", "17:00", at(8, 59)))
        self.assertFalse(self.wants("09:00", "17:00", at(9, 0)))
        self.assertFalse(self.wants("09:00", "17:00", at(16, 59)))
        self.assertTrue(self.wants("09:00", "17:00", at(17, 0)))

    def test_seconds_to_next_boundary(self):
        s = {"off": "23:00", "on": "07:00"}
        self.assertEqual(self.mod.ring_seconds_to_boundary(s, at(22, 59, 30)), 30)
        # right AT a boundary the next one is the other end, not zero
        self.assertEqual(self.mod.ring_seconds_to_boundary(s, at(23, 0)), 8 * 3600)
        self.assertEqual(self.mod.ring_seconds_to_boundary(s, at(12, 0)), 11 * 3600)


class TestRingSwitch(RingBase):
    def test_never_set_is_on_with_the_schedule_off(self):
        snap = self.ring().snapshot()
        self.assertEqual(snap, {"on": True, "clockSynced": True,
                                "schedule": {"enabled": False, "off": "23:00", "on": "07:00"}})
        self.assertFalse(os.path.exists(self.path))

    def test_off_darkens_nexusqd_and_persists(self):
        r = self.ring()
        snap = r.set_on({"on": False})
        self.assertFalse(snap["on"])
        self.assertEqual(self.nq.sent, ["dark 1"])
        self.assertEqual(self.stored()["on"], False)
        # and a fresh bridge (reboot / OTA restart) reads it back
        self.assertFalse(self.ring().snapshot()["on"])

    def test_manual_switch_disables_the_schedule(self):
        # Petr's rule: any manual switch turns the schedule off
        r = self.ring()
        r.set_schedule({"enabled": True, "off": "23:00", "on": "07:00"})
        snap = r.set_on({"on": False})
        self.assertFalse(snap["schedule"]["enabled"])
        # ...but keeps the times, so re-enabling does not lose them
        self.assertEqual((snap["schedule"]["off"], snap["schedule"]["on"]), ("23:00", "07:00"))

    def test_old_nexusqd_refuses_and_nothing_is_stored(self):
        self.nq.knows_dark = False
        r = self.ring()
        with self.assertRaises(self.mod.Err) as cm:
            r.set_on({"on": False})
        self.assertEqual(cm.exception.code, "unavailable")
        self.assertTrue(r.snapshot()["on"])
        self.assertFalse(os.path.exists(self.path))

    def test_bad_params(self):
        r = self.ring()
        for p in ({}, {"on": "false"}, {"on": 0}):
            with self.assertRaises(self.mod.Err) as cm:
                r.set_on(p)
            self.assertEqual(cm.exception.code, "bad_request")
        for p in ({"enabled": True, "off": "7:00"}, {"enabled": True, "off": "24:00"},
                  {"enabled": True, "on": "07:60"}, {"enabled": "yes"},
                  {"enabled": True, "off": "07:00", "on": "07:00"}):
            with self.assertRaises(self.mod.Err) as cm:
                r.set_schedule(p)
            self.assertEqual(cm.exception.code, "bad_request", p)
        self.assertEqual(self.nq.sent, [])

    def test_torn_file_reads_as_never_set(self):
        os.makedirs(os.path.dirname(self.path))
        for body in ('{"on": "no"}', '[]', '{"o', '',
                     '{"on": false, "schedule": {"enabled": true, "off": "25:00", "on": "07:00"}}'):
            with open(self.path, "w") as f:
                f.write(body)
            snap = self.ring().snapshot()
            self.assertFalse(snap["schedule"]["enabled"], body)
        # a valid `on` survives a torn schedule next to it
        self.assertFalse(snap["on"])

    def test_persist_failure_is_unavailable(self):
        r = self.ring()
        with mock.patch.object(self.mod.os, "replace", side_effect=OSError("ro fs")):
            with self.assertRaises(self.mod.Err) as cm:
                r.set_on({"on": False})
        self.assertEqual(cm.exception.code, "unavailable")


class TestScheduler(RingBase):
    def test_enabling_applies_the_schedule_at_once(self):
        self.now = at(23, 30)
        snap = self.ring().set_schedule({"enabled": True, "off": "23:00", "on": "07:00"})
        self.assertFalse(snap["on"])
        self.assertEqual(self.nq.sent, ["dark 1"])

    def test_tick_follows_the_clock_and_broadcasts(self):
        self.now = at(22, 59, 45)
        r = self.ring()
        r.set_schedule({"enabled": True, "off": "23:00", "on": "07:00"})
        self.assertEqual(r.tick(), 15.5)       # wakes just past the boundary, not up to 30 s late
        self.assertEqual(self.events, [])
        self.now = at(23, 0, 1)
        r.tick()
        self.assertEqual(len(self.events), 1)
        self.assertFalse(self.events[0]["on"])
        self.assertEqual(self.nq.sent[-1], "dark 1")
        self.assertFalse(self.stored()["on"])
        self.now = at(7, 0, 1)
        r.tick()
        self.assertTrue(self.events[-1]["on"])
        self.assertEqual(self.nq.sent[-1], "dark 0")

    def test_every_tick_reasserts_for_a_restarted_nexusqd(self):
        # nexusqd holds `dark` in memory only; the re-assert is what brings a
        # restarted nexusqd (or a boot) back to the user's setting.
        r = self.ring()
        r.set_on({"on": False})
        self.nq.sent.clear()
        self.assertEqual(r.tick(), self.mod.RING_REASSERT_S)
        r.tick()
        self.assertEqual(self.nq.sent, ["dark 1", "dark 1"])
        self.assertEqual(self.events, [])   # nothing the app shows changed

    def test_unsynced_clock_never_switches(self):
        # after a mains unplug the RTC is wrong until NTP; a schedule acting on
        # it would switch the ring at random
        self.is_synced = False
        self.now = at(3, 0)                  # "night" on a clock nobody trusts
        r = self.ring()
        snap = r.set_schedule({"enabled": True, "off": "23:00", "on": "07:00"})
        self.assertTrue(snap["on"])
        self.assertFalse(snap["clockSynced"])
        r.tick()
        self.assertTrue(r.snapshot()["on"])
        # NTP arrives: the schedule takes over, and the app hears about both
        self.is_synced = True
        r.tick()
        self.assertFalse(self.events[-1]["on"])
        self.assertTrue(self.events[-1]["clockSynced"])


if __name__ == "__main__":
    unittest.main()
