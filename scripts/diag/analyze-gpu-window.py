#!/usr/bin/env python3
"""GPU measurement windows: per-window summary and A/B verdict.

Reads what `nq-opp-study2.sh` writes with GPU=1 (arm_<label>_{pre,post}.snap,
arm_<label>_{pre,post}.edge, thermal_1hz.log, run.log, ABORTED) and derives the
values docs/gpu-sgx540/drafts/measurement-protocol.md §6 judges by, plus the
kernel-driver-port.md Addendum B.8 items:

  C3 share (Δtime C3 / Σ Δtime all states, both CPUs), idle exits/s,
  350 MHz residency and transitions/s, ctxt/s, IRQ/s (total, GPU, DSS),
  softirq/s, GFX runtime-PM active ms and genpd prm_gfx state, pm_debug ΔON/ΔOFF
  per domain, die °C at 1 Hz (median/p95/max), kernel audio-error and
  preemption-bug deltas, uname/vermagic/preemption model, boot-to-multi-user.

Every figure is a delta of a kernel counter over the window; the window is the
interval between the pre and post snapshots, nothing else.

Usage:
  analyze-gpu-window.py summary DIR [--label L] [--json] [--health CAPTURE]
  analyze-gpu-window.py compare --arm a1|p1a BASE_DIR [BASE_DIR ...] --test DIR [--json]

`--health CAPTURE` runs nq-health-report on an nq-collect capture over the
window's wall-clock span and adds its vdd_mismatch count. In `compare`, two or
more baselines (A0 run twice, as the protocol asks) give the noise: the spread
of each metric across them is printed next to the difference. A threshold
failure is a failure even inside that spread (protocol §6: not averaged away).
Exit: 0 all pass (compare) / summary printed, 1 a criterion failed, 2 usage or
unreadable input.
"""

import importlib.machinery
import importlib.util
import json
import os
import re
import statistics
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))


def _load(name, filename):
    loader = importlib.machinery.SourceFileLoader(name, os.path.join(HERE, filename))
    spec = importlib.util.spec_from_loader(name, loader)
    mod = importlib.util.module_from_spec(spec)
    loader.exec_module(mod)
    return mod


SNAPS = _load("analyze_opp_snaps", "analyze-opp-snaps.py")
parse = SNAPS.parse

PREEMPT_KEYS = ("sleeping_in_atomic", "smp_processor_id_preemptible", "scheduling_while_atomic", "rcu_stall")
DOMAINS = ("mpu_pwrdm", "core_pwrdm", "dss_pwrdm", "gfx_pwrdm")

# measurement-protocol §6. P1a's are *proposed* there; they reuse A1's idle ones.
THRESHOLDS = {
    "c3_share_pp_min": -1.0,
    "exits_rel_max": 0.05,
    "mhz350_pp_min": -0.5,
    "gfx_active_pct_max": 0.1,
}


# ── parsing ──────────────────────────────────────────────────────────────


def kv(lines):
    out = {}
    for ln in lines:
        p = ln.split(None, 1)
        if p:
            out[p[0]] = p[1].strip() if len(p) > 1 else ""
    return out


def first_int(text):
    m = re.search(r"-?\d+", text or "")
    return int(m.group(0)) if m else None


def cpuidle(s):
    """-> {state name: (usage, time_us)} summed over CPUs."""
    out = {}
    for ln in s.get("cpuidle", []):
        u = re.search(r"usage=(\d+)", ln)
        t = re.search(r"time=(\d+)", ln)
        n = re.search(r"name=(\S+)", ln)
        if not (u and t):
            continue
        name = n.group(1) if n else "state" + ln.split()[0].rsplit("state", 1)[-1]
        a, b = out.get(name, (0, 0))
        out[name] = (a + int(u.group(1)), b + int(t.group(1)))
    return out


def interrupts(s):
    """-> list of (key, controller+hwirq+type, name, total count). Key is the irq
    number or IPI name; per-CPU columns are summed."""
    lines = s.get("interrupts", [])
    ncpu = len(lines[0].split()) if lines else 0
    out = []
    for ln in lines[1:]:
        p = ln.split()
        if not p or not p[0].endswith(":"):
            continue
        key = p[0][:-1]
        vals = []
        for tok in p[1 : 1 + ncpu]:
            if not tok.isdigit():
                break
            vals.append(int(tok))
        if not vals:
            continue
        rest = p[1 + len(vals) :]
        out.append((key, " ".join(rest[:3]), " ".join(rest), sum(vals)))
    return out


def irq_class(key, desc):
    """'gpu', 'dss', 'ipi' or 'dev' for one /proc/interrupts line."""
    if not key.isdigit():
        return "ipi" if key.startswith("IPI") else "other"
    low = desc.lower()
    # The SGX is GIC SPI 21 = hwirq 53 (pm §8.1); behind the WUGEN it prints as 21.
    if re.search(r"pvr|sgx|gpu", low) or re.search(r"\bGIC-0 +53\b", desc) or re.search(r"\bWUGEN +21\b", desc):
        return "gpu"
    if "dispc" in low or "dss" in low or "hdmi" in low:
        return "dss"
    return "dev"


def pm_debug(lines):
    """'gfx_pwrdm (OFF),OFF:3,RET:0,...' -> {domain: (state, {key: int})}"""
    out = {}
    for ln in lines:
        m = re.match(r"(\w+_pwrdm) \(([^)]*)\),(.*)", ln)
        if not m:
            continue
        vals = {}
        for item in m.group(3).split(","):
            if ":" in item:
                k, v = item.split(":", 1)
                if v.strip().isdigit():
                    vals[k] = int(v)
        out[m.group(1)] = (m.group(2), vals)
    return out


def iso(wall):
    """'2026-10-11T17:05:00+0200' -> '2026-10-11T17:05:00+02:00'."""
    if not wall:
        return None
    return re.sub(r"([+-]\d\d)(\d\d)$", r"\1:\2", wall.strip())


def load_thermal(path, t0, t1):
    vals = []
    if not os.path.exists(path):
        return vals
    with open(path, errors="replace") as fh:
        for ln in fh:
            p = ln.split()
            if len(p) != 2 or not p[1].lstrip("-").isdigit():
                continue
            try:
                t = float(p[0])
            except ValueError:
                continue
            if t0 <= t <= t1:
                vals.append(int(p[1]) / 1000.0)
    return vals


def pctl(vals, q):
    if not vals:
        return None
    s = sorted(vals)
    k = max(0, min(len(s) - 1, int(round(q * (len(s) - 1)))))
    return s[k]


def boot_userspace_s(lines):
    """systemd-analyze: 'multi-user.target reached after 20.717s in userspace'."""
    for ln in lines:
        m = re.search(r"multi-user\.target reached after (.+?) in userspace", ln)
        if m:
            total = 0.0
            for num, unit in re.findall(r"([\d.]+)(min|ms|s|h)", m.group(1)):
                total += float(num) * {"h": 3600, "min": 60, "s": 1, "ms": 0.001}[unit]
            return round(total, 3)
    return None


# ── one window ───────────────────────────────────────────────────────────


def find_label(d, label=None):
    labels = sorted(
        os.path.basename(p)[len("arm_") : -len("_pre.snap")]
        for p in (os.path.join(d, f) for f in os.listdir(d))
        if os.path.basename(p).startswith("arm_") and p.endswith("_pre.snap")
    )
    if label:
        if label not in labels:
            raise SystemExit(f"{d}: no arm_{label}_pre.snap (have: {', '.join(labels) or 'none'})")
        return label
    if len(labels) != 1:
        raise SystemExit(f"{d}: {len(labels)} arms ({', '.join(labels)}); pick one with --label")
    return labels[0]


def summarize(d, label=None):
    label = find_label(d, label)
    pre_p = os.path.join(d, f"arm_{label}_pre.snap")
    post_p = os.path.join(d, f"arm_{label}_post.snap")
    if not os.path.exists(post_p):
        raise SystemExit(f"{d}: arm {label} has no post snapshot (still running, or aborted)")
    a, b = parse(pre_p), parse(post_p)
    t0, t1 = SNAPS.uptime(a), SNAPS.uptime(b)
    dt = t1 - t0
    if dt <= 0:
        raise SystemExit(f"{d}: arm {label} has a window of {dt:.1f} s; the snapshots are not a pre/post pair")
    w = {"dir": d, "label": label, "window_s": round(dt, 1), "uptime_start": t0, "uptime_end": t1}
    w["wall_start"] = iso((a.get("wall") or [None])[0])
    w["wall_end"] = iso((b.get("wall") or [None])[0])

    # validity
    run_log = ""
    if os.path.exists(os.path.join(d, "run.log")):
        with open(os.path.join(d, "run.log"), errors="replace") as fh:
            run_log = fh.read()
    aborted = None
    if os.path.exists(os.path.join(d, "ABORTED")):
        with open(os.path.join(d, "ABORTED")) as fh:
            aborted = fh.read().strip()
    w["aborted"] = aborted
    w["allow_units"] = (re.findall(r"=== ALLOW_UNITS \(deliberately live during this run\): (.*)", run_log) or [""])[0]
    w["audio_start"] = (a.get("audio") or [None])[0]
    w["audio_end"] = (b.get("audio") or [None])[0]

    # C-states
    ia, ib = cpuidle(a), cpuidle(b)
    d_time = {k: ib[k][1] - ia.get(k, (0, 0))[1] for k in ib}
    d_use = {k: ib[k][0] - ia.get(k, (0, 0))[0] for k in ib}
    tot = sum(d_time.values())
    w["cstate_share_pct"] = {k: round(100.0 * v / tot, 3) if tot else None for k, v in sorted(d_time.items())}
    w["c3_share_pct"] = w["cstate_share_pct"].get("C3")
    w["idle_exits_per_s"] = round(sum(d_use.values()) / dt, 2) if dt else None
    w["cstate_entries_per_s"] = {k: round(v / dt, 2) for k, v in sorted(d_use.items())}

    # cpufreq
    ta, tb = SNAPS.time_in_state(a), SNAPS.time_in_state(b)
    ttot = sum(tb[f] - ta.get(f, 0) for f in tb)
    w["opp_residency_pct"] = (
        {f // 1000: round(100.0 * (tb[f] - ta.get(f, 0)) / ttot, 3) for f in sorted(tb)} if ttot else {}
    )
    w["mhz350_pct"] = w["opp_residency_pct"].get(350)
    tra = first_int((a.get("total_trans") or [""])[0])
    trb = first_int((b.get("total_trans") or [""])[0])
    w["opp_trans_per_s"] = round((trb - tra) / dt, 3) if None not in (tra, trb) and dt else None

    # scheduler
    pa, sa = SNAPS.proc_stat(a)
    pb, sb = SNAPS.proc_stat(b)
    w["ctxt_per_s"] = round((sb["ctxt"] - sa["ctxt"]) / dt, 1)
    w["forks_per_s"] = round((sb["processes"] - sa["processes"]) / dt, 3)
    da = [x - y for x, y in zip(pb["cpu"], pa["cpu"])]
    w["busy_pct_both_cpus"] = round(100.0 * (sum(da) - da[3] - da[4]) / sum(da), 3) if sum(da) else None

    # interrupts
    xa = {k: n for k, _, _, n in interrupts(a)}
    rates = {"dev": 0, "gpu": 0, "dss": 0, "ipi": 0}
    lines = []
    for key, _, desc, n in interrupts(b):
        dn = n - xa.get(key, 0)
        cls = irq_class(key, desc)
        if cls in rates:
            rates[cls] += dn
        if cls in ("gpu", "dss"):
            lines.append(f"{key} {desc}")
    w["irq_per_s"] = {k: round(v / dt, 3) for k, v in rates.items()}
    w["irq_per_s"]["total_dev"] = round((rates["dev"] + rates["gpu"] + rates["dss"]) / dt, 3)
    w["gpu_dss_irq_lines"] = lines
    sa_, sb_ = SNAPS.softirqs(a), SNAPS.softirqs(b)
    w["softirq_per_s"] = {k: round((sb_[k] - sa_.get(k, 0)) / dt, 2) for k in sb_}

    # GFX
    ra, rb = kv(a.get("gfx_rpm", [])), kv(b.get("gfx_rpm", []))
    act_a, act_b = first_int(ra.get("runtime_active_time")), first_int(rb.get("runtime_active_time"))
    w["gfx_rpm_active_ms"] = act_b - act_a if None not in (act_a, act_b) else None
    w["gfx_rpm_active_pct"] = (
        round(100.0 * w["gfx_rpm_active_ms"] / 1000.0 / dt, 4) if w["gfx_rpm_active_ms"] is not None else None
    )
    w["gfx_rpm_status_end"] = rb.get("runtime_status")
    ga, gb = kv(a.get("genpd_prm_gfx", [])), kv(b.get("genpd_prm_gfx", []))
    g_a, g_b = first_int(ga.get("active_time")), first_int(gb.get("active_time"))
    w["genpd_gfx_active_ms"] = g_b - g_a if None not in (g_a, g_b) else None
    w["genpd_gfx_state_end"] = gb.get("current_state")

    # pm_debug (sampled at MPUSS transitions: context, not a ratio partner of the above)
    ca, cb = pm_debug(a.get("pm_debug_count", [])), pm_debug(b.get("pm_debug_count", []))
    pdb = {}
    for dom in DOMAINS:
        if dom not in cb:
            continue
        st, vb = cb[dom]
        va = ca.get(dom, ("", {}))[1]
        pdb[dom] = {"state_end": st, **{f"d{k}": vb[k] - va.get(k, 0) for k in ("ON", "OFF", "RET", "INA") if k in vb}}
    w["pm_debug"] = pdb

    # temperature
    therm = load_thermal(os.path.join(d, "thermal_1hz.log"), t0, t1)
    w["temp_1hz"] = {
        "n": len(therm),
        "median_C": round(statistics.median(therm), 2) if therm else None,
        "p95_C": pctl(therm, 0.95),
        "max_C": max(therm) if therm else None,
    }
    hw_a, hw_b = kv(a.get("hwmon", [])), kv(b.get("hwmon", []))
    w["tmp101_C"] = {
        "start": first_int(hw_a.get("tmp101")) / 1000.0 if first_int(hw_a.get("tmp101")) is not None else None,
        "end": first_int(hw_b.get("tmp101")) / 1000.0 if first_int(hw_b.get("tmp101")) is not None else None,
    }

    # dmesg
    da_, db_ = kv(a.get("dmesg_counts", [])), kv(b.get("dmesg_counts", []))
    dm = {}
    for k in ("audio_err", "kernel_warn") + PREEMPT_KEYS:
        x, y = first_int(da_.get(k)), first_int(db_.get(k))
        dm[k] = (y - x) if None not in (x, y) else None
    la, lb = first_int(da_.get("lines")), first_int(db_.get("lines"))
    dm["ring_wrapped"] = bool(da_ and (da_.get("first") != db_.get("first") or (lb or 0) < (la or 0)))
    dm["preempt_bugs_total_end"] = sum(first_int(db_.get(k)) or 0 for k in PREEMPT_KEYS) if db_ else None
    w["dmesg"] = dm

    # kernel identity and the probe, from the edge files
    edges = {}
    for side in ("pre", "post"):
        p = os.path.join(d, f"arm_{label}_{side}.edge")
        edges[side] = parse(p) if os.path.exists(p) else {}
    e0, e1 = edges["pre"], edges["post"]
    w["uname"] = (e0.get("uname") or [None])[0]
    w["vermagic"] = (e0.get("vermagic") or [None])[0]
    w["hostname"] = (e0.get("hostname") or [None])[0]
    w["kernel_same_at_end"] = (
        (e1.get("uname") or [None])[0] == w["uname"] and (e1.get("vermagic") or [None])[0] == w["vermagic"]
        if e1
        else None
    )
    w["preempt_config"] = [ln for ln in e0.get("preempt", []) if ln.strip()]
    w["boot_multi_user_userspace_s"] = boot_userspace_s(e0.get("boot", []))
    w["probe"] = {}
    for side, e in edges.items():
        lines = [ln for ln in e.get("gpu_probe", [])[1:] if re.match(r"(PASS|FAIL|WARN|INFO|SKIP)\b", ln)]
        w["probe"][side] = {
            "fail": [ln for ln in lines if ln.startswith("FAIL")],
            "gpu_lines": [ln for ln in lines if re.search(r"\bgpu_(driver|clock)\b|\bgfx", ln)],
            "exit": first_int((e.get("gpu_probe_exit") or [None])[0]),
        }

    w["health_cmd"] = (
        f"scripts/diag/nq-health-report <capture> --since={w['wall_start']} --until={w['wall_end']}"
        if w["wall_start"] and w["wall_end"]
        else None
    )
    return w


def add_health(w, capture):
    """vdd_mismatch over the window from an nq-collect capture."""
    if not (w["wall_start"] and w["wall_end"]):
        w["health"] = {"error": "no wall clock in the snapshots (GPU=0 run?)"}
        return
    cmd = [
        sys.executable,
        os.path.join(HERE, "nq-health-report"),
        capture,
        "--json",
        f"--since={w['wall_start']}",
        f"--until={w['wall_end']}",
    ]
    try:
        out = json.loads(subprocess.run(cmd, capture_output=True, text=True, check=True, timeout=120).stdout)
    except (subprocess.SubprocessError, ValueError) as e:
        w["health"] = {"error": str(e)}
        return
    s = out.get("summary", {})
    w["health"] = {
        "samples": s.get("samples"),
        "vdd_mismatch_samples": s.get("vdd_mismatch_samples"),
        "temp_peak_C": s.get("temp_peak_C"),
        "worst_severity": s.get("worst_severity"),
    }


# ── verdicts ─────────────────────────────────────────────────────────────


def validity(w):
    """Problems that make a window unusable, whatever its numbers."""
    bad = []
    if w["aborted"]:
        bad.append(f"aborted: {w['aborted']}")
    if w["audio_start"] != w["audio_end"]:
        bad.append(f"audio state changed: [{w['audio_start']}] -> [{w['audio_end']}]")
    if w["dmesg"].get("ring_wrapped"):
        bad.append("dmesg ring buffer wrapped: the kernel counts are not deltas")
    if w["kernel_same_at_end"] is False:
        bad.append("kernel/vermagic differs between the window edges")
    return bad


def mean(vals):
    vals = [v for v in vals if v is not None]
    return sum(vals) / len(vals) if vals else None


def spread(vals):
    vals = [v for v in vals if v is not None]
    return (max(vals) - min(vals)) if len(vals) > 1 else None


def compare(bases, test, arm):
    """-> (rows, ok). rows: (criterion, verdict, detail)."""
    rows = []

    def row(name, ok, detail):
        rows.append((name, "PASS" if ok else "FAIL", detail))

    for w in bases + [test]:
        for problem in validity(w):
            row(f"valid {w['label']} ({os.path.basename(w['dir'].rstrip('/'))})", False, problem)
    refs = {w[k] for w in bases + [test] for k in ("audio_start", "audio_end")}
    row("same audio state in every window", len(refs) == 1, " | ".join(sorted(str(r) for r in refs)))

    def metric(key, test_v, base_vs, limit, rel=False, higher_is_bad=False):
        b = mean(base_vs)
        if test_v is None or b is None:
            row(key, False, "not measured")
            return
        diff = (test_v - b) / b if rel and b else test_v - b
        ok = diff <= limit if higher_is_bad else diff >= limit
        sp = spread(base_vs)
        unit = "%" if rel else "pp"
        shown = 100 * diff if rel else diff
        lim = 100 * limit if rel else limit
        noise = f", baseline spread {100 * sp / b if rel and b else sp:.3f}{unit}" if sp is not None else ""
        row(
            key,
            ok,
            f"test {test_v:.3f} vs baseline {b:.3f}: Δ {shown:+.3f}{unit} "
            f"(limit {'≤' if higher_is_bad else '≥'} {lim:+g}{unit}{noise})",
        )

    metric("ΔC3 share", test["c3_share_pct"], [w["c3_share_pct"] for w in bases], THRESHOLDS["c3_share_pp_min"])
    metric(
        "Δidle exits/s",
        test["idle_exits_per_s"],
        [w["idle_exits_per_s"] for w in bases],
        THRESHOLDS["exits_rel_max"],
        rel=True,
        higher_is_bad=True,
    )
    metric("Δ350 MHz residency", test["mhz350_pct"], [w["mhz350_pct"] for w in bases], THRESHOLDS["mhz350_pp_min"])

    if arm == "a1":
        g = test["gfx_rpm_active_pct"]
        row(
            "GFX active ≤ 0.1 % of the window",
            g is not None and g <= THRESHOLDS["gfx_active_pct_max"],
            f"{g} % (runtime PM {test['gfx_rpm_active_ms']} ms; genpd {test['genpd_gfx_active_ms']} ms)",
        )
        st = test["genpd_gfx_state_end"] or ""
        row("prm_gfx off at window end", st.startswith("off"), st or "not read")

    for k in PREEMPT_KEYS:
        v = test["dmesg"].get(k)
        row(f"dmesg {k} Δ0", v == 0, f"Δ {v}")
    v = test["dmesg"].get("kernel_warn")
    row("dmesg new WARNING/BUG/Oops Δ0", v == 0, f"Δ {v}")
    if test["audio_start"] and "playback=1" in test["audio_start"]:
        v = test["dmesg"].get("audio_err")
        row("kernel audio errors Δ0 (music playing)", v == 0, f"Δ {v}")
    if "health" in test:
        h = test["health"]
        n = h.get("vdd_mismatch_samples")
        row("no vdd_mismatch (healthd)", n == 0, f"{n} sample(s)" if "error" not in h else h["error"])
    ok = all(v == "PASS" for _, v, _ in rows)
    return rows, ok


# ── output ───────────────────────────────────────────────────────────────


def print_summary(w):
    print(f"══ {w['label']}  {w['dir']}")
    print(f"window {w['window_s']} s   {w['wall_start']} → {w['wall_end']}   host {w['hostname']}")
    print(f"kernel {w['uname']}   vermagic '{w['vermagic']}'   preempt {', '.join(w['preempt_config']) or '?'}")
    print(f"boot: multi-user.target after {w['boot_multi_user_userspace_s']} s in userspace")
    print(f"audio start [{w['audio_start']}] end [{w['audio_end']}]   ALLOW_UNITS '{w['allow_units']}'")
    for p in validity(w):
        print(f"  !! INVALID: {p}")
    print(f"C3 share {w['c3_share_pct']} %   states {w['cstate_share_pct']}")
    print(f"idle exits {w['idle_exits_per_s']}/s   entries/s {w['cstate_entries_per_s']}")
    print(f"350 MHz {w['mhz350_pct']} %   OPP {w['opp_residency_pct']}   transitions {w['opp_trans_per_s']}/s")
    print(f"ctxt {w['ctxt_per_s']}/s   forks {w['forks_per_s']}/s   busy {w['busy_pct_both_cpus']} % (both CPUs)")
    print(f"IRQ/s {w['irq_per_s']}   lines {w['gpu_dss_irq_lines']}")
    print(f"softirq/s {w['softirq_per_s']}")
    print(
        f"GFX runtime-PM active {w['gfx_rpm_active_ms']} ms ({w['gfx_rpm_active_pct']} %),"
        f" status {w['gfx_rpm_status_end']};"
        f" genpd prm_gfx active {w['genpd_gfx_active_ms']} ms, state {w['genpd_gfx_state_end']}"
    )
    print(f"pm_debug {w['pm_debug']}")
    t = w["temp_1hz"]
    print(f"die °C 1 Hz: n={t['n']} median {t['median_C']} p95 {t['p95_C']} max {t['max_C']}   TMP101 {w['tmp101_C']}")
    print(f"dmesg Δ {w['dmesg']}")
    for side, p in w["probe"].items():
        print(f"probe {side}: exit {p['exit']}  FAIL {p['fail']}  gpu {p['gpu_lines']}")
    if "health" in w:
        print(f"healthd {w['health']}")
    elif w["health_cmd"]:
        print(f"healthd: {w['health_cmd']}")


def main(argv):
    if len(argv) < 2 or argv[1] not in ("summary", "compare"):
        print(__doc__)
        return 2
    cmd, args = argv[1], argv[2:]
    as_json = "--json" in args
    args = [x for x in args if x != "--json"]

    def opt(name):
        if name in args:
            i = args.index(name)
            v = args[i + 1]
            del args[i : i + 2]
            return v
        return None

    label = opt("--label")
    health = opt("--health")
    if cmd == "summary":
        if len(args) != 1:
            print(__doc__)
            return 2
        w = summarize(args[0], label)
        if health:
            add_health(w, health)
        if as_json:
            print(json.dumps(w, indent=2))
        else:
            print_summary(w)
        return 0

    arm = opt("--arm")
    test = opt("--test")
    if arm not in ("a1", "p1a") or not test or not args:
        print(__doc__)
        return 2
    bases = [summarize(d, label) for d in args]
    t = summarize(test, label)
    if health:
        add_health(t, health)
    rows, ok = compare(bases, t, arm)
    if as_json:
        print(json.dumps({"arm": arm, "pass": ok, "rows": rows, "test": t, "bases": bases}, indent=2))
    else:
        print(f"══ {arm.upper()} {t['dir']} against {', '.join(b['dir'] for b in bases)}")
        for name, v, detail in rows:
            print(f"  {v}  {name:<40} {detail}")
        print(f"verdict: {'PASS' if ok else 'FAIL'}")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
