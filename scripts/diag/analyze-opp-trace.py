#!/usr/bin/env python3
"""Answer 'what actually pulls an idle Nexus Q off 350 MHz' from an ftrace dump.

Reconstructs, from sched_switch pairs, exactly how long every task ran on every
CPU; then lines those runs up against the power:cpu_frequency events so each
ramp can be attributed to the burst that caused it.

The governor is `conservative`: every `sampling_rate` it compares busy time in
the window against up_threshold/down_threshold. So what matters is not average
CPU but BURST SHAPE — how much of one sampling window a wakeup fills.
"""
import gzip
import re
import sys
from collections import defaultdict

LINE = re.compile(
    r"^\s*(?P<comm>.+?)-(?P<pid>\d+)\s+\[(?P<cpu>\d+)\]\s+\S+\s+"
    r"(?P<ts>\d+\.\d+):\s+(?P<evt>\w+):\s*(?P<rest>.*)$"
)
SWITCH = re.compile(
    r"prev_comm=(?P<pc>.+?) prev_pid=(?P<pp>\d+).*?prev_state=(?P<ps>\S+) ==> "
    r"next_comm=(?P<nc>.+?) next_pid=(?P<np>\d+)"
)


def events(path):
    opener = gzip.open if path.endswith(".gz") else open
    with opener(path, "rt", errors="replace") as fh:
        for line in fh:
            if line.startswith("#") or not line.strip():
                continue
            m = LINE.match(line)
            if m:
                yield m


def main(path, sampling_ms=20.0, up_threshold=80.0):
    counts = defaultdict(int)
    runtime = defaultdict(float)          # comm -> seconds on cpu
    runs = []                             # (start, end, cpu, comm)
    freqs = []                            # (ts, cpu, khz)
    wakeups = defaultdict(int)
    irq = defaultdict(int)
    wq = defaultdict(int)
    forks = defaultdict(int)
    execs = defaultdict(int)
    hrtimer = defaultdict(int)
    cur = {}                              # cpu -> (comm, start_ts)
    t0 = t1 = None

    for m in events(path):
        ts = float(m["ts"])
        cpu = int(m["cpu"])
        evt = m["evt"]
        rest = m["rest"]
        counts[evt] += 1
        t0 = ts if t0 is None else t0
        t1 = ts

        if evt == "sched_switch":
            s = SWITCH.search(rest)
            if not s:
                continue
            prev, nxt = s["pc"], s["nc"]
            if cpu in cur:
                comm, start = cur[cpu]
                if not comm.startswith("swapper"):
                    runtime[comm] += ts - start
                    runs.append((start, ts, cpu, comm))
            cur[cpu] = (nxt, ts)
        elif evt in ("sched_wakeup", "sched_waking"):
            w = re.search(r"^(.+?):(\d+)", rest) or re.search(r"comm=(\S+)", rest)
            wakeups[w.group(1) if w else rest[:20]] += 1
        elif evt == "irq_handler_entry":
            n = re.search(r"name=(\S+)", rest)
            irq[n.group(1) if n else "?"] += 1
        elif evt == "workqueue_execute_start":
            f = re.search(r"function=(\S+)", rest)
            wq[f.group(1) if f else "?"] += 1
        elif evt == "sched_process_fork":
            f = re.search(r"comm=(\S+)", rest)
            forks[f.group(1) if f else m["comm"]] += 1
        elif evt == "sched_process_exec":
            f = re.search(r"filename=(\S+)", rest)
            execs[f.group(1) if f else "?"] += 1
        elif evt == "hrtimer_expire_entry":
            f = re.search(r"function=(\S+)", rest)
            hrtimer[f.group(1) if f else "?"] += 1
        elif evt == "cpu_frequency":
            st = re.search(r"state=(\d+)", rest)
            cid = re.search(r"cpu_id=(\d+)", rest)
            if st:
                freqs.append((ts, int(cid.group(1)) if cid else cpu, int(st.group(1))))

    span = (t1 - t0) if t0 and t1 else 0
    print(f"=== trace span {span:.1f} s, {sum(counts.values())} events")
    for k, v in sorted(counts.items(), key=lambda kv: -kv[1]):
        print(f"    {k:<28} {v:8d}  {v / span:9.2f}/s")

    print(f"\n=== CPU time by task (sched_switch reconstruction, {span:.1f} s window)")
    print(f"{'task':<24} {'run s':>8} {'% of 1 core':>12} {'slices':>8} {'mean ms':>9} {'max ms':>8}")
    per_task_runs = defaultdict(list)
    for s, e, c, comm in runs:
        per_task_runs[comm].append((e - s) * 1000.0)
    for comm, tot in sorted(runtime.items(), key=lambda kv: -kv[1])[:25]:
        sl = per_task_runs[comm]
        print(f"{comm:<24} {tot:8.3f} {100.0 * tot / span:11.3f} % {len(sl):8d} "
              f"{sum(sl) / len(sl):9.3f} {max(sl):8.2f}")
    total_busy = sum(runtime.values())
    print(f"{'TOTAL (both cores)':<24} {total_busy:8.3f} {100.0 * total_busy / span:11.3f} %"
          f"   -> {100.0 * total_busy / (2 * span):.3f} % of the 2-core machine")

    print("\n=== frequency timeline")
    print(f"transitions: {len(freqs)}  ({len(freqs) / span:.2f}/s)")
    res = defaultdict(float)
    ups = []
    for i, (ts, cid, khz) in enumerate(freqs):
        end = freqs[i + 1][0] if i + 1 < len(freqs) else t1
        res[khz] += end - ts
        if i and khz > freqs[i - 1][2]:
            ups.append((ts, freqs[i - 1][2], khz))
    tot = sum(res.values())
    for khz in sorted(res):
        print(f"    {khz // 1000:>5} MHz  {100.0 * res[khz] / tot:6.2f} %   ({res[khz]:7.2f} s)")

    # --- what ran in the sampling window that triggered each up-step
    print(f"\n=== attribution of {len(ups)} UP-transitions "
          f"(tasks running in the {sampling_ms:.0f} ms before each)")
    blame = defaultdict(float)
    blame_n = defaultdict(int)
    per_edge = defaultdict(int)
    win = sampling_ms / 1000.0
    runs.sort()
    for ts, frm, to in ups:
        per_edge[(frm // 1000, to // 1000)] += 1
        lo = ts - win
        seen = set()
        for s, e, c, comm in runs:
            if e < lo:
                continue
            if s > ts:
                break
            overlap = min(e, ts) - max(s, lo)
            if overlap > 0:
                blame[comm] += overlap
                seen.add(comm)
        for comm in seen:
            blame_n[comm] += 1
    for edge, n in sorted(per_edge.items(), key=lambda kv: -kv[1]):
        print(f"    {edge[0]:>5} -> {edge[1]:<5} {n:5d}  ({n / span:.2f}/s)")
    print(f"\n{'task':<24} {'cpu s in windows':>17} {'% of window time':>17} {'ramps present in':>18}")
    tot_win = len(ups) * win
    for comm, sec in sorted(blame.items(), key=lambda kv: -kv[1])[:20]:
        print(f"{comm:<24} {sec:17.3f} {100.0 * sec / tot_win if tot_win else 0:16.2f} % "
              f"{blame_n[comm]:17d}")

    # --- burst shape: can a single run fill a sampling window?
    print(f"\n=== burst shape vs the {sampling_ms:.0f} ms / {up_threshold:.0f} % ramp criterion")
    thresh_ms = sampling_ms * up_threshold / 100.0
    print(f"a single run must exceed {thresh_ms:.1f} ms to fill one window on its own")
    big = defaultdict(int)
    for comm, sl in per_task_runs.items():
        n = sum(1 for x in sl if x >= thresh_ms)
        if n:
            big[comm] = n
    for comm, n in sorted(big.items(), key=lambda kv: -kv[1])[:15]:
        sl = [x for x in per_task_runs[comm] if x >= thresh_ms]
        print(f"    {comm:<24} {n:6d} runs >= {thresh_ms:.0f} ms  ({n / span:6.3f}/s)  "
              f"longest {max(sl):8.2f} ms  total {sum(sl) / 1000:.2f} s")

    print("\n=== wakeup sources")
    for title, d in (("sched_wakeup target", wakeups), ("hard IRQ", irq),
                     ("workqueue fn", wq), ("hrtimer fn", hrtimer),
                     ("fork parent", forks), ("exec", execs)):
        rows = sorted(d.items(), key=lambda kv: -kv[1])[:12]
        if not rows:
            continue
        print(f"-- {title}")
        for k, v in rows:
            print(f"    {k:<40} {v:8d}  {v / span:8.2f}/s")


if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 else "trace.txt.gz")
