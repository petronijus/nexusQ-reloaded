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
(device-side anomaly events), `paths.txt`. (Since 2026-08-10 the on-device
`nexusq-mqtt` daemon also republishes the freshest `health.jsonl` sample to
MQTT/Home Assistant — a field change in healthd now propagates there too.)

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
  **nexusqd_no_progress** (no CPU time). *(Correction 2026-08-13: this used to
  say the sd_notify watchdog was a missing follow-up — it SHIPPED in v1.6.x
  (`543b492`). `nexusqd.service` is `Type=notify`, `WatchdogSec=15s`, and the
  daemon pings `WATCHDOG=1` once a second from the render loop, so systemd does
  SIGABRT + restart a wedged daemon; the healthd signals stay useful for faults
  that leave the render loop — and the ping — alive.)*
  ✅ **`nq_progress` is a 60 s WINDOW since device r72 (2026-08-13) — FIXED.**
  *(Was flagged here as an unverified risk; it was real — with `nexusqd` r13 +
  healthd ≤ r71 it fired **CRIT `led_frozen` on a healthy idle device twice**:
  `{"t_mono":214110,"sev":"crit","kind":"led_frozen","msg":"LED frame unchanged
  for 6 samples with distressed nexusqd (resp=1 progress=0) …"}`, again at
  214497.)* healthd compared `/proc/pid/stat` ticks across a single 5 s sample,
  and an idle r13 nexusqd accrues only **~0.8 USER_HZ ticks per sample** — so
  zero-delta became ordinary, while `LED_STALL >= 6` is guaranteed on a
  locked/blanked ring. **r72:** `nq_progress` is 0 only after the tick count has
  stood still for `NQ_PROGRESS_STALE_S` (default **60 s** ≈ 10× the ~6 s idle
  tick interval); the window resets while the unit is stopped. **On r72+ believe
  a `led_frozen` CRIT again**; downgrade it only on the narrow
  r13-with-healthd-≤r71 combination. See
  `docs/2026-08-13-led-stall-verdict-and-progress-window.md`.
  ✅ **Healthy-idle tell (r72 + `nexusq-mqtt` r2):** blanked ring ⇒ **large,
  growing `led_stall`** (hundreds–thousands) **with `led_stalled = false`** and
  `binary_sensor.nexus_q_led_ring = off` in HA. **HEALTHY — do not report it.**
  `led_stall` is diagnostic only; `led_stalled` (= `led_stall >= 6` AND nexusqd
  distressed, computed on-device) is the verdict the app and HA alarm on.
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
  ⚠️ **OTA LED states are NOT faults (nexusqd r11 / control r20, device OTA — PROTOCOL
  §12, 2026-08-02).** During/after a daemon OTA the bridge drives: the **mute LED
  blinks amber** (`mblink 255 140 0`) = "update available" (a persistent indicator, not
  a stuck frame), and the **ring shows a determinate `progress` bar** then a brief green
  `set 0 255 0` while installing (transient, expected). The install restarts the daemons
  (incl. `nexusq-control`/`nexusqd`), so a **brief nexusqd/bridge restart just after an
  OTA is expected**, not a `nexusqd_restart` fault. A **full-system OTA**
  (`installSystemUpdate`, §12b, control r21+) uses the **indeterminate `spin` spinner**
  (not the bar) and may **reboot** when base libc/init churns — a reboot/fresh uptime
  right after a System update is expected. See
  `docs/2026-08-02-device-ota-and-wifi-nogw-heal.md` +
  `docs/2026-08-02-full-system-ota-and-glibc-rt-split.md`.
  ⚠️ **KNOWN OPEN (2026-08-08): a System OTA reports "system update failed" even though
  the packages installed.** `apk fix -s` shows a **persistent pending
  `postmarketos-mkinitfs` trigger** (`1 error`, re-fails every apk run): `boot-deploy`
  can't find a kernel in `/boot` (empty plain dir on this ramdisk-less device — kernel
  is in the flashed boot partition). Verify with `apk info` (packages committed); don't
  read it as a broken update. NOT fixed, Phase-2 territory. See
  `docs/2026-08-08-system-ota-mkinitfs-trigger-failure.md`.
- **nexusqd_down / nexusqd_restart / librespot_restart** — service died or
  flapped; check the `nexusqd recent journal` section of `snapshot.txt`.
  ⚠️ **`ls_active`/`ls_restarts` are UNTRUSTWORTHY in captures from device
  r31–r39 images** (always `unknown`/`0` — healthd queried the SYSTEM manager
  after librespot became a uid-10000 USER unit in r31, so `librespot_restart`
  could never fire). **Fixed in r40** (v1.8.2, flashed 2026-07-13) via
  `systemctl -M user@ --user` — root cannot borrow the user's
  `XDG_RUNTIME_DIR` (systemd 261 refuses cross-user private sockets; r39
  shipped that broken form and was burned).
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
  ⚠️ **Thin headroom (active watch-item) — the envelope has been BREACHED.** Peak
  under sustained dual-core load crept from 91.8 °C (2026-07-03) to ~94–99 °C
  (2026-07-06, v1.6.9/v1.6.10; 97.2 °C on the 2026-07-13 v1.8.2 acceptance) and a
  **2026-07-15 (v1.9.0) sweep measured 102.8 °C under bounded dual-core load —
  PAST the 100 °C passive trip** (was "~94–99 °C, no throttle"; now 102.8 °C **with**
  throttling, as of 2026-07-15). So a **non-zero `cooling_device0/cur_state` under
  load is EXPECTED, not a fault** — 125 °C critical was never approached. **OPEN**;
  the old envelope understates the real ceiling. Always report the peak temp on a
  load run.
  ⚠️ **Idle temperature is observer-sensitive** (measured 2026-07-13): any live
  ssh/diag session heats the die to 74–79 °C within seconds (cooling constant
  ~10 s); the true unobserved idle floor is **~65–66 °C**. Judge idle temp only
  from an on-device self-logging capture with no session attached.
- **governor_not_scaling** — load was high but freq never left 350 MHz; the
  governor or cpufreq path is stalling. See `CPU` + `CLOCKS` (`dpll_mpu`).
  Expected governor since **v1.8.2** (kernel r43, 2026-07-13): **`conservative`**
  (was `ondemand` v1.6.6–v1.8.1) — and a healthy ≥v1.8.2 idle **settles at
  350 MHz** (~56.7 % residency 2026-07-13; **60.5 %** on the first clean 14 h
  hands-off measurement 2026-08-13/r70 — judge from `opp_ms`/MQTT `opp*_pct`,
  never `freq`; expect higher on **r71 + nexusqd r13**, the 2026-08-13 idle diet
  — healthd 6.3 → 2.3 % of a core, nexusqd 4.4 → **0.165 %** and 22 → **2.9
  wakeups/s**, idle fork rate 14 → 2.6/s, ~12 pp of one core removed;
  ~4.25 trans/s. **Post-diet 2026-08-13** (240 s, ring blanked): idle busy
  **8.73 %** of a core — **real ≈ 7.7 %**, an ssh poll loop inflated
  `sshd`/`init.scope` (untrustworthy) — forks **2.59/s**; **`nq-healthd`
  2.43 % = new #1**, nexusqd 0.14 %, **`brcmf` ~34–40 wakeups/s dominates all
  other wakeup sources combined**); a sustained ~920 MHz idle hover
  is a regression (the old ondemand microburst sawtooth). See
  `docs/2026-07-13-idle-power-governor-and-pid1-churn.md` +
  `docs/2026-08-13-idle-opp-residency-measurement.md`.
- **kernel_errors** — new oops/WARN/i2c-timeout/voltage lines; read the
  `KERNEL_LOG_FULL` tail in `snapshot.txt`. ℹ️ **As of v1.6.10 the boot log is
  GENUINELY CLEAN:** on a clean-flash `#36` / device r28 boot, `dmesg -l err,warn`
  is **EMPTY** and `journalctl -b -p warning` = **ONLY 4 genuinely-external
  residuals** (3 through v1.8.1; #4 dispositioned 2026-07-13) — (1) eth-lan DHCP
  fail on a DHCP-less direct PC cable
  (environmental), (2) kscreen `.service` D-Bus naming (upstream libkscreen),
  (3) avahi `No NSS support for mDNS` (`nss-mdns` unpackaged), (4) a **one-shot**
  NM `sd-event.c:4488 assertion failed` at the RTC→NTP clock step (NM's vendored
  libsystemd asserting on the huge CLOCK_REALTIME jump — no RTC battery; NM
  continues fine, WiFi associates the same second; more than one per boot = a
  finding). **Anything else is
  a REGRESSION** — including the whole former B/U residual set (B4 brcmfmac
  fw-probe, B10 hw-breakpoint, B16 ramoops, B21 L2C/gpmc/pmu/journald, B22/B23
  twl, U5 bluetoothd, U7 nsresourced), all now fixed/downgraded/disabled in
  v1.6.10 (patches 0033–0036, defconfig BPF/ACL/SYN, DTS, device r28 — see
  `docs/2026-07-02-boot-error-inventory.md` v1.6.10 update +
  `docs/2026-07-06-bootlog-cleanup.md`). The L2C aux-modify notice is an
  **authorized** `pr_debug` downgrade (register end-state identical to stock).
  ℹ️ healthd's `dmesg_err` matcher also counts **info-level** brcmfmac
  `clm_blob` lines (too-broad matcher, noted 2026-07-13) — cosmetic false
  positives in `kern_new_err`, not a device fault.
  ℹ️ **DEBUG-level noise on v1.7.0/v1.7.1 (NOT err/warn):** the continuous NFC-tap
  poll emits **~200 "shdlc: .." lines/boot** and the old cmdline
  (`ignore_loglevel`+`loglevel=7`) forces the debug firehose (gpiolib "can't parse
  scl-gpios") onto the HDMI console — `dmesg -l err,warn` stays EMPTY, so NOT a
  regression. **Silenced in v1.7.2** (kernel r39, on device): patch `0039`
  (`print_hex_dump_debug`) + cmdline drops `earlyprintk`/`ignore_loglevel`,
  `loglevel=7`→`4`. Confirm shdlc gone on the next sweep. See
  `docs/2026-07-08-audio-volume-scale-and-bootlog-cleanup.md`.
- **TAS5713 speaker was SILENT until v1.6.13 (kernel r36)** — a wrong `mcbsp2_pins`
  mux (`0x110/0x114/0x116` = `abe_dmic_*`, not McBSP2) left the real I2S balls in
  `safe_mode`, so the amp got no clock/data/frame while the ALSA pipeline read
  healthy (`aplay` rc=0). Fixed to stock pads `0x0f6/0x0fa/0x0fc` MUX_MODE0. Any
  pre-v1.6.13 "audio works" claim was software-only; silent amp with rc=0 = suspect
  the pinmux, not the driver.
- **Audio routing is PA-centric (v1.6.15, device r31 / nexusq-control r6 / nexusqd
  r7)** — the ALSA `type multi` fan-out is gone. librespot is a PA INPUT (USER unit,
  `--device pulse`); the active OUTPUT (speaker/SPDIF/HDMI) = the PA **default sink**,
  switched from the app via `setOutput` (`pactl set-default-sink` + move sink-inputs +
  amp Speaker safety toggle + default-source→`<sink>.monitor`). Volume/mute = `pactl`
  on the active sink. Both sinks run **48000 Hz** (`50-nexusq-48k.conf`; 44.1 kHz
  detunes the McASP DIT). The LED visualizer reads the active `<sink>.monitor` via
  `arecord -D pulse` + an **AGC** (`AGC_TARGET 0.15`) so it reacts to music at any
  volume — healthy tell: steady `audio DETECTED vol=0.150`; low-volume
  flicker↔breathing = AGC regressed. See
  `docs/2026-07-07-audio-outputs-spdif-mcbsp2-and-pa-routing.md`.
- **LED tap GATED on playback (v1.7.1, nexusqd r8)** — the `arecord -D pulse` tap
  used to run continuously (uncorked PA source-output held the `tas5713` sink
  IDLE/clocked at silence → ~7 % idle CPU, top idle-heat source). nexusqd runs
  arecord **only while a stream plays** (gate = sink-input count, not level).
  **Idle-healthy tell:** no `arecord`, `tas5713` sink **SUSPENDED** (not IDLE) in
  `pactl list short sinks`, nexusqd **~0-1 %** CPU (was ~7 %); playback → arecord
  present + sink RUNNING; after → re-gated → SUSPENDED. arecord running at idle /
  sink IDLE / nexusqd ~7 % = regression. Dep `+pulseaudio-utils`.
  🆕 **The gate is EVENT-DRIVEN since nexusqd r13 (2026-08-13)** — it used to poll
  `pactl list short sink-inputs` every 1.5 s while the tap was off (~0.67 forks/s,
  and each short-lived client also woke every *other* PA subscriber on the box).
  Now one **persistent `pactl subscribe`** child feeds `'new'`/`'remove'`
  sink-input events into the poll loop; timed re-counts are a safety net (30 s
  tapping / 60 s idle once the subscriber is proven ≥2 s alive, 1.5 s while it is
  down, respawn every 10 s). **Healthy tell:** exactly **one** long-lived
  `pactl subscribe` under `nexusqd.service` and **no** recurring short-lived
  `pactl` from it; a stream of short `pactl` forks on r13+ = the subscriber keeps
  dying (check PA). Gate latency measured live: a silent sink-input opens the tap
  in **~200 ms**. See `docs/2026-07-08-audio-volume-scale-and-bootlog-cleanup.md`
  + `docs/2026-08-13-idle-opp-residency-measurement.md`.
- **Volume gain RESOLVED (v1.7.2 kernel 0038 + v1.7.3 device r35, verified live)** — PA
  used to stack **both** TAS5713 controls: `analog-output-speaker.conf` marked
  `[Element Master]` **and** `[Element Speaker]` as `volume = merge`, so PA filled
  Master (0..+24 dB) then recruited Speaker (another +24 dB) = **+48 dB at 100 %**
  (deafening). Fix = kernel 0038 (Master dB-scale shift, on device) **plus** device
  **r35** post-install `sed`ing `[Element Speaker] volume = merge → volume = zero`
  (pins Speaker at unity). **Healthy tell:** `amixer`/`pactl` shows Speaker (numid 2)
  at **0 dB**, Master (numid 1) carrying the range; measured PA 50 % ≈ +6 dB, 100 % =
  +24 dB. Speaker at +24 dB / total +48 dB = the merge-stacking regressed. Also
  **nexusq-control r8** = dial→app volume sync (`pactl subscribe` → `volumeChanged`).
  r35 + r8 shipped via v1.7.3 and are **in the flashed image since the v1.8.x
  full-rootfs flashes** (was "not yet flashed" as of 2026-07-08).
  See `docs/2026-07-08-audio-volume-scale-and-bootlog-cleanup.md` §4.
- **Bluetooth A2DP RELIABLE (v1.8.0, kernel r40 / device r38)** — root cause of every
  past "BT won't stay connected / phantom Connected / corrupt-burst audio" was a
  **missing BT HCI UART `max-speed`**: the BCM4330 HCI runs over UART2 and `hci_bcm`
  left `oper_speed=0`, never syncing the host UART to the firmware baud. Kernel **patch
  0040** sets `max-speed = <3000000>` (stock 3 Mbaud). **Healthy tell:**
  `dmesg | grep -c 'Frame reassembly failed'` = **0** (was 26+), `bluetoothctl show`
  controller addr = **F8:8F:CA:20:49:E5**, and while a phone is connected a
  `bluez_source` (s24le/48 kHz) appears in `pactl list short sources` → looped to the
  TAS5713 sink. ANY `hci0: Frame reassembly failed (-84)` = the max-speed fix
  regressed. NOT coexistence, NOT HFP/SCO (both earlier wrong guesses). Verified live
  (boot.img); v1.8.0 tagged 2026-07-10.
  See `docs/2026-07-09-bluetooth-uart-max-speed-and-crackle-isolation.md`.
- **BT PAIRING: ROOT-CAUSED + FIXED 2026-07-15 (released in v1.9.0) — TWO userspace bugs, NOT
  a BCM4330 HW limit.** ⚠️ **"The BCM4330 cannot complete SSP bonding" is RETRACTED**
  — bonding + A2DP verified 2026-07-09 AND 2026-07-15. **Never re-derive a hardware
  limit from a userspace symptom.** If pairing breaks, check these FIRST:
  1. **A second BlueZ agent — almost always `blueman-applet`.** SSP picks its model
     from BOTH ends' IO caps: phone DisplayYesNo + Q `NoInputNoOutput` = **Just
     Works** (silent bond); phone DisplayYesNo + Q **DisplayYesNo** = **Numeric
     Comparison** = a Confirm/Deny dialog on the HDMI desktop **nothing attached to
     the Q can click** → every bond times out with **mgmt `0x0e`**. Also
     `RequestDefaultAgent` is **last-writer-wins** → the applet steals the default
     agent. Suppressed since **device r47** (`/etc/xdg/nexusq/autostart/blueman.desktop`,
     `Hidden=true`; the blueman *package* stays). **Starting `blueman-applet` by hand
     re-breaks pairing.** Healthy Just-Works tell in the journal:
     `user_confirm_request_callback ... confirm_hint 1`.
  2. **The phone bonding on demand from the socket.** Android's implicit bond from
     `createRfcommSocketToServiceRecord` against an unbonded Just-Works peer collapses
     (`bonding_attempt_complete status 0x5` → `0x0e`), no link key written, and it
     surfaces as a **misleading "incorrect PIN"** toast — *no PIN exists in Just
     Works*. The app must `createBond()` + await `BOND_BONDED` **before** connecting.
  **Expected healthy state:** `nexusq-btagent` registered as the **default agent**
  (permanent, `NoInputNoOutput`), blueman-applet **absent**, `nexusq-setupd`
  registering **NO** agent, profile `RequireAuthentication=True` on **channel 22**,
  bonds marked **`Trusted`**, Class **`0x006c0428`** (post-install sets `0x200428`;
  bluez 5 ORs in its own service bits), and — **since v1.10.0 / btagent r3** —
  **`ring ⇔ Pairable`, with `Pairable: no` AT REST** *(was `Pairable ==
  Discoverable` in v1.9.0 — that invariant was keyed on the WRONG property and
  silently broke OUTBOUND bond persistence; see §"BT pairing from the app" below)*.
  ⚠️ **At rest `Pairable: no` + ring not spinning is HEALTHY, not a fault.**
  `Pairable: yes` outside an open window is the anomaly worth reporting.
  **Correct BT firmware = stock steelhead
  `Google Phantasm BCM4330B1`, build 0749, md5 `7e5bb859e33142e94052c76fba23b9e6`,
  51813 B** (a WRONG `Proxima … NoExtLNA` build-0482 blob, md5 `16db686…`, shipped
  through v1.8.2 — check `bluetoothctl show`/`dmesg` for the loaded patchram build).
  **Known OPEN flake:** pairing may need ~2 failed attempts before succeeding (not
  root-caused; suspect the app's 30 s `ensureBonded` timeout and/or a stale
  phone-side bond). See
  `docs/2026-07-15-bt-onboarding-root-caused-blueman-agent-and-bond-first.md`.
- **BT PAIRING FROM THE APP — both directions (v1.10.0, btagent r3 / control r10).**
  The Q has no screen/input, so **the app IS its Bluetooth settings panel**.
  **Inbound** = a phone pairs for A2DP. **Outbound** = the Q scans for and pairs a
  **mouse/keyboard** — a *different flow*: a mouse never connects TO us.
  **⛔ The v1.9.0 `Pairable == Discoverable` invariant was keyed on the WRONG
  property and silently broke OUTBOUND bonding.** A/B (MX Master 4, same agent, one
  variable): `Pairable: no` → pair "succeeds", **`Bonded: no`, NO keys stored, gone
  on restart**; `Pairable: yes` → **`Bonded: yes`**, `[PeripheralLongTermKey]` +
  `[IdentityResolvingKey]` on disk, survives. Chain from `bluetoothd -d`: the LTK
  **arrives** (`new_long_term_key_callback() … enc_size 16`), but bluez only persists
  a key the kernel marked **`store_hint`**, which needs the SMP **bonding bit**,
  which our side only sets under **`HCI_BONDABLE`** = **`Adapter1.Pairable`**.
  **Do not "re-minimise" `Pairable` — it is what makes a bond durable.**
  ⚠️ **Read `bonded`, NEVER `paired` — `paired` alone LIES** (`paired: true` +
  `bonded: false` = pairs, connects, types, **gone on reboot**).
  **Healthy tells:** `/run/nexusq-btagent.sock` present (0600); the bridge forwards
  all BT calls to it (**the bridge is stdlib-only — no D-Bus in it, by design**);
  a paired mouse yields **3 key sections** in
  `/var/lib/bluetooth/<adapter>/<dev>/info` and a `/dev/input/event*` via **uhid**.
  **Non-faults:** BLE peers report **`class=none`** (they have **no CoD** — type
  comes from `Icon`→`Appearance` 0x03c1/0x03c2); `Alias` is **synthesised from the
  address** when unnamed, so it never proves identity; BLE addresses **rotate**
  between pairings/channels. A scan showing ~38 anonymous beacons in 25 s is normal
  radio noise, not a bug. See `docs/2026-07-15-step2-bt-pairing-implemented.md`.
- **HDMI DESKTOP ON DEMAND (v1.10.0, control r10 + device r48).** `setDesktop`/
  `getDesktop` → `tinydm.service`. **`/var/lib/systemd/linger/user` MUST be present**
  (device r48 bakes it, alongside the older `linger/root`) — PA + librespot are user
  units under `user@10000.service`, the desktop is `tinydm` → labwc in
  `session-c1.scope`; **without linger the user manager exists only because of the
  graphical session, so stopping the desktop KILLS THE MUSIC**. **Healthy tell:**
  with the desktop stopped, `pulseaudio` + `librespot` still **active** and **both
  sinks present**. ⚠️ **Not a fault:** stopping the desktop **churns logind** hard
  enough that ssh auth (`pam_systemd`) can **hang ~a minute** before recovering on
  its own — `set_desktop` allows 60 s. **Do not power-cycle** on that stall
  ([[never-conclude-dead-hardware]] applies to the box being "frozen" too).
- **Crackle ("lupance") CLOSED 2026-07-12 — two independent kernel fixes (r41 + r42),
  verified clean playback on `#43-postmarketOS`.** (a) Load-correlated drops =
  bus/DMA contention → kernel **r41** patch **0041** (sDMA `CCR_READ_PRIORITY` on the
  cyclic audio channel + GCR `HI_THREAD_RESERVED=1`). **Healthy tell:** sDMA
  `GCR = 0x00011010`, active audio channel CCR **bit6 = 1** (verified on ch20).
  (b) Metronomic ~1/s load-independent click = two free-running crystals (DPLL_ABE
  ref on sys_32k vs TAS5713 MCLK on the 38.4 MHz crystal) → kernel **r42** patch
  **0042** (DPLL_ABE relocked from sys_clkin). **Healthy tell:** `clk_summary` shows
  `abe_dpll_refclk_mux_ck` under `sys_clkin_ck` and `dpll_abe_ck` = **98304000**;
  a mux under `sys_32k_ck` or another rate = regression, the 1 Hz click returns.
  Baked mitigation from v1.8.0 still present: **`tsched=0`** in
  `/etc/pulse/default.pa` (healthy tell: `grep tsched /etc/pulse/default.pa` →
  `module-udev-detect tsched=0`) + Speaker-unity pin.
  See `docs/2026-07-12-audio-crackle-closed-sdma-priority-and-dpll-abe.md`.
  ⛔ v1.7.4 was a burned bake — its THRESHOLD service / 600 ms buffer / RT configs were
  removed; if any reappear (`nexusq-mcbsp-threshold.service`, `60-nexusq-latency.conf`,
  `CPUSchedulingPolicy` on the user units) it regressed.
- **`ss` is NOT installed on the device** — use **`netstat -tlnp`** to check listening
  sockets (a `ss`-not-found caused a long "no listener" misdiagnosis).
- **NFC tap-to-send (v1.7.0, device r33 / kernel r37)** — the PN544 chip works since
  `#29` (2026-07-03 pinmux fix); tap-to-send shipped v1.7.0. `nexusq-nfc.service` runs
  `/usr/bin/nexusq-nfc-send`, a **reverse-HCE reader daemon** that OWNS `nfc0` (the Q is
  the ISO-DEP reader, the phone runs the companion HCE service; AID `F0010203040506`).
  **Check:** `systemctl is-active nexusq-nfc` = active + `ls /sys/class/nfc/` → `nfc0`.
  **neard is NOT installed** (the daemon owns the device — don't start a second NFC
  consumer against `nfc0`; `systemctl stop nexusq-nfc` first if raw NFC is needed).
  Enabler: kernel **patch 0037** RATS-activates any ISO-DEP target (was DESFire-only),
  so a modern HCE phone (SAK 0x20) is reachable — without it the chip returns
  `ANY_E_NOK`. See `docs/2026-07-08-nfc-tap-to-send-reverse-hce.md`.
- **HDMI-audio card / PulseAudio** — the `omap-hdmi-audio` ALSA card is a
  snd-soc-dummy-DAI (not a usable sink; HDMI is desktop video only). Since
  **v1.6.9** PA ignores it via a `PULSE_IGNORE` udev rule, so
  `module-alsa-card: Failed to find a working profile` no longer fires. If it
  recurs it's a regression. **Lesson — ALSA card indices are probe-order
  dependent:** the first rule pinned `KERNEL=="card1"` and tagged the wrong card
  (HDMI came up as card2 one boot); the shipped rule matches the backing device
  `KERNELS=="omap-hdmi-audio.1.auto"`. Any per-card udev/PA rule MUST match by
  backing device (`KERNELS=`) or card id, never by `cardN` index.
- **Desktop audio sink / PulseAudio running (v1.6.12, device r30)** — the
  LXQt/labwc **Wayland** desktop had a **red-cross no-sink tray icon** because PA
  never started: Alpine ships no PA systemd user unit and the XDG autostart
  (`start-pulseaudio-x11`, hidden-under-systemd) never fires under systemd+Wayland
  (`xdg-desktop-autostart.target` dead), with `autospawn=no`. **Fix:** a native
  `pulseaudio.service` systemd USER unit (`default.target.wants/` symlink,
  plain daemon, NOT socket-activated — a socket double-binds PA's own native
  socket → "bind(): Address in use"). Also PULSE_IGNORE the snd-aloop **Loopback**
  (`KERNELS=="snd_aloop.0"`) so PA's ONLY sink is the TAS5713 speaker (Loopback had
  become the default sink at card index 0 on some boots). **Diag check:**
  `systemctl --user is-active pulseaudio` = active, and the default sink is
  `alsa_output.platform-sound-tas5713.stereo-fallback` (NOT `…snd_aloop…`). Red
  cross / "Connection refused" from `pactl` = PA not running = regression. See
  `docs/2026-07-07-desktop-audio-pulseaudio-fix.md`.
- **pstore** (crit) — a previous boot panicked; the dump is in the `PSTORE`
  section. Remember pstore only survives a *warm* reboot.

When a crit finding has a timestamp, `report.txt` prints the per-sample timeline
around it — use that to correlate (e.g. did temp spike or freq stall at the
moment the ring froze?).

## Reporting back

Give the user the verdict and the specific findings with their evidence (quote
the timeline / snapshot section), and—if a finding implies a code fix—name the
file to change (that is how the `nq_progress` false-CRIT vector opened by
nexusqd r13 got named and then fixed in
`pmos/device-google-steelhead/nq-healthd`, device r72, 2026-08-13) rather than
applying a workaround. Captures persist under `nq-captures/` for later diffs, so
you can compare a "good" run against a "bad" one.

All ground-truth subsystem paths this tooling reads are documented in
`scripts/diag/README.md`.
