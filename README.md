# Nexus Q Reloaded -- postmarketOS Port

Port of the Google Nexus Q (codename **steelhead**) to postmarketOS using a
mainline Linux 6.12 LTS kernel.

## Hardware

| Component | Chip | Driver | Bus |
|-----------|------|--------|-----|
| SoC | TI OMAP4460 (Cortex-A9 x2) | omap4 | - |
| Audio Codec | TI TWL6040 | snd-soc-omap-abe-twl6040 | McPDM (I2C1) |
| Audio Amp | TI TAS5713 25W Class-D | snd-soc-tas571x | McBSP2 (I2C4) |
| WiFi | Broadcom BCM4330 | brcmfmac | SDIO (MMC5) |
| Bluetooth | Broadcom BCM4330 | hci_bcm | UART2 |
| NFC | NXP PN544 | pn544_i2c | I2C3 |
| Ethernet | SMSC LAN9500A | smsc95xx | USB EHCI |
| HDMI | OMAP4 DSS + TPD12S015A | omapdrm | DSS |
| LEDs | AVR MCU + LP5523 | leds-lp5523 | I2C2 |
| PMIC | TI TWL6030 | twl-core | I2C1 |

## Status

**postmarketOS (systemd) boots; the device is daily-usable.** SSH over USB gadget
and WiFi (BCM4330), HDMI desktop, LED ring + rotary keys, and a full host-built
rootfs. Since the 2026-06-10 snapshot below, several "dead" verdicts were
overturned:

- **Dual-core SMP works** (since v1.2.0; re-confirmed `nproc=2` on 2026-06-28) —
  the old "single-core, SMP disabled" status is obsolete.
- **CPU frequency scaling 350→1200 MHz** (v1.4.0), governor `conservative`.
- **On-board Ethernet (LAN9500A) is NOT dead hardware** — fixed in v1.1.0/v1.3.0;
  currently **down again** on cpufreq builds (a v1.4.0 boot-timing regression, fix
  tracked for 1.4.1), not a hardware fault.
- The shipping kernel is built with **GCC 15.2** (Alpine, via pmbootstrap) and
  boots — the historical "GCC 13.3.Rel1 only" constraint applied to an early
  hand-cross-compiled build, not this path.
- **armv7 python3 works on the device (v1.6.0, flash-verified).** The long-standing
  crash (`python3 -S -c ''` → rc 139 in `Py_Initialize`, taking down `onboard` /
  `blueman` / `sleep-inhibitor` / `gdb`) was a **flash bug, not a build bug**:
  `raw2simg.py` emitted all-zero blocks as `DONT_CARE`, which the Nexus Q's non-erasing
  U-Boot left as **stale eMMC data**, re-corrupting libpython's should-be-zero regions
  on-device — fixed by writing a **byte-exact all-RAW sparse**. v1.6.0 ships a plain
  default-linker (bfd) `python3` rebuild that supersedes Alpine's broken `-r2`, with a
  build-integrity gate (`scripts/verify-libpython-clean.py`) + ship gate kept as a
  safety net. (A qemu-user build-corruption theory and a gold-linker workaround were
  tried and **dropped as unnecessary** — 6/6 default-linker builds were gate-clean.)
  Verified on a fresh flash (no live-patch): `libpython3.14.so.1.0` md5
  `79a0d4ace1358bb2d94c8a4d72479da9`, `python3` rc 0. See `CHANGELOG.md` and
  `docs/2026-06-28-session-findings.md`.
- **Spotify Connect (librespot) ships in the build** (`librespot 0.8.0`, libmdns
  zeroconf; advertises "Nexus Q", discovery + auth + streaming verified over 5 GHz
  WiFi). Baked into `device-google-steelhead` (pkgrel 11) as of **v1.6.1** — the
  systemd unit, the `nexusq` ALSA PCM (`asound.conf`) and the nftables drop-in now
  survive a flash.
- **TAS5713 25 W amp works** (correct pitch/speed). The v1.6.0 speaker path played
  exactly 2× too fast (McBSP2 left `CLKGDV=0` + a 256-BCLK frame → FSYNC at 2× the
  rate); **fixed in v1.6.1 by kernel patch 0022** (derive `CLKGDV` from the real
  fclk + a minimal I2S frame). Verified on hardware: 60 s of audio now plays in
  **60.00 s** (ratio 1.000×; was ~30 s). The old "B7 TAS5713 MCLK 16 vs 12.288"
  concern was a red herring. See
  `docs/2026-06-29-spotify-connect-and-tas5713-2x-speed.md`.

See `CHANGELOG.md` for the per-milestone record and `HANDOFF.md` for technical
notes and root-cause analysis.
See `PLAN.md` for the hardware status map and the prioritized roadmap
(TAS5713 amplifier + Spotify Connect now done; TOSLINK/SPDIF + the ethernet 1.4.1
regression next).

## Quick Start

```bash
# Build inside Docker
./docker-build.sh

# Or: build boot image manually (requires arm-none-eabi-gcc cross compiler)
# See docker-build.sh for the full build procedure
```

## Project Structure

```
kernel/
  dts/omap4-steelhead.dts          Device tree source
  configs/steelhead_defconfig      Kernel configuration
  patches/0001-*.patch             TAS5713 driver support
  patches/0002-*.patch             TAS5713 DT binding
  patches/0003-*.patch             Steelhead DTS in kernel tree
pmos/
  device-google-steelhead/         postmarketOS device package
  linux-google-steelhead/          postmarketOS kernel package
  firmware-google-steelhead/       BCM4330 firmware package
build-and-flash.sh                 Automated build and flash script
```

## Flashing

The Nexus Q has hardware-triggered fastboot mode (cover mute LED during
power-on). The device is **unbrickable** as long as the `bootloader`
partition is never overwritten.

### Partition Layout

| Partition | Size | Usage |
|-----------|------|-------|
| boot | 8 MB | Kernel + embedded initramfs + DTB (6.7 MB fits) |
| system | 1 GB | Not used (too small for rootfs) |
| userdata | 13 GB | **Rootfs target** |

### Flash Commands

```bash
# Flash kernel to boot partition (ramdisk-less, must fit the 8 MB boot partition):
fastboot flash boot output/nexusq-boot-v1.6.1.img

# Flash rootfs to userdata partition. The -S 100M chunking is REQUIRED: the 2012
# U-Boot has a ~150 MB download buffer and fails SILENTLY on a larger blob.
# The sparse is all-RAW (byte-exact, since v1.6.0) -- U-Boot never erases userdata, so
# the image must write every block (zeros included), not skip them as DONT_CARE.
fastboot -S 100M flash userdata output/nexusq-rootfs-v1.6.1-sparse.img

# Then power-cycle WITHOUT holding mute sensor to boot normally.
```

**IMPORTANT:**
- Always do a **full power cycle** (unplug power) between flash operations
- **Do NOT use `fastboot boot`** (RAM boot) -- it is unreliable on this U-Boot
- NEVER flash the `bootloader` partition

## Testing Pipeline

1. `make dtbs_check` -- validate device tree
2. `pmbootstrap kconfig check` -- validate kernel config
3. `pmbootstrap build` -- cross-compile
4. `pmbootstrap qemu` -- QEMU boot test (vexpress-a9)
5. `fastboot flash boot nexusq-boot-v*.img` -- flash kernel (ramdisk-less, <=8 MB)
6. `fastboot -S 100M flash userdata nexusq-rootfs-v*-sparse.img` -- flash rootfs

## Releases

Versioning is tag-only (milestone-based). Images are built locally (the kernel
and rootfs aren't built in GitHub CI) and attached to the GitHub release:

- `nexusq-boot-vX.Y.Z.img` -- kernel + initramfs boot image
- `nexusq-rootfs-vX.Y.Z-sparse.img` -- postmarketOS rootfs (Android sparse)

End-user flashing is in [INSTALL.md](INSTALL.md); build steps in `HANDOFF.md`;
version history in [CHANGELOG.md](CHANGELOG.md).

## License

[GPL-2.0](LICENSE) -- this repository carries Linux kernel patches, a device
tree and a defconfig, which are derivative works of the Linux kernel (GPLv2).
