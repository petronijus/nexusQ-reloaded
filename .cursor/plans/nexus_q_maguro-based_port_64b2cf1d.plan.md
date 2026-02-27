---
name: Nexus Q Maguro-Based Port
overview: Port the Google Nexus Q (steelhead) to postmarketOS using a mainline Linux 6.12 LTS kernel with custom device tree and driver patches, modeled on the Galaxy Nexus (samsung-maguro) port for boot parameters and firmware packaging.
todos:
  - id: create-device-tree
    content: "Create omap4-steelhead.dts: full device tree for OMAP4460 with all peripherals. Verify McBSP2 pad offsets against TRM. Use two-string compatible for WiFi/BT (brcm,bcm4330-fmac + brcm,bcm4329-fmac fallback)."
    status: pending
  - id: create-tas5713-patch
    content: "Create 0001-ASoC-tas571x-add-TAS5713-support.patch: add TAS5713 chip struct, register defaults, and regmap config to sound/soc/codecs/tas571x.c"
    status: pending
  - id: create-dt-bindings-patch
    content: "Create 0002-dt-bindings-add-ti-tas5713.patch: add ti,tas5713 compatible to Documentation/devicetree/bindings/sound/ti,tas571x.yaml"
    status: pending
  - id: create-dts-kernel-patch
    content: "Create 0003-ARM-dts-omap4-add-steelhead.patch: add omap4-steelhead.dts to arch/arm/boot/dts/ti/omap/ and its Makefile"
    status: pending
  - id: create-kernel-config
    content: "Create steelhead defconfig: start from omap2plus_defconfig, add BCM4330 WiFi/BT, TAS5713, LP5523, PN544, SMSC95XX, postmarketOS requirements. Validate with pmbootstrap kconfig check."
    status: pending
  - id: create-kernel-apkbuild
    content: "Create linux-google-steelhead APKBUILD: mainline 6.12 LTS, reference config and 3 patches, use downstreamkernel_package helper"
    status: pending
  - id: create-device-apkbuild
    content: Create device-google-steelhead APKBUILD + deviceinfo + modules-initfs. Use mkbootimg, console=ttyS2 (not ttyO2), fastboot offsets from maguro.
    status: pending
  - id: create-firmware-apkbuild
    content: "Create firmware-google-steelhead APKBUILD: depend on firmware-aosp-broadcom-wlan, install bcmdhd.cal for BCM4330"
    status: pending
  - id: create-build-script
    content: "Create build-and-flash.sh: pmbootstrap init/build/install/export workflow with fastboot boot (temp) and flash (permanent) steps"
    status: pending
  - id: validate-and-test
    content: "Validate: DTS compilation (make dtbs_check), kconfig check, cross-compile, QEMU vexpress-a9 boot test for userspace"
    status: pending
isProject: false
---

# Nexus Q postmarketOS Port

## Target Device: Google Nexus Q (Steelhead)

Spherical digital media player (4.6" diameter, ~923g), manufactured by Google in the USA, released June 2012. Codename **steelhead**. Headless embedded device -- no screen, no keyboard, no battery.

### Hardware Component Map

- **SoC**: TI OMAP4460 -- dual-core ARM Cortex-A9 @ 1.2 GHz, PowerVR SGX540 GPU (unused, software rendering only)
- **RAM**: 1 GB LPDDR2 (Elpida ECB240ABACN) at 0x80000000
- **Storage**: 16 GB eMMC (Samsung KLMAG4FEJA-A002)
- **PMIC**: TI TWL6030 + TPS62361 (I2C1, addr 0x48)
- **Audio codec**: TI TWL6040 (I2C1, addr 0x4b) -- McPDM to ABE
- **Audio amplifier**: TI TAS5713 25W Class-D (I2C4, addr 0x1b) -- McBSP2 I2S, drives banana jack speakers
- **WiFi**: Broadcom BCM4330 (SDIO on MMC5, WLAN_EN=GPIO43, IRQ=GPIO53)
- **Bluetooth**: Broadcom BCM4330 (UART2, BT_EN=GPIO46, BT_RESET=GPIO52)
- **NFC**: NXP PN544 (I2C3, addr 0x28, IRQ=GPIO164, EN=GPIO163)
- **Ethernet**: SMSC LAN9500A USB-to-10/100 (USB EHCI Port 1, NRESET=GPIO62)
- **HDMI**: OMAP4 DSS via TPD12S015A (CT_CP_HPD=GPIO60, LS_OE=GPIO41, HPD=GPIO63), micro-HDMI Type D
- **LED ring**: AVR MCU (I2C2, addr 0x20) -> LP5523 LED drivers (32 RGB LEDs)
- **Optical audio**: S/PDIF via McASP -> TOSLINK
- **Temperature**: TI TMP101 (I2C2, addr 0x48)
- **USB**: Micro-USB service port (OMAP4 USB OTG via MUSB)
- **Ports**: Micro-HDMI, Ethernet RJ-45, Micro-USB, TOSLINK, Banana jack L+R, AC power

### Boot Modes

- **Normal boot**: Power on -- circulating blue LED ring
- **Fastboot mode**: Cover mute LED during power-on -- solid red LED ring. Always reachable via hardware.
- **Recovery mode**: Cover mute LED at boot, use volume dome to scroll

**Anti-brick safety**: Fastboot is hardware-triggered (capacitive sensor), independent of any software partition. Device is unbrickable as long as `bootloader` partition is never overwritten.

### Partition Safety

- `bootloader` -- **NEVER FLASH** (bricks the device)
- `boot` -- 8 MB, kernel + ramdisk -- safe, but boot.img (~14 MB) exceeds it; use `fastboot boot` (RAM) instead
- `system` -- 1 GB, too small for rootfs; not used
- `userdata` -- 13 GB, **rootfs target** -- safe, always recoverable via fastboot
- `recovery`, `cache` -- safe

## Strategy

```mermaid
flowchart TD
  MainlineKernel["Mainline Linux 6.12 LTS"] -->|"+ TAS5713 driver patch"| KernelPkg[linux-google-steelhead]
  MainlineKernel -->|"+ steelhead DTS patch"| KernelPkg
  OMAP2plusDefconfig["omap2plus_defconfig"] -->|"+ device-specific options"| KernelPkg

  KernelPkg --> Build[pmbootstrap build]
  DevicePkg[device-google-steelhead] --> Build
  FirmwarePkg[firmware-google-steelhead] --> Build
  Build --> Test["fastboot boot (temp)"]
  Test -->|"works"| Flash["fastboot flash (perm)"]
```



### Key Design Decisions

- **Mainline kernel 6.12 LTS** (not the downstream 3.0.31 that Galaxy Nexus uses) -- modern driver framework, long-term support
- **Device-specific kernel package** (`linux-google-steelhead`) rather than shared `linux-postmarketos-mainline` -- needed because no OMAP4 device in pmaports uses the shared kernel, and we have custom DTS + TAS5713 patches
- **Boot parameters from Galaxy Nexus (samsung-maguro)** -- validated identical offsets: kernel=0x00008000, ramdisk=0x01000000, tags=0x00000100, pagesize=2048
- **Firmware from maguro pattern** -- `firmware-aosp-broadcom-wlan` + device-specific `bcmdhd.cal` for BCM4330
- **Console is `ttyS2`** (not `ttyO2`) -- mainline 8250 OMAP driver since kernel 3.19 uses `ttyS*` naming
- **omap2plus_defconfig as base** -- hand-written configs miss critical OMAP4 subsystem deps (pinctrl, clocks, DMA, interconnect, voltage domains)
- **WiFi/BT DTS compatible strings** must use two-string format: `"brcm,bcm4330-fmac", "brcm,bcm4329-fmac"` (specific + generic fallback per kernel binding docs)
- **McBSP2 pad offsets** must NOT overlap with McPDM pads (0x106/0x108/0x10a are McPDM, used by omap4-mcpdm.dtsi for TWL6040). Correct McBSP2 offsets must be verified against OMAP4460 TRM (SWPU235).

## Files to Create

### postmarketOS Packages (`pmos/`)

- `**device-google-steelhead/APKBUILD`** -- device package, depends on `linux-google-steelhead`, `mkbootimg`, `postmarketos-base`, `mesa-dri-gallium`
- `**device-google-steelhead/deviceinfo`** -- codename, arch=armv7, flash_method=fastboot, boot offsets, `console=ttyS2,115200n8`, DTB path, USB networking
- `**device-google-steelhead/modules-initfs`** -- omap_hsmmc, smsc95xx, omapdss, omapdrm, tpd12s015
- `**linux-google-steelhead/APKBUILD**` -- mainline 6.12 LTS kernel, references config + 3 patches
- `**firmware-google-steelhead/APKBUILD**` -- depends on `firmware-aosp-broadcom-wlan`, installs `bcmdhd.cal`

### Kernel Artifacts (`kernel/`)

- `**dts/omap4-steelhead.dts**` -- complete device tree (OMAP4460, TWL6030/6040, TAS5713, BCM4330, PN544, LAN9500A, LP5523, HDMI, all pinmux)
- `**configs/steelhead_defconfig**` -- based on omap2plus_defconfig + device-specific drivers + postmarketOS requirements
- `**patches/0001-ASoC-tas571x-add-TAS5713-support.patch**` -- add TAS5713 to mainline tas571x codec driver
- `**patches/0002-dt-bindings-add-ti-tas5713.patch**` -- add ti,tas5713 to DT binding YAML
- `**patches/0003-ARM-dts-omap4-add-steelhead.patch**` -- add DTS file to kernel tree + Makefile

### Build Scripts

- `**build-and-flash.sh**` -- pmbootstrap init/build/install/export + fastboot workflow

### Reference Files (informational)

- `**README.md**` -- project overview, hardware table, quick start
- `**firmware/README.md**` -- how to extract BCM4330 firmware from device

## Testing Pipeline

```mermaid
flowchart LR
  DTS["1. DTS Validation"] --> KConfig["2. Kconfig Check"]
  KConfig --> CrossBuild["3. Cross-compile"]
  CrossBuild --> QEMU["4. QEMU Boot"]
  QEMU --> FastbootBoot["5. fastboot boot"]
  FastbootBoot --> FastbootFlash["6. fastboot flash"]
```



### Stage 1: DTS Validation (no hardware)

```bash
make ARCH=arm CROSS_COMPILE=arm-linux-gnueabihf- dtbs
make ARCH=arm CROSS_COMPILE=arm-linux-gnueabihf- dtbs_check
make ARCH=arm dt_binding_check DT_SCHEMA_FILES=sound/ti,tas571x.yaml
```

Catches: wrong compatible strings, invalid properties, phandle errors, Makefile issues.

### Stage 2: Kconfig Validation (no hardware)

```bash
pmbootstrap kconfig check linux-google-steelhead
```

Validates config against postmarketOS requirements (cgroups, namespaces, devtmpfs, etc.).

### Stage 3: Cross-compile (no hardware)

```bash
pmbootstrap build linux-google-steelhead
pmbootstrap build device-google-steelhead
```

Catches: compile errors, missing includes, driver build failures.

### Stage 4: QEMU Boot Test (no hardware)

QEMU `vexpress-a9` emulates Cortex-A9 (same core as OMAP4460). Tests kernel boot, initramfs, userspace (Sway, PipeWire). Does NOT test device-specific peripherals.

```bash
pmbootstrap init  # select qemu-vexpress, armv7, sway
pmbootstrap install
pmbootstrap qemu --image-size=2G
# SSH: ssh -p 2222 user@127.0.0.1
```

### Stage 5: Temporary Boot (real hardware, non-destructive)

```bash
fastboot boot output/boot.img
```

Loads kernel+ramdisk into RAM (13.6 MB) without writing to flash. Power-cycle reverts to original. Tests: OMAP4460 boot, HDMI output, USB networking, serial console.

### Stage 6: Permanent Flash (real hardware, reversible)

```bash
# Convert to U-Boot-compatible sparse format (RAW + DONT_CARE only)
python raw2simg.py output/google-steelhead.img output/google-steelhead-sparse.img

# Flash rootfs to userdata in 64 MB chunks (avoids USB stalls)
fastboot flash -S 64M userdata output/google-steelhead-sparse.img

# Boot kernel from RAM (boot.img too large for 8 MB boot partition)
fastboot boot output/boot.img
```

Always recoverable via fastboot mode (cover mute LED during power-on). Do NOT use `pmbootstrap flasher` -- it does not handle the sparse format conversion or chunk size constraints.

### What QEMU Cannot Test (hardware only)

HDMI, WiFi/BT (BCM4330), audio amp (TAS5713), LED ring (AVR+LP5523), Ethernet (LAN9500A), NFC (PN544), eMMC timing, TWL6030 power sequencing. All safe to test via `fastboot boot`.

## Flashing Procedure -- Findings

Discovered through trial and error on real hardware. The Nexus Q's 2012 U-Boot fastboot implementation has several constraints not documented anywhere.

### Partition Layout Constraints

From `fastboot getvar all`:

| Partition | Size | Notes |
|-----------|------|-------|
| boot | 8 MB | Too small for generated boot.img (~14 MB) |
| system | 1 GB | Too small for rootfs (~720 MB raw) -- download buffer rejects it |
| userdata | 13.17 GB | **Rootfs target** -- only partition large enough |
| recovery | 8 MB | Same size as boot |

Key constraint: the bootloader's fastboot download buffer is somewhere between 128 MB and 720 MB. Raw images larger than this limit are rejected with `FAILED (remote: 'data too large')`.

### Image Preparation

pmbootstrap generates a **full disk image** (`google-steelhead.img`) containing a partition table + boot partition + rootfs partition. This cannot be flashed directly to a single partition. The rootfs ext4 partition must be extracted:

```bash
# In docker-build.sh Phase 10:
ROOTFS_INFO=$(sfdisk -J "$DISK_IMG" | python3 -c "
  import json, sys
  d = json.load(sys.stdin)
  p = d['partitiontable']['partitions'][1]  # partition 2 = rootfs
  ss = d['partitiontable'].get('sectorsize', 512)
  print(f'{p[\"start\"]} {p[\"size\"]} {ss}')
")
dd if="$DISK_IMG" of=rootfs.img bs=$SECTOR_SIZE skip=$START count=$SECTORS
```

Result: 720 MB raw ext4 image (down from ~965 MB full disk image).

### Sparse Format Compatibility

The U-Boot bootloader (steelheadB4H0J, April 2012) supports Android sparse format but **only two chunk types**:

| Chunk Type | ID | U-Boot Support |
|------------|------|----------------|
| RAW | 0xCAC1 | Yes |
| FILL | 0xCAC2 | **No** -- "unknown chunk ID cac2" |
| DONT_CARE | 0xCAC3 | Yes |
| CRC32 | 0xCAC4 | Unknown (not tested) |

Modern `fastboot -S` creates sparse images with FILL chunks for zero-filled regions, which the bootloader rejects. A custom converter (`raw2simg.py`) creates sparse images using only RAW + DONT_CARE chunks:

- Zero blocks (4096 bytes of 0x00) become DONT_CARE chunks (not stored, just skipped)
- Non-zero blocks become RAW chunks (stored verbatim)
- Result: ~531 MB sparse image (26% smaller than raw 720 MB)

### USB Transfer Stability

- **64 MB chunks work reliably** (`fastboot flash -S 64M`) -- 9 chunks, ~45 seconds total
- **128 MB chunks are unreliable** -- USB stalls on the 4th chunk, device becomes unresponsive
- **Interrupted transfers corrupt the USB session** -- device serial appears as `????????????`, `fastboot getvar` hangs. Requires full power cycle (unplug power, cover mute LED, re-plug) to recover
- Transfer speed: ~43 MB/s over USB 2.0

### Working Flash Procedure

```bash
# 1. Generate compatible sparse image (only RAW + DONT_CARE chunks)
python raw2simg.py output/google-steelhead.img output/google-steelhead-sparse.img

# 2. Flash rootfs to userdata in 64 MB chunks
fastboot flash -S 64M userdata output/google-steelhead-sparse.img
# Output: 9/9 chunks, ~45 seconds

# 3. Boot kernel from RAM (boot.img exceeds 8 MB boot partition)
fastboot boot output/boot.img

# 4. Connect via USB networking
ssh user@172.16.42.1  # password: 147147
```

### deviceinfo Configuration

```ini
# Flash rootfs to userdata (13 GB) instead of system (1 GB)
deviceinfo_flash_fastboot_partition_system="userdata"
```

### Build Environment Note (Windows)

All source files on a Windows volume mount have CRLF line endings. The Docker entrypoint strips `\r` from the build script, and `dos2unix` is run on all APKBUILD, deviceinfo, patch, and config files after copying them into the pmaports tree. Without this, pmbootstrap rejects the APKBUILDs with "Wrong line endings" and `abuild` fails with "not found" errors on CRLF-terminated lines.