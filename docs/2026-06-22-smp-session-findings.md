# Nexus Q — 2nd CPU core (SMP) bring-up — session findings 2026-06-22

Goal: bring CPU1 online on the OMAP4460 **HS** Nexus Q. `CONFIG_SMP=y` has
always silently deadlocked. This doc is the systematic record of what we
established this session, so we don't lose the thread again.

## A. Ground truth secured
- Stock Android kernel **Linux 3.0.8 `#1 SMP PREEMPT`** extracted from the
  `tungsten-ian67k` factory image → `reverse-eng/vmlinux.bin` (raw ARM, PAGE_OFFSET
  0xC0000000). It runs dual-core on our exact HW + bootloader (steelheadB4H0J), so
  it is the authoritative reference. `reverse-eng/` is gitignored; recreate per
  `reverse-eng/README.md`.

## B. Root-cause analysis (stock-parity-auditor, disassembly-backed)
1. **Secure SMC service IDs MATCH stock byte-for-byte** (0x103 read / 0x104 modify /
   0x105 addr / 0x25 PPA SMP-bit). The SMC plumbing is NOT the bug. Rules out the
   old research-doc worry about mismatched PPA service numbers.
2. **PRIME SUSPECT — missing SEV in `omap4_smp_prepare_cpus`.** Stock does
   `dmb;dsb;sev;dsb` in *prepare* right after writing AUX_CORE_BOOT_1 (@0xC001238C).
   Mainline omits it. On a cold U-Boot boot CPU1 sits in **ROM WFE**; the ROM only
   re-reads the startup address after an SEV. Without the prepare-time SEV, CPU1
   never leaves ROM WFE → `__cpu_up` blocks during `smp_init`, before any console →
   silent hang (no HDMI/net).
3. Secondary suspects (not yet tested):
   - Mainline `omap4_smp_maybe_reset_cpu1` may pulse cpu1_rstctrl `0x4824380C`;
     **stock never touches it.** A spurious pulse could knock CPU1 out of the ROM
     pen. → candidate: make it a no-op on this board.
   - **446x-HS gap:** mainline does the CPU1 NS-SMP-bit PPA call (svc 0x25) only for
     `soc_is_omap443x()`. Our **446x HS** skips it (mainline assumes 446x==GP-like).
     Runs on CPU1 *after* it starts, so not the hang cause itself, but likely needed
     once CPU1 is up.
4. One **benign MISMATCH**: omap446x secondary vector adds a GIC-dist write stock
   lacks — auditor says leave it (correct for 4460, harmless on cold boot).

## C. Confirmed on hardware
- ✅ **SMP=y boots single-core** (`maxcpus=1`): nproc=1, `cpu/possible=0-1`,
  `present=0-1` (kernel SEES both cores), taint=0, eth worked on first boot.
  → enabling SMP infrastructure is safe; size fits. (Increment 2 done.)
- ❌ **CPU1 bring-up (`maxcpus` removed) silently hangs the whole boot** — no
  HDMI/console/net. Reproduced twice (plain 2-core build #4, and the SEV-fix build).
- ❌ **SEV fix ALONE is NOT sufficient** — still silently hangs. So SEV is
  necessary-but-not-proven-sufficient, or the hang is elsewhere. **We have not yet
  OBSERVED where it hangs.**
- ✅ `omap_type()` = **HS** at runtime (`/sys/devices/soc0/type`) → secure path is
  taken; rules out GP-misdetection (auditor's #3).

## D. Repo-integrity bugs found & fixed
- **Patch 0008 (ethernet UHH_HOSTCONFIG)** applied with `git apply` but **FAILED
  under GNU `patch`** (which abuild uses) — released v1.1.0 source could not rebuild
  its own binary. Regenerated as a clean `diff -u`, GNU-patch-verified. See
  memory [[patches-must-apply-with-gnu-patch]].
- **Patch 0003 (DTS)** must be regenerated from `kernel/dts/omap4-steelhead.dts` via
  `scripts/regen-dts-patch.sh` — editing the dts alone does NOT propagate to the
  build (build consumes the patch). cpu@1 was silently missing until regen.

## E. Build / tooling
- `scripts/build-kernel-boot.sh` — fast **kernel-only** docker build + boot.img
  repack, reusing the warm `nexusq-workdir` volume (skips rootfs). abuild cleans the
  pkgdir, so it extracts vmlinuz/dtb from the built `.apk`.
- **Size:** SMP + gzip = 6856 KB (over the ~6656 KB U-Boot ceiling). Switched
  `CONFIG_KERNEL_GZIP` → `CONFIG_KERNEL_LZMA` → **5080 KB** (well under). Solved.

## F. Observability — the real blocker
- **pstore/ramoops does NOT survive reboot** (DRAM scrubbed), and a hang needs a
  power-cycle anyway → pstore is useless for this hang.
- The intended method — boot `maxcpus=1`, trigger CPU1 at runtime
  (`echo 1 > /sys/devices/system/cpu/cpu1/online`), read the synchronous
  `pr_emerg` milestones (patch 0009) off the HDMI text console — is sound, but we
  **could not execute it**: device connectivity was too flaky to reliably issue the
  trigger. THIS is the thing to fix next.

## G. Connectivity (important, partly open)
- All three transports (eth / USB-gadget / wifi) went flaky **during** this session.
- **Key datum (user):** the `#8` build transferred 600 MB rock-solid. So flakiness
  correlates with the **SMP kernels**, not the hardware.
- Hypotheses (unconfirmed): SMP=y on a single core degrades I/O timing; or the LXQt
  desktop saturates the single CPU and starves the network stacks (load was 1.6–2.6
  on one core). If it's CPU saturation, **getting CPU1 up would itself fix it.**
- eth0 (LAN9500A) intermittent enumeration is a separate, known issue (cold power-off
  resets it).

## H. Physical state at end of session
- Device **powered off**.
- Boot partition (p9): **#8 kernel** (`boot-eth-8.img`, sha 8c7b4f75 verified).
- Rootfs (p13): `/lib/modules/6.12.12` currently = **SMP modules** (mismatched with
  #8 → the `nfnetlink/module_layout disagrees` spam). Original #8 (non-SMP) modules
  are safe at `/lib/modules/6.12.12.nonsmp-bak` on the device.
- **One inconsistency to clear for a clean #8:** restore the non-SMP modules
  (`rm -rf /lib/modules/6.12.12 && mv …nonsmp-bak …6.12.12 && depmod`), then a cold
  power-on boot.

## I. Host artifacts (output/)
- `boot-eth-8.img` — released #8, non-SMP, rock-solid (RECOVERY TARGET).
- `boot-smp-maxcpus1.img` — SMP single-core, boots, flaky net.
- `boot-smp-instr.img` — SMP maxcpus=1 + instrumentation (patch 0009).
- `boot-smp-sevfix.img` — SMP 2-core + SEV fix → **hangs**.
- `p9-backup-7-working.img`, device `/root/p9-backup-pre-smp.img`.
- Patches: 0009 (instrumentation), 0010 (SEV fix) staged in `kernel/patches/` +
  `pmos/linux-google-steelhead/APKBUILD`. These are debug/experimental, NOT release.

## J. Boot/flash discipline (learned the hard way)
- **`fastboot reboot` is UNRELIABLE** on this U-Boot — re-enters fastboot or no-boots.
  The ONLY reliable boot is `fastboot flash boot` **+ cold power-cycle** (unplug ~10s,
  replug WITHOUT covering the mute sensor).
- `systemctl reboot -f` (force) also drops to fastboot; plain `systemctl reboot` boots
  normally.
- The device is **unbrickable** (bootloader untouched) — every bad state is
  recoverable via fastboot.

## K. Next step (systematic, connectivity-independent)
The blocker is OBSERVING the hang. Stop depending on live ssh mid-test. Instead make
the test **self-contained**: a boot-time service on the rootfs that, once the HDMI fb
console is up, auto-runs `echo 1 > cpu1/online` on the **instrumented maxcpus=1**
kernel — so the milestones print to HDMI with **no network needed**. Read the last
`STEELHEAD-SMP` line off the screen → that's where CPU1 dies → targeted fix
(SEV + suppress maybe_reset_cpu1 + 446x-HS PPA call, per the auditor). Do ONE change
at a time, each with a defined pass/fail read off HDMI.
