# Changelog

All notable changes to Nexus Q Reloaded. Format follows
[Keep a Changelog](https://keepachangelog.com/). Versioning is tag-only
(milestone-based) — there is no version string in the source.

## [Unreleased]

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
