# Ethernet LAN9500A — 2026-06-24 deep dive: HW proven fine, it's OUR software

A long session that converted "ethernet is intermittent / maybe dead HW" into a
**proven, bounded software bug**. Headline:

> **The hardware is fine. The STOCK Android kernel enumerates the LAN9500A on this
> exact unit, today.** Our mainline port does not. So the bug is 100% in our
> software — exactly as Petr insisted ("all boot errors are ours"). Believe it.

The earlier doc `docs/2026-06-24-ethernet-what-its-not.md` covers the first round
of eliminations (PHY alive, UHH write-once, not a sample-race, SMP ruled out,
settle/cpuidle ruled out). This doc adds the decisive proofs and the new
eliminations.

## THE decisive test: boot stock, watch the link

`fastboot boot output/stock-boot.img` (the factory `boot.img` from
`~/Downloads/tungsten-ian67k-factory-d766e5f1.zip`, RAM-booted, non-destructive —
our pmOS on p9 untouched). The RJ45 is cabled to the PC's `enp7s0`. Result:

```
enp7s0 CARRIER=1  from t+3s, held stable for 90s
```

Stock enumerated the LAN9500A and brought the link up, immediately and stably, on
the same physical device, same day, same cable. **HW is sound. It is our kernel.**
(Stock = `reverse-eng/vmlinux.bin` = Linux 3.0.8 SMP, factory `ian67k`.)

This also retires the "maybe it physically degraded today" idea I (wrongly) raised:
the exact frozen working `#8` binary (`nexusq-boot-v1.1.0.img`, sha `8c7b4f75`,
which passed 660 MB / 0% loss on 2026-06-22) was re-flashed with its matching
modules and **clean-booted (0 vermagic errors) → still no eth0.** Same software
that worked, fails now; stock works now. Therefore: not HW, not build-drift, not
the kernel image content per se — a software/behaviour gap vs stock.

## Failure signature (precise, current)

On a failing boot (every one of our kernels, today):
- `ehci-omap 4a064c00.ehci` binds; `usbhs_omap`, `usbhs_tll` bind; `ohci` disabled
  (correct). EHCI root hub = 3 ports.
- **Only the two root hubs on USB** (EHCI usb1, MUSB usb2). **No `0424:9e00`** on
  the bus, under any name (interface would be `eth0`, confirmed from history).
- ULPI PHY is alive: `VID=0x0424`, `FUNC=0x45 OTG=0x66 IFC=0x18`.
- Port powered: `PORTSC=0x00501000` = PP=1 + wake-on-connect/over-current armed,
  **CCS=0, LineState SE0**. The LAN9500A never asserts connect (never pulls D+).

So: PHY perfectly configured, port powered and armed, and the downstream LAN9500A
simply never connects.

## Eliminated this session (with proof)

1. **ULPI PHY register configuration is NOT the cause.** A diagnostic build read
   the registers back inside the `.reset` hook after programming them:
   `omap_ehci_reset port1 readback FUNC=0x45 IFC=0x18 OTG=0x66 VID=0x4:0x24`.
   So the full stock ULPI state (FUNC=0x45, IFC=0x18, OTG=0x66 — the auditor's
   stock values) IS written and held, and the LAN9500A STILL does not connect.
   The register *values* are not the gap. (`IFC=0x18` is our written value, not a
   default, proving the writes stuck.) Note: `OTG=0x66` — the host Dp/Dm
   pull-downs — is also the USB3320's **reset default**, so the pull-downs are
   present even without us. (build `boot-eth-diag2.img`, sha `9f6e6051`.)

2. **The write-placement matters but doesn't fix it.** ULPI viewport (INSNREG05)
   writes only take effect **after `ehci_setup()`** has set up the controller;
   issuing them in probe *before* `usb_add_hcd()` silently drops them. The
   stock-faithful place is the EHCI `.reset` hook (`omap_ehci_reset` →
   `ehci_setup()` then the ULPI burst), which is where stock does it (VA
   `0xC0331BDC`). We implemented that (`.reset` override via
   `ehci_driver_overrides.reset`, builds `boot-eth-resethook.img` `fdb9aee7`,
   `boot-eth-diag2.img`). Correct and more faithful — but the LAN9500A still
   doesn't connect. (Kept as the right structure; not committed yet.)

3. **PHY and LAN9500A SHARE NRESET (gpio_62).** Tried reordering: hold NRESET,
   program the PHY, then release NRESET (so the chip wakes into a configured host).
   It self-diagnosed: with NRESET held, every ULPI read/write **timed out**
   (`readback FUNC/IFC/OTG/VID = 0xffffff92 = -ETIMEDOUT`), the `.reset` hook ran
   ~100 s (hung-task warnings), because **the PHY is held in reset too**. So
   gpio_62 resets BOTH — the DTS comment was right — and the reorder is physically
   impossible. (build `boot-eth-resetorder.img` `b506d290`; reverted.)

4. (From the first round, still holds) Not the PHY being dead, not UHH revert, not
   a sample-timing race, not SMP, not the `udelay(1000)` settle, not `cpuidle.off`,
   not naming (it was always `eth0`), not a long-power-off/POR thing.

## What is established (mechanisms, true)

- HW fine; stock enumerates today.
- It's our software.
- PHY config (FUNC/IFC/OTG) is correct/identical to stock → not the gap.
- PHY + LAN9500A share NRESET (gpio_62); can't program PHY while chip is held in
  reset.
- The `.reset`-hook (post-`ehci_setup`) is the only place ULPI writes take effect.

## Remaining hypotheses (ranked, for next session)

1. **Stock live register read (DO THIS — option A).** Repack `stock-boot.img` with
   an insecure-adb ramdisk, `fastboot boot` it, `adb shell` and read the live
   EHCI op-registers (PORTSC), INSNREG, UHH_HOSTCONFIG and the ULPI regs **while
   eth works on stock**, then diff against our failing state. This is the only path
   to a hard ground-truth diff instead of guessing. Risk: userspace register reads
   may bus-error if a clock is gated — but on stock eth works, so USBHS clocks are
   on. Read via `/dev/mem` (busybox devmem) or debugfs.
2. **NRESET timing / phase.** Stock releases NRESET in board init (machine init,
   well before the EHCI driver powers the port); we release it inside the ehci
   probe, ~ms before `usb_add_hcd`. Even though a USB pull-up is static, the
   LAN9500A may need to be out of reset and settled *before* the port/PHY come up
   in a way our late, tightly-coupled sequence doesn't give it. Test: release
   NRESET much earlier (e.g. from the `usbhs_omap` parent probe) so the chip has
   time before port power. (Reset is shared with the PHY, so the PHY also comes up
   early — fine, we configure it later in `.reset`.)
3. **Vendor ULPI regs 0x32 / 0x39.** Stock writes these (×20) in its hub/port-reset
   handler; we never write them. They're written on port reset, which only happens
   after a connect — so probably not the *initial* connect, but worth confirming
   from the live stock read.
4. **A port-reset "kick"** after PHY config to re-trigger the LAN9500A.

## Build/process notes

- All builds are `scripts/build-kernel-boot.sh` (kernel-only, warm volume), flashed
  with `fastboot flash boot`. Device modules on rootfs are SMP (`6.12.12`,
  vermagic `6.12.12 SMP ...`); originals backed up on-device as
  `6.12.12.smp-working` / `6.12.12.nonsmp-bak`. `/root/modules-backup-1.2.0.tar.gz`
  is a full backup.
- **Device access:** WiFi (brcmfmac) is flaky for bulk and dies; the **USB gadget
  (172.16.42.1)** is reliable — but the host enx* iface RENAMES every boot, so
  pick the one with `LOWER_UP` (carrier) and assign `172.16.42.2/24` to *that* one
  (a stale enx holding the IP was the cause of repeated "gadget unreachable").
  Host sudo via `op-cache "sudo petronijus-PC"` → `sudo -S`.
- **Never test on a vermagic-mismatched boot** ([[experiments-need-clean-system]]):
  flashing an old-release boot.img while the rootfs has different-vermagic modules
  gives a degraded, unreachable boot and a worthless result. Build a matching
  kernel, or install matching modules first.
- Stock boot: `fastboot boot output/stock-boot.img` (RAM, non-destructive). Read
  the result via `enp7s0` carrier (cable to PC) — no adb needed just to prove HW.
- `kernel/patches/0006-*.patch` reverted to committed (v1.2.0) state; none of the
  experimental kernels are committed. The `.reset`-hook + full-ULPI work lives in
  the scratch regen at the path in the session, re-derive from this doc.

## UPDATE (same session, later): stock-adb live diff DONE; more eliminations

Built a **working stock diagnostic tool**: `output/stock-adb-boot.img` = stock
factory `boot.img` repacked with an insecure-root-adb ramdisk (busybox shell +
musl loader pulled from the pmOS device, since the stock ramdisk has no shell and
stock needs its /system we don't have). `fastboot boot output/stock-adb-boot.img`
→ `adb` root shell on the **working** stock kernel. Recreate: see
`scratchpad/.../stock/` (default.prop ro.secure=0, adb in `on init`, blocking
mounts disabled, `/system/bin/sh`=busybox). Reference saved:
`reverse-eng/stock-eth-working-state-2026-06-24.txt`.

**Stock live state (ethernet WORKING):**
- cmdline: `console=ttyFIQ0 ... smsc95xx.mac_addr=f8:8f:ca:20:3e:97 ...`
- EHCI = platform `ehci-omap.0` (3.0.8), structural=0x1313, capability=0x20016,
  command=0x10005 (RUN).
- `port:1 status 001005 ... PE CONNECT` (**CCS=1**), LAN9500A `Bus01 Dev2
  0424:9e00` bound by smsc95xx → `eth0`.
- Timing: EHCI start `[2.030s]` → `usb 1-1: new high speed USB device` `[2.375s]`
  → eth0 registered `[2.628s]`.

**Diff vs ours:** identical PHY config; our `port:1 PORTSC=0x501000` (PP=1, CCS=0)
vs stock `0x1005` (PP=1, **CCS=1**). Same HW. So a host/USBHS-level difference
makes stock see the connect and us not — NOT the PHY registers (ruled out),
NOT register-write placement, NOT reorder.

**NRESET-timing RULED OUT.** Hypothesis: stock releases NRESET early (board init,
before EHCI start) so the chip is booted before the port powers; we release it in
the ehci probe ~ms before `usb_add_hcd`. Tested a **2 s settle** after NRESET
release, before port power (`boot-eth-timing.img`, sha `feac3bd6`). The chip had
2 s to boot before the port came up → **still no connect** (CCS=0). So the
NRESET-to-port-power gap is not the cause.

**Could not read our EHCI op-registers** to diff structural/capability/command:
the 6.12 ehci debugfs `registers` file is config-gated/empty, and stock `/dev/mem`
is STRICT_DEVMEM-blocked. Next session: enable the ehci debugfs (or add a
dev_info dump of HCSPARAMS/HCCPARAMS/CMD/STS + UHH_HOSTCONFIG + TLL config in our
probe) and diff against stock's `0x1313 / 0x20016 / 0x10005`. The remaining gap is
at the **OMAP USBHS (UHH/TLL) or EHCI-core** level, not the PHY or the chip.

### Eliminations summary (this whole session)
NOT: dead HW, physical, build-drift, SMP, settle, cpuidle, naming, long-power-off,
UHH-revert, sample-race, PHY-dead, **ULPI register values** (match stock),
**.reset write-placement**, **NRESET reorder** (shared gpio_62), **NRESET timing**.
IS: a host/USBHS-level software difference vs stock — still open. Stock-adb tool +
reference now exist to nail it.
