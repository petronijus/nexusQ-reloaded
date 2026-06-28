# Changelog

All notable changes to Nexus Q Reloaded. Format follows
[Keep a Changelog](https://keepachangelog.com/). Versioning is tag-only
(milestone-based) — there is no version string in the source.

## [Unreleased]

### Added
- **zram compressed swap.** Kernel `CONFIG_ZRAM=m` plus
  `deviceinfo_zram_swap_algo="lzo-rle"` brings up `postmarketos-zram-swap`. The
  mainline ZRAM module here only carries the lzo/lzo-rle backend, so the service's
  default **zstd** failed (`zramctl: failed to set algorithm: Invalid argument`)
  and swap never came up; lzo-rle is also the CPU-cheap pick for this Cortex-A9.
  Verified live: `/dev/zram0` lzo-rle, 1.4 G, active `[SWAP]`. (linux APKBUILD
  pkgrel 23→24.)
- **User namespaces** — `CONFIG_USER_NS=y`. Verified live:
  `max_user_namespaces=7716`, `unshare --user` works.
- **Dual-core SMP re-confirmed on the full-rootfs image** — `nproc=2`,
  `cpu/online=0-1`, both Cortex-A9 in `/proc/cpuinfo`. (SMP shipped in 1.2.0; this
  corrects any stale "CPU1 not brought up / SMP is groundwork" framing — it is done
  and working on the current image.)
- **CPU power/thermal health confirmed live** — scales 350/700/920/1200 MHz,
  reaches 1.2 GHz under load, VDD_MPU tracks the OPP exactly (1200→1380, 920→1317,
  350→1025 mV; abb_mpu FBB@Nitro 1375 mV). Idle ~70 °C, peak 95 °C under sustained
  2-core load (no throttle; 100 °C passive trip not reached).

### Changed
- **Build infra: local `python3` override aport + Phase 7d.** `docker-build.sh`
  now stages `pmos/python3/` → `main/python3` (Phase 6) and builds it
  (`pmbootstrap --no-cross build python3 --arch armv7`, Phase 7d) so a higher
  pkgrel (now r4) is meant to supersede Alpine's broken `python3-3.14.5-r2` in the
  rootfs (see Known issues — the supersede currently misfires). The override drops
  `--with-lto` + `--enable-optimizations` and the `!gettext-dev` makedepends token
  (pmbootstrap's apk wrapper rejects `!` entries); r4 also builds the core at `-O0`
  (an experiment, since shown not to matter).
- **`device-google-steelhead` no longer masks `sleep-inhibitor.service`; adds
  on-device debug tools.** The `/dev/null` mask was removed in favour of fixing the
  root cause (the python crash below); the image now also ships `gdb` (16.3) +
  `python3-dbg` to debug it on hardware (gdb itself is blocked until python is fixed
  — it links `libpython`). (device APKBUILD pkgrel 6→10.)

### Known issues / in progress
- **python3-3.14.5 SIGSEGVs deterministically on real ARMv7 — OPEN.** Even
  `python3 -S -c ''` returns rc 139 before any user bytecode, during
  `Py_Initialize`, crashing `onboard`, `blueman-applet`, `sleep-inhibitor.service`
  — and `gdb` (it links `libpython`). **Root cause (narrowed 2026-06-28):** a
  **CPython 3.14 source-level use-before-init / garbage-pointer read**, NOT a
  compiler issue. `_PyStaticType_InitBuiltin` reads a garbage type-index
  (`interp->types.builtins.num_initialized` = `0xf0012b00`) and dereferences
  `_PyRuntime.types.managed_static.types[idx]`; the wild address is unmapped on real
  hardware (SIGSEGV) but mapped under qemu (false pass). **DISPROVEN:** LTO/PGO (r3
  dropped them, still crashes); LDREXD misalignment (faulting addr is 8-byte aligned
  but UNMAPPED → SIGSEGV not SIGBUS); gnu2/TLSDESC (binary uses traditional TLS, zero
  `R_ARM_TLS_DESC` relocs); and optimization level itself — two `-O0` r4 builds with
  **byte-identical `.text`** (3,528,976 bytes, `cmp`-equal) differing only in ~139 KB
  of data behave oppositely on the same device. Fix must come from source/upstream
  (candidate 3.14.6), not a `-O`/`-f` flag — **under investigation, not done.** The
  qemu-user build gate (`python3 -S -c ''` rc 0) is a **FALSE PASS** — validate armv7
  python **on-device only**. See `docs/2026-06-28-session-findings.md`.
- **Build-pipeline: rootfs python ≠ the verified apk — OPEN.** `docker-build.sh`
  Phase 7d builds and exports one `python3-3.14.5-r4` apk (libpython md5
  `d43b6509`, runs), but the Phase 9 rootfs install pulls a **different** r4 build
  (md5 `30e88d28`, crashes). Verification only checked the apk DB **version**
  (`r4`), not the libpython md5, so it green-lit a rootfs whose python differs from
  the verified/exported apk. To fix: byte-verify the rootfs libpython against the
  exported apk, and reconcile why two r4 builds exist / why Phase 9 doesn't install
  the Phase 7d apk. (This is why the device currently runs the crashing python.)
- **On-board LAN9500A Ethernet still down** — the v1.4.0 cpufreq boot-timing
  regression is unchanged: `smsc95xx` registers but the device never enumerates, no
  `eth0`. Use WiFi / the USB gadget. (Fix tracked for 1.4.1.)

## [1.5.0] - 2026-06-27

### Added
- **NFC: the PN544 stack is built into the kernel** (NFC / HCI / PN544 / PN544_I2C
  `=y`) with stock-faithful tweaks — a 20 ms VEN settle and a level-triggered IRQ.
  The chip is proven alive (it ACKs i2c when powered); full NFC functionality is a
  follow-up.
- **Nexus Q diagnostics suite.** `nq-healthd` continuously watches the things that
  silently fail in the field (LED-ring / nexusqd hangs, VDD_MPU-vs-OPP drift,
  thermal throttle, kernel errors) and logs to `/var/log/nq-health`;
  `nq-diag-snapshot` captures a full one-shot device snapshot. Both ship enabled in
  the device image, with host-side helpers (`scripts/diag/`) and a `nexusq-diag`
  skill to collect and analyse it over the best available link.
- **nexusqd** now signals systemd readiness + watchdog via `sd_notify`
  (self-contained, no libsystemd dependency), so the LED-ring daemon runs as a
  proper `Type=notify` unit.
- **SSH out of the box** — the device image now ships `openssh` (server + client),
  so the Nexus Q is reachable over the network and the USB gadget without any
  manual install.
- **Composite USB gadget** — a deterministic RNDIS network (`172.16.42.1`) **plus**
  an ACM serial console, bound every boot from configfs. This is the reliable
  fallback link when the on-board ethernet is down, and replaces the old, fragile
  RNDIS→ACM swap that could leave the gadget unbound (no net and no console).

### Changed
- **DTS regulators now point at the real board rails** — DSS `vdda_video`→vcxio,
  tmp101 `vs`→v1v8, the Bluetooth `vbat`/`vddio`, and the TAS5713 amp `AVDD`/`DVDD`→a
  3V3 rail replace placeholder dummies. The spurious "supplying voltage" warnings
  drop from 10 to 5.
- **Default cpufreq governor → `conservative`** (vs `ondemand`). _(Correction
  2026-06-28: this entry's claim that idle "settles at 350 MHz" is not what the
  live device does — idle actually hovers ~920 MHz because `nexusqd`'s LED-ring
  polling keeps the CPU busy, dipping to 350 MHz only briefly. ~70 °C idle. See
  `docs/2026-06-28-session-findings.md`.)_
- **Ethernet (LAN9500A) is reliable again** — it came up on every boot tested in
  v1.5.0 (the v1.4.0 cpufreq-build bring-up intermittency was not reproducible),
  sustaining full ~100 Mbit/s line-rate throughput.
- **Device image UI:** added `nm-tray` (network applet), `blueman` (Bluetooth
  manager) and `breeze-icons` to the LXQt-Wayland session.

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
- **boot: the systemd rootfs no longer drops to emergency mode.** pmbootstrap
  generated an `/etc/fstab` with a `/boot` entry for a separate boot partition that
  this single-partition (root-only) flash layout does not have; systemd failed that
  mount → `emergency.target`, and `root` was locked so the console was unusable. The
  image build now strips the `/boot` fstab line and unlocks `root`.
- **the device image now actually ships systemd** (explicit
  `deviceinfo_systemd="always"`). Without the opt-in pmbootstrap defaulted to
  OpenRC, silently dropping the entire systemd device integration — nexusqd,
  nq-healthd and the USB-gadget units never ran.

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
