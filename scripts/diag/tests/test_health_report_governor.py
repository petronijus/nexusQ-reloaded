"""Host tests for nq-health-report's governor verdicts.

What is being protected: `governor_not_scaling` must mean the CPU was really
working while the frequency stayed at the lowest OPP. Until 2026-09-30 it read
the one-minute load average, which touched 1.0 at ~16 % utilization in an idle
night and raised the warning for nothing.

Run from the repo root:
    python3 -m unittest discover -s scripts/diag/tests -v
"""

import importlib.machinery
import importlib.util
import os
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
loader = importlib.machinery.SourceFileLoader("nq_health_report", os.path.join(HERE, "..", "nq-health-report"))
spec = importlib.util.spec_from_loader("nq_health_report", loader)
MOD = importlib.util.module_from_spec(spec)
loader.exec_module(MOD)

IDLE = 400  # ms busy of 10000 per 5 s sample: ~4 % of both cores


def rows(samples):
    """samples: (busy_ms, freq_kHz, load1) per 5 s healthd sample."""
    return [
        {"t_mono": 100 + 5 * i, "temp_mC": 50000, "gov": "conservative", "busy_ms": busy, "freq": freq, "load1": load}
        for i, (busy, freq, load) in enumerate(samples)
    ]


def kinds(rs):
    findings, _ = MOD.analyze(rs, [], "")
    return {f["kind"]: f["sev"] for f in findings}


class TestGovernor(unittest.TestCase):
    def test_a_load_average_blip_at_idle_is_not_a_stall(self):
        # the 2026-09-30 soak: load1 1.03 at 1620 ms busy, 350 MHz
        k = kinds(rows([(IDLE, 350000, 0.3)] * 20 + [(1620, 350000, 1.03)] + [(IDLE, 350000, 0.3)] * 20))
        self.assertNotIn("governor_not_scaling", k)

    def test_sustained_work_held_at_350_is_a_stall(self):
        k = kinds(rows([(IDLE, 350000, 0.3)] * 10 + [(4500, 350000, 1.2)] * 3 + [(IDLE, 350000, 0.3)] * 10))
        self.assertEqual(k.get("governor_not_scaling"), "warn")

    def test_two_busy_samples_are_not_yet_a_stall(self):
        k = kinds(rows([(IDLE, 350000, 0.3)] * 10 + [(4500, 350000, 1.2)] * 2 + [(IDLE, 350000, 0.3)] * 10))
        self.assertNotIn("governor_not_scaling", k)

    def test_work_the_governor_answered_is_not_a_stall(self):
        k = kinds(rows([(IDLE, 350000, 0.3)] * 10 + [(4500, 1200000, 1.2)] * 5 + [(IDLE, 350000, 0.3)] * 10))
        self.assertNotIn("governor_not_scaling", k)

    def test_sustained_work_that_never_reached_the_top_opp_is_noted(self):
        k = kinds(rows([(IDLE, 350000, 0.3)] * 10 + [(4500, 700000, 1.2)] * 4 + [(IDLE, 350000, 0.3)] * 10))
        self.assertNotIn("governor_not_scaling", k)
        self.assertEqual(k.get("governor_no_turbo"), "info")


if __name__ == "__main__":
    unittest.main()
