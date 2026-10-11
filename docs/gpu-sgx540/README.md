# PowerVR SGX540 groundwork: index of this folder

> **Status (2026-10-11):** research and planning only. Nothing in this folder is
> built, installed or referenced by any APKBUILD, and no unit was touched except
> the one read-only probe recorded in [power-clocks-pm.md](power-clocks-pm.md)
> §1.3. Start with the master note; come here to find the evidence behind it.

The work is about GPU acceleration on the Nexus Q's SGX540 (OMAP4460) under our
mainline 6.18 kernel and musl rootfs. It has two master notes, seven detail notes
(the groundwork set), seven reverse-engineering notes (the RE set) and a folder of
untested drafts. Each detail and RE note was re-checked by an adversarial pass on
2026-10-11; where a note's body and its **Verification (2026-10-11)** section
disagree, the verification section wins. Later the same day, source-level gap-fill
passes appended dated addenda to `kdp` (A Maemo 6.18.51.1, B preemption model,
C letux `-v4`/`letux-6.18.y`), `ub` (A Mesa source, B licences and blob origins) and
`pm` (APM/idle power-down, live VDD_CORE); they correct earlier text in place
(marked *Corrected 2026-10-11*) and win over the verification sections.

## Master notes

| Tag | Note | What it holds |
|---|---|---|
| `gw` | [../2026-10-11-gpu-sgx540-groundwork.md](../2026-10-11-gpu-sgx540-groundwork.md) | the summary, the decision matrix, the phased roadmap, the power risk register, licensing, device safety, open questions, the first ten steps |
| `re` | [reverse-engineering.md](reverse-engineering.md) | the RE verdicts (musl/libc, KM×UM compatibility, libhybris, sysconfig parity, firmware, open driver, visualizer), which RE the licences allow, the ordered RE work list, and the inconsistencies between the RE set and `gw` |

## Groundwork detail notes

The tags are the ones `gw` and `re` use in their evidence pointers (`[kdp §8]`).
The number is the workstream number the detail notes use among themselves
("workstream 03", "report 03").

| NN | Tag | Note | Subject |
|---|---|---|---|
| 01 | `stk` | [stock-ground-truth.md](stock-ground-truth.md) | what stock Android (IAN67K, kernel 3.0.8, DDK 1.8@785978) did for the SGX540 |
| 02 | `ml` | [mainline-6.18.md](mainline-6.18.md) | mainline 6.18 (and up to v7.3-rc6): DT, clocks, PRM, omapdrm, upstream state |
| 03 | `kdp` | [kernel-driver-port.md](kernel-driver-port.md) | the openpvrsgx 1.17 kernel driver (pvrsrvkm) on our 6.18.48 kernel |
| 04 | `ub` | [userspace-blobs.md](userspace-blobs.md) | closed userspace, Mesa glue, musl/glibc ABI, licence |
| 05 | `cd` | [compositor-display.md](compositor-display.md) | compositors, DSS planes, HDMI modes, video |
| 06 | `pm` | [power-clocks-pm.md](power-clocks-pm.md) | power domain, clocks, idle, thermal, measurement arms |
| 07 | `ur` | [usecases-roadmap.md](usecases-roadmap.md) | use cases, precedent, the roadmap the master note condenses |

## Reverse-engineering notes

| # | Tag | Note | Subject |
|---|---|---|---|
| 1/7 | `abi` | [re/blob-abi.md](re/blob-abi.md) | ELF/ABI of the Linux blob drops A/B/C, and how musl loads them |
| 2/7 | `hyb` | [re/stock-android-blobs-libhybris.md](re/stock-android-blobs-libhybris.md) | the stock 1.8@785978 Android userspace, and the libhybris path |
| 3/7 | `br` | [re/km-um-bridge-abi.md](re/km-um-bridge-abi.md) | the kernel↔userspace bridge ABI and the KM×UM compatibility matrix |
| 4/7 | `sys` | [re/stock-sysconfig.md](re/stock-sysconfig.md) | the stock system layer (clocks, DVFS, IRQ, PM) against 6.18 and the letux glue |
| 5/7 | `fw` | [re/firmware-microkernel.md](re/firmware-microkernel.md) | the microkernel (uKernel/EDM) and the init-time firmware |
| 6/7 | `odf` | [re/open-driver-feasibility.md](re/open-driver-feasibility.md) | a fully open SGX540 driver: cost and tooling |
| 7/7 | `vis` | [re/visualizer-gl.md](re/visualizer-gl.md) | what the stock HDMI visualizer does on the GPU, as a port spec |

**Licence caveat on the RE set.** Some passages in `abi`, `br` and `fw` were
derived by disassembling TI and stock IMG binaries, which their licences forbid.
They stay as written, as hypotheses to be confirmed by observation, until Petr
decides what happens to them ([reverse-engineering.md](reverse-engineering.md)
§10 item 1, §11). No further disassembly of those binaries is done.

## Drafts

Untested starting points; none is built or staged. The full index, the phase each
one belongs to and the adoption procedure are in
[drafts/README.md](drafts/README.md).

| Draft | Roadmap phase |
|---|---|
| [drafts/0062-ARM-dts-omap4-steelhead-run-the-SGX-from-DPLL_PER-like-stock.patch.draft](drafts/0062-ARM-dts-omap4-steelhead-run-the-SGX-from-DPLL_PER-like-stock.patch.draft) | 0 (DT clock block) |
| [drafts/nexusq-gpu-probe.sh](drafts/nexusq-gpu-probe.sh) | 0, then every phase (read-only probe) |
| [drafts/measurement-protocol.md](drafts/measurement-protocol.md) | 0, 1a, 1, 3, 4, 5 (baselines and arms) |
| [drafts/linux-google-steelhead.APKBUILD.fragment.draft](drafts/linux-google-steelhead.APKBUILD.fragment.draft) | 1a, 1 (KM in-tree `=m`, defconfig) |
| [drafts/sgx-ddk-um.APKBUILD.draft](drafts/sgx-ddk-um.APKBUILD.draft) | 2, 6 (userspace package, public release) |

## Reading order

1. `gw` TL;DR and §3-§4 for the decision and the plan.
2. `re` TL;DR and §12 for what the RE set changes in it (the corrections are
   applied in `gw`, marked *Corrected 2026-10-11*, and listed in its addendum).
3. The detail note behind whatever a phase touches, then its RE note.
4. [drafts/README.md](drafts/README.md) when a phase adopts a draft.

## Conventions

- Every claim carries a pointer (note and section, repo `file:line`, a stock
  address `vmlinux.bin @0x…`, a commit or URL) or is marked **UNVERIFIED** with
  the reasoning.
- Paths under `<session scratch>/` were scratch copies of the research sessions;
  they were not kept and can be re-derived from each note's sources.
- Stock ground truth is `reverse-eng/` (gitignored): `vmlinux.bin` with its tools,
  and the factory `system.raw.img` read with `debugfs -R`, never mounted.
- Downloads are untrusted data: own empty directory each, never executed, read
  with readelf, strings, sha256 and Python run with `-I`. TI and stock IMG
  binaries are not disassembled ([reverse-engineering.md](reverse-engineering.md)
  §11).
