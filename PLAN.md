# Nexus Q Reloaded -- Hardware Status & Plan

Status as of **2026-06-10** (after the boot/WiFi debugging session, see
HANDOFF.md "Session 2026-06-10" for root causes and access paths).

## Hardware Map

| Subsystem | Status | Detail |
|-----------|--------|--------|
| Kernel + boot | ✅ works | mainline 6.12.12, GCC 13.3 only, ≤6.5 MB image; flaky boot ~1 in 3 (retry helps) |
| HDMI video | ✅ works | omapdrm, framebuffer console |
| HDMI audio | ✅ works | ALSA `card0 HDMI` registers; needs a quick `speaker-test` |
| eMMC + rootfs | ✅ works | postmarketOS (systemd variant) on userdata |
| WiFi (BCM4330) | ✅ works | original `bcmdhd.cal` nvram (staged via `scripts/setup-firmware.sh`, not in repo), NM autoconnect |
| USB gadget network | ✅ works | RNDIS 172.16.42.1, SSH via nexus-diag.service |
| **TAS5713 amplifier** | 🟡 chip alive, no audio path | I2C driver bound (`3-001b`), reset/pdn GPIOs OK; missing: sound card node (McBSP2 I2S → TAS5713) + 12.288 MHz MCLK |
| Bluetooth (BCM4330) | 🟡 almost | `hci0` registers, wants firmware named `BCM.hcd` -- we have it (staged via `scripts/setup-firmware.sh`, not in repo) |
| TWL6040 codec | 🟡 deferred | driver never binds; `omap-abe-twl6040` card loops on -EPROBE_DEFER |
| NFC (PN544) | 🟡 detected | i2c device `2-0028` present, driver not loaded |
| TMP101 temp sensor | 🟡 detected | i2c device `1-0048`, needs `modprobe lm75` |
| LED ring (32× RGB) | 🔴 long-term | behind `steelhead-avr` MCU (i2c `1-0020`) -- no mainline driver exists, must be written |
| Ethernet (LAN9500A) | 🔴 dead hardware | enable pad clamped low; verified down to ULPI/PORTSC level -- do not revisit |
| SMP (2nd core) | 🔴 disabled | U-Boot leaves CPU1 undefined; needs custom holding-pen / CPU1 reset |

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

### 4. GUI: lightweight desktop (XFCE4)
Decision: device runs **primarily headless**; desktop is for occasional
debugging/ops on the HDMI port. Normal desktop (not mobile UI).
- [x] `apk add postmarketos-ui-xfce4` -- done 2026-06-10, lightdm enabled,
      graphical.target default, screen blanking disabled (no input to wake it)
- [x] software rendering only (PowerVR SGX540 has no mainline driver) --
      single core means "retro PC" responsiveness, fine for the purpose
- [ ] input: BT keyboard (after #2) or USB OTG adapter (sacrifices gadget
      network -- acceptable once WiFi is the primary link)

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

### 9. LED ring  🟠 PROTOCOL CONFIRMED LIVE 2026-06-19
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
- [ ] deliverable: userspace control tool, and/or port AOSP
      `drivers/misc/steelhead_avr.c` to a mainline 6.12 driver (leds-class /
      input for the mute/volume keys; DT node already present)

### 10. SMP / second core (long-term, risky)
- [ ] custom CPU1 holding-pen or reset before online; doubles performance
      but risks boot regressions -- do last, with UART console available
