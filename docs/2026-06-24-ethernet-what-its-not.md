# Ethernet LAN9500A — what it is NOT (2026-06-24 live eliminations)

A focused day of **live measurement** (device reached over WiFi, bad boots caught in
the act, patch-0006 diag sampler read from `journalctl -b -k`, plus a controlled
`maxcpus=1` build). The point of this doc: record the hypotheses that are now
**falsified by hardware evidence**, so no future session re-chases them.

The failure signature on a bad cold boot (unchanged across everything below):
`eth0` absent, no `0424:9e00` on the USB bus, `PORTSC` CCS=0 / LineState SE0,
the LAN9500A never presents as a USB device.

## NOT the USB3320 ULPI PHY / its refclk
On a **bad** boot the patch-0006 sampler reads the PHY cleanly:
`ULPI VID=0x04:0x24` (SMSC **0x0424**), `PID=0x00:0x07`, `FUNC=0x45`, `OTG=0x66`
— `OTG=0x66` is exactly the value the patch-0008 commit recorded for *both* stock
and mainline. The PHY is alive, clocked, and in the same state as stock. The
problem is **downstream of the PHY**. (Rules out: dead/unclocked PHY, auxclk3
refclk timing, a PHY pre-reset settle being the cure.)

## NOT UHH_HOSTCONFIG reverting on runtime-resume
The stock-parity-auditor hypothesised mainline re-writes `UHH_HOSTCONFIG` on every
`usbhs_runtime_resume`, so SMP could race it back to `0x1c`. **Falsified against the
exact build source** (`build/linux-6.12.12/drivers/mfd/omap-usb-host.c`):
patch 0008 modifies `omap_usbhs_init()` (line 445), which `usbhs_omap_probe` calls
**once** (line 777), *before* `of_platform_populate` even creates the ehci child.
`usbhs_runtime_resume` contains **no HOSTCONFIG write** (only TLL/HSIC/UTMI clock
enables). So the connect bit is programmed write-once at probe in **both** stock and
our port — it cannot be "reverted on resume." (A reminder that auditor output is a
hypothesis to verify, not ground truth: [[verify-hypothesis-against-stock]].)

## NOT a sample-timing race / too-early ULPI soft reset
On a bad boot the diag sampler shows `PORTSC` CCS=0 and `ULPI DBG=0x0` (LineState
SE0) held flat across the **entire 0→900 ms** window. A healthy USB device pulls up
D+ within tens of ms of power+reset. The LAN9500A does **not connect late** — it
never connects at all. So "we struck the soft reset before the link settled and
missed a connect" is wrong; the chip is **hard-stuck**, not merely sampled early.
(Weakens the "1 ms settle window too short under SMP" idea — though the settle is
kept as real stock parity.)

## NOT recoverable warm — only a full cold boot fixes it
- `ehci-omap` unbind/bind: re-runs the whole probe (board reset + soft reset +
  sampler) → still bad.
- **Real** LAN9500A rail power-cycle: after unbind, drive `NENABLE` (gpio_1 =
  global gpio-513) physically high for 600 ms (rail off, verified via
  `/sys/kernel/debug/gpio`), back low, then bind → **0/5 recovered**.
- Only a cold power-cycle of the whole board recovers ethernet.
This means the LAN9500A latches into a no-connect state that its own enable/reset
rail (as we drive it) cannot clear — it needs the full-board cold power-on.

## NOT the second CPU core (SMP)  ← the headline elimination
Controlled experiment: the **identical** v1.2.0 kernel, changing exactly one
variable — `maxcpus=1` appended to the (forced) cmdline so CPU1 stays offline
through boot/probe. Same patches, same LZMA, same `cpuidle.off=1`, same settle, same
DTB (cpu@0 **and** cpu@1 present). Image `output/boot-maxcpus1-test.img`
(sha256 `3c7e059f…`).

Clean cold boots (confirmed power-down + fresh uptime each), `nproc=1`, `cpu1=0`:

| boot | result |
|------|--------|
| #1   | **BAD** (no eth0, CCS=0) |
| #2   | **BAD** (no eth0, CCS=0) |

**2/2 bad single-core.** If the second core were the cause, single-core would be
deterministic-good. It is not → **SMP is not the cause.** This is the same kernel
generation as the SMP build, only CPU1 held down, and it fails the same way.

## What remains in scope (next)
The bug is present on **both** SMP and single-core 1.2.0 kernels, yet ethernet was
reliable on **v1.1.0**. So the regression is something in the v1.1.0→v1.2.0 delta
that is in **both** 1.2.0 variants but absent from v1.1.0:

1. **The `udelay(1000)` ULPI pre-reset settle in patch 0006** — `udelay(1000)`
   count is **0 in v1.1.0, 3 in v1.2.0** (it was *added* in 1.2.0, ironically as an
   attempted fix). Prime suspect: it directly changed the eth bring-up path.
2. **`cpuidle.off=1`** on the cmdline (also new in 1.2.0).

Decisive next test (no new build needed): reflash the real **v1.1.0** image
(`output/nexusq-boot-v1.1.0.img` — no settle, no `cpuidle.off`) and cold-boot it
several times.
- v1.1.0 reliably good → a **real regression**; isolate settle vs cpuidle by
  reverting each.
- v1.1.0 also flaky → the bug predates 1.2.0; "deterministic single-core" was a
  small-sample artifact and the cause is a deeper power-on marginality.

## Side observation (separate, low priority)
An L3 NoC warning was seen at runtime: `omap_l3_noc … MASTER MPU TARGET L4CFG
(Read): … in User mode` — it fires from a **userspace** access (`do_work_pending`,
User mode), ~minutes after boot, unrelated to the USB-host probe timing. Not chased.
