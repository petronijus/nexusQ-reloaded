# Nexus Q — bringing up the second CPU core (OMAP4460 SMP)

**Date:** 2026-06-19
**Question:** SMP is disabled (PLAN #10) — `CONFIG_SMP=y` silently deadlocks. How do we
actually get the second Cortex-A9 online, and what's reusable?
**Answer (TL;DR):** The Nexus Q is **`OMAP4460 ES1.1 HS` (High Security)** — verified on the
device. On HS silicon, releasing/starting CPU1 goes through **secure SMC calls into the ROM/PPA**,
not direct register writes. The stock U-Boot 2011.09 leaves CPU1 (and the secure SMP handshake) in
a state mainline's secure path doesn't match → CPU1 never reaches its startup vector, the SMC
blocks in secure world, **no console output** (the silent hang). It *is* solvable — the device
shipped dual-core Android 4.0, so the bootloader's PPA + secure SMP API work — but it's the
riskiest item on the roadmap. **Constraint (2026-06-19): no soldering — UART serial console is
off the table.** So debugging must be software-only: **`ramoops`/pstore** to capture the silent
hang's last log line across a reset (the device's AOSP kernel already used Android `ram_console`
at a fixed RAM address, so this technique is known-good here), plus a **blind "force-reset-CPU1"
experiment** judged purely by boot/no-boot over HDMI+SSH. Without UART the odds drop and iteration
is slow; realistic payoff is ~2× only for multi-threaded loads, so this stays a low-priority,
high-risk item — reasonable to shelve.

---

## 1. The decisive fact: HS, not GP

```
# on 192.168.20.179
/sys/devices/soc0/family  = OMAP4
/sys/devices/soc0/machine = OMAP4460
/sys/devices/soc0/type    = HS          ← High Security
dmesg: "OMAP4460 ES1.1"
/sys/devices/system/cpu/possible = 0    ← only CPU0 (SMP=n)
```

This single bit decides the whole difficulty. In `arch/arm/mach-omap2/omap-smp.c`, every
AuxCoreBoot access branches on `omap_secure_apis_support()`:

| | GP (general purpose) | **HS (our Nexus Q)** |
|---|---|---|
| release CPU1 (AUX_CORE_BOOT_0) | `writel_relaxed(..., wakeupgen_base + OMAP_AUX_CORE_BOOT_0)` | **`omap_modify_auxcoreboot0()` → SMC into secure ROM/PPA** |
| set startup addr (AUX_CORE_BOOT_1) | direct `writel_relaxed` | **`omap_auxcoreboot_addr()` → SMC** |
| read release state | direct `readl_relaxed` | **`omap_read_auxcoreboot0()` → SMC** |

So on the Nexus Q the CPU1 bring-up is mediated by the **secure monitor / PPA** the bootchain
installed — we cannot just poke registers.

## 2. How OMAP4 SMP bring-up actually works (mainline)

`omap4_smp_prepare_cpus()` (omap-smp.c):
1. selects **`omap446x_cfg`**: `cpu1_rstctrl_pa = 0x4824380c` (PRCM_MPU local PRM CPU1 reset),
   `startup_addr = omap4460_secondary_startup`.
2. `scu_enable()`, then `omap4_smp_maybe_reset_cpu1()` (see §3), then writes the secondary
   startup address to **AUX_CORE_BOOT_1** (via SMC on HS).

`omap4_boot_secondary()`:
3. sets the **AUX_CORE_BOOT_0** release bit (SMC on HS); forces the `mpu1_clkdm` clockdomain awake
   (SGIs can't wake CPU1 from low power — OMAP4 limitation); sends the wakeup.
4. CPU1, sitting in **ROM code in WFE**, reads AUX_CORE_BOOT_1 and jumps to
   `omap4460_secondary_startup`.

OMAP4460-specific extras:
- **`omap4460_secondary_startup`** (not the 4430 one) and the **CA9 r2pX GIC ROM-bug workaround**
  (`PM_OMAP4_ROM_SMP_BOOT_ERRATUM_GICD`): before waking CPU1, CPU0 disables the GIC distributor;
  CPU1 re-enables it on its wake path. (OMAP4460 ROM is built against the r1pX GIC; 4470 fixed it.)

## 3. Why it hangs *here* — and the one escape hatch that doesn't fire

`omap4_smp_maybe_reset_cpu1()` is the kernel's existing "CPU1 in a bad state" handler, but it is
deliberately conservative (commit `351b7c490700`, *"ARM: omap2+: Revert omap-smp.c changes
resetting CPU1 during boot"* — an unconditional reset broke boards running a secure OS on CPU1):

- it resets CPU1 **only if** CPU1 is *not released* **and** its parked startup address is invalid /
  points **inside the booting kernel** (the kexec / suspend-resume case).
- the reset itself is a **direct** `writel 1 → 0` to `cpu1_rstctrl` (0x4824380c) — **non-secure**,
  so Linux *can* reset CPU1 even on HS.

On a fresh U-Boot boot, CPU1 is parked **wherever U-Boot left it** (not inside our kernel image),
so `needs_reset` stays false and this handler **returns without doing anything**. CPU1 is then
never re-parked into the ROM WFE loop, the SMC "release + SEV" doesn't deliver it to
`omap4460_secondary_startup`, and the secondary bring-up blocks. Because the failing step is an
**SMC into secure world**, a bad handshake can fault/hang there with no kernel console output →
the **silent deadlock** the HANDOFF describes.

## 4. What makes it solvable (the reusable pieces)

- **The device shipped dual-core Android 4.0 (ICS).** So the bootloader's **PPA (Primary
  Protected Application)** and the secure SMC SMP API are present and *work* with this U-Boot. The
  gap is purely mainline ↔ this PPA. The original **Google `steelhead`/`tungsten` AOSP kernel**
  (TI OMAP4 `mach-omap2`) holds the exact secure-SMP service IDs + CPU1 handling that succeed on
  this bootloader — the concrete reference to port from.
- **Sister SoC: Galaxy Nexus `maguro`/`toro` = same OMAP4460 HS.** Mainlined in postmarketOS
  (pmaports #175). Whatever SMP handling exists there is directly portable (same secure model).
  Caveat: SMP is *not* confirmed working on mainline maguro either — OMAP4 **HS** SMP on mainline
  is a known-hard, often-unsolved problem. Sets realistic expectations.
- **CPU1 reset is non-secure-accessible** (0x4824380c) → we can force-re-park CPU1 from Linux
  without touching secure world. This is the cheapest experiment.

## 5. Concrete plan — software-only (no soldering, UART ruled out)

**Constraint:** no opening the device, no UART. The failure is a silent deadlock, so the whole
game is *getting observability without serial*. Two software channels exist:

- **HDMI framebuffer console** (`console=tty0`, already on the cmdline). Catches hangs *after* DSS
  init, but the SMP bring-up runs in `smp_prepare_cpus` very early — likely **before** the
  framebuffer is up — so it probably won't show the SMP hang. Useful as a secondary check only.
- **`ramoops` / pstore-ram** — the real tool. Reserve a fixed RAM region (DT `ramoops` node +
  `CONFIG_PSTORE`, `CONFIG_PSTORE_RAM`), route the kernel log to it. After the SMP=y hang, reset
  the board, boot the known-good SMP=n image, and read `/sys/fs/pstore/dmesg-ramoops-0` — the last
  line printed before the deadlock pinpoints where it died. **Precedent: the Nexus Q's own AOSP
  kernel used Android `ram_console` at a fixed address**, so RAM-persisted logging is known to
  survive this platform's reset path. (It relies on DRAM contents surviving the reset; a watchdog/
  warm reset preserves them, a full unplug power-cycle does not — so trigger resets via watchdog,
  not by pulling power.)

Steps:
1. **Try the cheap blind experiment first — force-reset CPU1.** Small patch to
   `omap4_smp_prepare_cpus`: *unconditionally* pulse `cpu1_rstctrl` (`writel 1; readl; writel 0`)
   before the AuxCoreBoot writes, re-parking CPU1 into the ROM WFE loop regardless of U-Boot's
   state. Non-secure, low risk. Build `CONFIG_SMP=y` + this patch, flash boot, observe purely by
   outcome: **HDMI shows weston + `nproc == 2`** → win; **silent hang** → go to step 2. Zero
   instrumentation needed; this might Just Work.
2. **Add `ramoops`** (DT + pstore config) and a printk right before the `omap_auxcoreboot_addr()`
   SMC and after each bring-up milestone. Boot SMP=y, let it hang, warm-reset, boot SMP=n, read the
   pstore buffer to see the last milestone reached. Iterate.
3. **Once located**: if it's the secure SMC, compare service IDs against the steelhead AOSP
   `omap-secure` and align mainline's IDs to the bootloader's PPA; if it's CPU1 placement, refine
   the reset/holding-pen. (Slow without serial, but pstore gives enough signal.)
4. **Validate**: `/sys/devices/system/cpu/possible = 0-1`, `nproc == 2`, **no boot regression**
   (SMP is the historical #1 boot blocker; watch the ≤6.5 MB boot-image ceiling — headsmp adds
   code), stable across several cold boots.
5. Keep `CONFIG_SMP=n` as the shipping default until proven.

**Honest call:** without UART, step 1 is a cheap gamble worth one afternoon; if it hangs, the
pstore loop (step 2+) is real work for a ~2×-on-multithread-only payoff. Shelving SMP is a
legitimate decision — the device meets its purpose single-core.

## 6. Risks / caveats

- **Silent failure mode + no UART** (no soldering) → observability is limited to `ramoops`
  post-mortem and binary boot/no-boot. Slower iteration, lower odds than with serial.
- **Secure world**: a wrong SMC can hang or wedge the secure monitor. The device is *unbrickable*
  (bootloader partition never touched), so it's always recoverable via a power-cycle.
- **Boot reliability + image size**: SMP is the historical root cause of no-boot; re-enabling it
  risks the already-flaky boot (~1 in 3). Test with the embedded-initramfs path and keep an SMP=n
  fallback image.
- **Payoff is conditional**: today's workloads (weston/pixman, ALSA, nexusqd) are largely
  single-threaded, so the win is ~2× *only* for multi-threaded loads — the future SGX GPU
  userspace + compositor, audio DSP, on-device builds. This is correctly filed under "long-term,
  risky" — do it last, with UART in hand.

## 7. Primary sources

- `arch/arm/mach-omap2/omap-smp.c` — `omap4_boot_secondary`, `omap4_smp_maybe_reset_cpu1`,
  `omap446x_cfg` (cpu1_rstctrl_pa 0x4824380c, omap4460_secondary_startup), the CA9 r2pX GICD
  erratum, GP-vs-HS AuxCoreBoot branches.
- Commit `351b7c490700` *"ARM: omap2+: Revert omap-smp.c changes resetting CPU1 during boot"* —
  why CPU1 reset is conditional (secure-OS-on-CPU1 regression).
- `arch/arm/mach-omap2/omap-secure.c/.h` — `omap_secure_dispatcher`, `omap_smc1/2`,
  `OMAP4_PPA_SERVICE_0` (0x21): the secure SMC plumbing the HS path rides on.
- OMAP4460 cpuidle/SMP CA9 r2pX GIC ROM-bug workaround patches (linux-omap list).
- postmarketOS pmaports issue #175 — Galaxy Nexus (samsung-maguro) OMAP4460 mainlining tracker.
- HANDOFF.md "Finding 1" + PLAN.md #10 (local: SMP is the historical #1 boot blocker).
</content>
