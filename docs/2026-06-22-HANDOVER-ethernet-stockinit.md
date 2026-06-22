# HANDOVER — Nexus Q ethernet (LAN9500A), 2026-06-22

Continue seamlessly (e.g. after switching to Linux). Native `fastboot`/`adb` on
Linux means **no Zadig/WinUSB hassle** — the Windows-only driver dance is gone.

---
## ⭐ LATEST STATE (read this first) — UHH_HOSTCONFIG lead, build #8 ready

Builds #4–#7 all failed identically (eth0 absent, PORTSC CCS=0). #5 proved
GPIO/clock/reset match stock; #6 added vendor ehci-omap host-init (INSNREG01 +
soft-reset-before-add_hcd); #7 disabled OHCI (`&usbhsohci status=disabled`) +
added a kernel LineState/PORTSC diag. None worked — but #7's diag + a **live
register comparison against the booted stock** (read via `busybox devmem` over
adb — STRICT_DEVMEM blocks RAM not MMIO) cracked it open:

**Stock (eth0 UP) vs mainline #7 (broken), live USB3320/EHCI/USBHS regs:**
| reg | stock | mainline | note |
|---|---|---|---|
| ULPI OTG_CTRL | 0x66 | 0x66 | **VBUS identical → not VBUS** |
| ULPI DEBUG (LineState) | 0x00 (SE0) | 0x00 (SE0) | **SE0 is normal HS-idle**, not "no device" (earlier misread) |
| gpio_1 / gpio_62 | low / high | low / high | match |
| EHCI INSNREG01 | 0x00800080 | 0x00800080 | our threshold matches ✓ |
| EHCI PORTSC | **0x1005** (PP+PE+CCS) | **0x1000** (PP only) | connect vs none |
| **UHH_HOSTCONFIG (0x4A064040)** | **0x0000011C** | sets APP_START_CLK / leaves P1_CONNECT_STATUS default | **THE DIFF** |

Stock `0x11C` = INCR4/8/16 bursts + **P1_CONNECT_STATUS (bit 8) SET** +
**APP_START_CLK (bit 31) CLEAR**. Mainline `omap_usbhs_init` does the opposite
(`reg |= APP_START_CLK`; never sets P1_CONNECT_STATUS, which gates whether the
port reports connect → CCS stays 0). APP_START_CLK=1 is also the UHH auto-clock-
gating that made the USBHS go dark when idle (the devmem hangs we saw).

**THE TEST = kernel patch `0008-mfd-omap-usb-host-steelhead-UHH-HOSTCONFIG-connect.patch`**
(on `drivers/mfd/omap-usb-host.c`, in `omap_usbhs_init`): set P1_CONNECT_STATUS,
clear APP_START_CLK to match stock's 0x11C, and `dev_info` the before/after value
(so even on failure we finally learn mainline's actual HOSTCONFIG). pkgrel bumped
to 7 (= kernel **#8**). Build #8 was interrupted to switch to Linux.

### DO THIS FIRST on Linux
1. `git pull`. Build #8 (steps in "Build kernel" below; result is kernel **#8**).
   ⚠️ With the create_apks fix, the build now succeeds past the kernel and the
   pkgdir gets ZAPPED — get vmlinuz+dtb from the **.apk**, not pkgdir:
   `unzip/tar -xzf $WORK/packages/edge/armv7/linux-google-steelhead-6.12.12-r7.apk`
   → `boot/vmlinuz` + `boot/dtbs/omap4-steelhead.dtb`, then `cat vmlinuz dtb > z` and
   `make-bootimg.py z out.img - "<cmdline>"` (cmdline in `extract-and-repack.sh`).
   (A new, SEPARATE rootfs error — `device-google-steelhead post-install exit 127`
   — appears in Phase 9; it does NOT block the kernel. Worth fixing later.)
2. Flash to p9 (see below), reboot, check:
   `dmesg | grep -iE 'UHH_HOSTCONFIG|eth0|usb 1-1|0424|smsc95|steelhead: diag'`.
   - SUCCESS = `usb 1-1 ... 0424:9e00` + `eth0`.
   - Either way, the `steelhead: UHH_HOSTCONFIG before = 0x...` line tells us
     mainline's real value vs stock 0x11C → next move.
3. If still no eth0: the diff is confirmed at HOSTCONFIG; bisect bit8 vs bit31, or
   re-read the live stock regs with `scripts/ulpiread.c` (static-ARM mmap tool;
   cross-compile `arm-linux-gnueabihf-gcc -static -O2`) or `busybox devmem` on the
   stock-adb boot, and widen the reg comparison (USBCMD/USBSTS/CONFIGFLAG already
   match: stock USBCMD=0x10005 running, CONFIGFLAG=1).

Tooling added: `scripts/ulpiread.c` (ULPI viewport reader via /dev/mem).
Live stock read recipe: `fastboot boot output/stock-adb-boot.img` → adb →
`busybox devmem 0xADDR 32` (write form needs hex value: `printf '0x%x'` to avoid
the (1<<31) signed-overflow that busybox rejects).
---

## TL;DR — where we are

- **HARDWARE IS FINE.** Proven on HW: the stock Android 3.0 kernel enumerates the
  LAN9500A on this unit *right now* (`usb 1-1: ... idVendor=0424 idProduct=9e00`
  → `smsc95xx ... eth0`). The long-standing "dead HW" verdict was WRONG. The bug
  is 100% in our mainline software. Working stock dmesg saved:
  `reverse-eng/stock-dmesg-working-eth.txt`.
- **Root cause found** by reverse-engineering the stock `ehci-omap.c`
  (android-omap-steelhead-3.0): three steelhead host-init steps mainline lacks,
  all done BEFORE `usb_add_hcd()`.
- **Fix implemented** (consolidated into kernel patch 0006). **Kernel #6 was
  building** when this handover was written. Next action: finish the build,
  flash, test `eth0`.

## The fix (already in the tree — patch 0006, pkgrel 5)

`kernel/patches/0006-usb-ehci-omap-steelhead-keep-ethernet-port-alive-ulp.patch`
now does, in `ehci_hcd_omap_probe`, **before `usb_add_hcd()`** (the order is the
whole point — the vendor does it before the controller starts):

1. LAN9500A power-on-reset sequence: with auxclk3 (38.4 MHz) enabled,
   NENABLE(gpio_1) low → `udelay(100)` → NRESET(gpio_62) high → `udelay(2)`.
   (was the separate patch 0008, now folded in.)
2. **`INSNREG01` (0x94) OUT/IN burst thresholds = 0x80** — vendor
   `#ifdef CONFIG_MACH_STEELHEAD`, was entirely missing. NEW.
3. **ULPI Function-Control soft reset of the USB3320, BEFORE `usb_add_hcd()`** —
   the old 0006 did it *after* (wrong); a PHY reset after the port is started
   doesn't bring the device up. MOVED. NEW.

Diagnostic ULPI logging + root-hub keepalive stay AFTER `usb_add_hcd()`.
Patch 0008 was deleted (folded into 0006). DTS (patch 0003) already carries the
steelhead-ethernet enable/reset gpios + auxclk3 on `&usbhsehci` and the deleted
`hsusb1_power` regulator / bare nop-xceiv phy.

`has_smsc_ulpi_bug` (vendor flag) is a *resume-path* workaround only (writes ULPI
0x32/0x39 on resume error) — NOT relevant to our initial-connect failure, so not
implemented. Revisit only if connect works but suspend/resume is flaky.

## NEXT STEPS (on Linux)

### 1. Build kernel #6
```
# clear ccache first (build gotcha: stale ccache -> olddefconfig "unknown assembler")
docker run --rm -v nexusq-workdir:/work alpine:3.21 sh -c \
  'cd /work/cache_ccache_armv7 && find . -mindepth 1 -maxdepth 1 ! -name ccache.conf -exec rm -rf {} +'
# build (docker-build.sh). The create_apks perms failure is now FIXED (Phase 7a
# chowns $WORK/packages to the chroot abuild uid 12345), so a clean run produces
# linux-google-steelhead-*.apk and pmbootstrap install runs to completion.
docker run --rm --privileged -v "$PWD:/src:ro" -v nexusq-output:/tmp/output \
  -v nexusq-workdir:/home/pmos/.local/var/pmbootstrap \
  --name nexusq-build nexusq-builder /src/docker-build.sh 2>&1 | tee build-6.log
# OPTIONAL fast path: repack a kernel-only boot image straight from the pkgdir,
# skipping the rootfs build (quicker when only the kernel/DTB changed)
docker run --rm -v nexusq-workdir:/home/pmos/.local/var/pmbootstrap \
  -v "$PWD:/src:ro" -v "$PWD/output:/out" nexusq-builder /src/scripts/extract-and-repack.sh
```
NOTE: the Docker build volumes (`nexusq-workdir`, `nexusq-output`) and the
in-flight Windows build do NOT survive the reboot — rebuild from scratch on Linux
(image `nexusq-builder` rebuilds from the `Dockerfile`). `build-and-flash.sh`
step 1 builds the image. Confirm the result is kernel **#6** (KBUILD_BUILD_VERSION
= pkgrel+1 = 6): `python3 -c` on the vmlinuz banner, or check the DTB still has
only `cpu@0` and the new `steelhead-ethernet-*` props (see verify snippet below).

### 2. Flash to the boot partition (p9) and test
Device runs pmOS #5 now, reachable over the USB gadget (RNDIS) at
**172.16.42.1** (root pw in gitignored `.nexus_pw`; or WiFi 192.168.20.179 but
WiFi is unstable — use the gadget). On Linux the gadget iface autoconfigs or:
`sudo ip addr add 172.16.42.2/24 dev <iface>`.
```
NEXUS_PW=$(cat .nexus_pw)
# back up current p9 (#5) first, then dd the new image, read-back verify
scripts/nexus_put_chunked.py output/boot-ethernet-b7.img /tmp/boot6.img   # name from extract-and-repack
# on device: dd if=/tmp/boot6.img of=/dev/mmcblk0p9 bs=1M conv=fsync ; sync
# verify: head -c <imgsize> /dev/mmcblk0p9 | sha256sum  == local
# reboot: systemctl reboot ; wait ~110s
```
Then check the result:
```
uname -v                      # expect #6
dmesg | grep -iE 'smsc95|eth0|usb 1-1|LAN9500|power-on-reset sequenced|ULPI VID'
ls /sys/class/net/            # success = eth0 present
```
SUCCESS = `usb 1-1: new high speed USB device ... 0424:9e00` + `eth0` registers.

### 3. If #6 STILL fails (eth0 absent, PORTSC CCS=0, ULPI DBG=0/SE0)
Do NOT live-`devmem` the OMAP USBHS/EHCI regs (0x4A064xxx) — it bus-aborts and
hangs the device when the module is gated (it crashed the gadget this session;
recover by power-cycling without the mute sensor). Instead:
- Add a probe-time `dev_info` in 0006 dumping UHH_HOSTCONFIG/INSNREG01 (kernel-side
  reads are safe) and compare to the vendor.
- Re-confirm parity with the live stock again via the stock-image method (below)
  — re-read the working ULPI/PORTSC state by adding prints to a stock-kernel build,
  or diff more of the stock `ehci-omap.c` / `arch/arm/mach-omap2/usb-host*.c`
  (fetch from android.googlesource.com/kernel/omap branch
  `android-omap-steelhead-3.0-ics-aah`).
- Mainline USBHS core copies saved: `reverse-eng/mainline-omap-usb-host.c`,
  `mainline-omap-usb-tll.c` (UHH_HOSTCONFIG setup verified correct for ULPI mode).

## Stock-image diff method (reusable — see memory `stock-image-diff-method`)
Boot the stock kernel to prove HW / get a live reference:
- `output/stock-adb-boot.img` = stock kernel + ramdisk patched for insecure adb
  (root, no RSA auth). Built from `reverse-eng/kernel.bin` + a Python cpio rewrite
  of `default.prop` (ro.secure=0/ro.adb.secure=0/persist.sys.usb.config=adb) +
  `make-bootimg.py`.
- Enter fastboot: cover mute sensor at power-on (solid red). Software
  `reboot --reboot-argument=bootloader` does NOT work here.
- On Linux: `fastboot boot output/stock-adb-boot.img` (RAM, non-destructive — p9
  keeps pmOS) → `adb shell dmesg | grep eth`. Recover: `adb reboot`.

## Key files / artifacts
| path | what |
|---|---|
| `kernel/patches/0006-*ehci*.patch` | THE fix (consolidated, pkgrel 5) |
| `kernel/dts/omap4-steelhead.dts` + `0003` | ethernet enable/reset gpios + auxclk3 on usbhsehci |
| `reverse-eng/stock-dmesg-working-eth.txt` | proof HW works (stock dmesg) |
| `reverse-eng/mainline-omap-usb-host.c` | mainline USBHS core (for diffing) |
| `output/stock-adb-boot.img` | stock + insecure-adb (HW-vs-SW test) |
| `output/boot-eth-poreset-k5.img` (sha 73c8bd3d) | #5 (clk/seq fix, eth still broken) |
| `output/boot-kernel4-rollback.img` (sha d7794de9) | #4 rollback |
| `scripts/nexus_ssh.py`, `nexus_put_chunked.py` | device SSH/upload |

## Device facts
- USB gadget RNDIS: device 172.16.42.1, host 172.16.42.2/24. Gadget host IP needs
  re-applying after each device reboot (re-enumerates).
- Boot part = `/dev/mmcblk0p9` (8 MB). Flash from running pmOS via `dd` (no fastboot
  needed). `systemctl reboot` boots cleanly from p9.
- Root pw in `.nexus_pw` (gitignored). ed25519 key also authorized.
- Audio clock fix (#?) and single-core taint fix are already committed & live.

## Memory (persists across sessions/machines via ~/.claude)
`ethernet-bringup-and-gadget`, `stock-image-diff-method`, `nexus-connection`,
`proactive-no-flaky-schedulers`, `always-most-correct-path`.
