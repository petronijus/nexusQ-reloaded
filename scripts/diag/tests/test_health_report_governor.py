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


def opp_rows(samples):
    """samples: (busy_ms, nice_ms, spot freq kHz, opp_ms dict) per 5 s sample,
    as healthd >= device r124 writes them."""
    return [
        {
            "t_mono": 100 + 5 * i,
            "temp_mC": 50000,
            "gov": "conservative",
            "busy_ms": busy,
            "nice_ms": nice,
            "freq": freq,
            "opp_ms": {str(k): v for k, v in opp.items()},
            "load1": 1.0,
        }
        for i, (busy, nice, freq, opp) in enumerate(samples)
    ]


AT_350 = {350000: 5000}
MOSTLY_1200 = {350000: 80, 1200000: 4650}


class TestGovernorResidency(unittest.TestCase):
    """The 2026-09-30 install window (`nice apk add`, mkinitfs) raised
    governor_not_scaling twice over: the spot freq read 350 MHz while opp_ms
    had the CPU at 1.2 GHz, and the rest of the busy time was niced work,
    which ignore_nice_load=1 keeps at 350 MHz on purpose."""

    def test_spot_350_while_opp_ms_says_1200_is_not_a_stall(self):
        k = kinds(opp_rows([(8000, 0, 350000, MOSTLY_1200)] * 5))
        self.assertNotIn("governor_not_scaling", k)

    def test_niced_work_held_at_350_is_not_a_stall(self):
        k = kinds(opp_rows([(9000, 8700, 350000, AT_350)] * 5))
        self.assertNotIn("governor_not_scaling", k)
        self.assertNotIn("governor_no_turbo", k)

    def test_unniced_work_held_at_350_by_opp_ms_is_a_stall(self):
        k = kinds(opp_rows([(9000, 500, 350000, AT_350)] * 3))
        self.assertEqual(k.get("governor_not_scaling"), "warn")

    def test_a_burst_to_1200_between_spot_readings_counts_as_reaching_the_top(self):
        k = kinds(opp_rows([(4500, 0, 700000, {700000: 4800, 1200000: 200})] * 4))
        self.assertNotIn("governor_no_turbo", k)


class TestEventWindow(unittest.TestCase):
    def test_events_are_placed_by_wall_time_and_older_ones_are_counted_not_guessed(self):
        evs = [
            {"t_mono": 7537, "kind": "vdd_mismatch"},  # before device r124: no wall
            {"t_mono": 40, "kind": "a", "wall": "2026-09-30T12:33:40Z"},
            {"t_mono": 9000, "kind": "b", "wall": "2026-09-30T10:00:00Z"},
        ]
        since = MOD.parse_when("2026-09-30T12:33:00Z")
        placed, unplaced = MOD.events_in_window(evs, since, None)
        self.assertEqual([e["kind"] for e in placed], ["a"])
        self.assertEqual(unplaced, 1)
        self.assertEqual(MOD.events_in_window(evs), (evs, 0))


if __name__ == "__main__":
    unittest.main()
