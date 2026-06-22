# Changelog

All notable changes to Nexus Q Reloaded. Format follows
[Keep a Changelog](https://keepachangelog.com/). Versioning is tag-only
(milestone-based) — there is no version string in the source.

## [Unreleased]

### Added
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
  chroot pkgdir and repack a partition-sized boot image — the final `abuild`
  `create_apks` step fails on a chroot perms quirk, but the compiled artifacts
  in pkgdir are complete).

### Changed
- DTS: delete the upstream `cpu@1` node to match the single-core build
  (`CONFIG_SMP=n`). Clears the early-DT `nodes greater than max cores 1` warning
  and the resulting kernel taint (was 512, now 0). Re-add together with the
  deferred OMAP4460 SMP / CPU1 bring-up. Patch 0003 regenerated accordingly.
- Device root password is now read at runtime from a gitignored `.nexus_pw`
  (no hard-coded credential in the SSH/flash helpers).

### Known limitations
- **Ethernet (LAN9500A) still non-functional** on this unit. On the #4 kernel
  the EHCI port is powered and the ULPI PHY (SMSC USB3320, VID 0x4:0x24)
  responds, but `PORTSC` CCS never asserts — the LAN9500A never enumerates
  (no `eth0`, EHCI bus has only the root hub). Matches the earlier
  register/pad-level diagnosis (`gpio_1`/NENABLE clamped low). Investigation
  ongoing.

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
