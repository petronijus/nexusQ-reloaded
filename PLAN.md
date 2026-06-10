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
| WiFi (BCM4330) | ✅ works | original `bcmdhd.cal` nvram (repo `firmware/`), NM autoconnect |
| USB gadget network | ✅ works | RNDIS 172.16.42.1, SSH via nexus-diag.service |
| **TAS5713 amplifier** | 🟡 chip alive, no audio path | I2C driver bound (`3-001b`), reset/pdn GPIOs OK; missing: sound card node (McBSP2 I2S → TAS5713) + 12.288 MHz MCLK |
| Bluetooth (BCM4330) | 🟡 almost | `hci0` registers, wants firmware named `BCM.hcd` -- we have it (repo `firmware/bcm4330.hcd`) |
| TWL6040 codec | 🟡 deferred | driver never binds; `omap-abe-twl6040` card loops on -EPROBE_DEFER |
| NFC (PN544) | 🟡 detected | i2c device `2-0028` present, driver not loaded |
| TMP101 temp sensor | 🟡 detected | i2c device `1-0048`, needs `modprobe lm75` |
| LED ring (32× RGB) | 🔴 long-term | behind `steelhead-avr` MCU (i2c `1-0020`) -- no mainline driver exists, must be written |
| Ethernet (LAN9500A) | 🔴 dead hardware | enable pad clamped low; verified down to ULPI/PORTSC level -- do not revisit |
| SMP (2nd core) | 🔴 disabled | U-Boot leaves CPU1 undefined; needs custom holding-pen / CPU1 reset |

## Plan (by priority)

### 1. TAS5713 amplifier  ← TOP PRIORITY
The reason this device exists. Estimated: one afternoon.
- [ ] DTS: `simple-audio-card` node wiring McBSP2 (I2S, CPU DAI) → TAS5713 (codec DAI)
- [ ] DTS: MCLK 12.288 MHz -- `auxclk1` with /5 divider, muxed out on `fref_clk1_out`
      (exact recipe: `board-steelhead.c` lines 755-808 in AOSP android-omap-steelhead)
- [ ] verify `snd-soc-omap-mcbsp` module present and probing
- [ ] `speaker-test` / `aplay` over SSH, tune `tas571x` register defaults if needed
- Output: rear speaker terminals / banana jacks play audio

### 2. Bluetooth (~30 min)
- [ ] install `firmware/bcm4330.hcd` as `/lib/firmware/brcm/BCM.hcd` (name hci_bcm asks for)
- [ ] `bluetoothctl` scan test
- Bonus: BT keyboard/mouse solves the input problem for the GUI

### 3. HDMI audio smoke test (~10 min)
- [ ] `speaker-test -D hw:0` -- likely already functional

### 4. GUI: lightweight desktop (XFCE4)
Decision: device runs **primarily headless**; desktop is for occasional
debugging/ops on the HDMI port. Normal desktop (not mobile UI).
- [ ] `apk add postmarketos-ui-xfce4` (or plain xfce4 + lightdm) over SSH
- [ ] software rendering only (PowerVR SGX540 has no mainline driver) --
      single core means "retro PC" responsiveness, fine for the purpose
- [ ] input: BT keyboard (after #2) or USB OTG adapter (sacrifices gadget
      network -- acceptable once WiFi is the primary link)

### 5. TWL6040 codec (~2 h)
- [ ] find why the driver never binds (module? AUDPWRON gpio_127? 32k clock --
      possibly fixed already by patch 0004 / clk32kg)
- [ ] unblocks headset jack and the ABE routing ("sound" card stops deferring)

### 6. NFC + temp sensor (~15 min, completeness)
- [ ] `modprobe pn544_i2c`, `modprobe lm75`; add to /etc/modules if OK

### 7. Flaky boot (research)
- [ ] needs UART serial console (requires opening the device / soldering)
- [ ] until then workaround: power-cycle again
- Candidates: U-Boot DRAM init, kernel early race

### 8. LED ring (long-term, fun)
- [ ] write a kernel driver for the steelhead AVR i2c protocol
      (userspace reference exists in the AOSP steelhead tree)

### 9. SMP / second core (long-term, risky)
- [ ] custom CPU1 holding-pen or reset before online; doubles performance
      but risks boot regressions -- do last, with UART console available
