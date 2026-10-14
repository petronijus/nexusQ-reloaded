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
        # The 4460 default without the 0062 DT block (dpll_core_m7x2_ck).
        f, _ = MOD.analyze(rows(10, 0), [], SNAP.format(hz="266666667"))
        self.assertEqual(kinds(f)["gpu_clock"]["sev"], "warn")

    def test_another_opp_without_a_devfreq_block_is_info(self):
        # Kernel r31 (DVFS) under a device r129 snapshot, which has no devfreq
        # block: an idle GPU at 153.6 MHz is not a fault.
        for hz in ("153600000", "384000000"):
            f, _ = MOD.analyze(rows(10, 0), [], SNAP.format(hz=hz))
            self.assertEqual(kinds(f)["gpu_clock"]["sev"], "info", hz)


# The same section from a kernel with GPU DVFS (r31) and a device r130 snapshot.
SNAP_DVFS = """
==================== GPU_SGX540 ====================

--- gpu devfreq ---
device=56000000.gpu
governor=simple_ondemand
cur_freq={hz}

--- vdd_core / gpu clock / vdd_core ---
microvolts_before={before}
clk_rate={hz}
microvolts_after={after}

--- gpu clock ---
             dpll_per_m7x2_ck        0       1        0        {hz}   0          0     50000      Y
                l3-gfx-clkctrl:0000:24 0       1        0        {hz}   0          0     50000      Y

########## SNAPSHOT END ##########
"""


def dvfs_snap(hz, before=1139440, after=1139440):
    return SNAP_DVFS.format(hz=hz, before=before, after=after)


class GpuDvfs(unittest.TestCase):
    def test_every_opp_is_quiet(self):
        for hz in MOD.GPU_OPP_HZ:
            uv = 1253380 if hz == MOD.GPU_OV_HZ else 1139440
            f, _ = MOD.analyze(rows(10, 0), [], dvfs_snap(hz, uv, uv))
            self.assertFalse({"gpu_clock", "gpu_vdd_core"} & set(kinds(f)), hz)

    def test_a_rate_outside_the_table_is_a_warning(self):
        f, _ = MOD.analyze(rows(10, 0), [], dvfs_snap("266666667"))
        self.assertIn("gpu_clock", kinds(f))

    def test_384_mhz_on_the_low_rail_is_critical(self):
        f, _ = MOD.analyze(rows(10, 0), [], dvfs_snap("384000000"))
        k = kinds(f)
        self.assertIn("gpu_vdd_core", k)
        self.assertEqual(k["gpu_vdd_core"]["sev"], "crit")

    def test_a_step_between_the_reads_is_not_a_fault(self):
        # Down: 384 MHz read, then clock and rail drop before the second read.
        # Up: the first read is from before the rail rose.
        for before, after in ((1253380, 1139440), (1139440, 1253380)):
            f, _ = MOD.analyze(rows(10, 0), [], dvfs_snap("384000000", before, after))
            self.assertNotIn("gpu_vdd_core", kinds(f), (before, after))

    def test_residency_goes_into_the_gpu_line(self):
        r = rows(4, 300)
        for i, x in enumerate(r):
            x["gpu_freq"] = 384000000
            x["gpu_freq_ms"] = {} if i == 0 else {"153600000": 1000, "307200000": 1000, "384000000": 3000}
            x["gpu_trans"] = -1 if i == 0 else 2
        f, s = MOD.analyze(r, [], "")
        self.assertEqual(s["gpu"]["freq_ms"], {"153600000": 3000, "307200000": 3000, "384000000": 9000})
        self.assertEqual(s["gpu"]["freq_trans"], 6)
        self.assertIn("DVFS 153.6 MHz 20.0%, 307.2 MHz 20.0%, 384 MHz 60.0% (6 transitions)", kinds(f)["gpu"]["msg"])

    def test_capture_without_dvfs_fields_has_no_dvfs_text(self):
        f, s = MOD.analyze(rows(10, 300), [], "")
        self.assertIsNone(s["gpu"]["freq_ms"])
        self.assertNotIn("DVFS", kinds(f)["gpu"]["msg"])


if __name__ == "__main__":
    unittest.main()
