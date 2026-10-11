DRAFT — not built, not tested, not in any build (2026-10-11)

# GPU groundwork drafts

Untested starting points for the PowerVR SGX540 work planned in
[2026-10-11-gpu-sgx540-groundwork.md](../../2026-10-11-gpu-sgx540-groundwork.md).
None of these files is built, installed, staged by `docker-build.sh` or
referenced by any APKBUILD. Each one says at its top what it assumes and where
the assumption comes from. They become real only by the adoption steps below,
in the phase that needs them.

## Index

| Draft | What it is | Roadmap phase | Becomes, when adopted | Status |
|---|---|---|---|---|
| [0062-ARM-dts-omap4-steelhead-run-the-SGX-from-DPLL_PER-like-stock.patch.draft](0062-ARM-dts-omap4-steelhead-run-the-SGX-from-DPLL_PER-like-stock.patch.draft) | `&sgx_module` `assigned-clocks`: SGX mux to `dpll_per_m7x2_ck` at 307.2 MHz, like stock | 0 (step 4) | a block in `kernel/dts/omap4-steelhead.dts` plus the next free kernel patch number, `pkgrel` bump | draft; hunk context from dc988b9, must be regenerated; VDD_CORE gate open |
| [linux-google-steelhead.APKBUILD.fragment.draft](linux-google-steelhead.APKBUILD.fragment.draft) | how `pmos/linux-google-steelhead/APKBUILD` builds `pvrsrvkm_omap4_sgx540_120` in-tree (=m): pinned openpvrsgx archive, copy-before-patch, patch list (a)-(i), defconfig (preemption model and every PVR symbol), no subpackage, `pkgrel` plan, a kernel-side blacklist | 1a (preemption), 1 (KM) | edits to the kernel APKBUILD and `kernel/configs/steelhead_defconfig`, patches in `kernel/patches/`, a bump script | draft; upstream pins resolved with `git ls-remote` on 2026-10-11; nothing compiled |
| [sgx-ddk-um.APKBUILD.draft](sgx-ddk-um.APKBUILD.draft) | the userspace package: TI 1.17 ti443x blobs unmodified, Maemo's open libdbm and pvrsrvinit for musl, init unit, udev rule, apphints; delivery modes for `PUBLIC_RELEASE=1` (redistribute, fetch at install, private overlay) and the two new preflight checks; Mesa-sgx companion sketch; the route B (glibc sandbox) first-light procedure | 2 (route B first light, route A packaging), 6 (packaging, public release) | a new aport, a separate Mesa-sgx aport, preflight checks in `scripts/release-preflight-no-secrets.sh` | draft; per-file sha256 measured from TI 84a396a4 on 2026-10-11; nothing built |
| [nexusq-gpu-probe.sh](nexusq-gpu-probe.sh) | read-only on-device probe: hostname, DT nodes, device binding, SGX clock parent and rate, `prm_gfx` and `gfx_pwrdm`, VDD_CORE (regulator if exposed; TWL6030 VCORE1 with `--pmic`), optional allowlisted PRM/CM reads, module, nodes, dmesg | 0 (step 2), then every phase | a script under `scripts/diag/` after review, and a `POWER_DOMAINS_GPU` section in `nq-diag-snapshot` | draft; passes `shellcheck` with the repo's `.shellcheckrc` (0.11.0, 2026-10-11); never run on a unit |
| [measurement-protocol.md](measurement-protocol.md) | baseline-against-after checklist: arms A0, A0h, A0m, P1a, A1-A4, instruments, audio check, durations, pass/fail thresholds, the tests that must be seen failing | 0 (baselines), 1a, 1, 3, 4, 5 | the procedure each phase's dated `docs/` note follows | draft; thresholds partly proposed here (P1a) |

## How the master note refers to them

The master note's links were written before these files existed and use two
different names. The files here are the ones meant. *Resolved 2026-10-11:* the
master note now links these files by their real names; the table stays as the
key to the old names in earlier copies:

| Master note says | File here |
|---|---|
| `drafts/nq-gpu-probe.sh` (Phase 0 step 2, §9 step 2) | [nexusq-gpu-probe.sh](nexusq-gpu-probe.sh) |
| `linux-google-steelhead-pvrsgx.APKBUILD-fragment.draft` (Phase 1 step 2) | [linux-google-steelhead.APKBUILD.fragment.draft](linux-google-steelhead.APKBUILD.fragment.draft) |
| "blob package" (header), "Draft in gpu-sgx540/drafts/" (§6 option 2) | [sgx-ddk-um.APKBUILD.draft](sgx-ddk-um.APKBUILD.draft) |

## What was checked while writing them (2026-10-11)

- Full commit hashes for every pin the notes cite by prefix, with
  `git ls-remote`: openpvrsgx `pvrsrvkm-6.18-rc6` `d2f1e031d58a…`,
  `letux/pvrsrvkm-1.17.4948957-v3` `e5de75568819…`, Maemo `sgx-ddk-um` tag
  `1.17.4948957+leste15` `a9dbdc75233d…`, Maemo `droid4-linux` tag
  `maemo-kernel-6.18.51.1` `db432aff895b…`, TI
  `1.17.4948957/mesa/glibc-2.35` `84a396a4fb37…`. All match the prefixes in
  the notes.
- TI `84a396a4`: `LICENSE` and `targetfs/ti443x_linux/` fetched sparsely
  into scratch, hashed with `sha256sum` only (no TI binary was executed or
  disassembled). The 12-character prefixes equal
  [userspace-blobs.md §2.1](../userspace-blobs.md); the full hashes are in the
  blob draft.
- Maemo `sgx-ddk-um` at `a9dbdc75` (GitHub API): the `ti443x/` sizes match
  the TI files; the tree has **no TI licence file**, so the TSPA text must come
  from TI's repo; `pvrsrvinit.c` carries no licence header and the repo no
  COPYING; `dbm/dbm.c` is LGPL without a version number.
- The probe's `clk_summary` fallback parser on the host against
  `nq-captures/20261010-185940/snapshot.txt`: it returns
  `dpll_core_m7x2_ck 266666667`, the expected pre-0062 FAIL. A host check, not
  a device pass.

## Adopting a draft

1. Re-read the draft's assumptions against the code of the day; regenerate
   anything with hunk context or line numbers.
2. Move it to its real place (table above), in the phase that needs it, with
   the project's rules: `pkgrel` bump and CHANGELOG line naming the revision,
   new files in `source=`, `tests/test_aports.py` green, `just check` green.
3. stock-parity-auditor for anything touching clocks, power domains or the
   sysconfig constants; fleet-safety-reviewer before any commit under
   `kernel/`, `pmos/` or `scripts/`.
4. A test seen failing before it counts (each draft names its own).
5. Delete the draft once its adopted copy exists, so there is one source.
