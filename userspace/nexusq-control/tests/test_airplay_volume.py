"""The Q's volume back to an AirPlay sender (device r117).

The sender's slider sets the Q through shairport-sync's standard profile
(vol2attn) over the top 60 dB of the nexusq_vol control, whose dB is
PulseAudio's (60 log10 percent). The bridge pushes the other direction through
MPRIS SetVolume -> DACP, and the sender echoes that back -- so the inverse
must be exact, or each push would move the Q. Pinned here: the port of
vol2attn against values computed from shairport's own source, the inverse
round trip, the range floor, the settle, and the echo guard.
"""
import importlib.machinery
import importlib.util
import math
import os
import re
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
DAEMON = os.path.join(HERE, "..", "nexusq-control")
SHAIRPORT_CONF = os.path.join(HERE, "..", "..", "..", "pmos", "device-google-steelhead",
                              "shairport-sync.conf")


def load_daemon():
    spec = importlib.util.spec_from_loader(
        "nexusq_control", importlib.machinery.SourceFileLoader("nexusq_control", DAEMON))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


MOD = load_daemon()


def percent_of_cdb(cdb):
    return 100.0 * 10 ** (cdb / 6000.0)


class TestCurve(unittest.TestCase):
    def test_vol2attn_port(self):
        # shairport 5.1 common.c vol2attn, worked by hand for a 60 dB range:
        # lines {0,-3000}, {-5,-4500}, {-17,-6000} (cdB); the lowest one wins
        f = MOD.airplay_attn_cdb
        self.assertEqual(f(0.0), 0.0)
        self.assertEqual(f(-30.0), -6000.0)
        self.assertAlmostEqual(f(-15.0), min(-3000 * 15 / 30, -4500 * 10 / 25))   # -1800
        self.assertAlmostEqual(f(-3.0), -300.0)                                   # line 1 only
        self.assertAlmostEqual(f(-20.0), min(-2000.0, -2700.0, -6000 * 3 / 13))
        self.assertEqual(f(-144.0), -6000.0)            # AirPlay mute -> the floor

    def test_half_is_half(self):
        # why a 60 dB range: the iPhone's half-way is the app's 50 %
        self.assertAlmostEqual(percent_of_cdb(MOD.airplay_attn_cdb(-15.0)), 50.1, places=1)

    def test_inverse_round_trip(self):
        for p in range(10, 101):
            a = MOD.airplay_volume_for_percent(p)
            self.assertIsNotNone(a, p)
            self.assertTrue(-30.0 <= a <= 0.0)
            back = percent_of_cdb(MOD.airplay_attn_cdb(a))
            self.assertAlmostEqual(back, p, delta=0.01, msg=f"{p}% -> a={a}")

    def test_below_the_floor_is_not_expressible(self):
        for p in (0, 1, 5, 9):
            self.assertIsNone(MOD.airplay_volume_for_percent(p))

    def test_range_matches_shairport_conf(self):
        with open(SHAIRPORT_CONF) as f:
            m = re.search(r"^\s*volume_range_db\s*=\s*(\d+)\s*;", f.read(), re.M)
        self.assertIsNotNone(m, "volume_range_db not set in shairport-sync.conf")
        self.assertEqual(int(m.group(1)) * 100, MOD.AIRPLAY_RANGE_CDB)


class TestFollow(unittest.TestCase):
    def make(self, session=True, sender=None):
        self.pushed = []
        self.sender = sender
        return MOD.AirPlayVolumeFollow(session=lambda: session,
                                       sender_volume=lambda: self.sender,
                                       push=self.pushed.append, settle_s=60)

    def test_pushes_the_settled_value_only(self):
        f = self.make(sender=-15.0)
        for p in (40, 45, 52):
            f.volume_changed(p)
        a = f.settled()                  # the timer, fired by hand
        self.assertEqual(self.pushed, [a])
        self.assertAlmostEqual(percent_of_cdb(MOD.airplay_attn_cdb(a)), 52, delta=0.01)
        f._timer and f._timer.cancel()

    def test_no_session_no_push(self):
        f = self.make(session=False)
        f.volume_changed(50)
        self.assertIsNone(f.settled())
        self.assertEqual(self.pushed, [])

    def test_a_change_from_the_sender_is_not_echoed_back(self):
        a = MOD.airplay_volume_for_percent(63)
        f = self.make(sender=a)
        f.volume_changed(63)
        self.assertIsNone(f.settled())
        self.assertEqual(self.pushed, [])

    def test_below_the_floor_is_left_alone(self):
        f = self.make(sender=-10.0)
        f.volume_changed(4)
        self.assertIsNone(f.settled())
        self.assertEqual(self.pushed, [])

    def test_mute_is_not_a_volume(self):
        f = self.make(sender=-10.0)
        f.volume_changed(40, muted=True)
        self.assertIsNone(f._timer)
        self.assertEqual(self.pushed, [])


if __name__ == "__main__":
    unittest.main()
