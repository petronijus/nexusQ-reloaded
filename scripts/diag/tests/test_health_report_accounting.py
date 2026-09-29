"""Host tests for nq-health-report's CPU accounting (healthd >= device r119).

What is being protected: an overnight soak read from health.jsonl alone must
say what the box spent, per service, and how often nexusqd and the ambient
scheduler worked -- and must not be fooled by a daemon restarting in the
window, by the minute-only unit map, or by music played during it.

Run from the repo root:
    python3 -m unittest discover -s scripts/diag/tests -v
"""

import importlib.machinery
import importlib.util
import os
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
loader = importlib.machinery.SourceFileLoader("nq_health_report_acct", os.path.join(HERE, "..", "nq-health-report"))
spec = importlib.util.spec_from_loader("nq_health_report_acct", loader)
MOD = importlib.util.module_from_spec(spec)
loader.exec_module(MOD)


def night(n=120, busy_ms=100, pulse_us=6000, librespot_us=0, wake_every=12, pid=7):
    """n five-second samples; unit_us on every 12th, like healthd."""
    rows = []
    for i in range(n):
        r = {
            "t_mono": 1000 + 5 * i,
            "wall": "2026-09-28T%02d:%02d:%02dZ" % ((i * 5) // 3600, (i * 5) // 60 % 60, (i * 5) % 60),
            "temp_mC": 45000,
            "freq": 350000,
            "busy_ms": busy_ms,
            "forks": 2,
            "irqs": 400,
            "nq_pid": pid,
            "nq_renders": 5 * i,
            "nq_ctl": i // 3,
            "ambient_wakes": i // wake_every,
            "tap_fixes": 0,
        }
        if i % 12 == 0:
            r["unit_us"] = {"nexusq-control": 60000, "pulseaudio": pulse_us}
            if librespot_us:
                r["unit_us"]["librespot"] = librespot_us
        rows.append(r)
    return rows


class TestAccounting(unittest.TestCase):
    def test_the_night_in_numbers(self):
        a = MOD.accounting(night(), 5)
        # 100 ms per 5 s interval, over 2 cores = 1 %
        self.assertAlmostEqual(a["busy_pct_of_2_cores"], 1.0)
        self.assertAlmostEqual(a["forks_per_min"], 24.0)
        self.assertAlmostEqual(a["irqs_per_s"], 80.0)
        # 60 ms per 60 s minute = 0.1 % of a core
        self.assertAlmostEqual(a["unit_pct_of_1_core"]["nexusq-control"], 0.1)
        self.assertAlmostEqual(a["nexusqd_renders_per_s"], 5 * 119 / 600)
        self.assertEqual(a["ambient_wakes"], 119 // 12)

    def test_a_restarted_daemon_is_counted_in_both_lives(self):
        rows = night(60) + night(60, pid=8)  # nexusqd restarted, counters from 0
        for i, r in enumerate(rows):
            r["t_mono"] = 1000 + 5 * i
        a = MOD.accounting(rows, 5)
        self.assertAlmostEqual(a["nexusqd_renders_per_s"], (5 * 59 * 2) / 600)
        # the bridge restarted too (ambient_wakes fell): both lives, never negative
        self.assertEqual(a["ambient_wakes"], 2 * (59 // 12))

    def test_no_accounting_on_an_older_healthd(self):
        rows = [{"t_mono": 5 * i, "temp_mC": 40000} for i in range(10)]
        self.assertIsNone(MOD.accounting(rows, 5))


class TestVerdicts(unittest.TestCase):
    def kinds(self, rows):
        findings, _ = MOD.analyze(rows, [], "")
        return {f["kind"]: f for f in findings}

    def test_an_idle_night_is_not_flagged(self):
        k = self.kinds(night())
        self.assertIn("cpu_busy", k)
        self.assertIn("ambient_wakes", k)
        self.assertNotIn("window_not_idle", k)

    def test_music_in_the_window_is_flagged(self):
        k = self.kinds(night(librespot_us=3_000_000))  # 5 % of a core
        self.assertEqual(k["window_not_idle"]["sev"], "warn")


class TestWindow(unittest.TestCase):
    def test_since_until_select_by_wall_clock(self):
        rows = night(720)  # one hour
        got = MOD.in_window(rows, MOD.parse_when("2026-09-28T00:10:00Z"), MOD.parse_when("2026-09-28T00:20:00Z"))
        self.assertEqual(len(got), 120)
        self.assertEqual(got[0]["wall"], "2026-09-28T00:10:00Z")

    def test_a_time_without_a_zone_is_local(self):
        t = MOD.parse_when("2026-09-28T01:30")
        self.assertIsNotNone(t.tzinfo)


if __name__ == "__main__":
    unittest.main()
