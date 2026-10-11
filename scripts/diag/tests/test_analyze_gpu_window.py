"""Host tests for analyze-gpu-window.py: the §6 derived values and verdicts.

What is being protected: the GPU phases are gated on small differences (C3
share -1 pp, idle exits +5 %, 350 MHz -0.5 pp, GFX active 0.1 %), so a parser
that sums the wrong column or a verdict that compares the wrong way round
passes a regression. Each test plants a known delta in synthetic snapshots of
the exact format nq-opp-study2.sh writes on the Q (taken from the Prague unit,
6.18.48-r21, 2026-10-11) and checks the number and the verdict.

Run from the repo root:
    python3 -m unittest discover -s scripts/diag/tests -v
"""

import importlib.machinery
import importlib.util
import os
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
loader = importlib.machinery.SourceFileLoader("analyze_gpu_window", os.path.join(HERE, "..", "analyze-gpu-window.py"))
spec = importlib.util.spec_from_loader("analyze_gpu_window", loader)
MOD = importlib.util.module_from_spec(spec)
loader.exec_module(MOD)

CPUIDLE = "/sys/devices/system/cpu/cpu{c}/cpuidle/state{s}"


def snap(
    uptime,
    idle,
    tis,
    trans=100,
    ctxt=5000,
    gfx_ms=3,
    genpd="off-0",
    dmesg=None,
    audio="playback=0 usb-in=1 roon-loop=0",
    irq_gpu=0,
):
    """idle: {(cpu, state): (usage, time_us)}; tis: {MHz: 10 ms ticks}."""
    out = [f"@uptime {uptime} 0.00", "@time_in_state"]
    out += [f"{f * 1000} {t}" for f, t in sorted(tis.items())]
    out += [f"@total_trans {trans}", "@trans_table", "@proc_stat"]
    out += [
        "cpu  100 0 50 10000 5 1 2 0 0 0",
        "cpu0 50 0 25 5000 2 1 1 0 0 0",
        f"ctxt {ctxt}",
        "processes 300",
        "@interrupts",
        "           CPU0       CPU1       ",
        " 24:     170736     113220 GIC-0  29 Edge      twd",
        f"170:     {irq_gpu}          0    WUGEN  21 Level     pvrsrvkm",
        "162:          0          0    WUGEN  25 Level     OMAP DISPC",
        "IPI2:      8472      41433  Rescheduling interrupts",
        "@softirqs",
        "                    CPU0       CPU1       ",
        "       TIMER:      39167      88770",
        "@cpuidle",
    ]
    for (c, s), (u, t) in sorted(idle.items()):
        out.append(f"{CPUIDLE.format(c=c, s=s)} usage={u} time={t} name=C{s + 1}")
    out += [
        f"@audio {audio}",
        "@wall 2026-10-11T17:27:15+0200",
        "@pm_debug_count",
        "mpu_pwrdm (ON),OFF:0,RET:250756,INA:11462,ON:262219,RET-LOGIC-OFF:0",
        "gfx_pwrdm (OFF),OFF:3,RET:0,INA:0,ON:2,RET-LOGIC-OFF:0,RET-MEMBANK1-OFF:0",
        "@gfx_rpm",
        "runtime_status suspended",
        f"runtime_active_time {gfx_ms}",
        "@genpd_prm_gfx",
        f"current_state {genpd}",
        "active_time 5 ms",
        "@hwmon",
        "tmp101 42000",
        "@dmesg_counts",
    ]
    d = {"audio_err": 3, "kernel_warn": 0, "lines": 887, "first": "[    0.000000]"}
    d.update({k: 0 for k in MOD.PREEMPT_KEYS})
    d.update(dmesg or {})
    out += [f"{k} {v}" for k, v in d.items()]
    return "\n".join(out) + "\n"


def idle_counters(c3_us, other_us, exits):
    """Both CPUs alike: C3 gets c3_us, C1 other_us, `exits` entries split C1/C3."""
    d = {}
    for c in (0, 1):
        d[(c, 0)] = (exits // 4, other_us // 2)
        d[(c, 1)] = (0, 0)
        d[(c, 2)] = (exits // 4, c3_us // 2)
    return d


def window(root, name, dt=3600.0, c3=0.90, exits_s=350.0, mhz350=0.998, **post):
    """A pre/post pair with the given C3 share, exits/s and 350 MHz share."""
    d = os.path.join(root, name)
    os.makedirs(d)
    idle_us = 1.8e9  # both CPUs idle 90 % of an hour
    pre_idle = idle_counters(1_000_000, 1_000_000, 4000)
    c3_us, other_us = int(idle_us * c3), int(idle_us * (1 - c3))
    n = int(exits_s * dt)
    post_idle = {
        k: (pre_idle[k][0] + v[0], pre_idle[k][1] + v[1]) for k, v in idle_counters(c3_us, other_us, n).items()
    }
    ticks = int(dt * 100)
    pre_tis = {350: 1000, 700: 10, 920: 1, 1200: 1}
    post_tis = {350: 1000 + int(ticks * mhz350), 700: 10 + ticks - int(ticks * mhz350), 920: 1, 1200: 1}
    with open(os.path.join(d, "arm_A_pre.snap"), "w") as fh:
        fh.write(snap(1000.0, pre_idle, pre_tis, **({"audio": post["audio"]} if "audio" in post else {})))
    with open(os.path.join(d, "arm_A_post.snap"), "w") as fh:
        fh.write(snap(1000.0 + dt, post_idle, post_tis, trans=100 + int(0.5 * dt), ctxt=5000 + int(400 * dt), **post))
    with open(os.path.join(d, "thermal_1hz.log"), "w") as fh:
        fh.write("990.0 99000\n")  # before the window: must be ignored
        for i in range(101):
            fh.write(f"{1000.0 + i * dt / 100:.1f} {60000 + i * 100}\n")
    return d


class Derived(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = self.tmp.name

    def tearDown(self):
        self.tmp.cleanup()

    def test_planted_deltas_come_out(self):
        w = MOD.summarize(window(self.root, "w", c3=0.875, exits_s=353.0, mhz350=0.95, gfx_ms=3603))
        self.assertAlmostEqual(w["c3_share_pct"], 87.5, places=2)
        self.assertAlmostEqual(w["idle_exits_per_s"], 353.0, delta=0.5)
        self.assertAlmostEqual(w["mhz350_pct"], 95.0, places=1)
        self.assertEqual(w["opp_trans_per_s"], 0.5)
        self.assertEqual(w["ctxt_per_s"], 400.0)
        self.assertEqual(w["gfx_rpm_active_ms"], 3600)
        self.assertAlmostEqual(w["gfx_rpm_active_pct"], 0.1, places=3)
        self.assertEqual(w["genpd_gfx_state_end"], "off-0")
        self.assertEqual(w["pm_debug"]["gfx_pwrdm"]["state_end"], "OFF")

    def test_thermal_stats_use_the_window_only(self):
        w = MOD.summarize(window(self.root, "w"))
        t = w["temp_1hz"]
        self.assertEqual(t["n"], 101)  # the 99 C sample before the window is out
        self.assertEqual(t["max_C"], 70.0)
        self.assertEqual(t["median_C"], 65.0)
        self.assertEqual(t["p95_C"], 69.5)

    def test_gpu_irq_line_is_recognised_behind_the_wugen(self):
        w = MOD.summarize(window(self.root, "w", irq_gpu=36000))
        self.assertAlmostEqual(w["irq_per_s"]["gpu"], 10.0)
        self.assertEqual(MOD.irq_class("162", "WUGEN  25 Level OMAP DISPC"), "dss")
        self.assertEqual(MOD.irq_class("24", "GIC-0  29 Edge twd"), "dev")

    def test_boot_time_with_minutes(self):
        self.assertEqual(MOD.boot_userspace_s(["multi-user.target reached after 1min 2.5s in userspace."]), 62.5)
        self.assertEqual(MOD.boot_userspace_s(["multi-user.target reached after 20.717s in userspace."]), 20.717)


class Verdicts(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = self.tmp.name
        self.bases = [
            MOD.summarize(window(self.root, "a0a", c3=0.90, exits_s=350.0)),
            MOD.summarize(window(self.root, "a0b", c3=0.89, exits_s=352.0)),
        ]

    def tearDown(self):
        self.tmp.cleanup()

    def verdict(self, arm, **kw):
        rows, ok = MOD.compare(self.bases, MOD.summarize(window(self.root, "t", **kw)), arm)
        return {name: v for name, v, _ in rows}, ok

    def test_an_identical_window_passes(self):
        rows, ok = self.verdict("a1", c3=0.895, exits_s=351.0)
        self.assertTrue(ok, rows)

    def test_c3_drop_beyond_one_point_fails(self):
        rows, ok = self.verdict("p1a", c3=0.88)  # baseline mean 89.5 -> -1.5 pp
        self.assertFalse(ok)
        self.assertEqual(rows["ΔC3 share"], "FAIL")

    def test_exits_up_six_percent_fails_and_four_passes(self):
        rows, _ = self.verdict("p1a", exits_s=351.0 * 1.06)
        self.assertEqual(rows["Δidle exits/s"], "FAIL")
        self.tmp.cleanup()
        self.setUp()
        rows, _ = self.verdict("p1a", exits_s=351.0 * 1.04)
        self.assertEqual(rows["Δidle exits/s"], "PASS")

    def test_350_residency_drop_fails(self):
        rows, _ = self.verdict("p1a", mhz350=0.99)
        self.assertEqual(rows["Δ350 MHz residency"], "FAIL")

    def test_a1_gfx_awake_or_on_fails(self):
        rows, _ = self.verdict("a1", gfx_ms=3 + 4000)  # 0.11 % of an hour
        self.assertEqual(rows["GFX active ≤ 0.1 % of the window"], "FAIL")
        self.tmp.cleanup()
        self.setUp()
        rows, _ = self.verdict("a1", genpd="on")
        self.assertEqual(rows["prm_gfx off at window end"], "FAIL")

    def test_a_preemption_splat_fails_p1a(self):
        rows, ok = self.verdict("p1a", dmesg={"scheduling_while_atomic": 1})
        self.assertFalse(ok)
        self.assertEqual(rows["dmesg scheduling_while_atomic Δ0"], "FAIL")

    def test_audio_errors_are_judged_only_with_music(self):
        rows, _ = self.verdict("p1a", dmesg={"audio_err": 5})
        self.assertNotIn("kernel audio errors Δ0 (music playing)", rows)

    def test_a_wrapped_ring_buffer_invalidates_the_window(self):
        rows, ok = self.verdict("p1a", dmesg={"first": "[ 1234.5]"})
        self.assertFalse(ok)
        self.assertIn("FAIL", [v for k, v in rows.items() if k.startswith("valid A")])

    def test_different_audio_states_are_not_comparable(self):
        rows, ok = self.verdict("p1a", audio="playback=0 usb-in=0 roon-loop=0")
        self.assertFalse(ok)
        self.assertEqual(rows["same audio state in every window"], "FAIL")


if __name__ == "__main__":
    unittest.main()
