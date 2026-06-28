# Nexus Q Reloaded -- Hardware Status & Plan

Status as of **2026-06-10** (after the boot/WiFi debugging session, see
HANDOFF.md "Session 2026-06-10" for root causes and access paths).

## Hardware Map

| Subsystem | Status | Detail |
|-----------|--------|--------|
| Kernel + boot | ✅ works | mainline 6.12.12, ≤8 MB image; flaky boot ~1 in 3 (retry helps). _(Updated 2026-06-28: now built with Alpine GCC 15.2 and boots — the old "GCC 13.3 only" no longer holds for the pmbootstrap path.)_ |
| HDMI video | ✅ works | omapdrm, framebuffer console |
| HDMI audio | ✅ works | ALSA `card0 HDMI` registers; needs a quick `speaker-test` |
| eMMC + rootfs | ✅ works | postmarketOS (systemd variant) on userdata |
| WiFi (BCM4330) | 🟡 connects, bulk flaky | assoc + small packets fine, but **can't sustain bulk transfers** (driver/firmware, not signal −33dBm/channel/regdomain; stuck 54Mb/s, no 11n, clm_blob missing). Deploy over the USB gadget net. NEEDS INVESTIGATION — see `docs/2026-06-20-session-handoff.md` |
| USB gadget network | ✅ works | RNDIS 172.16.42.1, SSH via nexus-diag.service |
| **TAS5713 amplifier** | 🟡 chip alive, no audio path | I2C driver bound (`3-001b`), reset/pdn GPIOs OK; missing: sound card node (McBSP2 I2S → TAS5713) + 12.288 MHz MCLK |
| Bluetooth (BCM4330) | 🟡 almost | `hci0` registers, wants firmware named `BCM.hcd` -- we have it (staged via `scripts/setup-firmware.sh`, not in repo) |
| TWL6040 codec | 🟡 deferred | driver never binds; `omap-abe-twl6040` card loops on -EPROBE_DEFER |
| NFC (PN544) | 🟡 detected | i2c device `2-0028` present, driver not loaded |
| TMP101 temp sensor | 🟡 detected | i2c device `1-0048`, needs `modprobe lm75` |
| LED ring (32× RGB) | ✅ works | mainline 6.12 driver `leds-steelhead-avr` (Plan 1, merged, auto-loads) + `nexusqd` daemon (Plan 2: idle glow, themes, CLI, autostart) -- behind `steelhead-avr` MCU (i2c `1-0020`) |
| Ethernet (LAN9500A) | 🟠 sw bug, not dead HW | _(Updated 2026-06-28)_ the "dead hardware" verdict was **wrong** — fixed in v1.1.0/v1.3.0 (patches 0006/0012); **regressed** in v1.4.0 by the cpufreq boot-timing change (down on current builds, fix tracked 1.4.1) |
| SMP (2nd core) | ✅ works | _(Updated 2026-06-28)_ dual-core since v1.2.0 — patch 0009 `dsb_sev()` in prepare + `cpuidle.off=1`; `nproc=2` re-confirmed live. See `docs/SMP-second-core.md` |

## Plan (by priority)

### 1. TAS5713 amplifier  ← TOP PRIORITY
The reason this device exists. **🟠 SW path verified 2026-06-10, speaker output untested.**
- [x] DTS: `simple-audio-card` "NexusQ-Speaker" wiring McBSP2 → TAS5713
- [x] DTS: MCLK 12.288 MHz (dpll_per_m3x2 61.44 MHz → auxclk1 /5 → fref_clk1_out
      pad 0x19a); McBSP2 master (clkx/fsx pads OUTPUT), SRG from abe_24m_fclk
- [x] `snd-soc-omap-mcbsp` module enabled (=m) and probing
- [x] `speaker-test -D plughw:NexusQSpeaker` runs clean (rc=0, no dmesg errors)
- [ ] 🟠 physical listening test once speakers are attached to the rear terminals

### 2. Bluetooth  ✅ DONE 2026-06-10
- [x] firmware installed (BCM.hcd + BCM4330B1.hcd); loads automatically at boot
      ("Proxima - BCM4330B1 37.4 MHz Class 1.5" -- device-specific config)
- [x] scan finds devices; controller powered, name "Google Nexus Q"
- [ ] pair a BT keyboard when at hand (solves GUI input)

### 3. HDMI audio smoke test  🟠 blocked by monitor
- [x] tested 2026-06-10: ALSA opens fail with -22 because the Philips 190C
      (DVI-era panel) provides no audio EDID ("timeout reading edid").
      Retest against a real TV/AV receiver -- expected to work.

### 4. GUI: lightweight Wayland desktop (weston)  ✅ DONE 2026-06-19
Decision: device runs **primarily headless**; desktop is for occasional
debugging/ops on the HDMI port. Switched X11/XFCE → Wayland/weston so the
future SGX540 GPU path is viable (X11/glamor ES2 is the broken path on the SGX
blobs -- see docs/2026-06-19-gpu-sgx540-acceleration-research.md §5).
- [x] **was** XFCE4 + lightdm (2026-06-10, X11, llvmpipe). **Removed 2026-06-19**
      (`apk del postmarketos-ui-xfce4 lightdm`).
- [x] **now** `postmarketos-ui-weston` + `tinydm` (auto-login, no greeter).
      Reproducible: `docker-build.sh` `ui = weston`; device package ships
      `/etc/xdg/weston/weston.ini` + `weston-nexusq.desktop` session + a
      post-install that sets the default tinydm session.
- [x] **pixman** SW renderer forced (`[core] renderer=pixman` + explicit
      `--config`): lighter than GL-on-llvmpipe on the single A9. Idle bg #000F14.
- [x] headless-tolerant: `require-input=false` (DRM backend otherwise aborts
      with "failed to create input devices" -- no keyboard/mouse attached).
- [x] verified live on `192.168.20.179`: weston auto-starts on HDMI-A-1
      (1024x768@60), survives reboot, ~190 MB RAM.
- [~] input: a **BLE** mouse/keyboard (e.g. Logitech MX Master 4) pairs +
      bonds fine over the BCM4330, but delivers **no input** until the kernel
      has `CONFIG_UHID` — HID-over-GATT (HOGP) needs `/dev/uhid` to spawn the
      input device. Symptom without it: `Paired: yes`/`Connected: yes` yet
      bluetoothd loops `input-hog profile accept failed` and no `/dev/input/event*`
      appears. **Fixed in `steelhead_defconfig` (CONFIG_UHID=y + CONFIG_HIDRAW=y,
      2026-06-19) — pending a kernel rebuild + boot reflash.** `CONFIG_BT_HIDP=m`
      only covers Classic-BT HID, not BLE. The bond lives on the rootfs, so a
      boot-only reflash keeps it; the mouse will just connect once uhid is present.
      Alt: USB OTG mouse/Logi-Bolt receiver (sacrifices the gadget network).

### 5. TWL6040 codec  🔴 DEAD HARDWARE (closed 2026-06-10)
- [x] root-caused: chip never ACKs on I2C 0x4b (-121/EREMOTEIO) with all
      inputs verified live: V1V8+V2V1 rails enabled, CLK32KG running,
      AUDPWRON (gpio_127) raised, bus healthy (TWL6030 ACKs on 0x48-0x4a).
      Second dead chip on this unit (with ethernet). Headset jack gone;
      TAS5713 speaker path and HDMI audio are unaffected.
- [x] sound + twl6040 nodes disabled in DTS -> clean boot, no deferred loop

### 6. NFC + temp sensor  ✅/🟠 done 2026-06-10
- [x] TMP101: lm75 module added, binds, reads 41.75 °C on the board
- [x] PN544: NFC modules added (NFC_SHDLC=y was the missing dep), driver
      binds, `nfc0` registers. 🟠 "could not detect nfc_en polarity" warning
      -- chip health unverified until tested with an actual NFC tag

### 7. TOSLINK / SPDIF output (audio, nice-to-have)
Optical out is driven by the OMAP4's own McASP block -- fully independent of
the dead TWL6040 codec. `spdif_dit` node already exists in the DTS.
- [ ] check mainline support for the OMAP4 McASP variant (davinci-mcasp may
      not know it -- might need a small driver patch)
- [ ] wire a second simple-audio-card: McASP -> spdif_dit
- [ ] test into a DAC/AV receiver
- Payoff for a vinyl/music household: bit-perfect digital out into a hi-fi DAC

### 8. Flaky boot (research)
- [ ] needs UART serial console (requires opening the device / soldering)
- [ ] until then workaround: power-cycle again
- Candidates: U-Boot DRAM init, kernel early race

### 9. LED ring  ✅ DONE 2026-06-19 (driver + daemon)
The 32 RGB LEDs sit behind the steelhead-AVR MCU (i2c `1-0020`, DT node
`avr@20` compatible "google,steelhead-avr"). The AVR speaks a simple
register-write i2c protocol (from AOSP `drivers/misc/steelhead_avr_regs.h`):
  - 0x02 LED_MODE   (0x02 = HOST full control, 0x00 boot anim, 0x03 power-up)
  - 0x03 SET_ALL    payload R,G,B
  - 0x04 SET_RANGE  start, count, R,G,B...
  - 0x05 COMMIT     (0x00 immediate, 0x01 interpolate)
  - 0x06 SET_MUTE ; 0x07 GET_COUNT ; 0x08 HW_TYPE ; 0x09 HW_REV ; 0x0A FW_VER
- [x] verified from userspace via /dev/i2c-1 (no driver bound): AVR reports
      HW_TYPE=0x01 (SPHERE), LED count=32; "HOST mode + SET_ALL dim-blue +
      COMMIT" lit the whole ring blue. Reads work with plain write-then-read.
- [x] **driver (Plan 1):** mainline 6.12 `leds-steelhead-avr` — multicolor LED
      class for the 32 ring + mute, batch `frame` sysfs channel, mute/volume keys
      via threaded IRQ, AVR-reset restore. Merged to `main`, auto-loads at boot,
      validated live. Plan: `docs/superpowers/plans/2026-06-19-led-ring-kernel-driver.md`.
- [x] **daemon + CLI (Plan 2):** `nexusqd` (C11/musl) — idle glow, theme palettes,
      `/run/nexusqd.sock` control + `nexusled` CLI, mute key, postmarketOS aport,
      systemd autostart (verified across reboot). `userspace/nexusqd/`, `pmos/nexusqd/`.
      Plan: `docs/superpowers/plans/2026-06-19-nexusqd-daemon.md`.
- [x] **Plan 2b (done 2026-06-19):** pixel-perfect volume-ring + mute + true idle
      `#000F14` in the priority-10 reaction-layer seam (exact algo in
      `docs/2026-06-19-volume-mute-RE.md`). Verified live: fade-in + brightness levels +
      mute LED (#001E28/#006B8E) + idle #000F14. Volume ring is a rotary encoder (evtest).
- [x] **Plan 3 idle screensaver (done 2026-06-19):** pixel-perfect port of the factory
      ICS ParticleScreensaver LED path (RE'd from the tungsten-ian67k factory image →
      deodexed Visualizer.odex; `docs/2026-06-19-particle-screensaver-RE.md`). The ring
      breathes a uniform `#0099CC × A` (#000F14 ↔ #007AA3, 10 s cosine), 5 s fade-in,
      locks dim after 300 s without audio, blanks after 600 s. Compositor layer priority 5;
      `nexusled auto` resumes it after a manual override. Verified live (breathing + colors).
- [x] **Plan 3b music-reactive (done 2026-06-20):** all 5 scenes (Waveform/WaveformSolid/
      Circles/PointMorph/StarField) + AudioCapture/FFT/BeatProcessor ported pixel-perfect from
      the decompiled `Visualizer.apk` and wired into `nexusqd` (audio tap = arecord on the
      snd-aloop loopback). Verified live: a track played into the loopback drives the ring.
      RE: `docs/2026-06-19-music-effects-RE.md`. Audio source for now is the loopback (local
      WAV or, once the WiFi bulk issue is fixed, librespot/Spotify Connect "Nexus Q").
- [ ] LED follow-ons: Spotify-driven (blocked by the WiFi bulk issue, see §WiFi /
      `docs/2026-06-20-session-handoff.md`); scene auto-cycling (FadeTransition not ported);
      ship the musl apk (currently a static binary deployed over USB).

### 10. SMP / second core  ✅ DONE 2026-06-22 (v1.2.0)
- [x] root cause was **not** a U-Boot CPU1-state problem but two mainline gaps:
      a missing `dsb_sev()` in `omap4_smp_prepare_cpus` (patch 0009) + a secondary
      cpuidle panic (boot `cpuidle.off=1`). Both Cortex-A9 online, `nproc=2`,
      `taint=0`; re-confirmed live 2026-06-28. Full writeup `docs/SMP-second-core.md`.
- [ ] follow-on: proper OMAP4 coupled cpuidle for the secondary (low priority).
