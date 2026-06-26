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
- **nexusqd_down / nexusqd_restart / librespot_restart** — service died or
  flapped; check the `nexusqd recent journal` section of `snapshot.txt`.
- **vdd_mismatch** (warn/crit) — `vdd_mpu` is off the expected voltage for the
  current OPP (350→1025, 700→1203, 920→1317, 1200→1380 mV). A few samples = a
  DVFS transition; persistent = a VC-bridge / TPS62361 power-path problem
  (path B). Cross-check the `POWER_REGULATORS` + `omap_voltage/ti-abb/tps`
  sections of `snapshot.txt`.
- **thermal_throttle / thermal_crit / thermal_cooling_active** — at/over the
  100 °C passive or 125 °C critical trip, or cooling engaged. See `THERMAL`.
- **governor_not_scaling** — load was high but freq never left 350 MHz; the
  governor or cpufreq path is stalling. See `CPU` + `CLOCKS` (`dpll_mpu`).
- **kernel_errors** — new oops/WARN/i2c-timeout/voltage lines; read the
  `KERNEL_LOG_FULL` tail in `snapshot.txt`.
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
