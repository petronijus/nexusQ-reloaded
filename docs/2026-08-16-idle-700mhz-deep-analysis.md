# 2026-08-16 — Why an idle Nexus Q sits at 700 MHz, and what actually moves it

Follow-up to `docs/2026-08-16-idle-opp-remeasure.md`, which established the new
baseline (**70.7 % @ 350 MHz**) and re-pointed the STANDING GOAL at the residual
**22.6 % @ 700 MHz**. This note answers the next question — *what keeps putting
it there, and what can be done* — from measurement rather than inspection.

**Headline: the idle machine is only 3.8 % busy, but that CPU arrives as roughly
one long burst per second, and `conservative` turns every burst ≥16 ms into a
ramp. The bursts come from short-lived processes and from pid 1 — not from the
daemons. Changes that do not touch ramp responsiveness at all were shipped the
same evening and **measure 90.99 % @ 350 MHz on the device**, against a 72.4 %
same-conditions baseline, with 920/1200 MHz at 0.17/0.02 %. A wider sampling
window on top reached 98.7 % in the A/B, but that one needs a listening test.**

## Method

Two detached studies (`/usr/local/bin/nq-opp-study.sh`, round 2
`nq-opp-study2.sh`), each launched as a transient systemd unit and fetched
**once**, afterwards — an open ssh session heats the die from ~59 °C to ~68 °C
within seconds and drags the OPP up with it (2026-07-13 Finding 1, re-confirmed
today: the static probe alone moved `thermal_zone0` to 68.1 °C).

- **Phase 1** — 60 s of ftrace events (`power:cpu_frequency`, `sched_switch`,
  `sched_wakeup`, `irq_handler_entry`, `workqueue_execute_start`,
  `hrtimer_expire_entry`, fork/exec). `perf`, `trace-cmd` and `bpftrace` are not
  on the image and `available_tracers` is only `nop`, but the full event set is
  compiled in, which is all this needs.
- **Phase 2** — five 12-minute A/B arms, each measured from kernel
  `time_in_state` / `trans_table` deltas plus per-cgroup `cpu.stat`,
  `/proc/interrupts` and `/proc/softirqs` deltas.
- Both studies abort themselves and restore production settings if any audio
  unit goes active, so a listening session can never be measured — or run at a
  pinned 350 MHz — by accident.

Analysis tooling: `scripts/diag/nq-opp-study.sh` + `nq-opp-study2.sh` (device),
and on the host `scripts/diag/analyze-opp-snaps.py` /
`scripts/diag/analyze-opp-trace.py` (see §Tooling).

## The mechanism

`conservative` on this device, as shipped:

| knob | value |
|---|---|
| `sampling_rate` | **20 000 µs = 20 ms** |
| `up_threshold` | **80 %** |
| `down_threshold` | **20 %** |
| `freq_step` | 5 % of max = 60 MHz → always exactly one OPP step |
| `ignore_nice_load` | 0 |

Only four OPPs exist (350/700/920/1200 MHz at 1025/~1200/~1313/1380 mV) and both
CPUs share one policy (`related_cpus 0 1`), so the governor takes the **max load
across both cores** and steps one OPP per sampling tick. Three consequences:

1. **Any single run ≥16 ms ramps the clock** — that is 80 % of a 20 ms window,
   filled by one task on one core.
2. **Sustained bursts climb multiple steps**: 60 ms of work walks 350 → 700 →
   920 → 1200.
3. **Between 20 % and 80 % the governor does not come down at all, it holds.**
   At 700 MHz a mere 4 ms of work per 20 ms window is enough to pin it there —
   which is why the mean stay at 700 MHz was 227 ms rather than the ~40 ms a
   pure up-and-down transit would cost.

`schedutil` — which would derive frequency from PELT utilisation instead of
step-wise thresholds — is **not compiled in** (`scaling_available_governors` =
conservative, ondemand, userspace, powersave, performance;
`CONFIG_CPU_FREQ_GOV_SCHEDUTIL` is absent from `kernel/configs/steelhead_defconfig`,
as is `CPU_IDLE_GOV_TEO`). Only one cpuidle state exists — `C1, MPUSS ON` — so
idle power is dominated by the voltage the OPP holds, which is exactly why the
STANDING GOAL is framed on 350 MHz residency.

## What runs on an idle device (60 s ftrace, reconstructed from sched_switch)

Total busy **7.6 % of one core / 3.8 % of the two-core machine**.

| task | % of one core | slices | mean | **longest** | **runs ≥16 ms** |
|---|---|---|---|---|---|
| **systemd (pid 1)** | **1.94 %** | 190 | 6.2 ms | **59.1 ms** | **27** |
| **nq-healthd** | **1.41 %** | 153 | 4.2 ms | 40.1 ms | **18** |
| python3 (pid 417, daemon) | 0.52 % | 190 | 2.1 ms | 9.4 ms | 0 |
| avahi-daemon | 0.23 % | 417 | 0.34 ms | 6.3 ms | 0 |
| grep (healthd children) | 0.28 % | 24 | 7.1 ms | 24.2 ms | 4 |
| nq-opp-study.sh (our own) | 0.24 % | 31 | 4.6 ms | 30.4 ms | 3 |
| systemctl | 0.22 % | 88 | 1.5 ms | 20.0 ms | 1 |
| kworker/u11:0 | 0.18 % | 1489 | 0.07 ms | 0.9 ms | 0 |
| nexusqd | 0.069 % | 174 | 0.24 ms | 0.9 ms | 0 |

**The last column is the whole story.** 62 runs crossed the 16 ms ramp threshold
in 60 s; the trace recorded 48 up-transitions in the same window — very nearly
one ramp per long run. Long-lived daemons (python, avahi, nexusqd, the kworkers)
consume CPU in slices far too short to move the governor; **short-lived
processes and pid 1 are what actually drives the clock.**

Attribution of the 48 up-transitions by what was on-CPU in the preceding 20 ms:
**systemd 13.6 % of that window time (present in 11 ramps), python3 9.7 % (10),
nq-healthd 7.2 % (4)**. (The kworkers appearing in ~30 of them are the
governor's own `dbs_work_handler` setting the frequency — an artefact, not a
cause.)

### Why pid 1 is the biggest single ramp generator

`/usr/bin/systemctl` is executed **0.33×/s** on an idle device. Each invocation
costs a fork+exec *and* wakes pid 1 to serve it, and pid 1's service slices run
up to **59 ms** — three consecutive ramp windows on their own. The callers are
`nq-healthd`'s `sv()` show parser, `nexusq-mqtt` (it polls the state of the four
audio units for telemetry), `nexusq-wifi-watchdog`, and — measured, and fixed
for round 2 — **this study's own playback guard**.

A running unit has a cgroup directory and a stopped one does not, so
`[ -d /sys/fs/cgroup/system.slice/<unit> ]` answers the same question with **no
fork and no pid-1 wakeup**. `nq-healthd` already uses exactly this trick for
librespot liveness (`cg_scan`, r71); the remaining callers do not. Verified
against the captured snapshots: the four stopped audio units have no cgroup
directory, the three running services do.

### A hypothesis this disproved

The cumulative `trans_table` since boot showed arrivals at 700 MHz at
**1.008/s**, which matched nexusqd's 1 Hz AVR keepalive so exactly that it
looked like the culprit. **The trace refutes it**: nexusqd uses 0.069 % of a
core with a longest run of 0.9 ms and appears in none of the ramp windows. The
1 Hz figure was an average over 5.85 days that still contained the pre-r13/r71
workload; in the current steady state arrivals at 700 MHz run at 0.5/s. The
i2c keepalive is real (10.3 IRQ/s on `48072000.i2c`) but costs almost no CPU.

### Wakeup sources, for completeness

Hard IRQs: `twd` 69.6/s, IPI 50.1/s, **`mmc4` (WiFi SDIO) 25.1/s**,
`omap-dma-engine` 19.3/s, `48072000.i2c` (LED ring) 10.3/s, `mmc0` 3.4/s,
`brcmf_oob_intr` 3.1/s. hrtimers: `tick_nohz_handler` 35.1/s,
**`ehci_hrtimer_func` 8.9/s** — the USB host controller polls even though the
Q's ethernet (a USB-attached `smsc95xx`) has no cable in it. These cost
wakeups, not much CPU, and none of them produce a ≥16 ms run.

## Round 1 — governor A/B (5 × 12 min, identical conditions)

| arm | 350 MHz | 700 | 920 | 1200 | trans/s | busy (1 core) | rel. dynamic power |
|---|---|---|---|---|---|---|---|
| **baseline** 20 ms / 80 | 64.66 % | 25.40 | 7.93 | 2.01 | 1.55 | 5.22 % | 1.81 (+81 % vs floor) |
| 20 ms / **95** | 72.31 % | 21.43 | 5.36 | 0.90 | 1.22 | 5.60 % | 1.60 (−12 %) |
| **100 ms** / 80 | 76.93 % | 22.88 | **0.19** | **0.00** | 0.37 | 6.31 % | 1.41 (−22 %) |
| **100 ms / 95** | **92.11 %** | 7.89 | **0** | **0** | 0.12 | 6.85 % | **1.14 (−37 %)** |
| powersave (locked 350) | 100 % | 0 | 0 | 0 | 0 | 7.06 % | 1.00 (−45 %) |

Relative dynamic power is f·V² normalised to 350 MHz/1025 mV — a proxy for the
switching term only; leakage tracks the same voltage, so it moves the same way.

Three things this settles:

1. **Widening the sampling window alone erases the two hot OPPs.** 920 + 1200
   MHz go from 9.9 % to 0.19 % with no threshold change: a burst cannot fill
   80 % of a 100 ms window often enough to climb two steps.
2. **`up_threshold` alone is the weaker lever** (+7.7 pp) — because at 20 ms
   even a 19 ms burst clears 95 %.
3. **Nothing at idle needs more than 350 MHz.** Locked at the bottom OPP the
   machine is 7.06 % busy and everything keeps working. The extra busy time in
   the lower arms (5.22 → 7.06 %) is simply the same work taking longer at a
   lower clock — the expected trade, and irrelevant at this level of load.

**Caveat on absolute values:** the baseline arm reads 64.7 % where the passive
79 h measurement read 70.7 %. The difference is this study's own overhead (its
`systemctl`-based playback guard, since fixed). Arm-to-arm comparison is
unaffected — every arm carries the identical load — but the absolute numbers
here are ~6 pp pessimistic.

Die temperature was inconclusive over 12 min arms (60.8–63.1 °C, sensor
resolution ~1.1 °C); a thermal claim needs a multi-hour window.

## Round 2 — targeted arms (5 × 12 min)

The round-1 winner buys the most but slows the ramp for **real** load too.
`ignore_nice_load` is a sharper instrument: `conservative` counts nice time as
load by default, so renicing the housekeeping daemons and setting
`ignore_nice_load=1` makes their bursts invisible to the governor **while the
audio path — never nice'd, PA running RT — still ramps exactly as fast as
today**. `down_threshold` was the other suspect: at 20 % it is what glues the
CPU to 700 MHz for 318 ms per visit.

| arm | 350 MHz | 700 | 920 | 1200 | trans/s | ms per 700 MHz visit | rel. power |
|---|---|---|---|---|---|---|---|
| **base2** (production) | 72.37 % | 21.04 | 5.70 | 0.89 | 1.43 | 317.9 | 1.60 |
| `ignore_nice_load=1` + hk `Nice=19` | 77.49 % | 19.62 | 2.62 | 0.27 | 1.26 | 320.8 | 1.44 (−10 %) |
| `down_threshold=40` | 78.18 % | 17.85 | 3.73 | 0.24 | 1.57 | 237.8 | 1.45 (−10 %) |
| **both of the above** | **86.16 %** | 13.18 | 0.61 | 0.05 | 1.30 | 205.7 | 1.25 (−22 %) |
| **combo** (+ 100 ms / 95) | **98.74 %** | 1.26 | **0** | **0** | **0.04** | 650 | **1.02 (−36 %)** |

- The two targeted levers are **independent and additive** (+5.1 pp and +5.8 pp
  alone, +13.8 pp together) and they attack different things: nice+ignore hides
  the housekeeping *bursts* (920 MHz residency falls 5.70 → 2.62 %), while
  `down_threshold=40` shortens the *tail* (mean stay at 700 MHz 318 → 238 ms).
- **The combo arm reaches 98.74 % @ 350 MHz with 28 transitions in 12 minutes**
  (0.04/s against 1.43/s) — 2 % above the theoretical floor of a locked 350 MHz
  CPU, and it never touches 920 or 1200 MHz at all.
- Busy time rises 4.72 → 5.92 % of one core across the range, i.e. the same work
  taking longer at a lower clock. Nothing misbehaved in any arm.

### A measured bonus: what `systemctl` polling costs

Round 2's playback guard was changed from `systemctl is-active` to the cgroup
directory test, and **nothing else about the production arm changed**. Measured
350 MHz residency went from **64.66 % (round 1) to 72.37 % (round 2)** — and
the round-2 figure lands within 1.7 pp of the passive 79 h measurement (70.7 %),
i.e. round 2 barely perturbs the device at all.

Removing roughly **0.13 `systemctl` executions per second** is what changed.
Production still runs ~0.33/s of them. The two arms ran about an hour apart so
this is not a controlled A/B, but it agrees with the trace attribution (pid 1:
27 runs ≥16 ms per minute, longest 59 ms) and puts a number on the lever.

## Verified on the device (2026-08-16, after shipping)

Recommendations 1 and 2 were implemented and installed the same evening —
`device-google-steelhead` **r73**, `nexusq-btagent` **r5**, `nexusq-mqtt` **r3** —
and re-measured with the same 12 min harness:

| | base2 (before) | **shipped** |
|---|---|---|
| 350 MHz | 72.37 % | **90.99 %** |
| 700 MHz | 21.04 % | 8.83 % |
| 920 MHz | 5.70 % | 0.17 % |
| 1200 MHz | 0.89 % | 0.02 % |
| mean stay at 700 MHz | 318 ms | 170 ms |
| **init.scope (pid 1)** | 1.49–2.15 % of a core | **0.186 %** |
| nexusq-btagent | 1.00 % | 0.55 % |
| idle busy (1 core) | 4.72 % | 4.08 % |
| rel. dynamic power | 1.60 | **1.16 (−27.5 %)** |

**+18.6 pp — better than the 86.2 % the governor A/B predicted**, because that
arm still carried btagent's `systemctl` polling. The ~10× collapse of pid 1 is
the trace's attribution confirmed end-to-end: remove the `systemctl` execs and
the largest ramp generator on the device simply stops existing. What remains is
16 % above the floor of a CPU locked at 350 MHz.

## Ranked recommendations

**1. Stop polling `systemctl` on a timer — code, no downside.** Replace
`systemctl is-active <unit>` with `[ -d /sys/fs/cgroup/system.slice/<unit> ]` in
`nexusq-mqtt` (it polls four audio units per publish), `nq-healthd`'s `sv()`,
and `nexusq-wifi-watchdog`. Removes a fork *and* a pid-1 wakeup per call, and
pid 1 is the single largest ramp generator on the device. Indicative worth:
~8 pp. `nq-healthd` already does this for librespot liveness, so the pattern is
in-tree.

**2. `ignore_nice_load=1` + housekeeping `Nice=19` + `down_threshold=40` —
measured +13.8 pp (72.4 → 86.2 %), −22 % relative dynamic power.** Ramp
responsiveness for real load is **unchanged** (`sampling_rate` and
`up_threshold` stay at 20 ms / 80), because the only thing being hidden is nice
time. Ship as unit-file `Nice=` plus a cpufreq drop-in. Suggested scope:
`nq-healthd`, `nexusq-mqtt`, `nexusq-wifi-watchdog`, `nexusq-btagent`,
`nexusq-nfc` — but **not `nexusq-control`**, which serves the companion app's
volume RPC; the trace shows it never produces a run ≥16 ms anyway, so nothing is
lost by leaving it at nice 0.

**3. The `nq-healthd` C rewrite** (already item 2 of the 08-13 continue-list) —
18 runs ≥16 ms per minute and a 40 ms longest slice come from its ~6 forks per
tick (`grep` alone was measured at up to 24 ms per exec). This is the last big
burst source after (1).

**4. Aggressive governor (`sampling_rate=100 ms`, `up_threshold=95`) — only
after a listening test.** Combined with (2) it measured **98.74 %**, but it
delays the ramp for genuine load: reaching 1200 MHz now takes ~300 ms of
sustained demand instead of ~60 ms. At idle that is free; at the start of
playback it is exactly the kind of thing that produces a first-second glitch.
**Do not ship this without Petr driving a real listening test** (Spotify /
AirPlay / USB audio start, plus a volume sweep) with `dmesg` watched for XRUNs.

**5. Smaller wakeup sources, for later.** `ehci_hrtimer_func` fires 8.9×/s even
though the USB-attached `smsc95xx` ethernet has no cable in it (runtime PM for
the EHCI root port?); `avahi-daemon` wakes 6.9×/s; WiFi `mmc4` interrupts at
25/s because `mpc=0` (power save deliberately disabled for link stability —
changing it back trades idle wakeups against the 2026-07-07 flakiness work).
None of these produces a ≥16 ms run, so they cost wakeups rather than OPP
residency.

**6. For the upcoming cold build: add `CONFIG_CPU_FREQ_GOV_SCHEDUTIL`** (and
optionally `CPU_IDLE_GOV_TEO`) to `steelhead_defconfig`. A utilisation-driven
governor is structurally the right answer to bursty housekeeping and cannot be
evaluated at all today because it is not compiled in. The kernel has to be
rebuilt for the cold-build verification anyway, so the option costs nothing to
carry.

**Not recommended:** locking `powersave`. It reaches 100 % but removes the
headroom real playback needs, and (2)+(4) already come within 1.3 pp of it.

## Errata from this session

- The round-2 script left every housekeeping daemon at **nice 19** after the run:
  `RENICED` accumulated across two consecutive `hk19` arms, so the restore
  replayed `pid:10` and then `pid:19` for the same pid and the last write won.
  Caught by reading the device back afterwards, restored to each unit's
  configured `Nice=`, and fixed in `scripts/diag/nq-opp-study2.sh` (`unnice`
  now runs at the start of every arm). Governor state was restored correctly by
  the EXIT trap in both rounds — verified: `conservative`, 20000, 80, 20,
  `ignore_nice_load=0`.
- The **1 Hz AVR keepalive hypothesis was wrong** (see above). It was raised
  from cumulative counters and disproved by the trace within the same session.

## Tooling

- `scripts/diag/nq-opp-study.sh` — the detached study (ftrace phase + A/B arms,
  playback-guarded, restores every knob through an EXIT trap).
- `scripts/diag/analyze-opp-snaps.py` — snapshot pairs → per-arm OPP residency,
  transition matrix, mean residency per visit, per-cgroup CPU, IRQ/softirq
  rates, cpuidle, temperature.
- `scripts/diag/analyze-opp-trace.py` — ftrace dump → per-task CPU
  reconstruction, **burst-length histogram against the ramp threshold**, and
  attribution of every up-transition to what was running before it.

## Provenance

Device `nexusqd` r13 · `device-google-steelhead` r72 · `nexusq-mqtt` r2, kernel
6.12.12 SMP, uptime 5.85 d, no reboot. WiFi 192.168.20.246 (the eth-direct
10.42.0.2 address was occupied by the Nokia RM-875 pmOS box). All streaming
services off throughout; both studies self-abort if that changes. Raw data:
`/var/log/nq-opp-study{,2}/` on the device, copies in the session scratchpad.
