"""Ambient brightness (nexusq-control r50): the slider is the maximum, the sun
decides how much of it the ring gets.

The solar maths is checked against things that do not depend on this code:
the geometry of the equinoxes and solstices (noon elevation = 90 - lat + decl),
and Prague's published sunrise/sunset. The rules are Petr's (2026-09-23): full
by day, a gradual fade through dusk, never dark.
"""
import datetime
import importlib.machinery
import importlib.util
import json
import os
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
DAEMON = os.path.join(HERE, "..", "nexusq-control")
UTC = datetime.timezone.utc
PRAGUE = ("Europe/Prague", 50.0833, 14.4333)     # zone.tab: +5005+01426


def load_daemon():
    spec = importlib.util.spec_from_loader(
        "nexusq_control", importlib.machinery.SourceFileLoader("nexusq_control", DAEMON))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


MOD = load_daemon()


def utc(y, mo, d, h, mi=0):
    return datetime.datetime(y, mo, d, h, mi, tzinfo=UTC)


def solar_noon_elev(lat, lon, day):
    """Max elevation over the day, found by scanning — independent of how the
    code computes its hour angle."""
    return max(MOD.sun_elevation(lat, lon, day + datetime.timedelta(minutes=m))
               for m in range(0, 24 * 60, 2))


class TestSunElevation(unittest.TestCase):
    def test_noon_elevation_follows_the_seasons(self):
        lat, lon = PRAGUE[1], PRAGUE[2]
        # equinox: 90 - lat; solstices: +/- 23.44
        self.assertAlmostEqual(solar_noon_elev(lat, lon, utc(2026, 3, 20, 0)), 90 - lat, delta=0.6)
        self.assertAlmostEqual(solar_noon_elev(lat, lon, utc(2026, 6, 21, 0)), 90 - lat + 23.44, delta=0.3)
        self.assertAlmostEqual(solar_noon_elev(lat, lon, utc(2026, 12, 21, 0)), 90 - lat - 23.44, delta=0.3)

    def test_prague_sunrise_and_sunset(self):
        # 2026-09-22, Prague: sunrise ~06:48 CEST (04:48 UTC), sunset ~19:00 CEST
        # (17:00 UTC). At the published times the sun's centre is at about
        # -0.83 deg (refraction + the disc's radius); allow a few minutes.
        lat, lon = PRAGUE[1], PRAGUE[2]
        self.assertAlmostEqual(MOD.sun_elevation(lat, lon, utc(2026, 9, 22, 4, 48)), -0.83, delta=1.0)
        self.assertAlmostEqual(MOD.sun_elevation(lat, lon, utc(2026, 9, 22, 17, 0)), -0.83, delta=1.0)

    def test_the_southern_hemisphere_and_the_west_work_too(self):
        # Sydney, June solstice: winter, noon ~ 90 - 33.87 - 23.44
        self.assertAlmostEqual(solar_noon_elev(-33.87, 151.21, utc(2026, 6, 21, 0) - datetime.timedelta(hours=12)),
                               90 - 33.87 - 23.44, delta=0.4)
        # New York at 17:00 UTC (noon EST) in March: high, and midnight: deep
        self.assertGreater(MOD.sun_elevation(40.71, -74.01, utc(2026, 3, 20, 17)), 40)
        self.assertLess(MOD.sun_elevation(40.71, -74.01, utc(2026, 3, 21, 5)), -30)


class TestCurve(unittest.TestCase):
    def test_full_by_day_quarter_by_night(self):
        self.assertEqual(MOD.ambient_level(200, 30.0), 200)
        self.assertEqual(MOD.ambient_level(200, MOD.AMBIENT_DAY_ELEV), 200)
        self.assertEqual(MOD.ambient_level(200, -30.0), 50)
        self.assertEqual(MOD.ambient_level(200, MOD.AMBIENT_NIGHT_ELEV), 50)

    def test_dusk_fades_monotonically_with_no_jump(self):
        levels = [MOD.ambient_level(255, e / 10) for e in range(60, -121, -1)]
        self.assertEqual(levels, sorted(levels, reverse=True), "the fade reverses somewhere")
        steps = [a - b for a, b in zip(levels, levels[1:])]
        self.assertLessEqual(max(steps), 3, "a visible jump inside the fade")

    def test_never_dark(self):
        # a low maximum still keeps a visible floor at night...
        self.assertEqual(MOD.ambient_level(20, -40.0), MOD.AMBIENT_MIN_LEVEL)
        # ...but never above what the user set
        self.assertEqual(MOD.ambient_level(3, -40.0), 3)
        self.assertEqual(MOD.ambient_level(0, 20.0), 0)


class TestZoneLocation(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        with open(os.path.join(self.tmp.name, "zone.tab"), "w") as f:
            f.write("# comment\n"
                    "CZ\t+5005+01426\tEurope/Prague\n"
                    "SK\t+4809+01707\tEurope/Bratislava\n"
                    "US\t+404251-0740023\tAmerica/New_York\tEastern (most areas)\n"
                    "AU\t-3352+15113\tAustralia/Sydney\tNew South Wales (most areas)\n")

    def test_minutes_and_seconds_and_signs(self):
        lat, lon = MOD.zone_location("Europe/Prague", self.tmp.name)
        self.assertAlmostEqual(lat, 50 + 5 / 60, places=4)
        self.assertAlmostEqual(lon, 14 + 26 / 60, places=4)
        lat, lon = MOD.zone_location("America/New_York", self.tmp.name)
        self.assertAlmostEqual(lat, 40 + 42 / 60 + 51 / 3600, places=4)
        self.assertAlmostEqual(lon, -(74 + 0 / 60 + 23 / 3600), places=4)
        lat, lon = MOD.zone_location("Australia/Sydney", self.tmp.name)
        self.assertLess(lat, 0)

    def test_unknown_zone_is_none(self):
        self.assertIsNone(MOD.zone_location("Mars/Olympus", self.tmp.name))
        self.assertIsNone(MOD.zone_location("Europe/Prague", os.path.join(self.tmp.name, "nope")))

    def test_the_real_tzdata_knows_prague(self):
        if not os.path.exists("/usr/share/zoneinfo/zone.tab"):
            self.skipTest("no tzdata on this host")
        lat, lon = MOD.zone_location("Europe/Prague", "/usr/share/zoneinfo")
        self.assertAlmostEqual(lat, 50.08, delta=0.01)


class FakeNexusqd:
    def __init__(self, ok=True):
        self.sent, self.ok = [], ok

    def __call__(self, line):
        self.sent.append(line)
        return self.ok


class TestBrightness(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.path = os.path.join(self.tmp.name, "brightness.json")
        self.now = utc(2026, 9, 22, 11)          # midday in Prague
        self.is_synced = True
        self.nq = FakeNexusqd()
        self.events = []

    def b(self, location=PRAGUE):
        return MOD.Brightness(path=self.path, send=self.nq, clock=lambda: self.now,
                              synced=lambda: self.is_synced, location=location,
                              on_change=self.events.append)

    def test_off_is_exactly_the_old_behaviour(self):
        b = self.b()
        b.set_max(180)
        self.now = utc(2026, 9, 22, 23)          # night: still 180
        b.tick()
        self.assertEqual(self.nq.sent[-1], "brightness 180")
        self.assertEqual(self.events, [])

    def test_the_slider_is_persistent(self):
        # it used to reset to 255 on every bridge restart
        self.b().set_max(120)
        self.assertEqual(self.b().maximum(), 120)
        with open(self.path) as f:
            self.assertEqual(json.load(f), {"max": 120, "ambient": False})

    def test_ambient_follows_the_sun_under_the_maximum(self):
        b = self.b()
        b.set_max(200)
        self.assertEqual(b.set_ambient({"enabled": True})["level"], 200)   # midday
        self.now = utc(2026, 9, 22, 22)          # well after dusk
        b.tick()
        self.assertEqual(self.nq.sent[-1], "brightness 50")
        self.assertEqual(self.events[-1]["level"], 50)
        # moving the slider at night moves the MAXIMUM, the level follows
        mx, snap = b.set_max(100)
        self.assertEqual((mx, snap["level"]), (100, 25))
        self.assertEqual(self.nq.sent[-1], "brightness 25")

    def test_dusk_is_gradual_minute_by_minute(self):
        b = self.b()
        b.set_ambient({"enabled": True})
        levels = []
        for m in range(16 * 60, 19 * 60 + 1, 5):   # 16:00 -> 19:00 UTC, through dusk
            self.now = utc(2026, 9, 22, 0) + datetime.timedelta(minutes=m)
            b.tick()
            levels.append(int(self.nq.sent[-1].split()[1]))
        self.assertEqual(levels[0], 255)
        self.assertEqual(levels[-1], 64)          # 255 * 0.25, rounded
        self.assertEqual(levels, sorted(levels, reverse=True))
        self.assertLessEqual(max(a - b for a, b in zip(levels, levels[1:])), 15,
                             "a 5-minute step this large would be a visible jump")

    def test_an_untrusted_clock_never_dims(self):
        self.is_synced = False
        self.now = utc(2026, 9, 22, 23)          # "night" on a clock nobody trusts
        b = self.b()
        snap = b.set_ambient({"enabled": True})
        self.assertEqual(snap["level"], 255)
        self.assertFalse(snap["clockSynced"])
        self.is_synced = True
        b.tick()
        self.assertEqual(self.events[-1]["level"], 64)

    def test_no_location_refuses_ambient(self):
        b = self.b(location=())
        with self.assertRaises(MOD.Err) as cm:
            b.set_ambient({"enabled": True})
        self.assertEqual(cm.exception.code, "unavailable")
        self.assertIsNone(b.snapshot()["location"])

    def test_old_nexusqd_refusal_stores_nothing(self):
        self.nq.ok = False
        with self.assertRaises(MOD.Err):
            self.b().set_max(10)
        self.assertFalse(os.path.exists(self.path))

    def test_every_tick_reasserts_for_a_restarted_nexusqd(self):
        b = self.b()
        b.set_max(90)
        self.nq.sent.clear()
        b.tick()
        b.tick()
        self.assertEqual(self.nq.sent, ["brightness 90", "brightness 90"])

    def test_torn_file_reads_as_default(self):
        for body in ('{"max": 300}', '{"max": "x", "ambient": 1}', '[', ''):
            with open(self.path, "w") as f:
                f.write(body)
            snap = self.b().snapshot()
            self.assertEqual(self.b().maximum(), 255, body)
            self.assertFalse(snap["enabled"], body)


if __name__ == "__main__":
    unittest.main()
