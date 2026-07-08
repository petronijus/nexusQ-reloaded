# 2026-07-08 — TAS5713 volume scale (no PA software boost), idle-tap gating, boot-log cleanup

Three audio/thermal/log items this session. Item 1 is **shipped + verified** on
device (v1.7.1); items 2–3 are **built, not yet flashed** (v1.7.2 in the oven — do
not treat as confirmed until an on-device sweep). Recorded here regardless of
v1.7.2's outcome because the gain analysis + the +48 dB dead-end are worth keeping.

## 1. Idle LED-tap gating — nexusqd r8 (SHIPPED, VERIFIED, v1.7.1)

**Symptom:** ~7 % idle CPU on the OMAP4 doing nothing, and the top idle-heat
contributor. The LED music-visualizer tap (`arecord -D pulse` on the active
`tas5713.monitor`) was an **uncorked PA source-output**, so PA's suspend-on-idle
could never suspend the sink: at silence the `tas5713` sink stayed **IDLE
(clocked)**, PA (~4 %) + arecord (~2 %) burned ~7 %.

**Fix (`userspace/nexusqd`, `pmos/nexusqd` r7→r8, commit `af7fa0e`):** gate the tap
on a **live PA sink-input** — a real playback stream. nexusqd polls
`pactl list short sink-inputs`; when none exist it stops arecord so PA suspends the
sink, and respawns arecord when a stream appears so the visualizer still reacts.
The gate signal is sink-input **COUNT, not audio level** — a quiet passage of a
playing stream keeps the tap on. pactl is polled only around a possible transition
(tap off → ~1.5 s cadence; tap on + raw-silent 4 s → re-check), never while music
flows, so idle pactl overhead ≈ 0. `audio_open()` now returns the arecord pid;
`audio_close()` SIGTERMs it then closes the pipe. New dep: `pulseaudio-utils`
(for `pactl`). Code: `src/audio.c` (`audio_open`/`audio_close`/
`pa_sink_inputs_active`), `src/nexusqd.c`, `include/audio.h`.

**Verified LIVE on device (v1.7.1):**
- idle → `arecord`=0, `tas5713` sink **SUSPENDED** (was IDLE), nexusqd **0 %** CPU
- during playback → `arecord`=1, sink **RUNNING**
- after playback → `arecord`=0 (re-gated ~4 s later), sink IDLE→**SUSPENDED**

Idle CPU **~7 % → ~1 %**. Satisfies the AI-handover "idle temperature / performance" task.

## 2. TAS5713 Master volume scale — no PA software boost (BUILDING, v1.7.2, NOT flashed)

Kernel patch `0038-ASoC-tas571x-tas5713-steelhead-volume-scale-no-sw-boost.patch`
gives the TAS5713 its **own** ALSA controls (was sharing mainline `tas5711_controls`).

**Measured facts:**
- PA drives the **Master** volume (numid 1) for the sink; it **pins** the
  per-channel **Speaker** volume (numid 2) at that control's "0 dB" point.
  Total output gain = **Master(dB) + Speaker(dB)**.
- Mainline `tas5711_volume_tlv` tops out at **+24 dB** digital gain, so PA's 100 %
  sat **above** the hardware max: the Master control saturated at **~PA 45 %**, PA
  added **software gain** above that (a dead zone + quality loss), and the desktop
  volume icon read **"45 %" at the real ceiling**.

**Fix:** shift **only the Master** dB scale — new
`tas5713_volume_tlv = -12750` (i.e. −127.50 dB min, 0.5 dB step, over 0..0xff) so
the hardware max register (0xff) maps to **PA 0 dB / 100 %**. PA then spreads its
whole 0-100 % across the Master control: no software boost, the icon reads full at
the ceiling, hardware/decibel volume the whole way. The **Speaker** volume MUST
keep the original `tas5711_volume_tlv` (unity).

**Dead-end preserved — the +48 dB bug (first attempt, v1.7.1):** shifting **both**
scales pinned the Speaker at its **+24 dB extreme** and **stacked a second +24 dB**
on Master → **measured +48 dB total at PA 100 %**. Corrected in v1.7.2: Speaker
stays at unity, so PA 100 % total = **+24 dB**.

**Status — SUPERSEDED, see §4 Resolution below.** Patch 0038 **alone did NOT fix
loudness** — an on-device measurement showed PA stacks a *second* control on top of
Master, so the shift actually made PA recruit Speaker *sooner*. The complete fix
needed a second part (pin the Speaker control at unity). Resolved + verified live
2026-07-08; recorded in §4.

## 3. Boot-log cleanup (BUILDING, v1.7.2, NOT flashed)

- **`0039-nfc-hci-shdlc-silence-frame-hexdumps-steelhead.patch`** — `SHDLC_DUMP_SKB()`
  `print_hex_dump(KERN_DEBUG, …)` → `print_hex_dump_debug()`. `print_hex_dump()`
  always writes to the ring buffer regardless of console loglevel; the continuous
  pn544 poll for NFC tap-to-send therefore filled the log with **~200 "shdlc:
  00000000: .." lines every boot**. `print_hex_dump_debug()` is a no-op without
  `CONFIG_DYNAMIC_DEBUG`/per-file `DEBUG` (neither is set on this image), so the
  dumps vanish while staying one dynamic-debug toggle away for real SHDLC debugging.
  The paired `pr_debug("%s:\n")` was already gated the same way.
- **kernel cmdline** (`kernel/configs/steelhead_defconfig` `CONFIG_CMDLINE`, plus
  `scripts/repack-bootimg.sh` and `build-noramdisk.sh`): removed **`earlyprintk`**
  and **`ignore_loglevel`**, `loglevel=7` → **`loglevel=4`**. `ignore_loglevel` was
  forcing **all** debug prints onto the HDMI console — the gpiolib i2c "can't parse
  scl-gpios" verbosity **and** the shdlc dumps. The diag boot scripts
  (`build-diag-boot2.sh`, `manual-export.sh`) were **intentionally left verbose**.

Net effect (once flashed + verified): the continuous NFC polling no longer floods
`dmesg`/journal, and the HDMI console stops showing the debug-level firehose. Boot
log was already GENUINELY CLEAN at `dmesg -l err,warn` since v1.6.10; this is about
the **debug-level** volume the v1.7.0 NFC poll introduced.

## 4. RESOLUTION — volume fix completed + dial→app sync (verified LIVE 2026-07-08)

Kernel patch 0038 (v1.7.2, on device) shifted the **Master** dB scale but the amp
was still deafening. An on-device measurement found the **root cause the §2 draft
missed**: PulseAudio drives **BOTH** the TAS5713 Master (numid 1) **AND** the
per-channel Speaker (numid 2), because the mixer path
`analog-output-speaker.conf` marks BOTH `[Element Master]` and `[Element Speaker]`
as `volume = merge`. PA **stacks** them — it fills Master (0..+24 dB) then recruits
Speaker (another 0..+24 dB) → **+48 dB total at PA 100 %**. The shifted Master TLV
actually made PA recruit Speaker *sooner*, so 0038 alone was **insufficient**, not
"pending listen".

**The fix = two parts, both required:**
1. **Kernel patch 0038** (v1.7.2, already on device): Master dB scale shifted
   (`tas5713_volume_tlv = -12750`) so PA maps its whole 0-100 % across Master — no
   software-boost dead zone, icon reads full at the ceiling.
2. **device-google-steelhead r35** post-install (v1.7.3, BUILDING): pins the
   per-channel Speaker at unity — a `sed` sets `[Element Speaker] volume = merge →
   volume = zero` in `analog-output-speaker.conf` (in-place, idempotent, same
   pattern as the bluez/avahi patches already there). PA now drives **ONLY**
   Master; Speaker stays at **0 dB**.

**Measured LIVE (v1.7.2 kernel + the path pin applied on device):**

| PA level | Master gain | Speaker | Result |
|----------|-------------|---------|--------|
| 20 %     | −17.5 dB    | 0 dB    | quiet  |
| 50 %     | +6 dB       | 0 dB    | comfortable, mid-dial |
| 100 %    | +24 dB      | 0 dB    | max (was +48 dB) |

Base Volume 100 %; volume spreads cleanly 0-100 %; Speaker pinned 0 dB across the
whole range. **User confirmed by ear: "this is good."** The audio-gain-cap polish
item is CLOSED (no separate lower ceiling needed).

**Bidirectional volume sync — nexusq-control r8 (v1.7.3, BUILDING, verified live).**
Added `pa_watch_thread` to the bridge: a `pactl subscribe` loop that detects sink
volume/mute changes made **outside** the bridge — the physical dome dial (via
`nq-vol` → `pactl set-sink-volume`) and the LXQt panel applet — and broadcasts
`volumeChanged` to app clients, so the companion app's slider **tracks the knob**.
It re-reads the active sink on every `on sink #` event but broadcasts **only on an
actual level/mute change**, so the sink run-state transitions from the LED-tap
gating (§1) don't spam clients. Verified live.

**Maturity:** kernel 0038 (v1.7.2) is on device. The Speaker-pin (device **r35**)
and the dial→app sync (nexusq-control **r8**) are **BUILDING into v1.7.3 — not yet
flashed as an image, not tagged**. The measurements above used the r35 sed applied
live on the running device.

**Next task (user-flagged):** investigate audio crackling / "lupance" during
playback — deferred until this volume work is clean; now clean, so it's next.
