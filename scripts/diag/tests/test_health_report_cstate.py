"""Host tests for nq-health-report's C-state verdicts.

What is being protected: a CPU-latency QoS request that NEVER lets go keeps the
deep C-states from ever running while every counter looks merely quiet -- the BT
UART's 170 us did exactly that for weeks (docs/2026-09-20-sleep-states-design.md
4m). Since kernel r17 the states are armed on every boot, so a SHORT veto (BT
streaming) is ordinary and must not raise a warning, while the persistent one
still must.

Run from the repo root:
    python3 -m unittest discover -s scripts/diag/tests -v
"""

import importlib.machinery
import importlib.util
import os
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
loader = importlib.machinery.SourceFileLoader(
    "nq_health_report", os.path.join(HERE, "..", "nq-health-report"))
spec = importlib.util.spec_from_loader("nq_health_report", loader)
MOD = importlib.util.module_from_spec(spec)
loader.exec_module(MOD)


def rows(n, vetoed, armed="C2,C3"):
    """n healthd-like samples, the first `vetoed` of them under a 170 us QoS."""
    out = []
    for i in range(n):
        out.append({
            "t_mono": 100 + 5 * i, "temp_mC": 50000, "freq": 350000,
            "cstate_ms": {"C1": 500, "C2": 50, "C3": 4000},
            "cstate_armed": armed,
            "qos_us": 170 if i < vetoed else 4444,
        })
    return out


def kinds(rs):
    findings, _ = MOD.analyze(rs, [], "")
    return {f["kind"]: f["sev"] for f in findings}


class TestCstateVeto(unittest.TestCase):
    def test_no_veto_no_finding(self):
        k = kinds(rows(20, 0))
        self.assertNotIn("cstate_vetoed", k)
        self.assertNotIn("cstate_vetoed_transient", k)
        self.assertEqual(k["cstate_residency"], "info")

    def test_short_veto_is_info_not_warn(self):
        # BT streaming for a quarter of the window
        k = kinds(rows(20, 5))
        self.assertNotIn("cstate_vetoed", k)
        self.assertEqual(k["cstate_vetoed_transient"], "info")

    def test_persistent_veto_still_warns(self):
        # the failure this check exists for: the veto never lets go
        k = kinds(rows(20, 20))
        self.assertEqual(k["cstate_vetoed"], "warn")
        self.assertNotIn("cstate_vetoed_transient", k)

    def test_threshold_is_ninety_percent(self):
        self.assertEqual(kinds(rows(20, 18))["cstate_vetoed"], "warn")
        self.assertEqual(kinds(rows(20, 17))["cstate_vetoed_transient"], "info")

    def test_disarmed_states_are_never_vetoed(self):
        # a QoS below the exit latency means nothing when no deep state is armed
        k = kinds(rows(20, 20, armed=""))
        self.assertNotIn("cstate_vetoed", k)
        self.assertNotIn("cstate_vetoed_transient", k)


if __name__ == "__main__":
    unittest.main()
