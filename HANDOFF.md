# Nexus Q PostmarketOS Port -- Agent Handoff Document

## Project Goal

Boot PostmarketOS (mainline Linux 6.12 LTS) on the Google Nexus Q ("steelhead"), an OMAP4460-based media streamer from 2012.

## Current Status: KERNEL DOES NOT BOOT

The kernel compiles, the DTB is valid, `fastboot` accepts and loads the image, but the kernel **never produces any output** -- no HDMI, no USB enumeration, no network, nothing. The device silently disappears from fastboot and sits dark for 90+ seconds.

This happens consistently across:
- `fastboot boot` (RAM boot) and `fastboot flash boot` + power-cycle (partition boot)
- Full postmarketOS initramfs and minimal diagnostic initramfs
- Module-based drivers AND built-in drivers (DRM, USB, FBCON all =y)
- With and without ramdisk

## What Has Been Tried (and Failed)

### Boot Image Variants Tested
| Image | Size | Description | Result |
|-------|------|-------------|--------|
| `boot.img` | 13.5 MB | Full pmos initramfs, all drivers as modules | No output |
| `boot-diag.img` | 5.9 MB | Minimal diag initramfs, hardcoded insmod, telnetd | No output |
| `boot-builtin.img` | 8.8 MB | Full initramfs, DRM+USB+FBCON built-in (=y) | No output |
| `boot-noramdisk.img` | 5.0 MB | Kernel+DTB only, no ramdisk, console=tty0 | **NOT YET TESTED** |

### Kernel Configuration Changes (Current State)
These drivers were changed from `=m` (module) to `=y` (built-in) in `kernel/configs/steelhead_defconfig`:
- `CONFIG_DRM=y`, `CONFIG_DRM_OMAP=y` (HDMI display)
- `CONFIG_DRM_PANEL_SIMPLE=y`, `CONFIG_DRM_DISPLAY_CONNECTOR=y`
- `CONFIG_DRM_SIMPLE_BRIDGE=y`, `CONFIG_DRM_TI_TFP410=y`, `CONFIG_DRM_TI_TPD12S015=y`
- `CONFIG_USB=y`, `CONFIG_USB_EHCI_HCD=y` (USB host)
- `CONFIG_USB_MUSB_HDRC=y`, `CONFIG_USB_MUSB_OMAP2PLUS=y` (USB OTG)
- `CONFIG_NOP_USB_XCEIV=y`, `CONFIG_OMAP_USB2=y`, `CONFIG_TWL6030_USB=y` (USB PHY)
- `CONFIG_USB_GADGET=y`, `CONFIG_USB_CONFIGFS=y` (USB gadget/RNDIS)
- `CONFIG_USB_USBNET=y`, `CONFIG_USB_NET_SMSC95XX=y` (Ethernet)
- `CONFIG_FRAMEBUFFER_CONSOLE=y`, `CONFIG_FB=y` (framebuffer console)

### Other Fixes Applied
- `deviceinfo_dtb` changed from `"ti/omap/omap4-steelhead"` to `"omap4-steelhead"` (kernel installs DTBs flat, not under `ti/omap/`)
- `deviceinfo_append_dtb="true"` added (appends DTB to zImage)
- `CONFIG_ARM_APPENDED_DTB=y` and `CONFIG_ARM_ATAG_DTB_COMPAT=y` in defconfig
- Rootfs flashes to `userdata` partition (13 GB) since `system` is only 1 GB
- Custom `raw2simg.py` for sparse image conversion (U-Boot only supports RAW+DONT_CARE chunks)

## Key Unknowns / Suspected Root Causes

1. **The kernel may panic during early decompression/startup** before any console is available. Since serial output goes to UART3 (physical pins requiring soldering), we cannot see early boot messages.

2. **Possible DTB issues**: The `omap4-steelhead.dts` was written from scratch based on the old CyanogenMod board file. It may have incorrect clock parents, regulator configurations, or missing nodes that cause the PMIC to fail, which would kill power to the SoC subsystems.

3. **U-Boot 2012 compatibility**: The bootloader is from April 2012 and may not properly set up ATAGs or memory for a modern mainline kernel. The `CONFIG_ARM_ATAG_DTB_COMPAT=y` flag is supposed to handle this, but there may be edge cases.

4. **Kernel LZMA decompression**: `CONFIG_KERNEL_LZMA=y` -- if the decompressor has issues on this specific U-Boot version, the kernel would silently fail. Consider trying `CONFIG_KERNEL_GZIP=y` instead.

## Immediate Next Steps

### 1. Test `boot-noramdisk.img` (Already Built, ~5.0 MB)
Located at `output/boot-noramdisk.img`. This is kernel+DTB only with `console=tty0 loglevel=7 ignore_loglevel earlyprintk panic=30`. If no HDMI output even with built-in FBCON/DRM and no ramdisk, the problem is definitively in the kernel or DTB, not the initramfs.

### 2. Try Simpler Kernel Configurations
- Switch compression from LZMA to GZIP: `CONFIG_KERNEL_GZIP=y` (delete `CONFIG_KERNEL_LZMA=y`)
- Try `CONFIG_OMAP_RESET_CLOCKS=n` (this aggressively disables unused clocks at boot -- may kill DSS/USB clocks before drivers probe)
- Try disabling `CONFIG_POWER_AVS_OMAP=y` and `CONFIG_POWER_AVS_OMAP_CLASS3=y` (Adaptive Voltage Scaling can cause issues with power domains)

### 3. Try a Known-Working Kernel
The original Android 4.2 kernel and the CyanogenMod kernel (3.0.x) are known to boot on this hardware. Building one of those with a simple initramfs would confirm the hardware works. Repo: `https://github.com/AdrianDC/android_kernel_google_steelhead`

### 4. Serial Console Access
If software approaches fail, connecting to UART3 (pins on the board) is the only way to see early kernel output. The Nexus Q's UART3 is on the 10-pin header (J400): TX=pin 6, RX=pin 7, GND=pin 10. Requires 1.8V logic level UART adapter.

## Device Information

### Partition Layout
```
environment    97 KB    raw
crypto         16 KB    raw
xloader       384 KB    raw
bootloader    512 KB    raw     *** NEVER FLASH ***
device_info   512 KB    raw
bootloader2   512 KB    raw
misc          512 KB    raw
recovery        8 MB    boot
boot            8 MB    boot    (can fit <=8 MB images)
efs             8 MB    ext4
system          1 GB    ext4    (too small for rootfs)
cache         512 MB    ext4
userdata     13.17 GB   ext4    (rootfs target)
```

### Fastboot Mode
- Enter: Cover mute LED sensor during power-on -> solid red LED
- The device is **unbrickable** as long as bootloader is never overwritten
- Serial: `AW1S12241020`
- Bootloader: `steelheadB4H0J` (U-Boot 2011.09-rc1, Apr 2012)

### U-Boot Quirks
- Only supports sparse image chunk types `RAW` and `DONT_CARE` (not `CRC32` or `FILL`)
- `fastboot boot` accepts images up to ~150 MB (download buffer)
- `fastboot flash boot` limited to 8 MB partition
- USB connection can be flaky -- always power-cycle between flash operations

## Build System

### Docker Build (Windows Host)
```bash
# Build Docker image
docker build -t nexusq-builder .

# Full build (clean)
docker volume rm nexusq-workdir nexusq-output 2>/dev/null
docker run --rm --privileged \
    -v "${PWD}:/src:ro" \
    -v nexusq-output:/tmp/output \
    -v nexusq-workdir:/home/pmos/.local/var/pmbootstrap \
    --name nexusq-build \
    nexusq-builder /src/docker-build.sh

# Extract output
docker run --rm -v nexusq-output:/data -v "${PWD}/output:/out" \
    alpine:3.21 sh -c 'cp /data/*.img /out/'
```

### Build Volumes
- `nexusq-workdir` -- pmbootstrap work directory (kernel build cache, chroots)
- `nexusq-output` -- Output images (boot.img, rootfs)

### Current Build Artifacts in Docker Volume
The `nexusq-workdir` volume contains a **completed kernel build** with the built-in driver defconfig. Key paths inside:
```
chroot_rootfs_google-steelhead/boot/vmlinuz          (5.1 MB, kernel 6.12.12)
chroot_rootfs_google-steelhead/boot/dtbs/omap4-steelhead.dtb  (94 KB)
chroot_rootfs_google-steelhead/boot/config            (kernel config)
chroot_rootfs_google-steelhead/lib/modules/6.12.12/   (150 modules)
```

The `mkinitfs` step failed because `deviceinfo_dtb` had the wrong path (`ti/omap/omap4-steelhead` vs `omap4-steelhead`). This has been fixed in `pmos/device-google-steelhead/deviceinfo`. A clean rebuild should work.

### Manual Image Export
If `mkinitfs` fails in the chroot (QEMU binfmt issues), use `manual-export.sh` which:
1. Fixes DTB path in chroot deviceinfo
2. Builds initramfs manually (copies busybox + modules)
3. Creates boot.img with mkbootimg
4. Creates rootfs ext4 image from chroot

## File Inventory

### Core Configuration
| File | Purpose |
|------|---------|
| `kernel/configs/steelhead_defconfig` | Kernel config (MODIFIED: key drivers =y) |
| `kernel/dts/omap4-steelhead.dts` | Device tree source (579 lines) |
| `kernel/patches/0001-*.patch` | TAS5713 audio amp driver |
| `kernel/patches/0002-*.patch` | TAS5713 DT binding |
| `kernel/patches/0003-*.patch` | Steelhead DTS added to kernel tree |
| `pmos/device-google-steelhead/deviceinfo` | Device config (MODIFIED: DTB path fixed) |
| `pmos/device-google-steelhead/modules-initfs` | Initramfs modules list |
| `pmos/device-google-steelhead/APKBUILD` | Device package recipe |
| `pmos/linux-google-steelhead/APKBUILD` | Kernel package recipe |
| `pmos/firmware-google-steelhead/APKBUILD` | Firmware package recipe |

### Build Scripts
| File | Purpose |
|------|---------|
| `Dockerfile` | Alpine-based build container |
| `docker-build.sh` | Main build orchestrator (10 phases) |
| `build-and-flash.sh` | Top-level build + flash script |
| `manual-export.sh` | Manual image export when mkinitfs fails |
| `raw2simg.py` | Convert raw image to Android sparse format |

### Diagnostic Scripts
| File | Purpose |
|------|---------|
| `build-diag-boot2.sh` | Build minimal diagnostic boot image |
| `build-noramdisk.sh` | Build kernel-only boot image (no initramfs) |
| `fix-dtb.sh` | Manually append DTB to kernel |
| `verify-dtb.sh` | Validate DTB structure |
| `verify-kernel.sh` | Validate kernel binary |
| `inspect-initramfs.sh` | Extract and inspect initramfs contents |
| `inspect-initramfs-detail.sh` | Detailed initramfs inspection |
| `inspect-stage2.sh` | Inspect pmos init stage 2 |
| `regen-initramfs-fixed.sh` | Rebuild initramfs with correct module paths |

### Output Images
| File | Size | Description |
|------|------|-------------|
| `output/boot.img` | 13.5 MB | Original full image (modules) |
| `output/boot-diag.img` | 5.9 MB | Diagnostic image |
| `output/boot-builtin.img` | 8.8 MB | Built-in drivers image |
| `output/boot-noramdisk.img` | 5.0 MB | Kernel+DTB only |
| `output/google-steelhead.img` | 720 MB | Rootfs (raw ext4) |
| `output/google-steelhead-sparse.img` | 530 MB | Rootfs (sparse, for flashing) |

## Ubuntu Transition Notes

If continuing on Ubuntu (instead of Windows):
1. USB/fastboot should work natively (`sudo apt install android-tools-adb android-tools-fastboot`)
2. Docker build should be faster (no QEMU overhead for Windows Docker)
3. Can also build natively with pmbootstrap if Alpine chroot works
4. Serial UART debugging is easier with USB-to-serial adapters on Linux
5. The rootfs (`google-steelhead-sparse.img`) is already flashed to the device's userdata partition -- only boot.img needs reflashing after kernel rebuilds
6. Consider using `pmbootstrap` natively on Ubuntu instead of Docker for faster iteration
