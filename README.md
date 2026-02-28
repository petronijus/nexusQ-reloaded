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

**Kernel boots!** (as of 2026-02-27) -- HDMI framebuffer console works, eMMC detected, all partitions visible. Currently running single-core (SMP disabled due to U-Boot bug). Full postmarketOS userspace boot is next.

See `HANDOFF.md` for detailed technical notes and root cause analysis.

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
# Flash kernel to boot partition (RECOMMENDED -- reliable boot path):
fastboot flash boot output/boot-atag-embedded.img

# Flash rootfs to userdata partition:
fastboot flash userdata output/google-steelhead-sparse.img

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
5. `fastboot boot boot.img` -- temporary boot on real hardware
6. `fastboot flash userdata google-steelhead.img` -- permanent flash rootfs
