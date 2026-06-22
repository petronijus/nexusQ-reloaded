# Nexus Q — bringing up the second CPU core (OMAP4460 HS SMP)

**Status: WORKING & validated (2026-06-22).** Both Cortex-A9 cores online and
stable on mainline Linux 6.12. This document is the authoritative writeup of how
it was solved and what the key components are.

---

## 1. TL;DR

Enabling `CONFIG_SMP=y` had silently deadlocked the whole boot for the entire
life of the port. The cause was **two missing pieces**, both recovered by
reverse-engineering the stock Android kernel:

1. **A missing `SEV` in `omap4_smp_prepare_cpus()`** — stock issues `dsb;sev`
   right after writing CPU1's startup address; mainline does not. Without it CPU1
   stays parked in ROM WFE and `__cpu_up()` blocks before any console exists →
   silent hang. → fix: **kernel patch 0009** (`dsb_sev()` at end of prepare).
2. **CPU1 panics in deep cpuidle** once online (`Attempted to kill the idle
   task`). Stock ships `cpuidle44xx.disallow_smp_idle`. → fix: boot with
   **`cpuidle.off=1`**.

With those two changes the device boots dual-core natively (`CPU1 up at [0.25s]`,
`nproc=2`), stable, both cores executing work, `taint=0`.

---

## 2. The constraint that made it hard: OMAP4460 **HS**

The SoC is **OMAP4460 ES1.1 HS (High Security)** (`/sys/devices/soc0/type = HS`).
On HS silicon, releasing the secondary CPU (writing the AUX_CORE_BOOT_0/1
registers) does **not** happen via plain register writes — it goes through
**secure SMC calls into the bootloader's PPA** (Primary Protected Application).
So we could not just "poke registers"; the bring-up had to match what the stock
`steelheadB4H0J` bootloader's PPA expects.

Good news established early (by the `stock-parity-auditor`): the **secure SMC
service IDs already match** mainline byte-for-byte (`0x103` read / `0x104` modify
/ `0x105` addr / `0x25` PPA SMP-bit). So the SMC plumbing was never the bug — the
gap was purely in the *sequence* around those calls.

---

## 3. Method — how we found it (reproducible approach)

1. **Ground truth.** Extracted the stock kernel (Linux 3.0.8 `#1 SMP PREEMPT`)
   from the `tungsten-ian67k` factory image → `reverse-eng/vmlinux.bin`. This
   kernel runs dual-core on our exact HW + bootloader, so its bring-up is correct
   by definition.
2. **Disassembly diff.** The `stock-parity-auditor` agent disassembled the stock
   `platform_smp_prepare_cpus` / `boot_secondary` / `secondary_init` and compared
   them function-by-function against mainline `arch/arm/mach-omap2/omap-smp.c`.
   That surfaced the **one structural divergence**: stock SEVs in *prepare*,
   mainline only SEVs later in *boot_secondary*.
3. **Network-independent observation.** The hang is silent and pre-console, and
   the device's network (eth/usb-gadget/wifi) was too flaky to drive a live test
   (`pstore` is useless here — the hang needs a power-cycle, which scrubs DRAM).
   The trick that worked:
   - boot `maxcpus=1` (boots clean, single core),
   - `systemd.unit=multi-user.target` on the cmdline → **no desktop**, so the
     HDMI framebuffer console shows kernel `printk`,
   - a **late_initcall kthread** that onlines CPU1 ~30 s after boot (once the fb
     console is up), with `pr_emerg` milestones around every bring-up step.
   We then photographed the HDMI console. The panic ran on **`swapper/1`** (the
   per-CPU idle task of CPU1) → proof that CPU1 *did* come alive (the SEV fix
   worked) and that the remaining fault was in **cpuidle**.

This observation scaffolding (patches `0009-instrument`, `0011-autoprobe` and the
`maxcpus=1` / `multi-user` cmdline) was **debug-only and has been removed** from
the shipping build. It is preserved in commit `510f8ab` for reference.

---

## 4. Root cause #1 — missing SEV in prepare

Out of cold U-Boot reset, CPU1 is parked in **ROM WFE** (wait-for-event). The
boot ROM only (re)reads `AUX_CORE_BOOT_1` (the secondary startup address) **after
an `SEV` wakes it**, at which point CPU1 jumps to `omap4460_secondary_startup`
and spins in the kernel hold loop waiting for the release bit.

- **Stock** issues `dmb;dsb;sev;dsb` inside `platform_smp_prepare_cpus`, right
  after `omap_auxcoreboot_addr()` writes the startup address (stock
  `vmlinux.bin @ 0xC001238C`).
- **Mainline** `omap4_smp_prepare_cpus` ends after that write — no SEV. Its first
  SEV is much later, in `omap4_boot_secondary`'s first-time branch. On this
  bootloader that is too late / does not reach CPU1, so CPU1 never leaves ROM WFE,
  `__cpu_up()` waits on a completion that never fires, and because this runs in
  `smp_init` (very early) it deadlocks **before any console** → the silent hang.

**Fix (patch `0009-ARM-OMAP4-steelhead-SEV-in-prepare-wake-cpu1.patch`):** add
`dsb_sev()` at the end of `omap4_smp_prepare_cpus()`, mirroring stock. One line of
effect; harmless on boards where CPU1 is already running (a stray SEV is a no-op).

```c
	if (omap_secure_apis_support())
		omap_auxcoreboot_addr(__pa_symbol(cfg.startup_addr));
	else
		writel_relaxed(__pa_symbol(cfg.startup_addr),
			       cfg.wakeupgen_base + OMAP_AUX_CORE_BOOT_1);

	/* Steelhead OMAP4460 HS: SEV here to kick CPU1 out of ROM WFE (stock parity) */
	dsb_sev();
}
```

## 5. Root cause #2 — CPU1 cpuidle panic

Once CPU1 was online it immediately panicked when it went idle:

```
PC is at 0xc0c6efe0           (bad/unmapped address)
LR is at cpuidle_enter_state
Process swapper/1
Kernel panic - not syncing: Attempted to kill the idle task!
```

OMAP4 secondary deep-idle (`cpuidle44xx`, coupled C-states: CPU power-domain
OFF/RET) drives a power transition that needs SAR/secure save-restore our U-Boot/
PPA flow does not satisfy → CPU1's idle path jumps to a bad address → the idle
task dies → panic.

**Fix:** boot with **`cpuidle.off=1`** (baked into `CONFIG_CMDLINE`). Stock does
the equivalent via `cpuidle44xx.disallow_smp_idle`. CPU1 then just does plain
`WFI` and stays up. (Trade-off: no deep CPU power-saving; acceptable — see
hardening notes.)

---

## 6. Key components (what makes dual-core work)

| Component | Where | Why |
|---|---|---|
| `dsb_sev()` in prepare | patch `0009` → `omap-smp.c` | wakes CPU1 from ROM WFE (THE fix) |
| `cpuidle.off=1` | `CONFIG_CMDLINE` (defconfig) | prevents the secondary cpuidle panic |
| `CONFIG_SMP=y` | defconfig | enable SMP |
| `CONFIG_NR_CPUS=2` | defconfig | two logical CPUs |
| `CONFIG_HOTPLUG_CPU=y` | defconfig | clean CPU1 offline + (was used by the debug auto-probe) |
| `cpu@1` DT node | `kernel/dts/omap4-steelhead.dts` (patch `0003`) | else `arm_dt_init_cpu_maps` caps to 1 core |
| `CONFIG_KERNEL_LZMA` | defconfig | SMP+gzip busted the ~6.6 MB U-Boot ceiling; LZMA → ~5.1 MB |

No DT `enable-method` is needed: the OMAP4 machine descriptor wires
`omap4_smp_ops` (`board-generic.c`). No secure/SMC code changes are needed: the
service IDs already match stock. The mainline-only `omap4_smp_maybe_reset_cpu1`
(pulses cpu1_rstctrl `0x4824380C`) does **not** fire on a cold boot here and was
left untouched.

---

## 7. Build & reproduce

```sh
# fast kernel-only build (reuses the warm pmbootstrap docker volume)
docker run --rm --privileged -v "${PWD}:/src:ro" \
  -v nexusq-output:/tmp/output -v nexusq-workdir:/home/pmos/.local/var/pmbootstrap \
  nexusq-builder /src/scripts/build-kernel-boot.sh boot-smp-dualcore.img
# extract from the nexusq-output volume, then flash via fastboot + COLD power-cycle:
fastboot flash boot output/boot-smp-dualcore.img      # then unplug ~10s, replug (no mute sensor)
```
Patches `0001-0009` apply in order (all GNU-`patch` verified — abuild uses GNU
patch, not `git apply`; see `docs/.../patches-must-apply-with-gnu-patch`). The
SMP modules must match the SMP kernel (same vermagic `6.12.12 SMP`); a #8 (non-SMP)
kernel with SMP modules — or vice versa — produces `module_layout disagrees` spam.

## 8. Validation (cold boot, `boot-smp-dualcore.img`)

- `nproc=2`, `cpu/online=present=possible=0-1`, **`taint=0`**, **0** module-ABI errors
- `smp: Brought up 1 node, 2 CPUs`; `SMP: Total of 2 processors activated`; CPU1 up at `[0.25s]`
- both cores execute under a 4-worker load (cpu0 + cpu1 jiffies climb); ~59 °C stable
- subsystems up: audio (`NexusQ-Speaker` TAS5713 + HDMI + Loopback), 32-LED ring,
  wifi, Bluetooth, USB
- **bonus:** dual-core cured the earlier connectivity flakiness — that was
  single-core saturation by the desktop starving the network stacks.

## 9. Hardening status & open items

**Shipping posture:** `CONFIG_SMP=y` is built and proven, but keep the historical
caution in mind — SMP was the #1 boot blocker for years. Before making it the
unconditional default, validate boot reliability across many cold boots (the
device has a separate ~1-in-3 intermittent black-screen boot flake) and re-confirm
the ≤6.6 MB boot-image ceiling.

Open items (tracked as tasks; see `docs/2026-06-22-smp-session-findings.md`):
- **cpuidle:** currently disabled (`cpuidle.off=1`, stock parity). Proper fix =
  make OMAP4 coupled cpuidle work for the secondary (needs correct SAR/secure
  setup). Low priority — the device meets its purpose without deep CPU idle.
- **Ethernet** LAN9500A enumerates only intermittently; an in-driver reset
  (unbind/bind ehci-omap) is NOT enough (PORTSC CCS stays 0) — only a full cold
  power-off re-enumerates. Independent of SMP.
- **WiFi** BCM4330: `Power Management: on` + 54 Mb/s (g) → high jitter
  (avg ~20 ms, spikes to ~660 ms) and poor bulk; try `iwconfig wlan0 power off`.
- Userspace boot ~1m22s (desktop-heavy); `ti-sysc 4a318000` EBUSY; HDMI EDID
  read timeout; brcmfmac `clm_blob` missing — all benign / pre-existing.

## 10. Primary references
- `reverse-eng/vmlinux.bin` — stock 3.0.8 SMP kernel (ground truth)
- `kernel/patches/0009-ARM-OMAP4-steelhead-SEV-in-prepare-wake-cpu1.patch`
- `arch/arm/mach-omap2/omap-smp.c`, `omap-secure.{c,h}`, `omap-smc.S`, `omap-headsmp.S`
- `docs/2026-06-22-smp-session-findings.md` (full session log)
- `docs/2026-06-22-smp-cpu1-panic-photos.md` (the HDMI panic analysis)
- `docs/2026-06-19-smp-second-core-research.md` (the original research that framed it)
- git: branch `feat/smp-cpu1-bringup` — `510f8ab` (breakthrough + debug),
  `8d4df5d` (clean dual-core)
