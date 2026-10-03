"""Host tests for nq-health-report's memory trend (mem.jsonl, healthd >= device r125).

What is being protected: days of mem.jsonl must name the service whose
anonymous memory grows, must not mistake a service restart or a GC for a
trend, must keep to the newest boot, must not claim a trend from a window too
short to tell a leak from churn, and must warn only when the growth would
actually exhaust memory soon.

Run from the repo root:
    python3 -m unittest discover -s scripts/diag/tests -v
"""

import importlib.machinery
import importlib.util
import os
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
loader = importlib.machinery.SourceFileLoader("nq_health_report_mem", os.path.join(HERE, "..", "nq-health-report"))
spec = importlib.util.spec_from_loader("nq_health_report_mem", loader)
MOD = importlib.util.module_from_spec(spec)
loader.exec_module(MOD)


def mem_log(hours=72, roon_kb_h=300, avail=780000, boot="b1", t0=300, mqtt_kb_h=0, mqtt_restart_h=None):
    """One record per 10 min, shaped like healthd's. Roon grows linearly under
    a GC sawtooth, nexusq-control wobbles around a flat line, nexusq-mqtt
    grows at mqtt_kb_h and optionally restarts (back to its startup size)."""
    rows = []
    for i in range(int(hours * 6) + 1):
        h = i / 6.0
        roon = int(60000 + roon_kb_h * h + (3000 if i % 7 < 3 else -3000))
        ctl = 15000 + (400 if i % 2 else -400)
        since = h if mqtt_restart_h is None or h < mqtt_restart_h else h - mqtt_restart_h
        mqtt = int(2500 + mqtt_kb_h * since)
        units = {"system.slice": 52000 + mqtt, "user.slice": 80000 + roon - 60000, "init.scope": 4300}
        units.update({"nexusq-control": ctl, "nexusq-mqtt": mqtt, "roon": roon})
        rows.append(
            {
                "t_mono": t0 + i * 600,
                "wall": "2026-10-01T00:00:00Z",
                "boot_id": boot,
                "mem_avail_kB": int(avail - roon_kb_h * h),
                "anon_kB": int(140000 + roon_kb_h * h),
                "shmem_kB": 27600,
                "unit_anon_kB": units,
            }
        )
    return rows


class TestPieces(unittest.TestCase):
    def test_slope_is_per_hour(self):
        self.assertAlmostEqual(MOD.slope_per_h([(0, 100), (3600, 150), (7200, 200)]), 50.0)
        self.assertIsNone(MOD.slope_per_h([(5, 1)]))
        self.assertIsNone(MOD.slope_per_h([(5, 1), (5, 2)]))

    def test_restart_starts_a_new_series(self):
        pts = [(0, 8000), (1, 8100), (2, 2500), (3, 2600)]
        self.assertEqual(MOD.since_restart(pts), [(2, 2500), (3, 2600)])
        pts = [(0, 8000), (1, None), (2, 7000), (3, 7100)]
        self.assertEqual(MOD.since_restart(pts), [(2, 7000), (3, 7100)])
        # a GC that gives back a third is not a restart
        pts = [(0, 9000), (1, 6000), (2, 9100)]
        self.assertEqual(MOD.since_restart(pts), pts)

    def test_newest_boot_only(self):
        rows = mem_log(hours=5, boot="old") + mem_log(hours=4, boot="new")
        self.assertEqual({r["boot_id"] for r in MOD.last_boot(rows)}, {"new"})
        # without boot_id (health.jsonl), t_mono going backwards is the boot
        rows = [{"t_mono": t} for t in (100, 200, 300, 50, 60)]
        self.assertEqual([r["t_mono"] for r in MOD.last_boot(rows)], [50, 60])


class TestTrend(unittest.TestCase):
    def test_names_the_grower(self):
        m = MOD.memory_trend(mem_log(), [])
        self.assertEqual(m["source"], "mem.jsonl")
        self.assertAlmostEqual(m["anon_kB_per_h"], 300, delta=1)
        self.assertEqual(list(m["growers_kB_per_h"]), ["roon"])
        self.assertAlmostEqual(m["growers_kB_per_h"]["roon"], 300, delta=15)
        self.assertIn("user.slice", m["slices_kB_per_h"])
        self.assertNotIn("roon", m["slices_kB_per_h"])

    def test_a_restart_does_not_hide_a_leak(self):
        # leaking 200 kB/h, restarted at 40 h: fitted across the restart the
        # series reads as shrinking; since the restart it is the leak it is
        m = MOD.memory_trend(mem_log(mqtt_kb_h=200, mqtt_restart_h=40), [])
        self.assertAlmostEqual(m["growers_kB_per_h"]["nexusq-mqtt"], 200, delta=1)
        # a flat service that restarts is not a grower either way
        m = MOD.memory_trend(mem_log(mqtt_restart_h=40), [])
        self.assertNotIn("nexusq-mqtt", m["growers_kB_per_h"])

    def test_short_window_claims_nothing(self):
        m = MOD.memory_trend(mem_log(hours=2), [])
        self.assertNotIn("anon_kB_per_h", m)
        findings, _ = MOD.analyze([], [], "", mem_log(hours=2))
        self.assertEqual([f["kind"] for f in findings if f["kind"].startswith("mem")], [])

    def test_slow_leak_is_info_fast_one_warns(self):
        def kinds(rows):
            health = [{"t_mono": r["t_mono"], "temp_mC": 50000, "freq": 350000} for r in rows]
            findings, summary = MOD.analyze(health, [], "", rows)
            return {f["kind"]: f for f in findings}, summary

        # the 2026-10-03 rate: ~0.3 MB/h against 780 MB lasts 100+ days
        k, summary = kinds(mem_log())
        self.assertIn("mem_trend", k)
        self.assertNotIn("mem_growth", k)
        self.assertIn("roon", k["mem_trend"]["msg"])
        self.assertGreater(summary["memory"]["days_to_exhaustion"], 100)
        # 4 MB/h against 780 MB: gone in ~8 days
        k, _ = kinds(mem_log(roon_kb_h=4096))
        self.assertEqual(k["mem_growth"]["sev"], "warn")
        self.assertIn("roon", k["mem_growth"]["msg"])
        # the same rate seen for only 4 h is not enough to warn on
        k, _ = kinds(mem_log(hours=4, roon_kb_h=4096))
        self.assertNotIn("mem_growth", k)

    def test_a_field_younger_than_the_window_claims_nothing(self):
        # health.jsonl right after the upgrade to r125: 13.8 h without anon_kB,
        # then 2 minutes with it, one of them a transient spike. The window is
        # long enough; the anon series is not, so no slope and no warning.
        rows = [{"t_mono": 100 + 5 * i, "mem_avail_kB": 760000} for i in range(9936)]
        t = rows[-1]["t_mono"]
        for j, kb in enumerate([140000, 141000, 165000, 141500, 141600, 141700, 141800, 141900]):
            rows.append({"t_mono": t + 5 * (j + 1), "mem_avail_kB": 750000, "anon_kB": kb, "shmem_kB": 27600})
        m = MOD.memory_trend([], rows)
        self.assertGreater(m["span_h"], 13)
        self.assertIsNone(m["anon_kB_per_h"])
        self.assertIsNone(m["shmem_kB_per_h"])
        self.assertIsNone(m["days_to_exhaustion"])
        findings, _ = MOD.analyze(rows, [], "", [])
        self.assertNotIn("mem_growth", [f["kind"] for f in findings])

    def test_health_jsonl_fallback(self):
        rows = [{"t_mono": 100 + 5 * i, "mem_avail_kB": 780000 - i, "anon_kB": 140000 + i} for i in range(0, 4000, 10)]
        m = MOD.memory_trend([], rows)
        self.assertEqual(m["source"], "health.jsonl")
        self.assertAlmostEqual(m["anon_kB_per_h"], 720, delta=1)
        self.assertEqual(m["growers_kB_per_h"], {})


if __name__ == "__main__":
    unittest.main()
