# Nexus Q — CPU1 bring-up: panic photo analysis (2026-06-22)

Source: `~/Downloads/Photos-3-001.zip` (12 photos, time-ordered 18:28:58→18:29:21),
of the HDMI text console (multi-user, no desktop) of the `boot-smp-probe.img` build
(SMP + maxcpus=1 + SEV fix 0010 + instrumentation 0009 + auto-probe 0011).

## ★ THE BREAKTHROUGH — CPU1 comes online (SEV fix works)
The auto-probe fired ~31 s in and the screen showed, in order:
- `STEELHEAD-SMP: AUTO-PROBE: onlining CPU1 now (nr_online=1)`
- `STEELHEAD-SMP: boot_secondary cpu=1 ENTER (secure_apis=1)`  ← secure HS path taken
- `STEELHEAD-SMP: AUX_CORE_BOOT0 release path returned`
- `STEELHEAD-SMP: first bringup, dsb_sev() to wake CPU1 from WFE`
- `STEELHEAD-SMP: sending wakeup IPI to CPU1`
- CPU1 then **executed** — the panic that followed runs on `Process swapper/1`
  (the per-CPU **idle task of CPU1**). So CPU1 left ROM WFE, entered the kernel,
  ran secondary_init, came online. **The multi-month silent SMP deadlock is solved**
  by the prepare-time `dsb_sev()` (patch 0010), exactly as the stock-parity auditor
  predicted.

## ★ The remaining blocker — CPU1 cpuidle panic
Final screen (photo 12, ~31.5 s):
- `Hardware name: Generic OMAP4 (Flattened Device Tree)`
- `PC is at 0xc0c6efe0`  (bad/unmapped address)
- `LR is at cpuidle_enter_state+0x80/0x...`
- `Process swapper/1 (pid: 0 ...)`
- `Kernel panic - not syncing: Attempted to kill the idle task!`

Interpretation: once CPU1 is online and goes idle, `cpuidle_enter_state` drives the
OMAP4 deep C-state (CPU-powerdomain OFF/RET, coupled idle) and **jumps to a bad
address** → the idle task dies → panic. This is the classic OMAP4 secondary-CPU
cpuidle problem (needs correct SAR/secure save-restore for the CPU1 power
transition, which our U-Boot/PPA flow doesn't satisfy).

**Fix (stock parity):** stock ships `cpuidle44xx.disallow_smp_idle` (string present
in `reverse-eng/vmlinux.bin`) — i.e. stock keeps the SMP CPUs out of deep idle.
Mainline equivalent: boot with **`cpuidle.off=1`** (or disable CONFIG_CPU_IDLE),
so CPU1 just does plain WFI and stays up. Next test: add `cpuidle.off=1` to the
probe cmdline → expect `AUTO-PROBE: add_cpu(1) rc=0 nr_online=2` and no panic.

## Other findings (saved aside, per request — not blocking SMP)
1. **multi-user text-console boot works great as an observability tool**
   (`systemd.unit=multi-user.target` in cmdline → no compositor → kernel printk
   visible on HDMI). Reusable for any future on-screen debugging.
2. **No `module_layout disagrees` spam this boot** — confirms the SMP kernel +
   SMP modules match. (The earlier spam was only the #8-kernel + SMP-modules mix.)
3. **Benign GPIO lookup fallbacks (cleanup candidates):**
   - `of_get_named_gpiod_flags: can't parse 'wg-gpio' property of node
     /ocp/interconnect@4a000000/...` then `using lookup tables for GPIO lookup` —
     repeated on an mmc/hwmod node. Optional gpio, falls through.
   - `reset-gpios` parse note for `steelhead-avr 1-0020`.
   - `gpio gpiochip5: Persistence not supported for GPIO 16`.
4. **`pwrseq_simple: external clock not ready`** (~26 s) — BCM4330 wifi pwrseq
   clock note; worth a look during the wifi-stability investigation.
5. **PSI not enabled** — systemd skips OOM-killer/pressure units
   (`ConditionPathExists=/proc/pressure/memory`). Consider `CONFIG_PSI=y` later if
   we want memory-pressure / better OOM behaviour.
6. journald: audit collection disabled, IP-firewall warnings — cosmetic.

## Next step
Add `cpuidle.off=1` to the probe cmdline, rebuild, flash, cold-boot, read HDMI at
~30 s. If `nr_online=2` and no panic → CPU1 is stably online → build the real
dual-core image (SEV fix + cpuidle.off, drop the debug probe + maxcpus + revert
multi-user) and validate stability + whether dual-core also fixes the SMP-kernel
network flakiness.
