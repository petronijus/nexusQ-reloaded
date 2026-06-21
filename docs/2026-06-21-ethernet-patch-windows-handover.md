# Handover: finish the ethernet kernel-patch build on Windows

**Date:** 2026-06-21 · started on Linux (petronijus-PC), continue on **Windows**
**Goal:** build the patched kernel, flash it, and find out whether the Nexus Q
ethernet port actually works.

## TL;DR of the investigation (Linux session)

The old "Ethernet = dead hardware, do not revisit" verdict is **wrong**. Measured
live over the USB gadget net (172.16.42.1):

- 38.4 MHz PHY refclk running (`auxclk3_ck` → `hsusb1-phy`), VBUS regulator
  enabled, PHY reset (gpio_62) deasserted at boot, EHCI probes clean (no
  PHY/EPROBE/port-mode errors). **Config is correct, not the fault.**
- Real symptom: the SMSC **LAN9500A** (USB-ethernet `0424:9500` behind an SMSC
  USB3320 ULPI PHY on EHCI port 1) never enumerates.
- Why it couldn't be fixed from user space: OMAP `ehci-omap` lets its root hub
  autosuspend within ms when no device is attached → bus-suspend halts the
  controller and gates the port clocks. Register writes get dropped, the ULPI
  viewport returns garbage. Chicken-and-egg: idle port suspends, suspended port
  never sees a connect.

## What was done (committed to the repo)

- **`kernel/patches/0006-usb-ehci-omap-steelhead-keep-ethernet-port-alive-ulp.patch`**
  — in `ehci_hcd_omap_probe()`:
  1. `usb_disable_autosuspend(root_hub)` → keep the port powered + running so the
     soldered LAN9500A always gets a live port.
  2. Log the USB3320 ULPI VID/PID (healthy = `0x0424` / `0x0007`) + PORTSC via the
     INSNREG05 viewport during probe — a decisive PHY-alive test captured while
     the controller is guaranteed running.
  - Compiles clean (cross-built `ehci-omap.o`, GCC 13.3). Applies clean (`-p1`).
- **`pmos/linux-google-steelhead/APKBUILD`** — patch 0006 added to `source=` and
  `sha512sums` (SKIP placeholder; `pmbootstrap checksum` regenerates it).

## Build on Windows — steps

Requires **Docker Desktop** (WSL2 backend) + a bash shell (WSL or Git Bash).

1. `git pull` on `main` so you have patch 0006 + the APKBUILD change.
2. From the repo root run the established docker build:
   ```bash
   ./build-and-flash.sh
   ```
   (or directly: `docker build -t nexusq-builder .` then the `docker run --privileged …
   nexusq-builder /src/docker-build.sh` block — see build-and-flash.sh). Kernel
   compile ≈ 60–70 min.
3. **Known infra gotcha (hit on Linux):** the persistent pmbootstrap workdir
   volume can get a UID mismatch — host user (uid 1000) vs in-chroot `pmos`
   (uid 12345) — which makes:
   - the abuild signing key (`config_abuild/pmos@local-*.rsa`, mode 0600)
     unreadable → "failed to sign … Permission denied", and
   - `cache_distfiles` / chroot distfiles unwritable → "abuild-fetch: …lock:
     Permission denied" → `linux-google-steelhead: checksum failed`.
   On Windows the volume starts fresh, so this likely won't bite. **If it does**,
   fix perms in the volume (non-destructive), then re-run:
   ```bash
   docker run --rm -v nexusq-workdir:/w alpine:3.21 sh -c '
     chmod 0644 /w/config_abuild/pmos@local-*.rsa
     chmod 1777 /w/cache_distfiles /w/chroot_native/var/cache/distfiles'
   ```
   (Volume name is whatever `docker run -v <name>:/home/pmos/.local/var/pmbootstrap`
   uses; build-and-flash.sh uses `nexusq-workdir`.)

## Repackage + flash

- pmbootstrap's `boot.img` is ~14.6 MB (ramdisk U-Boot ignores). The boot
  partition ceiling is **~6.5 MB zImage+DTB**. Repackage with `make-bootimg.py`
  (zImage with appended DTB, no external ramdisk) — see HANDOFF.md §"Get USB
  Networking" / the manual recipe around lines 207-212, and existing
  `output/vmlinuz-r1` / `make-bootimg.py` usage.
- Put the Nexus Q in **fastboot** (cover the mute LED during power-on → solid
  red), connect the micro-USB service port.
- `fastboot flash boot <img>` (reversible by reflashing the old boot.img).
  **Do NOT** use `fastboot boot` (RAM boot) — unreliable on this U-Boot.
- Windows fastboot: use platform-tools `fastboot.exe`, or WSL with `usbipd-win`
  to pass the USB device into WSL.

## Verify the result

After it boots, over the gadget net (re-discover the `enx*` iface, re-add
172.16.42.2 — the gadget MAC/name changes each boot):
```bash
ssh root@172.16.42.1 'dmesg | grep -i steelhead; ip -br link; lsusb'
```
- **`steelhead: port1 ULPI VID=0x4:0x24 PID=0x0:0x7`** → PHY is alive; if `eth0`
  also appears, the hardware works (plug in the cable to PC, `udhcpc`/static, ping).
- **`ULPI … VID=0xffffffff` / timeout** → PHY unclocked/in reset → back to
  clock/reset wiring (but we measured those OK, so unlikely).
- If the ULPI ID is healthy but still no `eth0`, the fault is downstream of the
  PHY (LAN9500A power/dead) — that would finally justify a hardware verdict.

## State left on Linux

- Docker build was **stopped** mid-compile; `nexusq-build` container stopped.
  Nothing to clean up — Windows builds fresh.
- Patch + APKBUILD committed & pushed to `origin/main`.
