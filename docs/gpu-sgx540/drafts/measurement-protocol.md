DRAFT — not built, not tested, not in any build (2026-10-11)

# GPU measurement protocol: baseline against after

The checklist every GPU phase uses to show that turning the SGX540 on does not
cost idle power, CPU headroom or audio, and, in Phase 4, that it pays for
itself. It turns [power-clocks-pm.md §9](../power-clocks-pm.md) into a
procedure and adds the preemption-model arm that the master note's Phase 1a
needs ([groundwork §4](../../2026-10-11-gpu-sgx540-groundwork.md)). Nothing here
has been run. Thresholds marked *proposed* are judgements, not measurements.

Short names follow the master note: `pm` = power-clocks-pm.md, `ur` =
usecases-roadmap.md, `kdp` = kernel-driver-port.md.

## 1. Rules for every window

| Rule | Why | Evidence |
|---|---|---|
| `hostname` first; it must name the unit | addresses have moved between devices | AGENTS.md hard rules |
| No ssh session open during a window. Start a detached sampler, disconnect, collect afterwards | an open session heats the die to 74-79 °C (up to 82.6 °C) and drags the OPP up | `scripts/diag/README.md` "Two traps"; pm §9.1 |
| Reuse `scripts/diag/nq-opp-study2.sh` (extended with the GPU items of §3), not a one-off sampler | it already captures interrupts, softirqs, cpuidle and `time_in_state`, and guards against playback | `scripts/diag/README.md`; pm §9.2 |
| Idle arms: nothing playing. Check `pactl list sink-inputs` before the window; the sampler's guard aborts if playback starts | audio holds a 1312 µs QoS request and changes the C-state mix | pm §9.1; `docs/2026-09-20-sleep-states-design.md:1562-1564` |
| Audio arms: Petr starts the music at his own volume; no test tones, no volume changes by us | 25 W amplifier, steep curve | AGENTS.md "Respect the device" |
| Settle ≥ 15 min after any change (boot, module load, client start) | transients | pm §9.1 |
| Counters, not samples: cumulative counters at window start and end, deltas only | sampling misses short events | pm §9.1 |
| Never mix sources in one ratio: `pm_debug` (sched_clock, sampled at MPUSS transitions) vs runtime PM / genpd (monotonic) differ by ≈ 245 s over 7 days | timebase drift and sampling bias | pm §1.3, §6.1; groundwork §5 P12 |
| Every arm twice; A0 again after the last arm | drift (ambient, uptime) | pm §9.1 |
| Same image or same boot for an A/B where possible (module load/unload, client start/stop); a kernel A/B (arm P1a) uses the trial slot and records both revisions | arm transitions should not be reflashes | pm §9.1, §9.6 |
| Device loads: `timeout` + `nice`, 30 fps cap, client thermal stop at 95 °C | two busy loops have locked out sshd before | groundwork §7 |
| Full nexusq-diag sweep, CPU frequency and VDD_MPU against the OPP included, after every flash or OTA and after each arm | standing rule | AGENTS.md; memory `always-run-cpu-power-diag` |

## 2. Arms

| Arm | State | HDMI | Isolates | Phase |
|---|---|---|---|---|
| **A0** | today's image, no GPU driver | unplugged (DSS off) | baseline: C3 share, exits/s, 350 MHz %, die °C, W | 0 |
| **A0h** | as A0 | plugged, labwc/pixman, static desktop | the scan-out cost alone, so it is never blamed on the GPU | 0 |
| **A0m** | as A0, music playing (Petr) | as used | the audio baseline: XRUN and error counters, C-state mix while playing | 0 |
| **P1a** | the preemption-model kernel (VOLUNTARY or PREEMPT), no GPU driver; run idle like A0 and playing like A0m | as A0 / A0m | the cost of the kernel-wide scheduling change, before any GPU code | 1a |
| **A1** | `pvrsrvkm_omap4_sgx540_120` loaded, services initialised, no client | unplugged | the driver's idle cost; should equal A0 | 1 |
| **A2** | GLES compositor idle, static desktop | plugged | idle compositor on the GPU against A0h | 5 (optional) |
| **A3** | GPU visualizer at a fixed rate, 30 and 60 fps sub-arms | plugged | active cost: die °C, OPP residency, exits/s, GPU IRQ/s, W | 3-4 |
| **A4** | the same scenes on the CPU reference renderer, same fps target | plugged | the comparison that justifies the GPU | 0 (renderer), 4 (comparison) |

A0, A0h and A1-A4 are pm §9.3. A0m and P1a are added here: the master note's
Phase 1a needs an "A/B against the baseline: XRUNs with music playing, C3
share, 350 MHz residency, idle exits/s, VDD_MPU against the OPP, boot log"
([groundwork §4 Phase 1a](../../2026-10-11-gpu-sgx540-groundwork.md)), and
every rendering phase must run with music playing ([ur §5.4](../usecases-roadmap.md)).

## 3. Instruments: what to read at window start and end

All reads are read-only. `drafts/nexusq-gpu-probe.sh` covers the GPU rows in
one call (run it at start and end, outside the window if an ssh session is
needed to start it).

| # | Metric | Source | Derived value | Notes |
|---|---|---|---|---|
| 1 | Idle C-state residency | `/sys/devices/system/cpu/cpu{0,1}/cpuidle/state*/{usage,time}` | C3 share = Δtime(C3) / Σ Δtime(all states), both CPUs summed; idle exits/s = Σ Δusage / window | today C3 is 86-93 % of idle, 353 exits/s on r111 [pm §5.1, Verification]; healthd `cstate_ms`/`cstate_n` give the same per 5 s |
| 2 | GFX residency (authoritative) | `/sys/bus/platform/devices/5600fe00.target-module/power/runtime_active_time`; `/sys/kernel/debug/pm_genpd/prm_gfx/{current_state,active_time,total_idle_time}` | Δactive ms / window; state at end | pm §6.1 "Authoritative GPU residency" |
| 3 | Domain counters (context) | `/sys/kernel/debug/pm_debug/{count,time}`, lines `gfx_pwrdm`, `core_pwrdm`, `dss_pwrdm`, `mpu_pwrdm` | ΔON/ΔOFF per domain | sampled only at MPUSS low-power transitions; biased while rendering; reading `time` is itself a sample [pm §6.1]. CORE has never left ON (USB pins it) [pm §5.2] |
| 4 | GFX ground truth (once per arm) | `PM_GFX_PWRSTST` 0x4a307204 via `nexusq-gpu-probe.sh --regs` | POWERSTATEST, LASTPOWERSTATEENTERED | PRM only; never an address in 0x56000000-0x57ffffff [groundwork §7] |
| 5 | CPU frequency | `/sys/devices/system/cpu/cpufreq/policy0/stats/{time_in_state,total_trans}` | 350 MHz residency %, transitions/s | today 350 MHz ≈ 99.8 % at idle [pm §5.1]; passive long-window number from HA: `scripts/diag/ha-opp-window.py` |
| 6 | VDD_MPU against the OPP | regulator `vdd_mpu` µV + `abb_mpu`; healthd `vdd_uV`, `vdd_exp_uV`, `vdd_mismatch`, `abb_uV` | any `vdd_mismatch` event in the window | expected 350/1025, 700/1203, 920/1317, 1200/1380 MHz/mV (`nq-diag-snapshot` "vdd_mpu vs OPP expectation") |
| 7 | VDD_CORE | TWL6030 VCORE1: a multimeter on the VCORE1 output. *(Corrected 2026-10-11: `nexusq-gpu-probe.sh --pmic` read 0x48 0x55/0x56 = 0x00/0x00 on the Prague unit with the rail on; the control interface does not show the setpoint, so `--pmic` only records the raw block and reports VDD_CORE unreadable. Expected 1 139 440 µV from the x-loader)* [pm Addendum "Live VDD_CORE without a device" §6] | value in mV, once per arm; it must not change | Linux has no VDD_CORE regulator; PRM VP_CORE reads are expected to be 0 [pm §4] |
| 8 | Temperature | `/sys/class/thermal/thermal_zone0/temp` at 1 Hz in the detached sampler; TMP101 hwmon (i2c 0x48 on I2C2) | median, p95, max | passive trip 100 °C cools the CPU only [pm §7] |
| 9 | Interrupts | `/proc/interrupts` (GPU line = GIC-0 hwirq 53, DSS line, total), `/proc/softirqs` | GPU IRQ/s, total IRQ/s | GIC SPI 21 = hwirq 53 [pm §8.1] |
| 10 | GPU clock | `nexusq-gpu-probe.sh` `gpu_clock`, `dpll_m7` | parent and rate at start and end | must be `dpll_per_m7x2_ck` 307 200 000 (or 153 600 000 under the VDD_CORE gate) [pm §2, §4] |
| 11 | healthd / MQTT | `/var/log/nq-health/health.jsonl` (5 s): `freq`, `opp_ms`, `opp_trans`, `temp_mC`, `cool`, `vdd_*`, `cstate_ms`, `cstate_n`, `cstate_armed`, `qos_us`, `busy_ms`, `irqs`, `load1`, `unit_us`; proposed append-only `gpu_active_ms`, `gpu_rpm`, `gpu_irqs`, `dss_active_ms`, `die2_mC` (Phase 0 step 5) | per-window sums from `scripts/diag/nq-health-report --since/--until` | the proposed fields do not exist yet [pm §6.2]; the schema is append-only [nq-healthd.c:1641-1645 per pm §6.2] |
| 12 | Exits attribution (optional) | 60 s `power:cpu_idle` + `sched:sched_switch` + `irq:*` + `ipi:*` trace at the window midpoint | who wakes the CPUs | as in `docs/2026-09-26-idle-audit-five-pollers.md` [pm §9.2] |
| 13 | Wall power | a ≥ 0.1 W meter or a DC shunt (Petr's call) | Wh over the window / h | the Solight meter reads whole watts; without a better one report "below instrument resolution" [pm §9.4, groundwork §5 P17] |
| 14 | Client (A3/A4 only) | the client's own log | achieved fps, frame-time p95 | pm §9.3 |

## 4. Audio check (A0m, P1a playing, A3 with music, Phase 3-4 exits)

Method of the C2/C3 audio runs in `docs/2026-09-20-sleep-states-design.md:1554-1560`
and `:1838-1840`, counters only, nobody listens for us:

1. `pactl list sink-inputs` before anything; record what is playing.
2. Petr starts playback (Spotify via librespot is the reference path).
3. Count over the window, start and end:
   - kernel audio errors: `dmesg` lines matching `XRUN|underrun|McBSP|DMA|TAS571x`
     (Δ must be 0);
   - ALSA playback state `RUNNING` in `/proc/asound/card*/pcm*p/sub0/status`
     at start, mid-window and end;
   - PulseAudio underruns in the user `pulseaudio.service` journal (Δ must be 0);
   - librespot `err`/`warn` lines (report; the reference OFF run had 1).
4. The listening judgement is Petr's, separately, never ours
   [ur §5.4; memory `no-risky-speaker-audio-testing`].

The crackle class this guards against is L3/EMIF DMA contention starving the
McBSP2 FIFO; the SGX is a new L3 initiator and HDMI scan-out adds ≈ 212 MB/s at
720p60 ([ur §5.4](../usecases-roadmap.md),
`docs/2026-07-08-audio-crackle-dma-contention.md`). It is not a PulseAudio
buffer problem, so "0 PA XRUN" alone is not enough: the kernel counter is the
one that matters (same doc, "Proven by elimination").

## 5. Procedure per window

1. `hostname`; confirm the kernel revision (`uname -r`) and record image and
   kernel slot.
2. `nexusq-gpu-probe.sh` (and `--regs` once per arm); record VDD_CORE per §3 row 7.
3. `pactl list sink-inputs`.
4. Set the arm up (module load, client start, HDMI plug, music by Petr).
5. Start the detached sampler with `systemd-run` (extended `nq-opp-study2.sh`),
   then close the session.
6. Settle ≥ 15 min, then the window: **≥ 60 min** for idle arms (A0, A0h, A1,
   A2, P1a idle), **≥ 15 min** for active arms (A3, A4), **60 min** of playback
   for A0m and P1a playing [pm §9.1; the 1 h playback run in sleep-states-design
   is the precedent].
7. Collect: sampler output, `scripts/diag/nq-collect`, HA window via
   `ha-opp-window.py --since/--until`.
8. Probe again; full diag sweep.
9. Restore anything the arm changed (unload, stop client).

## 6. Pass/fail

| Comparison | Pass | Source |
|---|---|---|
| A1 against A0 (idle, HDMI off) | ΔC3 share ≥ −1 pp; Δidle exits/s ≤ +5 %; GFX active ≤ 0.1 % of the window; `prm_gfx` `off-0` at window end; gpu `runtime_usage` 0 within 1 s of the last client exit; Δ350 MHz residency ≥ −0.5 pp; ΔW below meter resolution | pm §9.5, §8.3 step 3 |
| P1a against A0 / A0m (preemption) | *proposed*, same idle thresholds as A1 (ΔC3 ≥ −1 pp, Δexits/s ≤ +5 %, Δ350 MHz ≥ −0.5 pp), no `vdd_mismatch`; with music: kernel audio errors Δ0, PulseAudio underruns Δ0, ALSA `RUNNING` throughout; boot log: no new warning or error; full diag sweep clean. The master note asks for "no audio or idle regression beyond noise": noise is the spread of the two A0 runs, and a difference smaller than that spread is not a regression | groundwork §4 Phase 1a; this draft |
| A2 against A0h (idle desktop) | GFX active ≤ 2 % of the window; ΔC3 share ≥ −3 pp; no new IRQ source > 5/s at a static screen | pm §9.5 |
| A3 | die < 85 °C steady at 30 fps; no `vdd_mismatch`; audio check §4 clean with music; frame pacing stable; GFX `off` within `sgx_apm_latency` (100 ms) + ε after the client stops | pm §9.5; groundwork §4 Phase 4 exit |
| A3 against A4 | the GPU arm uses less CPU (busy %) **and** spends more time at 350 MHz than the SW arm at the same fps; for the Phase 4 product, CPU at 720p30 at least 2× lower | pm §9.5; groundwork §4 Phase 4 exit |
| Phase 3 exit | 30 min at 720p30 with flips, no corruption, audio check clean with music, 20 exit/restart cycles without leaking DRM master or GEM memory, HDMI audio unbroken across handover | groundwork §4 Phase 3 |
| Phase 4 exit | 1 h with music, audio check clean; die < 85 °C at 30 fps | groundwork §4 Phase 4 |
| Every arm | full nexusq-diag sweep clean, CPU frequency and VDD_MPU against the OPP included | AGENTS.md; pm §9.5 |

A result that fails its threshold stops the phase; it is not averaged away by
a third run.

## 7. Tests that must be seen failing before the protocol counts

A check that has never failed proves nothing (AGENTS.md; memory
`test-must-be-seen-failing`). Each instrument is shown red once, on purpose,
in the cheapest way that touches nothing risky:

| Check | How it is made to fail | Expected | Phase |
|---|---|---|---|
| probe `gpu_driver` | run on today's image (no driver) | FAIL | 0 |
| probe `gpu_clock` | run on 6.18.48-r20 (mux on `dpll_core_m7x2_ck`, 266 666 667) | FAIL; PASS after the 0062 DT block. The clk_summary fallback parser was run on the host against `nq-captures/20261010-185940/snapshot.txt` on 2026-10-11 and returned `dpll_core_m7x2_ck 266666667`: a host check only, not a device pass | 0 |
| A1 GFX-idle criterion | load the KM **without** patch (d) on the trial slot | `prm_gfx` stays ON, `gfx_idle` FAIL; with (d) it goes `off-0` | 1 [groundwork §4 Phase 1; pm §8.3 step 3] |
| C3-share criterion | one short control window with C3 taken out through its sysfs user-disable bit (`echo 1 > /sys/devices/system/cpu/cpu*/cpuidle/state2/disable`, patch 0058; restored afterwards) | ΔC3 far below −1 pp → FAIL | 0 |
| GFX-active criterion | run the A1 analysis on an A3 window (client rendering) | GFX active far above 0.1 % → FAIL | 3 |
| kernel audio-error counter | feed the counting command a saved `dmesg`/journal containing known XRUN/underrun lines (host side; no audio is generated) | count > 0 → FAIL | 0 |
| preemption gate | the Phase 1 compile gate on the old `PREEMPT_NONE` config | build stops at `osfunc.c:126-135` `#error`, or earlier at the aport's readable check | 1a [groundwork §4 Phase 1a] |

`vdd_mismatch` (row 6) is healthd's existing event; whether it was ever seen
firing is not recorded in the GPU notes (UNVERIFIED). If no record exists, it
gets its own seen-failing test before Phase 1a relies on it.

## 8. Recording

One dated `docs/` note per phase (Phase 0: the baseline note named in
groundwork §4 Phase 0 exit) with: unit hostname, image and kernel revision and
slot, ambient (room, time of day), which arms ran and when, raw start/end
counters, the deltas, the thresholds applied and the verdict, who listened, and
anything that invalidates a window (an ssh session, playback in an idle arm).
Numbers stay in the note; the CHANGELOG names the revision.

## 9. Open points

- The VCORE1 register address on the TWL6030 control interface is still to be
  confirmed from the TRM before row 7 can be read without a multimeter *(closed
  2026-10-11: derived from stock and mainline without the TRM; the first live read
  confirms it [pm Addendum "Live VDD_CORE without a device"])* *(Reopened
  2026-10-11: the live read gave 0x00/0x00 at 0x55/0x56 with VCORE1 on. No
  read-only register path exists; row 7 needs the multimeter [pm Addendum §6])*
  [groundwork §8 q1].
- The proposed healthd fields (row 11) and the `nq-opp-study2.sh` GPU items do
  not exist yet; until they do, rows 2-3 and 9 come from the probe and the
  sampler's start/end snapshots only.
- The wall-power instrument (row 13) is Petr's decision [groundwork §8 q4].
- P1a's thresholds are proposed here, not taken from a note; Petr may want
  stricter audio criteria (e.g. a longer playback window) before a kernel-wide
  scheduling change ships.
