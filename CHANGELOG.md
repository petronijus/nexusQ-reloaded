# Changelog

All notable changes to Nexus Q Reloaded. Format follows
[Keep a Changelog](https://keepachangelog.com/). Versioning is tag-only
(milestone-based) — there is no version string in the source.

## [Unreleased]

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
