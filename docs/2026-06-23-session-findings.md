# Session findings — 2026-06-23 (device hardening: SMP, AVR keys, HDMI, WiFi, ethernet)

A long methodical session on `feat/device-hardening`, building on the dual-core
SMP breakthrough (2026-06-22). Working rule throughout: **every half-working
subsystem or boot warning is serious and must be root-caused, never marginalised**;
**verify every hypothesis against the reverse-engineered stock kernel before
building** (the discipline that solved SMP and HDMI and that caught a wrong
ethernet fix this session).

TL;DR of what landed, all verified on hardware unless noted:

| Subsystem | Result | Mechanism |
|---|---|---|
| **SMP 2nd core** | ✅ works (prior day, on main) | SEV in `omap4_smp_prepare_cpus` + `cpuidle.off=1` |
| **WiFi latency** | ✅ fixed | NM drop-in `wifi.powersave = 2` (175 ms→15 ms) |
| **HDMI EDID** | ✅ reads | DDC pads `PIN_INPUT` (dropped forced internal pull-up) |
| **HDMI desktop** | ✅ visible @1280×720 | hdmi4 bridge `.mode_valid` caps pclk 75 MHz |
| **AVR rotary volume / mute keys** | ✅ FIXED | drain KEY_FIFO at probe (patch 0011) |
| **Ethernet LAN9500A** | ⚠️ still intermittent | added stock 1 ms ULPI settle (necessary, not sufficient) |

---

## 1. HDMI — EDID read + a visible desktop

**Problem A (EDID):** the HDMI DDC (I²C) never returned EDID, so userspace had no
mode list. **Root cause:** the `hdmi_scl`/`hdmi_sda` pads (`0x09c`/`0x09e`) were
muxed `PIN_INPUT_PULLUP | MUX_MODE0` — the forced *internal* pull-up fought the
board's external DDC pull-ups and corrupted the open-drain I²C. **Fix:** changed
both to `PIN_INPUT | MUX_MODE0`. EDID now reads 128 bytes, modes enumerate.
(commit `b8ce574`.)

**Problem B (blank desktop at native res):** once EDID read, the wlroots
compositor (labwc) picked the monitor's **native 1440×900 @ 106.5 MHz pixel
clock**, which the OMAP4 HDMI PLL cannot generate cleanly → the panel detects a
signal but the desktop is blank. The boot fbcon (cmdline `video=…1280x720`) hid
this because `video=` only affects fbcon, **not** the compositor, which picks the
EDID-preferred mode independently.

**Fix:** add `.mode_valid` to the **hdmi4 bridge** (`hdmi4_bridge_funcs`) capping
the advertised pixel clock at 75 MHz (patch 0010). That drops 1440×900 /
1280×1024 from the mode list; wlroots then selects **1280×720 @ 60 Hz
(74.25 MHz)** and the LXQt-Wayland desktop renders. Validated on HW: compositor
CRTC `size=1280x720` (was 1440×900), 1440×900 gone from
`/sys/class/drm/card0-HDMI-A-1/modes`, desktop visible. (commits `794424e`,
`82ffc28`.) Native 1440×900 remains a follow-up (omapdrm HDMI PLL divider
investigation — task #13).

Units clarification recorded for the future: **60 Hz is the refresh** (kept); the
**MHz figure is the pixel clock**, forced by resolution×blanking×refresh; the
PHY's ~186 MHz is only a capability ceiling, not a target.

## 2. WiFi (BCM4330) — latency jitter

Power-save caused ping avg ~175 ms with spikes to 545–660 ms. Disabled via a
persistent NetworkManager drop-in (`wifi.powersave = 2`) shipped by the device
package → stable ~15 ms. (commit `234d408`.) **Note:** this only fixes
latency/responsiveness; sustained **bulk throughput** is a separate brcmfmac /
firmware limitation on this 2012 chip (no clm_blob, stuck 802.11g) — task #10.

## 3. CPU usage (standing monitoring request)

Dual-core idle desktop: load settles to ~1.x, **~70 % idle**, ~58–60 °C. The
~30 % busy baseline is the **software-rendered (pixman) wlroots compositor** —
expected on this GPU-less board, and comfortably absorbed by the second core
(on single-core this path saturated and starved the network).

## 4. AVR rotary volume + mute keys — THE notable fix

**Symptom:** the capacitive **rotary volume ring** and mute key produced no input
events. The user was certain it had worked before and that we had broken
something — correct instinct.

**Methodical isolation (no rebuilds, all live):**
1. Driver (patch 0005) is correct: threaded IRQ → reads `AVR_REG_KEY_FIFO` in a
   loop → decodes `KEY_MUTE`/`KEY_VOLUMEUP`/`KEY_VOLUMEDOWN`. DTS is correct:
   `avr@20` interrupt `gpio2` line 17 (gpio_49) `EDGE_FALLING`, `avr_pins` muxes
   gpio_49 = `PIN_INPUT_PULLUP | MUX_MODE3`.
2. **`/proc/interrupts` `steelhead-avr` count = 0** even after the user pressed +
   rotated → the AVR IRQ never fired.
3. **Decisive test:** read `KEY_FIFO` (reg 0x00) **directly over i²c**
   (`I2C_SLAVE_FORCE`, the driver owns 0x20) while rotating → it streamed key
   codes `0x81/0x01` (vol-down down/up), `0x82/0x02` (vol-up). **The AVR detects
   keys perfectly — it was never a firmware/HW problem.**

**Root cause:** the AVR holds its INT line **low** while `KEY_FIFO` is non-empty.
The driver requests the irq `IRQF_TRIGGER_FALLING`. If the FIFO already has stale
entries at probe, INT is **already low**, so **no falling edge ever arrives** →
`avr_irq()` never runs → the FIFO is never drained → INT stays low forever. Whether
this happens depends on the FIFO state at probe — exactly why the keys "worked
sometimes" (a boot that probed with an empty FIFO) and were dead otherwise. It was
a **latent driver bug**, not a regression we introduced and not firmware.

**Proof + fix:** draining the FIFO live (read to empty over i²c) immediately made
the IRQ start firing (**0 → 118**) and every mute/volume/rotation event appear.
Patch **0011** drains `KEY_FIFO` in probe after `request_irq`, releasing INT and
arming the edge for the first real press. Flashed via fastboot, cold-boot
validated: IRQ fires, `KEY_VOLUMEDOWN`/`UP` stream as you rotate. (commit
`136c266`.)

**Bonus:** this also brought the **LED ring to life on rotation** — `nexusqd`
already maps the volume keys to the ring; it was only starved of input events.
The signature Nexus Q control (turn the dome → ring responds) works again.

**Open follow-ups (userspace, task #14):** map `KEY_VOLUMEUP/DOWN` to actual
audio volume, and fix the audio stack (pulseaudio **and** wireplumber both
running, `wpctl` shows 0 sinks, pulseaudio `module-alsa-card` load failed).

### Two non-issues correctly ruled out (not marginalised — checked)
- **"Screen turns off/on occasionally"** → it was the multiple flash+reboot
  cycles during HDMI iteration. Device stable afterwards: connector
  `connected/On` steady, no flap, watchdog **not** armed (`RuntimeWatchdogUSec=0`),
  no reset loop (uptime continuous).
- **"LEDs stopped responding"** → audio-reactive ring is dark when nothing is
  playing (PCM `closed`); a direct sysfs write lit the ring (driver/AVR path OK).
  The real gap was the key-input path above.

## 5. Ethernet (LAN9500A) — investigation, a partial fix, and what's left

Still **intermittent**: on unlucky boots `PORTSC` CCS stays 0 (line status 00 →
the chip does not drive D+ → no USB device), eth0 absent; only a full cold
power-cycle reliably recovers, an unbind/bind does not.

**What the stock-parity-auditor found (evidence in `reverse-eng/vmlinux.bin`):**
- Stock board reset is **identical** to ours: `clk(auxclk3 38.4 MHz) →
  udelay(100) → NENABLE low → udelay(2) → NRESET high`. No power-cycle, no
  post-NRESET delay, no connect poll/retry. → **the earlier board-level
  timing/power-cycle hypothesis was REFUTED** (and the half-built power-cycle fix
  was discarded before flashing — the user's "does stock confirm this?" caught it).
- **One real divergence:** stock `omap_ehci_soft_phy_reset` (VA `0xc0329ba4`)
  does **`udelay(1000)` = 1 ms BEFORE** the INSNREG05 ULPI Function-Control reset;
  our patch 0006 struck it immediately. Added that settle (commit `3b06c41`,
  verified: diff vs old 0006 result = *only* the settle).
- **But it is not sufficient:** with the settle, a cold boot still showed CCS=0 /
  no enumeration. So the remaining intermittency has another cause.

**Other parity items (all MATCH):** INSNREG01 = `0x00800080`; ULPI soft reset
before `usb_add_hcd`; OHCI held suspended; reset GPIO polarities; refclk 38.4 MHz.
The auditor flagged **UHH_HOSTCONFIG** (patch 0008, vendor `0x11c`) as the
*dominant determinism factor* but could only confirm it from the patch-0008 live
measurement, **not** isolate the write statically (it lives in
`usbhs_runtime_resume`) — that is the prime open suspect.

See `2026-06-23-ethernet-continuation.md` for the exact next diagnostic.

---

## Build / process notes
- All kernel changes went in as GNU-`patch`-clean patches (abuild uses
  `patch -p1`), each verified to apply on pristine v6.12.12 and (for regens of
  0006) proven to differ from the original by *only* the intended hunk.
- Reliable flash = `fastboot flash boot` + cold power-cycle. `fastboot reboot` is
  a warm reboot (LAN9500A rail survives) and is **not** a fair ethernet test.
- WiFi bulk is too slow for a 5 MB `scp` (it stalls) — **always sha-verify the
  on-device image before `dd`**; one flash this session silently `dd`'d a 0-byte
  file (empty-file sha `e3b0c442…`) because the scp timed out. Use fastboot or the
  USB gadget for the boot image.
