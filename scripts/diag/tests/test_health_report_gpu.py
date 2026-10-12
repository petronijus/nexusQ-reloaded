"""Host tests for nq-health-report's SGX540 findings (healthd >= device r129).

What is being protected: the GPU's power only stays off while nothing renders
if runtime PM and the DDK's APM both let go. A regression that keeps the GPU
target module awake costs leakage on an idle box and shows nowhere else: the
desktop still draws, the CPU counters stay quiet. The report must flag a GPU
that never sleeps and one that is awake with nothing on HDMI, and must stay
quiet for an idle desktop and for a capture from an image without the fields.

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


def rows(n, active_ms, hdmi_on=1, drv=1, rpm="suspended"):
    """n healthd-like samples 5 s apart; active_ms is per sample (int or a function of i)."""
    out = []
    for i in range(n):
        a = active_ms(i) if callable(active_ms) else active_ms
        out.append(
            {
                "t_mono": 100 + 5 * i,
                "temp_mC": 60000 + (20000 if a else 0),
                "freq": 350000,
                "gpu_drv": drv,
                "gpu_rpm": "active" if a else rpm,
                "gpu_active_ms": -1 if i == 0 else a,
                "hdmi_on": hdmi_on,
            }
        )
    return out


def kinds(findings):
    return {f["kind"]: f for f in findings}


class GpuFindings(unittest.TestCase):
    def test_idle_desktop_is_info_only(self):
        # Desktop on HDMI, the GPU wakes briefly for a few redraws and sleeps.
        f, s = MOD.analyze(rows(240, lambda i: 300 if i % 60 == 1 else 0), [], "")
        k = kinds(f)
        self.assertIn("gpu", k)
        self.assertNotIn("gpu_never_sleeps", k)
        self.assertNotIn("gpu_awake_headless", k)
        self.assertLess(s["gpu"]["awake_pct"], 1.0)
        self.assertEqual([x for x in f if x["kind"].startswith("gpu") and x["sev"] != "info"], [])

    def test_gpu_that_never_sleeps_is_a_warning(self):
        # Awake the whole interval for 20 minutes.
        f, s = MOD.analyze(rows(240, 5000), [], "")
        k = kinds(f)
        self.assertIn("gpu_never_sleeps", k)
        self.assertEqual(k["gpu_never_sleeps"]["sev"], "warn")
        self.assertGreaterEqual(s["gpu"]["never_sleeps_s"], MOD.GPU_NEVER_SLEEPS_S)

    def test_short_rendering_burst_is_not_never_sleeps(self):
        # A five-minute benchmark, then idle: below the 10-minute threshold.
        f, _ = MOD.analyze(rows(240, lambda i: 5000 if i < 60 else 0), [], "")
        self.assertNotIn("gpu_never_sleeps", kinds(f))

    def test_awake_with_hdmi_off_is_a_warning(self):
        f, s = MOD.analyze(rows(60, lambda i: 400 if i % 3 == 0 else 0, hdmi_on=0), [], "")
        k = kinds(f)
        self.assertIn("gpu_awake_headless", k)
        self.assertGreater(s["gpu"]["headless_pct"], MOD.GPU_HEADLESS_PCT)

    def test_capture_without_gpu_fields_stays_silent(self):
        old = [{k: v for k, v in r.items() if not k.startswith("gpu_") and k != "hdmi_on"} for r in rows(60, 0)]
        f, s = MOD.analyze(old, [], "")
        self.assertFalse({"gpu", "gpu_never_sleeps", "gpu_awake_headless"} & set(kinds(f)))
        self.assertIsNone(s["gpu"])

    def test_driver_not_loaded_stays_silent(self):
        f, _ = MOD.analyze(rows(60, 0, drv=0, rpm="suspended"), [], "")
        self.assertNotIn("gpu", kinds(f))


SNAP = """
==================== GPU_SGX540 ====================

--- gpu clock ---
             dpll_per_m7x2_ck        0       1        0        307200000   0          0     50000      Y
                l3-gfx-clkctrl:0000:24 0       1        0        {hz}   0          0     50000      Y
             dpll_core_m7x2_ck       0       0        0        266666667   0          0     50000      Y

########## SNAPSHOT END ##########
"""


class GpuClock(unittest.TestCase):
    def test_stock_clock_is_quiet(self):
        f, _ = MOD.analyze(rows(10, 0), [], SNAP.format(hz="307200000"))
        self.assertNotIn("gpu_clock", kinds(f))

    def test_other_clock_is_a_warning(self):
        # The 4460 default without the 0062 DT block (dpll_core_m7x2_ck), and 384 MHz.
        for hz in ("266666667", "384000000"):
            f, _ = MOD.analyze(rows(10, 0), [], SNAP.format(hz=hz))
            self.assertIn("gpu_clock", kinds(f), hz)


if __name__ == "__main__":
    unittest.main()
