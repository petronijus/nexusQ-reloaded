# Nexus Q PostmarketOS Port -- Agent Handoff Document

## Project Goal

Boot PostmarketOS (mainline Linux 6.12 LTS) on the Google Nexus Q ("steelhead"), an OMAP4460-based media streamer from 2012.

## Current Status: KERNEL BOOTS (HDMI output confirmed)

**Milestone achieved 2026-02-27:** The kernel boots, HDMI output works (framebuffer console with Tux logo), eMMC is fully detected with all partitions, and the kernel panics with "Unable to mount root fs" -- which is expected since no rootfs is configured yet.

### What Was Wrong (Root Causes)

Three kernel config options prevented boot:

1. **`CONFIG_SMP=y`** (CRITICAL) -- The U-Boot 2011.09 bootloader leaves CPU1 (second Cortex-A9 core) in an undefined state. The mainline kernel's SMP startup code hangs trying to bring it online. **Fix: `CONFIG_SMP` disabled.**

2. **`CONFIG_ARM_ATAG_DTB_COMPAT=y`** -- U-Boot passes ATAGs that crash the zImage decompressor's ATAG-to-DTB merge code. Since the DTB is appended to the kernel (`CONFIG_ARM_APPENDED_DTB=y`), ATAG merging is unnecessary. **Fix: `CONFIG_ARM_ATAG_DTB_COMPAT` disabled.**

3. **`CONFIG_CMDLINE_EXTEND=y`** -- With ATAG_DTB_COMPAT disabled, the bootloader's cmdline (from mkbootimg header) is not passed to the kernel. All cmdline parameters must be compiled in. **Fix: `CONFIG_CMDLINE_FORCE=y` with all parameters in `CONFIG_CMDLINE`.**

### Boot Method

- **Reliable: `fastboot flash boot` + normal power-on** -- Flash to the 8 MB boot partition, then power-cycle without holding mute sensor. U-Boot loads from partition and boots reliably.
- **Unreliable: `fastboot boot` (RAM boot)** -- Intermittent on this U-Boot. Works sometimes, fails silently other times. Avoid for testing.

### Remaining Issue

The full boot.img with initramfs is **14.6 MB**, exceeding the 8 MB boot partition. The kernel+DTB alone is 6.2 MB (fits), but the pmos initramfs adds 8.4 MB. Need to either shrink the image or find another boot strategy.

## Boot Image Variants Tested
| Image | Size | Description | Result |
|-------|------|-------------|--------|
| `boot.img` | 13.5 MB | Full pmos initramfs, all drivers as modules | No output (SMP bug) |
| `boot-diag.img` | 5.9 MB | Minimal diag initramfs, hardcoded insmod, telnetd | No output (SMP bug) |
| `boot-builtin.img` | 8.8 MB | Full initramfs, DRM+USB+FBCON built-in (=y) | No output (SMP bug) |
| `boot-noramdisk.img` | 5.0 MB | Kernel+DTB only, no ramdisk, console=tty0 | No output (SMP bug) |
| `boot-test-nosmp-noatag.img` | 6.2 MB | SMP=n, ATAG_COMPAT=n, CMDLINE_FORCE, no ramdisk | **BOOTS! HDMI works!** |
| `boot-full-working.img` | 14.6 MB | Same fixes + pmos initramfs | Too large for boot partition |

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

## Resolved Root Causes

1. **`CONFIG_SMP=y` caused a hard hang** -- U-Boot 2011.09 leaves the secondary CPU (CPU1) in an undefined state. The mainline kernel's OMAP4 SMP startup code tries to bring CPU1 online and hangs indefinitely. No panic, no output, just a silent deadlock. Fixed by disabling SMP.

2. **`CONFIG_ARM_ATAG_DTB_COMPAT=y` crashed the decompressor** -- U-Boot passes ATAGs in r2 that the zImage decompressor's atags_to_fdt() function can't handle properly. Since we use `CONFIG_ARM_APPENDED_DTB=y` (DTB concatenated after zImage), ATAG merging is unnecessary. Fixed by disabling ATAG_DTB_COMPAT.

3. **`CONFIG_CMDLINE_EXTEND` produced an empty cmdline** -- With ATAG_DTB_COMPAT disabled, the bootloader's cmdline (from mkbootimg header, passed via ATAGs) never reaches the kernel. The DTS has no `/chosen/bootargs`. With CMDLINE_EXTEND, the result was just CONFIG_CMDLINE (which worked). Changed to CMDLINE_FORCE for clarity.

4. **`fastboot boot` (RAM boot) is unreliable** -- The steelhead U-Boot's RAM boot path is intermittent. Flashing to the boot partition (`fastboot flash boot`) and doing a normal power-on boot is 100% reliable.

### What Was NOT the Problem
- LZMA compression (was a red herring; GZIP kept for slightly faster boot)
- `CONFIG_OMAP_RESET_CLOCKS` (disabled as precaution, may be safe to re-enable)
- `CONFIG_POWER_AVS_OMAP` (disabled as precaution, may be safe to re-enable)
- The device tree (omap4-steelhead.dts is correct)
- The boot image format (mkbootimg header v0, correct addresses)

## Immediate Next Steps

### 1. Solve the Boot Partition Size Problem
The full boot.img (kernel 6.1 MB + DTB 93 KB + initramfs 8.4 MB = 14.6 MB) exceeds the 8 MB boot partition. Options:
- **Switch drivers back to modules** (=m) to reduce kernel size, move bulk to rootfs
- **Switch compression back to LZMA** (now safe since the real issue was SMP, not LZMA)
- **Strip the initramfs** (remove unnecessary modules/files)
- **Use a two-stage boot**: minimal initramfs loads the full rootfs from userdata
- **Boot from recovery partition** (also 8 MB) to free boot for a larger image

### 2. Flash and Boot Full postmarketOS
Once the size issue is solved:
- Flash rootfs to userdata: `fastboot flash userdata output/google-steelhead-sparse.img`
  (Note: 488 MB transfer; may need to split into smaller chunks for this U-Boot)
- Flash boot.img to boot partition: `fastboot flash boot output/boot.img`
- Normal power-on (don't hold mute sensor)

### 3. Enable USB Networking
The pmos initramfs configures USB gadget (RNDIS) for initial access. Once booted:
- The device should appear as a USB network adapter on the host
- SSH into the device via USB network

### 4. Re-enable SMP (Future)
Investigate proper OMAP4460 SMP startup with this U-Boot. May need:
- Custom SMP startup code that handles the undefined CPU1 state
- A secondary CPU holding pen implementation
- Patching the kernel's OMAP4 SMP code to reset CPU1 before bringing it online

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
