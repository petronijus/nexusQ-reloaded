#!/usr/bin/env python3
"""Turn nq-opp-study snapshot pairs into per-arm deltas.

Every figure here is a delta of a kernel counter over a known wall interval, so
nothing depends on a sampler's own view of itself.
"""
import glob
import gzip
import os
import re
import sys

USER_HZ = 100.0


def parse(path):
    """snapshot file -> {section: [lines]} plus scalars."""
    sec, out = None, {}
    opener = gzip.open if path.endswith(".gz") else open
    with opener(path, "rt", errors="replace") as fh:
        for line in fh:
            line = line.rstrip("\n")
            if line.startswith("@"):
                head = line[1:].split(" ", 1)
                sec = head[0]
                out.setdefault(sec, [])
                if len(head) > 1:
                    out[sec].append(head[1])
                continue
            if sec:
                out[sec].append(line)
    return out


def uptime(s):
    return float(s["uptime"][0].split()[0])


def time_in_state(s):
    d = {}
    for ln in s.get("time_in_state", []):
        f, t = ln.split()
        d[int(f)] = int(t)          # 10 ms units
    return d


def trans_table(s):
    """-> {(from,to): count}"""
    rows, cols, out = s.get("trans_table", []), None, {}
    for ln in rows:
        if ":" not in ln:
            continue
        left, right = ln.split(":", 1)
        left, vals = left.strip(), right.split()
        if left == "From":
            continue
        if not left.isdigit():
            cols = [int(v) for v in vals if v.isdigit()]
            continue
        if cols is None:
            continue
        for c, v in zip(cols, vals):
            out[(int(left), c)] = int(v)
    return out


def cols_from_header(s):
    for ln in s.get("trans_table", []):
        vals = ln.split()
        if vals and all(v.isdigit() for v in vals):
            return [int(v) for v in vals]
    return []


def proc_stat(s):
    cpus, scal = {}, {}
    for ln in s.get("proc_stat", []):
        p = ln.split()
        if p[0].startswith("cpu"):
            cpus[p[0]] = [int(x) for x in p[1:]]
        elif p[0] in ("ctxt", "processes"):
            scal[p[0]] = int(p[1])
    return cpus, scal


def irqs(s):
    out = {}
    for ln in s.get("interrupts", []):
        p = ln.split()
        if not p or not p[0].rstrip(":").rstrip().isalnum():
            continue
        key = p[0].rstrip(":")
        vals = []
        for tok in p[1:]:
            if tok.lstrip("-").isdigit():
                vals.append(int(tok))
            else:
                break
        if not vals:
            continue
        name = " ".join(p[1 + len(vals):]) or key
        out[f"{key} {name}"] = sum(vals)
    return out


def softirqs(s):
    out = {}
    for ln in s.get("softirqs", []):
        p = ln.split()
        if len(p) < 2 or not p[0].endswith(":"):
            continue
        out[p[0].rstrip(":")] = sum(int(x) for x in p[1:] if x.isdigit())
    return out


def cgroups(s):
    out = {}
    for ln in s.get("cgroups", []):
        p = ln.split()
        if len(p) < 3:
            continue
        m = re.search(r"usage_usec (\d+)", ln)
        if m:
            out[p[0]] = int(m.group(1))
    return out


def temps(s):
    return {ln.split()[0]: int(ln.split()[1]) for ln in s.get("thermal", []) if len(ln.split()) == 2}


def report(label, pre_path, post_path, top=14):
    a, b = parse(pre_path), parse(post_path)
    dt = uptime(b) - uptime(a)
    print(f"\n{'=' * 78}\n== ARM {label}   window {dt:.0f} s\n{'=' * 78}")

    # --- OPP residency
    ta, tb = time_in_state(a), time_in_state(b)
    tot = sum(tb[f] - ta[f] for f in tb)
    print("OPP residency:")
    for f in sorted(tb):
        d = tb[f] - ta[f]
        pct = 100.0 * d / tot if tot else 0
        print(f"   {f // 1000:>5} MHz {pct:6.2f} %   ({d / 100:8.1f} s)  {'#' * int(pct / 2)}")

    # --- transitions
    ca, cb = trans_table(a), trans_table(b)
    edges = {k: cb.get(k, 0) - ca.get(k, 0) for k in cb if cb.get(k, 0) - ca.get(k, 0) > 0}
    ntr = sum(edges.values())
    print(f"transitions: {ntr} ({ntr / dt:.2f}/s)")
    for (f, t), n in sorted(edges.items(), key=lambda kv: -kv[1]):
        print(f"   {f // 1000:>5} -> {t // 1000:<5} {n:7d}  {n / dt:6.3f}/s")
    # mean residency per visit
    print("mean residency per visit:")
    for f in sorted(tb):
        arrivals = sum(n for (src, dst), n in edges.items() if dst == f)
        d = (tb[f] - ta[f]) / 100.0
        if arrivals:
            print(f"   {f // 1000:>5} MHz  {1000 * d / arrivals:7.1f} ms  over {arrivals} visits")

    # --- CPU busy
    pa, sa = proc_stat(a)
    pb, sb = proc_stat(b)
    print("cpu busy (delta):")
    for k in sorted(pb):
        da = [x - y for x, y in zip(pb[k], pa[k])]
        tot_j = sum(da)
        busy = tot_j - da[3] - da[4]
        if tot_j:
            print(f"   {k:<5} busy {100.0 * busy / tot_j:5.2f} %   "
                  f"user {100.0 * da[0] / tot_j:4.2f}  nice {100.0 * da[1] / tot_j:4.2f}  "
                  f"sys {100.0 * da[2] / tot_j:4.2f}  irq/sirq {100.0 * (da[5] + da[6]) / tot_j:4.2f}  "
                  f"(accounted {tot_j / USER_HZ:.0f}s of {dt:.0f}s)")
    print(f"ctxt {(sb['ctxt'] - sa['ctxt']) / dt:8.1f}/s     "
          f"forks {(sb['processes'] - sa['processes']) / dt:6.2f}/s")

    # --- per-cgroup CPU
    ga, gb = cgroups(a), cgroups(b)
    rows = []
    for k in gb:
        if k in ga:
            d = (gb[k] - ga[k]) / 1e6
            if d > 0.01:
                rows.append((d, k))
    rows.sort(reverse=True)
    print("per-cgroup CPU (% of ONE core):")
    for d, k in rows[:top]:
        name = k.replace("/sys/fs/cgroup/", "")
        print(f"   {name:<52} {100.0 * d / dt:6.3f} %  ({d:7.2f} s)")

    # --- wakeup sources
    ia, ib = irqs(a), irqs(b)
    rows = sorted(((ib[k] - ia.get(k, 0), k) for k in ib), reverse=True)
    print("IRQ rates:")
    for n, k in rows[:top]:
        if n / dt < 0.05:
            break
        print(f"   {k:<44} {n / dt:8.2f}/s   ({n})")
    sa_, sb_ = softirqs(a), softirqs(b)
    rows = sorted(((sb_[k] - sa_.get(k, 0), k) for k in sb_), reverse=True)
    print("softirq rates: " + "  ".join(f"{k}={n / dt:.1f}/s" for n, k in rows if n / dt >= 0.5))

    # --- idle + thermal
    ua = {ln.split()[0]: ln for ln in a.get("cpuidle", [])}
    ub = {ln.split()[0]: ln for ln in b.get("cpuidle", [])}
    for k in sorted(ub):
        if k not in ua:
            continue
        g = lambda ln, f: int(re.search(f + r"=(\d+)", ln).group(1))
        du = g(ub[k], "usage") - g(ua[k], "usage")
        dt_us = g(ub[k], "time") - g(ua[k], "time")
        print(f"cpuidle {k.split('/')[-3]}/{k.split('/')[-1]}: {du / dt:7.1f} entries/s   "
              f"residency {100.0 * dt_us / 1e6 / dt:5.1f} %   mean {dt_us / du if du else 0:6.0f} us")
    print("temp: " + "  ".join(f"{k.split('/')[-2]}={(temps(b)[k]) / 1000:.1f}C "
                               f"(was {(temps(a)[k]) / 1000:.1f})" for k in temps(b)))


def main():
    d = sys.argv[1] if len(sys.argv) > 1 else "."
    pairs = []
    for pre in sorted(glob.glob(os.path.join(d, "*_pre.snap"))):
        post = pre.replace("_pre.snap", "_post.snap")
        if os.path.exists(post):
            label = os.path.basename(pre).replace("_pre.snap", "")
            pairs.append((label, pre, post))
    if not pairs:
        sys.exit(f"no snapshot pairs in {d}")
    order = ["trace", "arm_baseline", "arm_sr100ms", "arm_sr100up95", "arm_sr20up95", "arm_powersave"]
    pairs.sort(key=lambda p: order.index(p[0]) if p[0] in order else 99)
    for label, pre, post in pairs:
        report(label, pre, post)


if __name__ == "__main__":
    main()
