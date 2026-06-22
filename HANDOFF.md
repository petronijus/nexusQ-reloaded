# Nexus Q PostmarketOS Port -- Agent Handoff Document

## Project Goal

Boot PostmarketOS (mainline Linux 6.12 LTS) on the Google Nexus Q ("steelhead"), an OMAP4460-based media streamer from 2012.

## Session 2026-06-22 (latest): SECOND CPU CORE WORKS ✅ — dual-core SMP

The OMAP4460 HS second Cortex-A9 is online and stable on mainline 6.12.
`CONFIG_SMP=y` had silently deadlocked the boot for the life of the port; root
cause found by disassembling the stock kernel (`reverse-eng/vmlinux.bin`):

- **Missing SEV in `omap4_smp_prepare_cpus`** — stock issues `dsb;sev` after
  writing AUX_CORE_BOOT_1 to kick CPU1 out of ROM WFE; mainline omits it → CPU1
  never starts → `__cpu_up` hangs before any console. Fix: **patch 0009**
  (`dsb_sev()` at end of prepare).
- **CPU1 cpuidle panic** once online (`Attempted to kill the idle task`, on
  `swapper/1`). Fix: **`cpuidle.off=1`** (stock ships `cpuidle44xx.disallow_smp_idle`).

Secure SMC service IDs already matched stock byte-for-byte; `omap_type()=HS`.
defconfig: `CONFIG_SMP=y`, `NR_CPUS=2`, `HOTPLUG_CPU=y`, `KERNEL_LZMA` (SMP+gzip
busted the ~6.6 MB U-Boot ceiling; LZMA → ~5.1 MB); DTS `cpu@1` restored.

**Validated** (cold boot, `boot-smp-dualcore.img`): `nproc=2`, online/possible=0-1,
`taint=0`, 0 module-ABI errors, `SMP: Total of 2 processors activated`, CPU1 up at
`[0.25s]`, both cores load under stress, ~59 °C; audio/LED-ring/wifi/BT/USB up.
Dual-core also cured the single-core-saturation network flakiness.

Build: `scripts/build-kernel-boot.sh` (fast kernel-only docker build). Branch
`feat/smp-cpu1-bringup` (`510f8ab` breakthrough+debug, `8d4df5d` clean dual-core).
Also fixed a repo-integrity bug: patch 0008 (ethernet) applied with `git apply`
but FAILED under GNU `patch` (abuild) — regenerated clean.

**Full writeup: `docs/SMP-second-core.md`.** Open items (cpuidle proper, eth
LAN9500A enumeration reliability, wifi BCM4330 power-save, making SMP the default
after multi-cold-boot reliability validation) tracked in
`docs/2026-06-22-smp-session-findings.md`.

## Session 2026-06-22 (late): ETHERNET FIXED ✅ — kernel #8, released v1.1.0

The on-board **SMSC LAN9500A USB-ethernet works.** This retires the multi-month
"ethernet is dead hardware" verdict, which was wrong: the stock Android 3.0 kernel
enumerates the same chip on this unit, so the bug was always in our mainline port.

**Two kernel patches, both required:**
- `0006-usb-ehci-omap-steelhead-keep-ethernet-port-alive-ulp` — vendor steelhead
  host-init in `ehci-omap` done *before* `usb_add_hcd()`: LAN9500A power-on-reset
  sequence (auxclk3 38.4 MHz, NENABLE/NRESET gpios), `INSNREG01` burst thresholds
  = 0x80, a ULPI Function-Control soft reset of the USB3320, plus
  `usb_disable_autosuspend()` on the root hub so the idle port is not clock-gated.
- `0008-mfd-omap-usb-host-steelhead-UHH-HOSTCONFIG-connect` — in `omap_usbhs_init`,
  program `UHH_HOSTCONFIG` to the vendor's **0x11c**: set `P1_CONNECT_STATUS`
  (bit 8) so EHCI latches the port-1 connect, and leave `APP_START_CLK` (bit 31)
  **clear** so the UHH does not auto clock-gate. Measured mainline default was
  **0x1c** (the "ethernet-stockinit" handover's APP_START_CLK guess was wrong).

**Discovery note:** kernel **#7** (patch 0006 alone) already enumerated `eth0` —
the `docs/2026-06-22-HANDOVER-ethernet-stockinit.md` "#4–#7 all failed, eth0 absent"
conclusion was a mis-test. #8 adds the UHH_HOSTCONFIG change as the *more-correct*
root-cause form (matches the vendor exactly, no autosuspend reliance) and is the
released kernel.

**Verified on hardware (#8):** `eth0` (`0424:9e00` → `smsc95xx`) at 100 Mbps/Full,
bidirectional ping 0% loss (~0.69 ms avg), **zero** rx/tx/CRC/frame/over errors and
zero collisions after ~660 MB transferred. Throughput TX ~60 / RX ~28 Mbps —
USB2 + single-core OMAP4 bound (device ~64% idle during RX), not a link fault.

**Access over ethernet (now preferred over the renaming USB gadget):** the Nexus
RJ45 is cabled directly to `petronijus-PC` NIC `enp7s0` (Intel I225-V, 100M). Device
`eth0` has a persistent NetworkManager profile **`eth-direct`** (`ipv4.method
manual`, `10.42.0.2/24`, never-default, autoconnect, bound to ifname not MAC since
smsc95xx has no EEPROM MAC) → survives reboot and stopped the earlier NM-DHCP-timeout
link flap. PC side: `enp7s0` = `10.42.0.1/24`, set NM-unmanaged so the IP sticks.
`ssh root@10.42.0.2`.

Artifacts: `#7` backup `output/p9-backup-7-working.img` (sha c0dd95d1); released
`#8` boot image `output/boot-eth-8.img` (sha 8c7b4f75, 6496 KB, under the ~6.5 MB
U-Boot ceiling). The released boot image is #8 *with* a one-time diagnostic
`UHH_HOSTCONFIG` boot log; source patch 0008 in the v1.1.0 tag omits that logging
(functionally identical). Build gotcha fixed: `docker-build.sh` Phase 7a now also
chowns `$WORK/cache_ccache_armv7` to uid 12345.

## Session 2026-06-22: TAS5713 amp clock fixed, single-core taint cleared; ethernet still dead

Built and flashed kernel **#4** (`6.12.12`), verified live over the USB gadget
(WiFi is unstable — flash/diagnostics go over `172.16.42.1`).

- **TAS5713 amplifier MCLK fixed** (kernel patch 0007). OMAP4 composite-clock
  `round_rate`/`set_rate` were `-EINVAL` stubs; delegated to
  `ti_clk_divider_ops`. On HW: `dpll_per_m3x2_ck` = 61.44 MHz, `auxclk1_ck` =
  12.288 MHz (256×48 kHz), ALSA `card 0 NexusQ-Speaker` registers, no clock
  error. (Actual audio playback through speakers not yet tested.)
- **Single-core taint cleared.** DTS now `/delete-node/ cpu@1` (matches
  `CONFIG_SMP=n`). `/proc/sys/kernel/tainted` = 0 (was 512), no DT cpu-cap WARN.
- `CONFIG_SRAM=y`; new helper scripts `regen-dts-patch.sh`,
  `extract-and-repack.sh`; device password moved to gitignored `.nexus_pw`.
- **Ethernet (LAN9500A) STILL DEAD.** #4 kernel: EHCI port powered, ULPI PHY
  (USB3320, VID 0x4:0x24) responds, `PORTSC=00001000` (PP set, CCS clear) — no
  enumeration, no `eth0`, EHCI bus 002 has only the root hub. This is the next
  thing to investigate/fix. Backup of the pre-#4 boot partition:
  `output/p9-backup-pre-clockfix-b7.img`.

## Session 2026-06-10: Userspace boots, WiFi works, ethernet is dead HW

### Status: postmarketOS (systemd) boots, SSH over USB gadget, WiFi functional

### Root causes found today (in order of discovery)
1. **U-Boot kernel-size ceiling (~6.5-7 MB)** when loading from the boot
   partition: 6.45 MB zImage+DTB boots, 7.3 MB does not. This was the hidden
   variable behind "Finding 2" (identical-config rebuilds not booting) --
   embedded initramfs pushed the image over the limit.
2. **Ubuntu GCC 15.2 kernels do NOT boot** (black screen). Only the Arm GNU
   Toolchain 13.3.Rel1 (same as original builds) produces booting kernels.
   Toolchain lives in `build/arm-gnu-toolchain-13.3.rel1-*/bin`,
   prefix `arm-none-linux-gnueabihf-`.
3. **Feb rootfs flash silently failed**: 511 MB sparse image exceeds the
   U-Boot fastboot download buffer (~150 MB). Flash userdata with
   `fastboot -S 100M flash userdata <img>` -- works reliably (6 chunks).
4. **Rootfs is pmOS systemd variant** (/sbin/init -> ../lib/systemd/systemd).
   /etc/inittab and /etc/init.d are decoys. Emergency mode was caused by an
   fstab entry for a /boot partition UUID that only existed in the build VM;
   line removed. Root account unlocked (password 147147, same as user).
5. **Ethernet (LAN9500A) is dead hardware.** Verified at register/pad level:
   pinmux applied, GPIO pads toggle (DATAIN readback), 38.4 MHz PHY refclk
   running, ULPI PHY (SMSC USB3320, id 0x0424/0x0007) responds via the EHCI
   ULPI viewport (INSNREG05 @ 0x4A064CA4), EHCI port powered -- but PORTSC
   CCS never asserts. gpio_1 (ethernet NENABLE) is physically clamped low
   (drive-high reads back 0). DTS ethernet fixes applied anyway (38.4 MHz
   clock per board-steelhead-usbhost.c, NENABLE polarity, gpio_wk1 pad 0x042
   in wkup domain, fref_clk3_out mux) -- correct for a healthy unit.
6. **WiFi (BCM4330) works.** Chain of fixes:
   - kernel patch 0004: twl-core registers the clk mfd cell for TWL6030
     (mainline only did TWL6032; register bases 0x8C/0x8F are identical)
   - DTS: pwrseq clocks = <&twl 1> (clk32kaudio, per board-steelhead-wifi.c)
   - DTS: WLAN_EN (gpio_43) only in pwrseq (was double-claimed by the vmmc
     regulator -> EBUSY); vmmc is a plain always-on 3.3 V fixed regulator
     (3.3 V matters: SDIO OCR negotiation fails at 1.8 V "no support for
     card's volts")
   - nvram: **original bcmdhd.cal recovered from the old Android system
     partition (mmcblk0p11, still intact!)** -> /lib/firmware/brcm/
     brcmfmac4330-sdio.txt. Generic Prowise nvram does NOT work (dongle
     timeout -110). Also recovered bcm4330.hcd (Bluetooth patchram).
     Both backed up in `firmware/` in this repo.

### Access to the running device
- USB gadget RNDIS via micro-USB: device 172.16.42.1, host 172.16.42.2/24
  (NetworkManager profile "nexusq" on this PC; iface name changes each boot
  -- random MAC -- fix with `nmcli con mod nexusq connection.interface-name <enx...>`)
- SSH as root (password 147147, petronijus' ed25519 key authorized)
- Gadget+sshd is started by /usr/local/bin/nexus-diag.sh (systemd unit
  nexus-diag.service), which also dumps diagnostics to /dev/tty1 and
  /var/log/nexus-diag.log
- **Boot images can be written from the running system**:
  `dd if=boot.img of=/dev/mmcblk0p9 bs=1M conv=fsync` -- no fastboot needed
- **`systemctl reboot` over SSH works cleanly** (~90 s to gadget back up).
  The old "software reboot re-enters fastboot" note applied to panic-reboots
  and `fastboot reboot`, NOT to a clean systemd reboot.
- pstore/ramoops configured in cmdline (last 1 MB of RAM, mem=1008M) --
  survives warm reboots only

### Current images
- boot: `output/boot-wifi-v5.img` (GCC 13.3, gzip, no initramfs,
  root=/dev/mmcblk0p13 + ramoops in cmdline, DTS with all fixes)
- rootfs: `output/work-rootfs.img` (raw) / `work-rootfs-sparse.img` (flash)
  -- modules for this exact kernel installed, fstab fixed, sshd fixed
  (UsePAM drop-in removed), root unlocked, host keys baked in
- mini mkbootimg replacement: `make-bootimg.py` (or reuse a proven header)

### Known issues / next steps
1. **Intermittent boot failure** (~1 in 3 boots: black screen, retry helps).
   Unexplained. Candidates: U-Boot flakiness, DRAM init, kernel race.
   pstore won't help across cold cycles. Consider UART2/3 serial console.
2. WiFi: NetworkManager connection profile not yet configured (needs SSID
   + password). brcmfmac autoloads on boot; firmware+nvram persist in rootfs.
3. Bluetooth: bcm4330.hcd recovered; hci_bcm + UART2 wiring in DTS untested.
4. SMP still disabled (single core) -- original U-Boot CPU1 issue.
5. Audio (TWL6040/TAS5713), NFC, LEDs untested.
6. APKBUILD sha512sums need refresh (0004 patch added with SKIP).

## Current Status: KERNEL BOOTS (HDMI output confirmed)

**Milestone achieved 2026-02-27:** The kernel boots, HDMI output works (framebuffer console with Tux logo), eMMC is fully detected with all partitions, and the kernel panics with "Unable to mount root fs" -- which is expected since no rootfs is configured yet.

### What Was Wrong (Root Cause)

**`CONFIG_SMP=y`** was the sole root cause of boot failure. The U-Boot 2011.09 bootloader leaves CPU1 (second Cortex-A9 core) in an undefined state. The mainline kernel's OMAP4 SMP startup code hangs trying to bring it online -- no panic, no output, silent deadlock. **Fix: `CONFIG_SMP` disabled.**

### Required Config for Boot (all must be set)

| Option | Value | Why |
|--------|-------|-----|
| `CONFIG_SMP` | `n` | U-Boot leaves CPU1 in bad state; SMP startup hangs |
| `CONFIG_ARM_ATAG_DTB_COMPAT` | `y` | **REQUIRED** -- kernel does NOT boot without it; U-Boot passes ATAGs that the kernel needs for proper initialization |
| `CONFIG_ARM_APPENDED_DTB` | `y` | DTB appended to zImage (standard for this platform) |
| `CONFIG_CMDLINE_FORCE` | `y` | U-Boot's cmdline is unreliable; compiled-in cmdline only |
| `CONFIG_INITRAMFS_SOURCE` | `"mini-initramfs.cpio"` | Initramfs MUST be embedded in kernel (see below) |

### Boot Method

- **Reliable: `fastboot flash boot` + normal power-on** -- Flash to the 8 MB boot partition, then power-cycle without holding mute sensor. U-Boot loads from partition and boots reliably.
- **Unreliable: `fastboot boot` (RAM boot)** -- Intermittent on this U-Boot. Works sometimes, fails silently other times. Avoid for testing.

### Initramfs Strategy: MUST Be Embedded in Kernel

**U-Boot does NOT load the ramdisk from the boot partition** during normal boot. The boot.img ramdisk section is ignored. Therefore:
- External ramdisk in boot.img: **DOES NOT WORK** (U-Boot ignores it)
- DTB initrd-start/end: **DOES NOT WORK** (U-Boot doesn't load ramdisk to RAM)
- `CONFIG_INITRAMFS_SOURCE`: **WORKS** (initramfs compiled into zImage)

A minimal initramfs (busybox + USB gadget setup, 549 KB compressed) is embedded in the kernel via `CONFIG_INITRAMFS_SOURCE="mini-initramfs.cpio"`. Total boot image: 6.7 MB, fits in 8 MB partition.

The full pmOS initramfs (8.4 MB) is too large to embed. Solution: use the minimal initramfs for initial boot, mount full rootfs from userdata partition.

## Boot Image Variants Tested
| Image | Size | Description | Result |
|-------|------|-------------|--------|
| `boot.img` | 13.5 MB | Full pmos initramfs, SMP=y | No output (SMP bug) |
| `boot-diag.img` | 5.9 MB | Minimal diag initramfs, SMP=y | No output (SMP bug) |
| `boot-builtin.img` | 8.8 MB | Full initramfs, built-in drivers, SMP=y | No output (SMP bug) |
| `boot-noramdisk.img` | 5.0 MB | Kernel+DTB only, SMP=y | No output (SMP bug) |
| `boot-test-nosmp-noatag.img` | 6.2 MB | SMP=n, ATAG=n, no ramdisk | Boots (HDMI+kernel panic) |
| `boot-atag-initramfs.img` | 6.7 MB | SMP=n, ATAG=y, external ramdisk | Boots (panic: ramdisk not found) |
| `boot-atag-embedded.img` | 6.7 MB | SMP=n, ATAG=y, embedded initramfs | **Testing...** |
| Various rebuild tests | 6.2 MB | SMP=n, ATAG=n, no ramdisk | No output (ATAG required) |

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
- `CONFIG_ARM_APPENDED_DTB=y` in defconfig (DTB concatenated after zImage)
- `CONFIG_ARM_ATAG_DTB_COMPAT=y` in defconfig (REQUIRED for boot, see Investigation Log)
- Rootfs flashes to `userdata` partition (13 GB) since `system` is only 1 GB
- Custom `raw2simg.py` for sparse image conversion (U-Boot only supports RAW+DONT_CARE chunks)

## Investigation Log & Key Findings

### Finding 1: SMP Is the Only Boot Blocker
`CONFIG_SMP=y` causes a silent deadlock during OMAP4 SMP startup. All other early boot failures were caused by SMP, not by other config options. With SMP disabled, the kernel boots reliably.

### Finding 2: ATAG_DTB_COMPAT Is REQUIRED (Corrected)
Earlier testing incorrectly concluded that `CONFIG_ARM_ATAG_DTB_COMPAT=y` caused crashes. This was wrong -- ATAG_DTB_COMPAT was always disabled alongside SMP, so the real culprit (SMP) was masked. When we later rebuilt with ATAG_DTB_COMPAT=y and SMP=n, the kernel booted fine (6.12.12 #2).

**With ATAG_DTB_COMPAT=n, kernel rebuilds do NOT boot.** The original working binary was a fluke or compiled under slightly different conditions. Multiple clean rebuilds with ATAG_DTB_COMPAT=n (identical config, verified via extract-ikconfig, only 43 bytes of timestamp differences) all failed to boot.

### Finding 3: U-Boot Ignores Boot.img Ramdisk on Partition Boot
U-Boot 2011.09 on the Nexus Q does NOT load the ramdisk section of the Android boot.img when booting from the boot partition. Only the kernel is loaded and executed. This means:
- External ramdisk in boot.img is useless for partition boot
- The initramfs must be embedded in the kernel via `CONFIG_INITRAMFS_SOURCE`
- CyanogenMod worked because it used `fastboot boot` (RAM boot) which DOES load the ramdisk, or because its U-Boot had ramdisk loading patched in

### Finding 4: Boot Method Reliability
- `fastboot flash boot` + cold power-cycle (unplug/replug): **RELIABLE**
- `fastboot boot` (RAM boot): **UNRELIABLE** (intermittent)
- `fastboot reboot`: **UNRELIABLE** (often re-enters fastboot instead of booting)
- Software reboot (panic=XX): Re-enters fastboot

### What Was NOT the Problem
- LZMA compression (GZIP kept for compatibility)
- `CONFIG_OMAP_RESET_CLOCKS` (disabled as precaution)
- `CONFIG_POWER_AVS_OMAP` (disabled as precaution)
- The device tree (omap4-steelhead.dts is correct)
- The boot image format (mkbootimg header v0, correct addresses)
- `CONFIG_ARM_ATAG_DTB_COMPAT` (was falsely suspected)

## Immediate Next Steps

### 1. Verify Embedded Initramfs Boot (IN PROGRESS)
`boot-atag-embedded.img` (6.7 MB) has the kernel with embedded mini-initramfs and ATAG_DTB_COMPAT=y. Currently being tested.

### 2. Get USB Networking / Telnet Access
The mini-initramfs sets up:
- USB gadget RNDIS on micro-USB (host IP 172.16.42.1, client 172.16.42.2)
- Telnet on 172.16.42.1:23
- Tries to mount rootfs from /dev/mmcblk0p13 (userdata)
- Falls back to interactive shell on HDMI console

### 3. Flash Full Rootfs to Userdata
Once we have shell access:
- Flash the full pmOS rootfs to userdata partition (mmcblk0p13)
- Or create a minimal rootfs with networking, then expand later

### 4. Re-enable SMP (Future)
Investigate proper OMAP4460 SMP startup with this U-Boot. May need:
- Custom SMP startup code that handles the undefined CPU1 state
- A secondary CPU holding pen implementation
- Patching the kernel's OMAP4 SMP code to reset CPU1 before bringing it online

## How to Reproduce a Working Boot

```bash
# 1. Build kernel (from /tmp/linux-6.12.12)
export ARCH=arm CROSS_COMPILE=/path/to/arm-none-linux-gnueabihf-
# Ensure .config has: SMP=n, ATAG_DTB_COMPAT=y, INITRAMFS_SOURCE="mini-initramfs.cpio"
make -j$(nproc) zImage dtbs

# 2. Create boot image (kernel + appended DTB, no external ramdisk)
cat arch/arm/boot/zImage arch/arm/boot/dts/ti/omap/omap4-steelhead.dtb > zImage-dtb
# Use Python mkbootimg script (see output/ directory) with:
#   base=0x80000000, kernel_offset=0x8000, ramdisk_size=0, pagesize=2048

# 3. Flash
fastboot flash boot output/boot-atag-embedded.img

# 4. Cold power-cycle (UNPLUG power, wait 5s, replug WITHOUT mute sensor)
# Do NOT use 'fastboot reboot' -- it re-enters fastboot
```

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
| `output/boot-atag-embedded.img` | 6.7 MB | **CURRENT** -- SMP=n, ATAG=y, embedded initramfs |
| `output/boot-test-nosmp-noatag.img` | 6.2 MB | Milestone: first boot (SMP=n, ATAG=n, no ramdisk) |
| `output/boot-atag-initramfs.img` | 6.7 MB | SMP=n, ATAG=y, external ramdisk (boots, no initramfs) |
| `output/boot.img` | 13.5 MB | Original full image (SMP=y, no boot) |
| `output/google-steelhead.img` | 720 MB | Rootfs (raw ext4) |
| `output/google-steelhead-sparse.img` | 530 MB | Rootfs (sparse, for flashing) |
| `output/milestone-kernel-boot-2026-02-27.png` | -- | Screenshot of first kernel boot |

## Ubuntu Transition Notes

If continuing on Ubuntu (instead of Windows):
1. USB/fastboot should work natively (`sudo apt install android-tools-adb android-tools-fastboot`)
2. Docker build should be faster (no QEMU overhead for Windows Docker)
3. Can also build natively with pmbootstrap if Alpine chroot works
4. Serial UART debugging is easier with USB-to-serial adapters on Linux
5. The rootfs (`google-steelhead-sparse.img`) is already flashed to the device's userdata partition -- only boot.img needs reflashing after kernel rebuilds
6. Consider using `pmbootstrap` natively on Ubuntu instead of Docker for faster iteration
