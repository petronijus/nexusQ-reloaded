# Idle power: the "hot idle" was mis-measured — the real faults were the governor and OUR healthd (v1.8.2)

**Date:** 2026-07-12 (evening) → 2026-07-13 · **Ships:** v1.8.2 = kernel **r43**
(`#44-postmarketOS`, defconfig-only) + `device-google-steelhead` **r40**
(nq-healthd rewrite + root linger; **r39 was burned**, see the gotcha) ·
**Acceptance:** `nq-captures/20260713-102339/` PASS ·
**Artifacts:** `output/nexusq-v1.8.2.sha256`

The AI-handover task was "snížit idle teplotu". Measurement first — and the
measurement rewrote the problem statement.

## Finding 1 — the ~74–76 °C "idle floor" was an OBSERVER ARTIFACT

A 686 s true-idle study on v1.8.1 (self-logging on-device, no ssh session open)
showed:

- **Any ssh/diag session pushes the die to 74–79 °C within seconds.** The
  thermal time constant is ~10 s, so every "let me quickly read the temp over
  ssh" measures the measurement.
- The **true unobserved idle floor is ~65–66 °C** — every prior "idle 74–76 °C"
  figure in our records was heated by the observer.

Diag rule going forward: judge idle temperature only from an **on-device
self-logging capture with no live session**, never from an interactive read.

## Finding 2 — the real problem: 74 % of idle spent at ≥700 MHz / ≥1203 mV

Same study, cpufreq residency at "idle":

- 350 MHz only **25.6 %**; **74 %** of idle at ≥700 MHz (≥1203 mV VDD_MPU),
  hovering ~920 MHz.
- Cause: **~1000 wakeups/s** with ~1.1–1.4 ms dwell each (twd local timer tick
  168/s, WiFi SDIO 29.5/s, AVR i2c 15.5/s, DISPC 4.9/s) hitting **ondemand**'s
  20 ms sampling window with `up_threshold=95` → a jump-to-max **3.7×/s** and a
  **17.5 transitions/s** sawtooth. The box idles busy-looking to the governor.

## Finding 3 — pid 1 was the top userspace idle consumer (steady 3.4 %) — root cause OURS

- **nq-healthd ran 5 `systemctl` execs per 5 s sample.** Every root `systemctl`
  opens pid 1's private bus and forces a full object-tree re-registration —
  that alone held pid 1 at ~3.3–3.4 %.
- Worse: **2 of the 5 queried `librespot.service` on the SYSTEM manager**, where
  it hasn't existed since device **r31** (it became a uid-10000 USER unit). pid 1
  loaded + GC'd a nonexistent unit from disk every poll, **and the healthd
  `ls_active`/`ls_restarts` fields were silently broken r31–r38** — librespot
  restart detection was dead the whole time (always `unknown`/`0`).
- Second amplifier: every ssh login built and tore down the whole
  `user@0.service` session — **~7.5 s CPU per login/logout cycle** (31 logins
  that boot).

## Governor A/B/C test (8-min windows, live sysfs, restored after)

| Candidate | 350 MHz | 1.2 GHz | trans/s | avg temp | verdict |
|---|---|---|---|---|---|
| ondemand (stock settings, baseline) | 25.6 % | high | 17.5 | 66.4 °C | sawtooth |
| ondemand `sampling_rate=100000` `up_threshold=80` `sampling_down_factor=5` | 21 % | — | — | — | **REGRESSION** — parks at high OPPs |
| ondemand `powersave_bias=100` | — | — | **39.9** | — | dithers |
| **conservative** | **51.5 %** | **9.6 %** | **4.16** | **65.1 °C** | **WINNER** |

**Lesson:** slower ondemand sampling does NOT tame microburst load — averaging
over a longer window still sees "busy" and jumps; `conservative`'s gradual
`freq_step` climb is what actually matches a 1000-wakeups/s, ~1 ms-dwell
workload. (This re-reverses the v1.6.6 "back to ondemand" defconfig change —
that one was about disproving the v1.5.0 rationale, not about idle residency,
which nobody had measured until now.)

## Fixes shipped (v1.8.2)

1. **defconfig: `CONFIG_CPU_FREQ_DEFAULT_GOV_CONSERVATIVE=y`** (ondemand still
   built) — kernel **r43**, uname `#44-postmarketOS`. No new patch; 42 patches
   unchanged.
2. **nq-healthd REWRITTEN process-first** (device r40): cached MainPID +
   `/proc` liveness check per sample; **ONE** `systemctl show` (3 props, one bus
   connection) only on transitions (pid unknown / vanished / reused — a unit
   restart always changes MainPID, so NRestarts bumps are still caught).
   librespot is queried on the **uid-10000 USER manager** — `ls_active` /
   `ls_restarts` work again for the first time since r31.
3. **Baked `/var/lib/systemd/linger/root`** (empty file = `loginctl
   enable-linger root`): root's user manager stays resident, killing the
   per-login `user@0` build/teardown churn.

### GOTCHA that burned r39: root cannot borrow the user's XDG_RUNTIME_DIR

The obvious `XDG_RUNTIME_DIR=/run/user/10000 systemctl --user show …` as root
**does not work** — systemd 261 refuses cross-user private-socket connections
(`Operation not permitted, consider using --machine=<user>@.host`). The correct
form is:

```sh
systemctl -M user@ --user show -p ActiveState -p MainPID -p NRestarts librespot.service
```

(verified on-device 2026-07-13; guard on `[ -d /run/user/10000/systemd ]` for
early boot). **r39 shipped the broken form** — `ls_active=unknown` again —
caught by the post-flash acceptance sweep (the [[run-diag-after-every-boot]]
rule paying out), fixed as **r40** + rebuild + reflash.

## Measured payoff (542 s idle re-study on final v1.8.2)

| Metric | v1.8.1 | v1.8.2 |
|---|---|---|
| 350 MHz idle residency | 25.6 % | **56.7 %** |
| ≥700 MHz idle residency | 74 % | **43.3 %** |
| 1.2 GHz idle residency | (part of 74 %) | **3.5 %** |
| freq transitions/s | 17.5 | **4.25** |
| pid 1 CPU | 3.4 % | **0.10 %** |
| idle temp avg | 66.4 °C | **65.8 °C** |
| idle settle | hovers ~920 MHz | **settles at 350 MHz** |

The remaining **~65 °C structural floor is C1-only MPUSS** (deep cpuidle C2+
blocked on serial access — unchanged).

## Acceptance sweep (nq-captures/20260713-102339) — PASS

All v1.8.1 regressions-to-watch clean: DPLL_ABE **98.304 MHz** under sys_clkin,
sDMA GCR **0x00011010**, WiFi associated (`.184`), BT **0** frame-reassembly,
`dmesg` err/warn **EMPTY**, **0 failed units**. Thermal peak **97.2 °C** under
bounded load — inside the known ~94–99 °C watch band, no throttle.

**NEW journal residual (#4):** a one-shot
`NetworkManager: sd-event.c:4488 assertion failed` exactly at the RTC→NTP clock
step — NM's **vendored libsystemd** asserting on the huge CLOCK_REALTIME jump
(this box has no RTC battery; clock jumps years at NTP sync). NM continued
fine; WiFi associated the same second. Disposition: **external/upstream**, added
to the known-residual set in `docs/2026-07-02-boot-error-inventory.md`.
Potential real fix (upstream NM, or ordering the clock step before NM start) =
backlog, not cleanly ours-fixable in-tree.

**Artifacts** (`output/nexusq-v1.8.2.sha256`, flashed to device):
`nexusq-boot-v1.8.2.img` sha256
`1c589a70ffc10e4ac0ea7197a420e5168d43da64d0e902160dcf90a0ee977d0c` (5,545,984 B),
`nexusq-rootfs-v1.8.2-sparse.img` sha256
`6538e0ba225f63585551604f0323ad4d3bdfa8d67347e27e15acbeebdddb8a02`.

## Durable operational lessons

- **`timeout 12 sh -c "yes & yes & wait"` ORPHANS the `yes` children** —
  timeout kills the wrapper shell, the loads keep running. Timeout each load
  process individually (`timeout 12 yes >/dev/null & timeout 12 yes >/dev/null &
  wait`). (Directly relevant to the [[no-unbounded-cpu-load-on-device]] rule.)
- healthd's `dmesg_err` matcher counts **info-level** brcmfmac `clm_blob` lines
  — cosmetic false positives in `kern_new_err`; refinement candidate, not a
  device fault.
- The **uid-10000 user manager** (`systemd --user`) is now the **#2 idle
  consumer at 1.28 %** — minor watch item.

## Remaining idle backlog

- **HDMI desktop idle policy** (Todoist p3): DPMS never blanks at the DRM level
  — the desktop keeps DISPC awake forever.
- **Deep cpuidle C2+** (p4): the actual ~65 °C floor; BLOCKED on serial.
- Watch: `user@10000` manager idle share (1.28 %).
