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
| `pmos/device-google-steelhead/nq-healthd.c` | device | continuous health monitor — **a C daemon since device r77 (2026-08-20)**: the shell original was deleted (git history has it) after measuring 3.08 % of a core even post-diet; the C rewrite measures 0.55 %, **JSONL schema unchanged** (verified field-by-field). Source is kept in sync with `userspace/nq-healthd/nq-healthd.c` — edit both. Writes `/var/log/nq-health/{health,events}.jsonl` (systemd `nq-healthd.service`, enabled by the device package). Since 2026-08-10 `health.jsonl` has an on-device consumer: **`nexusq-mqtt`** tails the latest sample (used only when fresh ≤60 s) and republishes it — plus its own extras — to MQTT / Home Assistant (see `userspace/nexusq-mqtt/README.md`); a change to healthd's field names/semantics now also touches the MQTT state JSON + HA discovery templates. Since **mqtt r2** (2026-08-13) that coupling is explicit: the payload carries a **`led_stalled` verdict** derived from healthd's own `led_stall` + `nq_resp`/`nq_progress` distress co-signal — so changing what `nq_progress` means (as device **r72** did) changes what the app and HA alarm on |
| `pmos/device-google-steelhead/nq-diag-snapshot` | device | comprehensive read-only "log everything" one-shot dump |
| `scripts/diag/nqctl` | host | reach the device over the best link (ethernet `10.42.0.2` first, then USB-net / WiFi / serial), incl. `net-usb up` (RNDIS gadget + host NAT) |
| `scripts/diag/nq-collect` | host | **the engine**: connect → snapshot → pull/burst samples → save locally → analyze |
| `scripts/diag/nq-health-report` | host | analyze a capture → findings (human + JSON) |
| `scripts/diag/ha-opp-window.py` | host | **the STANDING GOAL measurement**: idle OPP residency read out of Home Assistant history (the `nexusq-mqtt` rolling 1 h window). **Passive — it never touches the device**, which is the whole point: an ssh session invalidates the number it is measuring |
| `scripts/diag/nq-opp-study.sh` | device | detached idle-OPP study: 60 s ftrace event capture + governor A/B arms, measured from `time_in_state`/`trans_table` deltas. Aborts and restores every knob if playback starts |
| `scripts/diag/nq-opp-study2.sh` | device | same harness with arms given on the command line (`label:gov:sampling_rate:up:down:ignore_nice:nice_mode`), incl. renicing the housekeeping units for an `ignore_nice_load` A/B |
| `scripts/diag/analyze-opp-snaps.py` | host | study snapshots → per-arm OPP residency, transition matrix, **mean residency per visit**, per-cgroup CPU, IRQ/softirq rates, cpuidle, temperature |
| `scripts/diag/analyze-opp-trace.py` | host | ftrace dump → per-task CPU reconstruction from `sched_switch`, **burst-length histogram against the governor's ramp threshold**, and attribution of every up-transition to what ran before it |
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

# idle OPP residency (the STANDING GOAL number) — never over ssh:
scripts/diag/ha-opp-window.py --days 3.5 --since '2026-08-13 12:00'
```

⚠️ **Two traps in the OPP measurement**, both already paid for:

1. **Do not measure idle with a session open.** An ssh login pushes the die to
   74–79 °C and drags the OPP up; on 2026-08-16 *every* contaminated sample in a
   3.5 d window fell inside the previous session's own ssh hours (die up to
   82.6 °C, opp1200 up to 16 %). Hence a host-side, HA-only tool.
2. **HA's history endpoint silently truncates a long multi-entity response.** A
   single 3.5 d call for 12 entities returned only the first 24 h — well-formed
   JSON, no error. `ha-opp-window.py` fetches in 6 h chunks and merges; if you
   ever query HA history by hand, chunk it and check the last timestamp.

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
the defconfig enables `CPU_FREQ_STAT`, so `time_in_state` exists and the sampling
fallback is just a cross-check.)_ Expected governor: **`conservative` since
v1.8.2 / kernel r43** (2026-07-13 — measurement-backed: ondemand's jump-to-max on
~1000 microburst wakeups/s kept 74 % of idle at ≥700 MHz; was `ondemand`
v1.6.6–v1.8.1, `conservative` v1.5.0–v1.6.5). Idle expectation **changed with
v1.8.2**: a healthy idle now **settles at 350 MHz** (56.7 % residency 2026-07-13;
**60.5 %** on the first clean 14 h hands-off MQTT-window measurement 2026-08-13/
r70 — judge from `opp_ms`/MQTT `opp*_pct`, never healthd's `freq`; expect higher
on **r71 + nexusqd r13**, the 2026-08-13 idle diet: healthd 6.3 → 2.3 % of a
core, nexusqd 4.4 → **0.165 %** and 22 → **2.9 wakeups/s**, system idle fork rate
14 → 2.6/s — ~12 pp of one core of constant background gone; ~4.25 trans/s.
**Post-diet attribution, 2026-08-13, 240 s blanked-ring window:** total idle busy
**8.73 %** of one core (real ≈ **7.7 %** — an ssh poll loop inflated
`sshd`/`init.scope`, those two figures are NOT trustworthy), forks **2.59/s**;
**`nq-healthd` 2.43 % is the new #1**, nexusqd 0.14 %, and **`brcmf` WiFi
kworker at ~34–40 wakeups/s dominates every other wakeup source combined**) —
the old "hovers ~920 MHz"
behaviour was the ondemand sawtooth (+ healthd's own polling load) and on a
≥v1.8.2 image it is a **regression signal**, not the norm. ⚠️ Idle **temperature** must be judged from an on-device
self-logging capture with no live ssh session — any interactive session heats
the die to 74–79 °C within seconds (cooling constant ~10 s; true unobserved idle
floor ~65–66 °C — measured 2026-07-13).

**Power delivery** — every `/sys/class/regulator/regulator.*` (resolved by the
`name` attribute, not the opaque index). `vdd_mpu` is checked against the
expected voltage for the current OPP (350→1025, 700→1203, 920→1317, 1200→1380 mV);
`abb_mpu` reflects ABB/FBB mode. Drift here points at the VC-bridge / TPS62361
path (path B).

**Thermal** — `thermal_zone0` (`cpu_thermal`), trips at 100 °C (passive) and
125 °C (critical), plus `cooling_device0/cur_state` for active throttling.
Ground truth as of **2026-07-15**: bounded dual-core load reached **102.8 °C** —
**past the passive trip**, so a non-zero `cur_state` under load is EXPECTED, not a
fault (125 °C critical was never approached). This supersedes the older "peaks
~94–99 °C, no throttle" envelope. True idle: **72–75 °C**, 52 % residency at
350 MHz. Always report the peak.

**LED ring / nexusqd / AVR** — the ring is 32 `steelhead:rgb:ring-*` LEDs (+ a
`mute` LED) driven by the userspace daemon **nexusqd** (control socket
`/run/nexusqd.sock`, queried via `nexusled status`) through an on-board **AVR**
MCU on i2c (IRQ line `steelhead-avr`). *(Corrected 2026-08-13 — this section
used to say "nexusqd has **no systemd watchdog**": it has had one since v1.6.x /
`543b492`. `nexusqd.service` is `Type=notify` with `WatchdogSec=15s` and the
daemon pings `WATCHDOG=1` once a second from the render loop, so a **wedged**
daemon is SIGABRT'd + restarted by systemd. The healthd heuristics below remain
the finer-grained signal — they catch a ring/AVR fault that leaves the render
loop, and therefore the ping, alive.)* We detect a hang via socket
unresponsiveness + a frozen LED frame + no daemon CPU progress. The frame
fingerprint reads the AVR driver's **`frame` bin_attr** (readable since kernel
patch 0029 / healthd r20 — md5 + byte sum of the committed frame; since **r71**
(2026-08-13) one `od|awk` pass yields byte sum + a rolling hash, no md5 — the
fingerprint only ever feeds an equality test, semantics unchanged), falling back
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

> 🆕 **nexusqd r13 (2026-08-13) — the idle daemon is now nearly free, and the
> ring renders at 1 Hz when idle.** Two changes a sweep must expect:
> - **The PA sink-input gate is event-driven.** A **persistent `pactl subscribe`
>   child** (exactly one, owned by nexusqd) replaces the old `pactl list short
>   sink-inputs` every 1.5 s. Timed re-counts are now a safety net (30 s while
>   tapping / 60 s while idle once the subscriber is proven ≥2 s alive; 1.5 s
>   while it is down/unproven, respawn every 10 s). **Healthy tells:** exactly
>   **one** long-lived `pactl subscribe` under `nexusqd.service`, and **no**
>   recurring short-lived `pactl` under it. A *stream* of short `pactl` forks
>   from nexusqd on r13+ means the subscriber keeps dying — check PulseAudio.
>   A subscription is not a stream: it holds no sink out of suspend.
> - **The render loop stretches to 1 Hz when idle.** After 40 bit-identical
>   renders **and** an intent-idle test (no volume overlay, no music fade, no
>   breathe/spin, screensaver locked or blanked) the frame deadline goes 50 ms →
>   **1.0 s** (0.25 s cap while the tap is open, 0.5 s while the update blink
>   runs). Measured idle cost: **0.165 % of a core, 2.9 wakeups/s** (was 4.4 % /
>   22 wake per s on r12). It snaps back instantly on a key, on any mutating
>   control command (`nexusled status` deliberately does **not** — healthd probes
>   it every 5 s), and on a stream starting.
> - ⚠️ **A/B rule: never compare nexusqd CPU/wakeups across screensaver states.**
>   A fresh `systemctl restart nexusqd` restarts the screensaver, so the ring
>   breathes at 20 fps for `SS_LOCK_S` — a measurement taken then reads ~1.6 % /
>   54 wakeups per s and is meaningless. Wait out `SS_LOCK_S`/`SS_BLANK_S`
>   (~9 min) and confirm `led_sum` is static/0 first.
> - ✅ **`nq_progress` is a WINDOW, not a per-sample delta — FIXED in device r72
>   (2026-08-13).** *(Was flagged the same day as an "unverified risk"; it was
>   NOT theoretical — it fired **twice** on the live device between `nexusqd` r13
>   and r72 landing:
>   `{"t_mono":214110,"sev":"crit","kind":"led_frozen","msg":"LED frame unchanged
>   for 6 samples with distressed nexusqd (resp=1 progress=0) …"}`, and again at
>   `t_mono` 214497.)*
>   The old definition — "did nexusqd's `/proc/pid/stat` tick count change since
>   the last 5 s sample" — was valid only while nexusqd burned 4.4 % of a core
>   (≈22 USER_HZ ticks/sample). r13 dropped it to 0.165 % ≈ **0.8 ticks/sample**,
>   so a zero delta became the ORDINARY reading for a healthy daemon, and since
>   `LED_STALL >= 6` is *guaranteed* on a locked/blanked ring, healthd's
>   co-signal `nq_resp=0 || nq_progress=0` produced **CRIT `led_frozen` on a
>   healthy idle device**.
>   **Since r72:** `nq_progress` is 0 only when nexusqd's CPU time has not
>   advanced for `PROGRESS_STALE_S` (env **`NQ_PROGRESS_STALE_S`**, default
>   **60 s**) — ~10× the ~6 s idle tick interval, and the window resets while the
>   unit is not running. The same idle state now logs **info `led_static` …
>   (resp=1)**.
>   **Reading a capture:** on **r72+** a `nq_progress=0` is meaningful again —
>   believe a `led_frozen` CRIT. On an image with **nexusqd r13 + healthd ≤ r71**
>   (the narrow window above) treat `led_frozen` with `nq_resp=1` as **info** and
>   judge the ring by `nq_resp`/`nexusled status`. Record:
>   `docs/2026-08-13-led-stall-verdict-and-progress-window.md`.
> - ✅ **Healthy-idle expectation (r72 + `nexusq-mqtt` r2):** a blanked ring shows
>   a **large and growing `led_stall`** (hundreds to thousands — the screensaver
>   locks/blanks by design and the 1 Hz keepalive re-commits identical bytes)
>   together with **`led_stalled = false`** in the MQTT payload and
>   `binary_sensor.nexus_q_led_ring = off` in HA. **That combination is HEALTHY —
>   do not report it.** `led_stall` is a diagnostic number only; the fault verdict
>   is `led_stalled` (= `led_stall >= 6` AND nexusqd distressed), computed
>   on-device from the same co-signal healthd uses. Live reference sample:
>   `led_stall=17, led_stalled=False`.

> **The mute LED blinking amber is NOT a fault — it means "OTA update available".**
> Since `nexusqd` **r11** / `nexusq-control` **r20** (device OTA, PROTOCOL §12) the
> bridge drives two LED states that a sweep must not mis-read: the dedicated **mute
> LED blinks amber** (`mblink 255 140 0`) when a daemon OTA is pending (a *persistent*
> indicator, cleared only by installing or `mblink stop`), and the **ring shows a
> determinate `progress` bar** (then a brief green `set 0 255 0`) **during an
> install** — a transient, expected state, not a stuck frame. The install restarts the
> daemons (incl. `nexusq-control`), so a **brief `nexusqd`/bridge restart right after
> an OTA is expected**, not a `nexusqd_restart` fault.
>
> ⚠️ **Known open (2026-08-08): a System OTA reports "system update failed" but the
> packages installed.** `apk fix -s` shows a **persistent pending
> `postmarketos-mkinitfs` trigger** (`1 error`, re-fails every apk run): `boot-deploy`
> finds `No kernel found in /boot` (empty plain dir — the Q boots ramdisk-less from the
> flashed boot partition). Verify with `apk info` (packages committed); don't read it as
> a broken update. NOT fixed, Phase-2 territory. See
> `docs/2026-08-08-system-ota-mkinitfs-trigger-failure.md`.

**Crashes / kernel** — new error lines in `dmesg`
(oops/WARN/stall/i2c-timeout/omap_voltage/brownout/thermal-shutdown) and
`/sys/fs/pstore` (survives a *warm* reboot only).

**WiFi (BCM4330)** — `iw dev wlan0 link` + gateway reachability. Ground truth as of
**2026-08-02**: the long-uptime **5 GHz TX-dead wedge** (associated but 0 traffic,
`brcmf_escan_timeout` flooding ~58 s — the chip failing in-firmware background *roam*
scans) is **fixed by `brcmfmac roamoff=1`** (device r56); the on-device
**`nexusq-wifi-watchdog.service`** (device r57) gateway-pings every 30 s and
auto-bounces `wlan0` after 3 failures, logging per-check health (loss %, signal) +
heal events to **`/var/log/nq-health/wifi-watchdog.jsonl`** (steady "ok" thinned to
1 line/5 min, capped ~20 000 lines). Read it to confirm the fix holds (a 29 h clean
run 2026-08-01 did); any `brcmf_escan_timeout` return or repeated heals = regression.
Since **device r61** (2026-08-02) the watchdog also heals the **associated-but-no-route
`nogw` wedge** — `wlan0` associated at good signal but NM stuck in "getting IP
configuration" (DHCP got no lease → an IP but **no default route/gateway**, LAN
unreachable). A `"st":"nogw"` line now carries `"fails"` and, once it reaches
`FAILS_TO_HEAL`, triggers the same `nmcli disconnect/connect` heal (the pre-r61 code
held `fails=0` in that branch and never healed it). Repeated `nogw` heals in the log =
a DHCP/AP problem worth chasing.

**Audio inputs** — Spotify (librespot) + AirPlay (shairport-sync) are vendor-default-ON
and mix into the default PulseAudio sink (TAS5713); Roon (`roon.service`) + **USB Audio**
(`nexusq-uac2-in.service`, the Q as a UAC2 USB DAC — kernel r46
`CONFIG_USB_CONFIGFS_F_UAC2`) are **default-OFF**, so an inactive one is **normal, not a
`failed_unit`**.
⚠️ **USB Audio is EXCLUSIVE and bypasses PulseAudio (rewritten 2026-08-09, device r65).**
When USB Audio is ON, the healthy tells are DIFFERENT from the other inputs: the
`UAC2Gadget` ALSA capture card is present, an **`alsaloop` process is running**
(`hw:UAC2Gadget` → `hw:NexusQSpeaker`, `--sync=simple`), and **PulseAudio's tas5713
sink is SUSPENDED** — that suspended sink is **NORMAL while USB audio is on, NOT a
fault** (alsaloop owns the TAS5713 card directly; PA is handed back on stop). Volume is
driven via the TAS5713 **hardware** mixer (`amixer` Master/Speaker via `nq-vol`), not
PA. `alsaloop` sits at **~0 %** CPU; die temp is **76–79 °C** with USB audio playing.
✅ **The old PA-bridge bugs are FIXED here** — the multi-minute playback drift (bogus
`module-alsa-source` latency poisoning `module-loopback`) and the idle CPU/heat burn
(never-corked loopback sink-input) are gone with the direct-alsaloop rewrite; do NOT
re-flag them. **Note:** the nexusqd LED music visualizer taps the PA source, so it does
**not** react to USB-audio playback (a known minor limitation, not a fault). See
`docs/2026-08-08-usb-audio-playback-delay-and-ota-publish.md`.
The Q has **no optical/HDMI/line input** — every port is an OUTPUT.

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
`led_frozen_events` and `led_static_events`. *(Since device **r72**, 2026-08-13,
the `nq_progress` half of that co-signal is a **60 s window**
(`NQ_PROGRESS_STALE_S`), not a per-sample tick delta — see the r13/r72 note
above; on r13-with-healthd-≤r71 it was firing false CRITs on idle devices.)*

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
>   readable ring-state source — and healthd fingerprints it (md5 + byte sum;
>   since r71 a one-pass od|awk byte-sum + rolling hash — no md5, equality-only
>   use, semantics unchanged), keeping the brightness loop only as a pre-0029
>   fallback.
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
> - **`ls_active`/`ls_restarts` were silently DEAD on device r31–r39** (fixed
>   **r40**, flashed 2026-07-13): librespot became a uid-10000 **user** unit in
>   r31 but healthd kept querying the SYSTEM manager → always `unknown`/`0`, so
>   `librespot_restart` could never fire on those images (and pid 1 loaded+GC'd
>   the nonexistent unit every poll). r39's attempted fix
>   (`XDG_RUNTIME_DIR=/run/user/10000 systemctl --user`) also fails — systemd 261
>   refuses cross-user private-socket connections; the working form (r40) is
>   `systemctl -M user@ --user show …`. Don't trust `ls_*` fields in any capture
>   from an r31–r39 image.
> - **healthd itself was the top idle CPU consumer through r39** — 5 systemctl
>   execs per 5 s sample held pid 1 at ~3.4 % idle. **r40 is process-first**:
>   cached MainPID + `/proc` liveness per sample; ONE `systemctl show` (3 props)
>   only on transitions (a restart always changes MainPID, so `NRestarts` bumps
>   are still caught). pid 1 idle: 3.4 % → 0.10 % measured. **r68 (2026-08-12)**:
>   with librespot *masked* the r40 transition rule degenerated into a
>   `systemctl -M user@` per tick (~600 PAM sessions/h, pid 1 back to 4 %) —
>   unit state is now resolved **cgroup-first**, systemd asked only on a real
>   (re)start or once per `NQ_UNIT_REFRESH_S`; also new `opp_ms`/`opp_trans`
>   kernel-counter residency fields. **r71 (2026-08-13, the fork diet)**: the
>   2026-08-13 attribution still measured healthd at ~6.3 % of a core (~5.7 %
>   its ~35-40 forked children per 5 s tick) — now every probe that can be an
>   ash builtin is one (`rdv` reads, fork-free stat/show parsing, one-pass LED
>   fingerprint, dmesg every `NQ_DMESG_EVERY` ticks default 30 s, glob pstore
>   count, fifo `read -t` tick instead of `sleep`). Measured: 4212 → 1682 ms
>   CPU/60 s (−60 %), production 2.3 % of a core, system idle fork rate
>   14 → 3.2/s. **JSONL schema unchanged** — captures parse identically.
>   See `docs/2026-08-13-idle-opp-residency-measurement.md`.
>   **r77 (2026-08-20, the C rewrite)**: even post-diet the shell measured
>   3.08 % of a core; the C daemon measures **0.55 %**, forks 2.45 → 0.75/s,
>   schema verified field-by-field against the shell.
> - **Log rotation stopped producing `health.jsonl` on r77–r79 (fixed r80,
>   2026-08-23)** — the C rewrite's `rotate_if_big()` renamed the file past the
>   4 MiB cap but kept the open `FILE *`, so the daemon appended to the renamed
>   inode forever: `health.jsonl.1` grows **unbounded** (25 MB seen live) and
>   `health.jsonl` is never recreated. Symptom: `nexusq-mqtt` publishes
>   **`healthd_fresh:false`** / HA raises "Health sampler" while
>   `nq-healthd.service` is active and sampling — check
>   `ls -la /var/log/nq-health/` before suspecting the daemon. **Fix (r80):**
>   `rotate_if_big(FILE **outp)` fcloses+NULLs the stream after a successful
>   rename. `docs/2026-08-23-healthd-rotation-and-ota-holdback.md`.
> - **`dmesg_err`/`kern_new_err` counts info-level brcmfmac `clm_blob` lines**
>   (matcher too broad) — cosmetic false positives, refinement candidate
>   (noted 2026-07-13; not a device fault).

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

- ~~**nexusqd has no watchdog** — a hang is unrecoverable. Real fix: sd_notify +
  `WatchdogSec=` in `pmos/nexusqd/` (so systemd restarts a wedged daemon).~~
  ✅ **DONE (v1.6.x, commit `543b492`)** — `nexusqd.service` is `Type=notify`
  with **`WatchdogSec=15s`**, and the daemon pings `WATCHDOG=1` from the render
  loop (rate-limited to 1/s, sent even when the frame is unchanged / the ring is
  idle — including under r13's stretched 1 Hz idle cadence). systemd SIGABRTs and
  restarts a wedged daemon. *(Stale entry corrected 2026-08-13.)*
- **RTC is wrong** (year 2000 until NTP) — timestamps use monotonic uptime;
  worth fixing RTC/NTP independently.
