# Changelog

All notable changes to Nexus Q Reloaded. Format follows
[Keep a Changelog](https://keepachangelog.com/). Versioning is tag-only
(milestone-based) — there is no version string in the source.

## [1.5.0] - 2026-06-26

### Added
- **NFC: the PN544 stack is built into the kernel** (NFC / HCI / PN544 / PN544_I2C
  `=y`) with stock-faithful tweaks — a 20 ms VEN settle and a level-triggered IRQ.
  The chip is proven alive (it ACKs i2c when powered); full NFC functionality is a
  follow-up.

### Changed
- **DTS regulators now point at the real board rails** — DSS `vdda_video`→vcxio,
  tmp101 `vs`→v1v8, the Bluetooth `vbat`/`vddio`, and the TAS5713 amp `AVDD`/`DVDD`→a
  3V3 rail replace placeholder dummies. The spurious "supplying voltage" warnings
  drop from 10 to 5.
- **Default cpufreq governor → `conservative`** — idle now settles at 350 MHz (vs
  `ondemand`'s 920 MHz), ~66 °C, instead of holding a high clock.
- **Ethernet (LAN9500A) is reliable again** — it came up on every boot tested in
  v1.5.0 (the v1.4.0 cpufreq-build bring-up intermittency was not reproducible),
  sustaining full ~100 Mbit/s line-rate throughput.

### Fixed
- **WiFi: the BCM4330 radio no longer sleeps when idle.** brcmfmac forced the
  firmware `mpc` (Minimum Power Consumption) iovar on, powering the radio down
  between packets — ~30 % packet loss and 270–530 ms latency. A new brcmfmac `mpc`
  module parameter plus a device modprobe.d conf (`mpc=0`) keep it awake (the
  Nexus Q is mains-powered): loss 30 %→0 %, latency 270–530 ms→4–59 ms. Stock-proven
  to be a driver gap — the same firmware + nvram works under the vendor `bcmdhd`.
- **WiFi: disabled brcmfmac P2P** on the BCM4330 — the firmware advertises P2P but
  cannot create the P2P_DEVICE interface, which spammed the log with failed p2p-dev
  creations and orphaned "event handler failed (72)" errors.
- **boot: silenced the benign ti-sysc active-timer `-EBUSY`** probe error for
  GPTIMER1 (an always-on system clockevent owned by the timer core).

### Known issues
- **WiFi 2.4 GHz bulk throughput** is limited by Bluetooth coexistence (the BCM4330
  combo shares one 2.4 GHz antenna) on a g-only AP — **use 5 GHz for full speed**
  (~26–30 Mbit/s, 802.11n). See
  `docs/2026-06-26-wifi-mpc-fix-and-bulk-bufferbloat.md`.

## [1.4.0] - 2026-06-26

### Added
- **MPU CPU frequency scaling — on-demand up to 1.2 GHz (3.4× the old floor).** 🚀
  The OMAP4460 was pinned at its 350 MHz boot OPP; it now scales across
  350 / 700 / 920 / 1200 MHz under the `ondemand` governor. Built up in small,
  hardware-validated stages, each cross-checked against this unit's
  reverse-engineered stock kernel:
  - VDD_MPU is handed from the TWL6030 VCORE1 SMPS to the external **TPS62361**
    regulator over the PRM Voltage-Controller SR-i2c — the same hand-over stock does.
  - A thin "VC-bridge" `cpu-supply` regulator lets `cpufreq-dt` scale the rail
    through the OMAP voltage layer (VP force-update), at the stock-measured nominal
    voltages (1025 / 1203 / 1317 / 1380 mV).
  - At the 1.2 GHz OPP, **Forward Body Bias** is engaged on VDD_MPU via the on-chip
    ABB LDO — required for stable 1.2 GHz operation.
  - **Thermal throttling**: at the 100 °C trip the CPU cooling drops the frequency
    and ramps it back as it cools, so sustained full load stays safe.
- **USB serial debug console.** The USB gadget is now an ACM serial console
  (`/dev/ttyACM0` on the host, with a `steelhead login:` prompt) that survives
  reboots and leaves fastboot untouched.

### Changed
- The USB gadget no longer exposes a host-side network interface — it was swapped
  from the RNDIS network gadget to the serial console above. Use the on-board
  ethernet / WiFi for networking.

### Known issues
- **On-board LAN9500A USB-Ethernet is down — a regression from 1.3.0.** 🌐 The
  Ethernet that 1.3.0 fixed no longer enumerates on these cpufreq builds: the
  LAN9500A fails to connect (the EHCI port's `PORTSC` connect-status stays 0). It
  is a boot-timing side-effect of the voltage/cpufreq changes, which tipped the
  formerly-marginal connect timing into consistent failure. WiFi works in the
  meantime; a fix (a settle delay in the ethernet bring-up, or reordering the
  voltage init) is tracked for 1.4.1.

## [1.3.0] - 2026-06-24

### Fixed
- **On-board LAN9500A USB-Ethernet now works on mainline 6.12** 🌐 — the
  long-standing "intermittent / never enumerates" problem is **resolved**. The
  chip enumerates on every boot (`0424:9e00` → `smsc95xx … eth0`), the link comes
  up at 100 Mbps/Full and passes traffic cleanly. Verified on hardware: 5/5
  reboots all enumerate, 600 sustained pings at **0 % loss**, 410 MB moved with
  **zero** rx/tx/CRC/drop errors. Root cause was two combined bugs, both found by
  stock-parity auditing against the factory Android kernel:
  - **Patch 0012** (`mfd: omap-usb-host`): mainline only enables the per-port
    UTMI functional clock (`usb_host_hs_utmi_pN_clk` — the L3INIT CLKCTRL
    OPTFCLKEN gate) for **TLL/HSIC** port modes. An external-PHY (`ehci-phy`)
    port falls through to `default:` and never gets its clock, so the port-1 UTMI
    link block ran unclocked (`clk_summary` showed it disabled) and the
    controller never latched the downstream connect (PORTSC CCS stuck 0). Added
    `OMAP_EHCI_PORT_MODE_PHY` to the clock enable/disable paths.
  - **Patch 0006** (`usb: ehci-omap`): stock's `omap_ehci_soft_phy_reset` (the
    UHH softreset / gpio pulse / clock re-park / ULPI register burst) is **not**
    the EHCI `.reset` hook — it is a runtime `ehci_hub_control` *recovery*
    handler that only fires when a port reset/resume times out, **after** a
    device has connected. We were running that whole sequence at bring-up, which
    blocked the very first connect. The `.reset` hook is now a plain
    `ehci_setup()` bring-up (the USB3320's reset defaults already put it in host
    mode); the ULPI/UHH recovery helpers are retained for a future hub_control
    hook.

### Changed
- All kernel patch headers now carry `petronijus@bastla.com` (was a work email /
  placeholder).

## [1.2.0] - 2026-06-23

### Added
- **Second CPU core (dual-core SMP) now works** 🧠 — the OMAP4460 ES1.1 **HS**
  ("steelhead") had always silently dead-locked with `CONFIG_SMP=y`. Two changes:
  - Kernel patch `0009-ARM-OMAP4-steelhead-SEV-in-prepare-wake-cpu1` — stock
    issues a `dsb_sev()` at the end of `omap4_smp_prepare_cpus` after writing
    `AUX_CORE_BOOT_1`; mainline omitted it, so CPU1 (parked in the ROM WFE
    holding pen) never re-read the boot address. Adding the SEV releases it.
  - `cpuidle.off=1` on the cmdline (stock = `cpuidle44xx.disallow_smp_idle`) —
    OMAP4 secondary deep-idle faults → "Attempted to kill the idle task" panic
    on `swapper/1`. Disabling cpuidle keeps SMP stable.
  - `CONFIG_SMP=y`, `CONFIG_NR_CPUS=2`, `CONFIG_HOTPLUG_CPU=y`, `cpu@1` restored
    in the DTS. **Verified on hardware**: both cores online (`nproc` = 2), load
    spreads across CPUs, idle desktop ~70 % idle (the second core absorbs the
    software-rendered compositor that saturated single-core).
  - Kernel switched to **LZMA** compression to keep the now-larger SMP image
    under the ~6.6 MB U-Boot boot-partition ceiling.
- **HDMI EDID now reads + the desktop is visible.** DDC pads
  (`hdmi_scl 0x09c` / `hdmi_sda 0x09e`) changed from `PIN_INPUT_PULLUP` to
  `PIN_INPUT` — the forced internal pull-up fought the board's external DDC
  pull-ups and corrupted the I²C, so EDID never read. Then patch
  `0010-drm-omapdrm-hdmi4-cap-pixel-clock-steelhead` adds `.mode_valid` to the
  hdmi4 bridge capping the pixel clock at 75 MHz: the wlroots compositor was
  selecting the monitor's native 1440×900 @ 106.5 MHz (which the OMAP4 HDMI PLL
  can't generate → blank), and `video=` only constrains fbcon, not the
  compositor. With the cap, wlroots picks **1280×720 @ 60 Hz** and the
  LXQt-Wayland desktop renders. **Verified on hardware.** Native 1440×900 is a
  follow-up (omapdrm PLL).
- **Rotary volume + mute keys work again** 🎛️ — patch
  `0011-leds-steelhead-avr-drain-key-fifo-at-probe`. The `steelhead-avr` keys
  were dead: the AVR holds INT low while its KEY_FIFO is non-empty, the driver
  requests an `IRQF_TRIGGER_FALLING` irq, so a FIFO with stale entries at probe
  left INT already-low → no falling edge → the irq never fired → the FIFO was
  never drained (a latent driver bug; "worked sometimes" = a boot that probed
  with an empty FIFO). Draining the FIFO in probe releases INT and arms the edge.
  **Verified on hardware**: the IRQ fires (0 → 118), `KEY_VOLUMEUP/DOWN` stream as
  you rotate the dome, and the LED ring (driven by `nexusqd`) responds again. The
  AVR was detecting keys all along — confirmed by reading its KEY_FIFO directly
  over i²c. (Mapping the keys to actual audio volume + fixing the
  pulseaudio/wireplumber audio stack is a remaining userspace follow-up.)

### Changed
- **WiFi (BCM4330) power-save disabled by default** — NetworkManager drop-in
  `wifi.powersave = 2` shipped by the device package. Fixes severe latency jitter
  (ping avg ~175 ms, spikes 545–660 ms → stable ~15 ms). Bulk throughput is a
  separate firmware limitation, untouched.

### Added (ethernet, partial)
- Kernel patch `0006` gains stock's **1 ms `udelay(1000)` ULPI pre-reset settle**
  in `omap_ehci_soft_phy_reset` (stock VA `0xc0329ba4`). Real stock parity, but
  not sufficient to make LAN9500A enumeration deterministic — see Known issues.

### Tooling / docs
- `scripts/build-kernel-boot.sh` — fast docker kernel-only rebuild + boot.img
  repack reusing the warm `nexusq-workdir` volume (skips the rootfs).
- Comprehensive writeups: `docs/SMP-second-core.md`,
  `docs/2026-06-22-smp-session-findings.md`, `docs/ethernet-bringup-procedure.md`,
  `docs/2026-06-23-session-findings.md`,
  `docs/2026-06-23-ethernet-continuation.md`.
- `reverse-eng/` ground-truth: stock 3.0.8 SMP `vmlinux.bin` extracted for the
  stock-parity-auditor (gitignored; recreation in `reverse-eng/README.md`).

## [1.1.0] - 2026-06-22

### Added
- **Ethernet (LAN9500A) now works** 🎉 — the soldered on-board SMSC LAN9500A
  USB-ethernet enumerates and carries traffic. Two kernel changes did it:
  - `0006-usb-ehci-omap-steelhead-keep-ethernet-port-alive-ulp` — steelhead
    host-init in `ehci-omap`: INSNREG01 burst thresholds, a ULPI Function-Control
    soft reset of the USB3320 PHY *before* `usb_add_hcd()`, and
    `usb_disable_autosuspend()` on the root hub so the idle port is not
    clock-gated away.
  - `0008-mfd-omap-usb-host-steelhead-UHH-HOSTCONFIG-connect` — program
    `UHH_HOSTCONFIG` to the vendor's `0x11c` (set `P1_CONNECT_STATUS`, leave
    `APP_START_CLK` clear) so the EHCI latches the port-1 connect. Measured
    mainline default was `0x1c`; the stock Android 3.0 kernel uses `0x11c`.

  The long-standing "ethernet is dead hardware" verdict was **wrong** — the stock
  kernel enumerates the same chip on this unit, proving the HW is fine and the bug
  was ours. **Verified on hardware** (#8 kernel): `eth0` (`0424:9e00` → `smsc95xx`)
  links at 100 Mbps/Full and passes bidirectional traffic — 0% packet loss over a
  direct cable, zero rx/tx/CRC/frame errors after ~660 MB moved. Throughput
  ~30–60 Mbps (USB2 / single-core OMAP4 bound, not a link fault). Reach the device
  over ethernet with the persistent `eth-direct` NetworkManager profile
  (static `10.42.0.2/24`).
- Kernel patch `0007-clk-ti-composite-implement-divider-round-set-rate` — OMAP4
  `ti,composite-clock` nodes (gate + divider) had stub `round_rate`/`set_rate`
  returning `-EINVAL`, so any `clk_set_rate()` on them failed. Delegated both to
  `ti_clk_divider_ops` (as `recalc_rate` already did). Fixes the TAS5713
  amplifier MCLK: `dpll_per_m3x2_ck` now sets to 61.44 MHz →
  `auxclk1_ck` = 12.288 MHz (256 × 48 kHz). **Verified on hardware** (#4 kernel):
  clock rates correct, ALSA card 0 `NexusQ-Speaker` registers cleanly, no
  `couldn't set dpll_per_m3x2_ck` error.
- `CONFIG_SRAM=y` in the defconfig (OMAP4 on-chip SRAM driver).
- Tooling: `scripts/regen-dts-patch.sh` (regenerate patch 0003 from the working
  DTS) and `scripts/extract-and-repack.sh` (pull kernel+DTB from the build
  chroot pkgdir and repack a partition-sized boot image — a fast path that skips
  the rootfs build).
- **Build fix:** the recurring `abuild create_apks` "Permission denied" on
  `/home/pmos/packages//pmos/armv7/...apk` is fixed. On a reused `nexusq-workdir`
  volume `$WORK/packages` was owned by the container `pmos` (uid 1000) while
  abuild inside the chroot runs as uid 12345, so it could not write its `.apk`.
  `docker-build.sh` Phase 7a now `chown`s `$WORK/packages` to 12345 before the
  build, so `linux-google-steelhead-*.apk` is created cleanly and `pmbootstrap
  install` runs. `extract-and-repack.sh` is kept as a fast path, no longer a
  required workaround.
- **Build fix:** clearing the armv7 ccache out-of-band leaves its directory owned
  by uid 1000, so abuild inside the chroot (uid 12345) then hits `ccache: error:
  Permission denied` at `make olddefconfig`. `docker-build.sh` Phase 7a now also
  `chown`s `$WORK/cache_ccache_armv7` to 12345 (alongside `$WORK/packages`).

### Changed
- DTS: delete the upstream `cpu@1` node to match the single-core build
  (`CONFIG_SMP=n`). Clears the early-DT `nodes greater than max cores 1` warning
  and the resulting kernel taint (was 512, now 0). Re-add together with the
  deferred OMAP4460 SMP / CPU1 bring-up. Patch 0003 regenerated accordingly.
- Device root password is now read at runtime from a gitignored `.nexus_pw`
  (no hard-coded credential in the SSH/flash helpers).

### Known limitations
- Rootfs image build (`pmbootstrap install`, Phase 9) currently fails on a
  `device-google-steelhead` post-install step (exit 127); the kernel `.apk` and
  boot image build fine, so kernel/DTB iteration is unaffected. Reflash boot only.

## [0.1.0] - 2026-06-10

First public milestone — **postmarketOS userspace boots on the Nexus Q**.

### Working
- Mainline Linux 6.12 LTS boots on TI OMAP4460 (`steelhead`); postmarketOS
  (systemd) comes up from the userdata partition.
- SSH access over USB gadget and over WiFi (BCM4330, original calibration).
- Audio amplifier path (TAS5713) and BT auto-firmware load; sensors.
- HDMI framebuffer console, eMMC + all partitions detected.
- Device tree, defconfig and kernel patches under `kernel/`; pmbootstrap build
  pipeline (`docker-build.sh`) and flashing helpers (`build-and-flash.sh`).
- Release images: `nexusq-boot-v0.1.0.img` + `nexusq-rootfs-v0.1.0-sparse.img`
  (see `INSTALL.md`).

### Known limitations
- Single-core only (SMP disabled due to a U-Boot bug).
- Ethernet is dead hardware on this unit.
- TAS5713 amplifier bring-up is the next roadmap item (`PLAN.md`).

See `HANDOFF.md` for technical notes and root-cause analysis.
