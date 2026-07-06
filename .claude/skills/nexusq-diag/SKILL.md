---
name: nexusq-diag
description: >-
  Run a full hardware/runtime diagnostic of the Google Nexus Q (steelhead)
  postmarketOS device: collect a comprehensive on-device snapshot plus a window
  of runtime health samples over the best available link, save everything
  locally on this PC, and analyze it for faults — LED-ring / nexusqd hangs,
  power delivery / VDD_MPU-vs-OPP drift, thermal throttling, cpufreq-governor
  stalls, kernel errors, and crash dumps. Use when asked to diagnose or
  health-check the Nexus Q, investigate the LED "rotation" freezing or stopping
  responding, verify power/governor/temperature behaviour, or capture device
  state for later analysis. Trigger phrases: "diagnose nexus", "nexus q health
  check", "zkontroluj nexus", "co je s nexusem", "nexus diagnostika", "led
  rotace spadla / přestala reagovat", "capture nexus state".
---

# Nexus Q diagnostic

This skill drives the diagnostic tooling in `scripts/diag/`. The heavy lifting is
deterministic (shell + Python); your job is to run it, read the analyzed report,
and reason about the findings — then dig into the raw capture only where a
finding points.

## Run it

From the repo root:

```sh
scripts/diag/nq-collect
```

`nq-collect` will, on its own:
1. find a working link to the device (`nqctl`: prefers the stable USB-net
   `172.16.42.1`, falls back to WiFi `<device-wifi-ip>`; if nothing is up it tries
   `nqctl net-usb up` to bring the RNDIS gadget + host NAT online),
2. run the comprehensive `nq-diag-snapshot` on the device,
3. pull the `nq-healthd` time-series + events — or, if the running image predates
   the daemon, bootstrap the tools into `/tmp` and gather a short live burst,
4. save everything under `nq-captures/<timestamp>/` on this PC
   (`nq-captures/latest` always points at the newest), and
5. analyze it with `nq-health-report`, writing `report.txt` and `report.json`.

The capture dir contains: `report.txt` (human), `report.json` (machine findings),
`snapshot.txt` (full device dump), `health.jsonl` (samples), `events.jsonl`
(device-side anomaly events), `paths.txt`.

Options: `nq-collect [OUTDIR] [--burst N] [--interval S]`. To watch a suspected
intermittent fault live for longer, raise the burst, e.g. `--burst 60 --interval 2`
(2 minutes). If you only need connectivity for ad-hoc checks, use `scripts/diag/nqctl`
directly (`nqctl status`, `nqctl run '<cmd>'`, `nqctl logs --follow`).

## Read the report

Start with `report.txt` / `report.json`. `summary.worst_severity` is the verdict.
Findings are tagged by `kind`; interpret them like this:

- **nexusqd_hang** (crit) — the LED daemon is alive but its control socket
  (`nexusled status`) does not answer. This is the classic "ring rotation froze
  and never came back": a *hang*, not a crash, so `Restart=on-failure` never
  fires. Confirm with **led_frozen** (frame unchanged ≥6 samples) and
  **nexusqd_no_progress** (no CPU time). Real fix lives in `pmos/nexusqd/`
  (add an sd_notify watchdog / `WatchdogSec=`) — note it, don't hack around it.
  ⚠️ **A dark ring is NOT a hang if the socket still answers** (`nq_resp=1`) — either
  (a) idle-off (the ring blanks on the idle timeout; false CRIT seen 2026-06-28), or
  (b) **AVR starvation** (FIXED v1.6.5) — a dark ring after a **long** idle (~20 h) was the
  `steelhead-avr` fw's host-frame watchdog starving once `nexusqd`'s `memcmp` write-gate
  stopped committing a static screensaver-locked/blanked frame; `nexusqd` (pkgrel 5) now
  re-commits every `AVR_KEEPALIVE_S=1.0 s`. On **≥ v1.6.5** a dark-after-long-idle ring
  means the keepalive stopped, not a design blank. See
  `docs/2026-07-01-led-ring-avr-starvation-keepalive.md`.
  ⚠️ **`led_frozen` is a PERMANENT FALSE CRIT on nexusqd r5+ with images up to
  `#27`/r19** (2026-07-03 finding): healthd fingerprints led_classdev
  `brightness`, but nexusqd commits via the write-only `frame` bin_attr →
  `led_sum` is structurally 0. There, ignore `led_frozen`; judge the ring by
  `nq_resp`/`nexusled status`. **On `#29`/r20+ (flashed 2026-07-03)** kernel
  patch 0029 makes `frame` readable and nq-healthd r20 fingerprints it — the
  fingerprint is real. ✅ **Since 2026-07-04 (healthd r21 + nq-health-report;
  baked in the flashed image since v1.6.7, 2026-07-05) the static-by-design
  guard is LIVE** (verified: 33× info `led_static`, zero false CRIT in 91
  acceptance samples): a static frame with
  a healthy daemon (the screensaver locks a static frame after ~300 s and the
  keepalive re-commits identical bytes) emits **info `led_static`** — expected
  on idle captures, not a fault — while `led_frozen` CRIT fires only with a
  distress co-signal (`nq_resp=0`/`nq_progress=0`), so a CRIT is now
  believable as a real hang. (On healthd r20 exactly, the idle false CRIT
  still applies — believe it only with the distress co-signal.) Similarly,
  `vdd_mismatch` warnings on ≤r19 can be non-atomic freq/vdd sampling
  artifacts (fixed in r20 by re-checking freq across the vdd read; a residual
  race remains — 1/91 samples slipped past the guard on the 2026-07-05 v1.6.7
  acceptance — so a single isolated warn is still noise). Ethernet: task #17 is
  **FULLY CLOSED 2026-07-06** — `eth0` enumerates from a cold boot on `#33`+
  (v1.6.8). The old "enumeration intermittency" was an **unmuxed `gpio_1`
  NENABLE pad** (`kpd_col2` @ `0x186`), not a race, fixed by a DTS pad mux (the
  "0/3 vs 3/3 boots" was stock priming). On a **pre-`#33`** image a missing
  `eth0` is that unmuxed pad — report the kernel is out of date, not a new
  regression. The NM layer is also fixed (baked r21 profiles) and
  `NetworkManager-wait-online` stays green even with the chip absent, so a
  wait-online failure IS a real fault. gpio-debug lesson: debugfs "asserted" =
  the DATAOUT latch is driven, NOT that the pad is routed — verify the IOPAD mux.
- **failed_unit** — a systemd unit failed. On a **pre-fix** image the usual cause is
  **python**: `python3` SIGSEGVs on ARMv7 — a **FLASH** corruption (NOT a
  build/alignment/compiler/CPython-source/qemu-build bug, all disproven) taking down
  `onboard` / `blueman-applet` / `sleep-inhibitor.service` / `gdb`. **Fixed in v1.6.0
  (2026-06-28)** by the byte-exact **all-RAW `raw2simg.py`** flash — the old `DONT_CARE`
  blocks left STALE eMMC data on the non-erasing U-Boot, re-corrupting a *clean*
  libpython on reflash. (v1.6.0 ships a plain default-linker python3 rebuild + a
  build-integrity gate as a safety net; a gold-linker workaround was tried and dropped as
  unnecessary.) Confirm on device with `python3 -S -c ''; echo rc=$?` — rc 139 = a
  pre-v1.6.0 corrupt python is flashed (needs a v1.6.0 all-RAW image), rc 0 = fixed. See
  `docs/2026-06-28-session-findings.md`.
- **nexusqd_down / nexusqd_restart / librespot_restart** — service died or
  flapped; check the `nexusqd recent journal` section of `snapshot.txt`.
  ℹ️ **Historical (FIXED in v1.6.1):** on v1.6.0 a Spotify track that played then
  **auto-skipped ~40 s in** was NOT a restart — it was the **TAS5713 2× speed bug**
  (McBSP2 FSYNC at 2× rate, tracks ended in half time; librespot stayed up), fixed by
  kernel patch 0022. `librespot_restart` is a real *service* restart. If the ~40 s
  auto-skip ever returns it's an audio-clock regression, not this finding.
  See `docs/2026-06-29-spotify-connect-and-tas5713-2x-speed.md`.
- **vdd_mismatch** (warn/crit) — `vdd_mpu` is off the expected voltage for the
  current OPP (350→1025, 700→1203, 920→1317, 1200→1380 mV). A few samples = a
  DVFS transition; persistent = a VC-bridge / TPS62361 power-path problem
  (path B). Cross-check the `POWER_REGULATORS` + `omap_voltage/ti-abb/tps`
  sections of `snapshot.txt`.
  ⚠️ Known tooling bug (2026-07-03, images ≤ r19): freq and vdd are sampled
  non-atomically, so
  a DVFS transition between the reads fabricates a mismatch — re-read freq after
  vdd before believing a warning. **Fixed in nq-healthd r20** (on device since
  the `#29` flash, 2026-07-03).
- **thermal_throttle / thermal_crit / thermal_cooling_active** — at/over the
  100 °C passive or 125 °C critical trip, or cooling engaged. See `THERMAL`.
  ⚠️ **Thin headroom (active watch-item):** peak under sustained dual-core load
  crept from 91.8 °C (2026-07-03) to **~98–99 °C (2026-07-06, v1.6.9)** — still
  below the 100 °C trip, no throttle, but only ~1–2 °C to spare. Always report
  the peak temp on a load run.
- **governor_not_scaling** — load was high but freq never left 350 MHz; the
  governor or cpufreq path is stalling. See `CPU` + `CLOCKS` (`dpll_mpu`).
- **kernel_errors** — new oops/WARN/i2c-timeout/voltage lines; read the
  `KERNEL_LOG_FULL` tail in `snapshot.txt`. ℹ️ **As of v1.6.9 the boot is CLEAN
  (0 failed units)** and the remaining err/warn are all a **known, individually
  triaged benign residual** (U5 bluetoothd MGMT-config, B4 brcmfmac fw-probe
  misses, B10 hw-breakpoint, B16 cold-boot ramoops, B21 L2C/gpmc/pmu/journald,
  B22/B23 twl, U7 nsresourced bpf-lsm — all in
  `docs/2026-07-02-boot-error-inventory.md`); don't re-derive them, but a NEW /
  unlisted line is still ours.
- **HDMI-audio card / PulseAudio** — the `omap-hdmi-audio` ALSA card is a
  snd-soc-dummy-DAI (not a usable sink; HDMI is desktop video only). Since
  **v1.6.9** PA ignores it via a `PULSE_IGNORE` udev rule, so
  `module-alsa-card: Failed to find a working profile` no longer fires. If it
  recurs it's a regression. **Lesson — ALSA card indices are probe-order
  dependent:** the first rule pinned `KERNEL=="card1"` and tagged the wrong card
  (HDMI came up as card2 one boot); the shipped rule matches the backing device
  `KERNELS=="omap-hdmi-audio.1.auto"`. Any per-card udev/PA rule MUST match by
  backing device (`KERNELS=`) or card id, never by `cardN` index.
- **pstore** (crit) — a previous boot panicked; the dump is in the `PSTORE`
  section. Remember pstore only survives a *warm* reboot.

When a crit finding has a timestamp, `report.txt` prints the per-sample timeline
around it — use that to correlate (e.g. did temp spike or freq stall at the
moment the ring froze?).

## Reporting back

Give the user the verdict and the specific findings with their evidence (quote
the timeline / snapshot section), and—if a finding implies a code fix—name the
file to change (e.g. `pmos/nexusqd/` for the missing watchdog) rather than
applying a workaround. Captures persist under `nq-captures/` for later diffs, so
you can compare a "good" run against a "bad" one.

All ground-truth subsystem paths this tooling reads are documented in
`scripts/diag/README.md`.
