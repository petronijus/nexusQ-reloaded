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
and WiFi (BCM4330), HDMI desktop, TAS5713 amp, LED ring + rotary keys, and a full
host-built rootfs. Since the 2026-06-10 snapshot below, several "dead" verdicts were
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
- **OPEN: python3-3.14.5 SIGSEGVs on real ARMv7** — `python3 -S -c ''` crashes in
  `Py_Initialize` (a CPython source-level init bug, not a compiler/alignment issue;
  qemu gives a false pass), taking down `onboard` / `blueman` / `sleep-inhibitor` /
  `gdb`. Needs a source/upstream fix. See `CHANGELOG.md` and
  `docs/2026-06-28-session-findings.md`.

See `CHANGELOG.md` for the per-milestone record and `HANDOFF.md` for technical
notes and root-cause analysis.
See `PLAN.md` for the hardware status map and the prioritized roadmap
(TAS5713 amplifier first).

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
fastboot flash boot output/nexusq-boot-v1.5.0.img

# Flash rootfs to userdata partition. The -S 100M chunking is REQUIRED: the 2012
# U-Boot has a ~150 MB download buffer and fails SILENTLY on a larger blob.
fastboot -S 100M flash userdata output/nexusq-rootfs-v1.5.0-sparse.img

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
