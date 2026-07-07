# Nexus Q diagnostics

A small suite for capturing and analyzing the runtime state of the Nexus Q
(steelhead) — built because the hard bugs here are **intermittent runtime
faults** (the LED ring "rotation" freezing, power/governor misbehaviour, the
occasional crash) and the **device link is flaky**, so "SSH in and poke around"
is slow and lossy. The suite turns that into: *one command → a saved, analyzed
capture.*

## Layout

| Tool | Side | What it does |
|------|------|--------------|
| `pmos/device-google-steelhead/nq-healthd` | device | continuous health monitor → `/var/log/nq-health/{health,events}.jsonl` (systemd `nq-healthd.service`, enabled by the device package) |
| `pmos/device-google-steelhead/nq-diag-snapshot` | device | comprehensive read-only "log everything" one-shot dump |
| `scripts/diag/nqctl` | host | reach the device over the best link (ethernet `10.42.0.2` first, then USB-net / WiFi / serial), incl. `net-usb up` (RNDIS gadget + host NAT) |
| `scripts/diag/nq-collect` | host | **the engine**: connect → snapshot → pull/burst samples → save locally → analyze |
| `scripts/diag/nq-health-report` | host | analyze a capture → findings (human + JSON) |
| `.claude/skills/nexusq-diag/` | — | agent skill wrapping `nq-collect` + interpretation guidance |

Captures land in `nq-captures/<timestamp>/` (git-ignored; `nq-captures/latest`
points at the newest).

## Quick start

```sh
scripts/diag/nq-collect            # full capture + analysis to nq-captures/<ts>/
cat nq-captures/latest/report.txt  # the findings

# ad-hoc:
scripts/diag/nqctl status                 # which links are up
scripts/diag/nqctl run 'nq-diag-snapshot --brief'
scripts/diag/nqctl logs --follow          # tail the live health log
scripts/diag/nqctl net-usb up             # USB-gadget fallback (ethernet 10.42.0.2 is the default)
scripts/diag/nq-health-report nq-captures/latest   # re-analyze a capture
```

`nq-collect` works against **today's image too**: if the device doesn't yet ship
`nq-healthd`/`nq-diag-snapshot`, it pushes them to `/tmp` and gathers a short
live burst instead of reading the persistent log.

## What gets sampled, and why

All sources were verified against the live device + the kernel/DTS, not guessed.

**Compute / governor** — `…/cpu0/cpufreq/{scaling_governor,scaling_cur_freq,…}`,
`nproc`, `/sys/kernel/debug/clk/dpll_mpu_ck/clk_rate`. OPPs: 350/700/920/1200 MHz.
cpufreq stats are off in the kernel on images up to v1.6.5 (`CONFIG_CPU_FREQ_STAT`
not set → no `cpufreq/stats/time_in_state`), so residency is built by sampling
`scaling_cur_freq` over time. _(Since the 2026-07-03 flash — verified on device:
the defconfig enables `CPU_FREQ_STAT` and defaults the governor back to
`ondemand`, so `time_in_state` exists and the sampling fallback is just a
cross-check.)_ Note idle is **not** 350 MHz here — it
hovers ~920 MHz because nexusqd's LED polling keeps the clock up.

**Power delivery** — every `/sys/class/regulator/regulator.*` (resolved by the
`name` attribute, not the opaque index). `vdd_mpu` is checked against the
expected voltage for the current OPP (350→1025, 700→1203, 920→1317, 1200→1380 mV);
`abb_mpu` reflects ABB/FBB mode. Drift here points at the VC-bridge / TPS62361
path (path B).

**Thermal** — `thermal_zone0` (`cpu_thermal`), trips at 100 °C (passive) and
125 °C (critical), plus `cooling_device0/cur_state` for active throttling.

**LED ring / nexusqd / AVR** — the ring is 32 `steelhead:rgb:ring-*` LEDs (+ a
`mute` LED) driven by the userspace daemon **nexusqd** (control socket
`/run/nexusqd.sock`, queried via `nexusled status`) through an on-board **AVR**
MCU on i2c (IRQ line `steelhead-avr`). nexusqd has **no systemd watchdog**, so a
*hang* (vs a crash) is invisible to systemd — we detect it via socket
unresponsiveness + a frozen LED frame + no daemon CPU progress. The frame
fingerprint reads the AVR driver's **`frame` bin_attr** (readable since kernel
patch 0029 / healthd r20 — md5 + byte sum of the committed frame), falling back
to the classdev `brightness` sample spread on pre-0029 kernels (where it is
blind to nexusqd's writes — see the bug note below).

> **A dark ring is NOT a hang by itself.** If the ring is dark **but the control
> socket answers** (`nexusled status` returns, `nq_resp=1`), that is **not** a
> `nexusqd_hang` (a hang requires the socket to be **dead**). It is one of two
> non-hang states:
> - **idle-off / blank** — by design, after the screensaver blank timeout
>   (`SS_BLANK_S=600 s`) the daemon renders a black frame. Observed 2026-06-28: a
>   dark-but-responsive ring tripped a false CRIT that was not a daemon hang.
> - **AVR starvation** (FIXED in v1.6.5) — a dark ring after a **long** idle/uptime
>   (~20 h observed) with the socket alive was **not** benign idle-off: the
>   `steelhead-avr` MCU firmware (fw `0x00`) **starves** — its host-frame watchdog
>   stops lighting the ring if the host sends no frame *commit* for too long. Once the
>   screensaver locked to a **static** frame (`SS_LOCK_S=300 s`, `ledAlpha` constant
>   `0.1`) / blanked, `nexusqd`'s per-frame `memcmp(pk,lastpk)` write-gate suppressed all
>   commits, so the AVR received none and went dark until a daemon restart. **Fix:**
>   `nexusqd` (pkgrel 5) now re-commits the current frame every `AVR_KEEPALIVE_S=1.0 s`
>   even when unchanged. If a dark-after-long-idle ring recurs on a **≥ v1.6.5** image,
>   suspect the keepalive stopped (check `nexusqd` is up and the render loop is ticking)
>   rather than a design blank. See `docs/2026-07-01-led-ring-avr-starvation-keepalive.md`.

**Crashes / kernel** — new error lines in `dmesg`
(oops/WARN/stall/i2c-timeout/omap_voltage/brownout/thermal-shutdown) and
`/sys/fs/pstore` (survives a *warm* reboot only).

## Finding kinds (from `nq-health-report`)

`nexusqd_hang`, `led_frozen`, `led_static`, `nexusqd_no_progress`,
`nexusqd_down`, `nexusqd_restart`, `librespot_restart`, `vdd_mismatch`,
`thermal_high`, `thermal_throttle`, `thermal_crit`, `thermal_cooling_active`,
`governor_not_scaling`, `governor_no_turbo`, `freq_residency`, `kernel_errors`,
`pstore`, `snapshot_truncated`, `failed_unit`. Each carries severity
(crit/warn/info) and, where meaningful, the `t_mono` uptime so the report can
print the per-sample timeline around it. Since 2026-07-04 a stalled LED frame
splits by distress: crit **`led_frozen`** only when `nq_resp=0`/`nq_progress=0`
co-fires; a static frame with a healthy daemon is info **`led_static`**
(screensaver static-by-design), and the summary carries both
`led_frozen_events` and `led_static_events`.

> **Known nq-healthd bugs (found by the 2026-07-03 acceptance run; FIXED
> on-device since the `#29` flash 2026-07-03 — kernel patch 0029 +
> `device-google-steelhead` r20 — but still live on any `#27`/r19-or-older
> device):**
> - **`led_frozen` is a permanent FALSE CRIT on nexusqd r5+ (≤ r19)** — healthd
>   fingerprints the led_classdev `brightness` attributes, but nexusqd commits
>   frames via the **write-only `frame` bin_attr**, so the sampled `led_sum` is
>   structurally 0 and the frozen heuristic always trips. On those images ignore
>   `led_frozen`; judge the ring by `nq_resp`/`nexusled status`. **Fix (r20):**
>   patch 0029 makes `frame` readable (0644) — the system previously had NO
>   readable ring-state source — and healthd fingerprints it (md5 + byte sum),
>   keeping the brightness loop only as a pre-0029 fallback.
>   ✅ **Static-by-design guard SHIPPED 2026-07-04 (healthd r21 +
>   `nq-health-report`; baked + flashed since v1.6.7, 2026-07-05).** The
>   screensaver intentionally locks
>   a **static** frame after ~300 s idle and the v1.6.5 keepalive re-commits
>   identical bytes, so the (now real) fingerprint legitimately stops changing
>   on a healthy idle device — that used to end verdict=CRIT (the `#29`
>   acceptance capture did exactly this, `nq_resp=1` throughout). Now
>   `led_frozen` is CRIT **only** when `nq_resp=0` or `nq_progress=0` co-fires
>   in the stalled samples; a healthy static frame emits **info `led_static`**.
>   Regression-tested on `nq-captures/20260703-144228/`: verdict CRIT → OK,
>   `led_static … 25 occasion(s)`. **Verified live on the flashed v1.6.7
>   acceptance (2026-07-05): 33× info `led_static`, zero false CRIT in 91
>   samples.** (On a device still running healthd ≤ r20, the idle false CRIT
>   persists until the r21 image is flashed.)
> - **`vdd_mismatch` can be fabricated by non-atomic sampling (≤ r19)** — freq
>   and vdd are read at different instants, so a DVFS transition between the
>   reads looks like a mismatch (17/71 samples in the acceptance capture).
>   **Fix (r20):** the sample is judged only when `scaling_cur_freq` holds
>   across the vdd read. Verified clean in the `#29` acceptance capture
>   (2026-07-03, `nq-captures/20260703-144228/`). **Residual race (2026-07-05,
>   minor/warn-only):** the freq-hold guard is not fully atomic — the v1.6.7
>   acceptance saw **1/91 samples** slip past it (a DVFS transition landing
>   between the two matching freq reads and the vdd read). A single isolated
>   `vdd_mismatch` warn is still noise; only a persistent run means a real
>   power-path fault.

> **`librespot_restart` ≠ the "Spotify skips" symptom.** `librespot_restart` is a
> real *service* flap (the unit's `NRestarts` grew). **Historical (FIXED in v1.6.1):**
> on v1.6.0 a librespot/Spotify track that **played then auto-skipped ~40 s in** was
> instead the **TAS5713 2× speed bug** — card `NexusQSpeaker` (McBSP2 → TAS5713) emitted
> FSYNC at 2× the requested rate, so audio drained in half wall-clock and the player
> advanced to the next track (librespot staying up). Fixed by kernel patch 0022 (derive
> McBSP2 `CLKGDV` from the real fclk); the speaker now plays at 1.000×. If that ~40 s
> auto-skip ever returns it's an audio-clock regression, not `librespot_restart`. See
> `docs/2026-06-29-spotify-connect-and-tas5713-2x-speed.md`.

## Packaging

The device package (`pmos/device-google-steelhead/APKBUILD`) installs
`nq-healthd` + `nq-diag-snapshot` to `/usr/bin` and enables
`nq-healthd.service` by default, so a freshly built image is already recording
health and a capture needs no bootstrap. The existing boot script
`scripts/device-nexus-diag.sh` now calls `nq-diag-snapshot` for its log (with an
inline fallback).

## Known follow-ups surfaced by this work

- **nexusqd has no watchdog** — a hang is unrecoverable. Real fix: sd_notify +
  `WatchdogSec=` in `pmos/nexusqd/` (so systemd restarts a wedged daemon).
- **RTC is wrong** (year 2000 until NTP) — timestamps use monotonic uptime;
  worth fixing RTC/NTP independently.
