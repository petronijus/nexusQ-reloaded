# Ethernet bring-up — progress & handover (2026-06-22)

Continues `docs/2026-06-21-ethernet-patch-windows-handover.md`. Goal: get the
soldered **SMSC LAN9500A** USB-Ethernet (EHCI port 1, behind an **SMSC USB3320
ULPI PHY**) to enumerate. **Status: not yet enumerating, but real progress and a
clear root-cause chain — NOT a dead-hardware verdict.** Step-by-step, comparing
against the original Android factory image.

## What is now WORKING / confirmed

- **Kernel build + flash pipeline on Windows** (Docker Desktop + pmbootstrap).
  Build gotchas found & fixed: `boot_size` must be **512** (was 256, newer
  pmbootstrap rejects it) in `docker-build.sh`; abuild **signing key** perms
  (`config_abuild/pmos@local-*.rsa` must be 0644 for the in-chroot uid); the
  apk-packaging step's `/home/pmos/packages` perms failure is now **FIXED** —
  same uid-12345 class of bug as the signing key: `$WORK/packages` on the reused
  work volume was owned by the container `pmos` (uid 1000) while abuild in the
  chroot runs as uid 12345, so it could not write the `.apk`. `docker-build.sh`
  Phase 7a chowns `$WORK/packages` to 12345 before the build, so create_apks
  succeeds and `pmbootstrap install` runs. As a fast path the
  **compiled `vmlinuz` + dtb can still be taken straight from the build chroot**
  (`chroot_buildroot_armv7/home/pmos/build/pkg/linux-google-steelhead/boot/`)
  and repacked — no full rootfs build needed.
  - **CRITICAL build gotcha:** a *populated* ccache makes the kernel `olddefconfig`
    fail with `cc: unknown assembler invoked` / "Sorry, this assembler is not
    supported". **Clear `cache_ccache_*` before each kernel build** (empty ccache
    = clean build, ~40 min). Nuking chroots alone does NOT fix it.
- **USB gadget RNDIS now works on Windows AND Linux** (was Code 28 on Windows).
  Fix is persistent in `scripts/device-nexus-diag.sh` (deployed to the device's
  `/usr/local/bin/nexus-diag.sh`): RNDIS function class **e0/01/03** + device IAD
  0xEF/02/01 + Microsoft OS descriptors + fixed MACs. Windows side: one-time
  elevated `scripts/install-gadget-rndis.ps1` (clears `usbflags` cache, removes
  device, rescans, assigns 172.16.42.2). adb/fastboot installed via winget.
- **Reliable tooling for next time:** `scripts/nexus_ssh.py` (paramiko SSH/scp,
  password via `$NEXUS_PW` env — see HANDOFF.md; native ssh fails on the
  1Password agent when backgrounded; always
  `export MSYS_NO_PATHCONV=1` for remote `/...` paths). WiFi (192.168.20.179)
  bulk *upload* is broken (BCM4330) — transfer over the **USB gadget net**
  (172.16.42.1). `scripts/device-ulpi.sh` = ULPI register read/write via
  `/usr/local/bin/devmem` through the EHCI INSNREG05 viewport.

## Ethernet — what we proved today (the diagnostic chain)

The patched kernel (`kernel/patches/0006-...`, built as **#3 / r2**, flashed to
`/dev/mmcblk0p9`) logs the live ULPI state at probe. Booted reading:

```
steelhead: port1 ULPI VID=0x4:0x24 PID=0x0:0x7 FUNC=0x45 OTG=0x66 DBG=0x0 PORTSC=00001000
```

Decoded — everything on the PHY side is CORRECT:
- **USB3320 PHY alive**: VID 0x0424 / PID 0x0007 (reads via INSNREG05 viewport).
- **Power**: `hsusb1_power` 3.3V rail enabled, `gpio_1` (NENABLE) driven low and —
  importantly — **gpio_1 IS drivable high** (the old 2026-06-10 "clamped low =
  dead HW" reading was an artifact of the always-on regulator holding it low,
  not damage). PHY refclk `auxclk3` = 38.4 MHz. PHY reset `gpio_62` deasserted.
- **FUNC=0x45**: SuspendM=1 (awake), XcvrSel=FS, OpMode=normal, Reset=0.
- **OTG=0x66**: DrvVbus=1 + DrvVbusExt=1 (PHY driving VBUS) + Dp/Dm pulldowns
  (host mode) — set at the brief powered window.
- **DBG=0x00 = SE0 line state**: downstream LAN9500A is NOT pulling D+ → not
  signalling connect. No `2-1` device on bus 2, no eth0, nothing in `lsusb`.

### Two root causes identified (one fixed in code, one still open)

1. **Missing ULPI Function-Control soft reset (FIXED in patch).** The vendor
   Android `ehci-omap.c` does `omap_ehci_soft_phy_reset()` (writes
   ULPI_FUNC_CTRL_RESET via INSNREG05) at probe; mainline dropped it when PHY
   handling moved to the generic framework, so an external ULPI PHY modelled as
   usb-nop-xceiv never gets its transceiver soft-reset. Re-added in patch 0006
   (built as r2, confirmed running — FUNC/OTG now read sane post-reset values).
   This did NOT by itself make the LAN9500A enumerate.

2. **EHCI port power does not stay on (OPEN — this is the current blocker).**
   After probe the EHCI root hub autosuspends → `ehci_bus_suspend()` halts the
   controller (USBCMD.RS=0) and the **OMAP gates the EHCI functional clock**, so
   PORTSC drops to 0 (port unpowered) and even raw `devmem` writes to
   USBCMD/PORTSC are silently dropped. The LAN9500A loses its USB session before
   it can connect. Confirmed from userspace that this is **un-fixable from user
   space**: forcing the whole PM chain (`target-module`/`usbhshost`/`ehci`/`usb2`)
   to `power/control=on` (runtime_status=active) still leaves USBCMD.RS=0 / port
   off — a suspended EHCI bus only resumes via the HCD, not via sysfs. The patch's
   original `usb_disable_autosuspend()` is overridden by pmOS userspace
   (`/lib/udev/rules.d/60-autosuspend.rules`, hwdb `ID_AUTOSUSPEND`).

## Ready for tomorrow (next step, untested)

- **`kernel/patches/0006-...` has been updated** (NOT yet built/flashed) to also
  **pin the root hub runtime-active**: `pm_runtime_forbid()` +
  `pm_runtime_get_noresume()` on `hcd->self.root_hub->dev` after `usb_add_hcd()`.
  Holding a PM usage_count > 0 should make the USB core never autosuspend the
  root hub (un-overridable by udev's control=auto), keeping the functional clock
  on and the port powered so the LAN9500A gets a continuous session + the hub
  keeps polling for it. Build = bump `pkgrel` 2→3, **clear ccache**, build,
  repack `vmlinuz`+dtb, `dd` to p9, reboot.
- Also deployed (userspace, harmless if the kernel fix supersedes it):
  `/etc/udev/rules.d/99-steelhead-ehci-keepalive.rules` forcing the EHCI
  control=on at device-add (kept usb2 active but, as expected, could not revive
  an already-suspended bus).
- If, with the port held powered continuously, the LAN9500A *still* shows SE0:
  next reverse-engineer the Android `smsc95xx` / `lan9500` init and the exact
  Android boot ULPI/OTG sequence (DrvVbus timing, any extra reset) from
  `reverse-eng/vmlinux.bin` (decompressed Android kernel) before considering any
  hardware conclusion.

## Tomorrow = ONE combined kernel rebuild (per user)

Bundle the ethernet fix with the still-pending **B7 boot-warnings batch** (the
other Todoist task `6gwFP59X24QV9CF3`, documented in
`docs/2026-06-19-boot-warnings-followup.md`) so we rebuild the kernel only once:

- **Ethernet** (this doc): patch 0006 v3 (ULPI soft reset + pin root hub) — ready.
- **B7**: new patch `0007` for `drivers/clk/clk-composite.c` —
  `round_rate` fallback in the no-mux branch of `clk_composite_determine_rate()`
  so `dpll_per_m3x2_ck` can be set to 61.44 MHz → `auxclk1_ck` 12.288 MHz (TAS5713
  MCLK). Add to `pmos/linux-google-steelhead/APKBUILD` source + sha512sums.
- **B1/B2/B3/B6**: DTS edits in `kernel/dts/omap4-steelhead.dts` (gptimer1 ti-sysc,
  drop `cpu@1`, SRAM I688 barrier pool, HDMI EDID/connector).
- **B11**: `CONFIG_SND_ALOOP=y` already in defconfig (will take effect on rebuild).
- Bump `pkgrel` 2→3 (one `uname` marker for the combined build). Build flow as
  above (clear ccache!), one boot.img repack + `dd` to p9, one reboot to verify
  all of it together.

## Device state left running
- Kernel **#3** (soft-reset r2) on p9; WiFi + USB-gadget(RNDIS) both up; gadget
  fix + keepalive udev rule persistent. p9 backup of the original #2 kernel is on
  the PC (`output/p9-backup-pre-ethernet.img`) for fastboot recovery.
