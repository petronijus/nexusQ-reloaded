# SGX540 reverse engineering: what the RE set found, and what is left to do (2026-10-11)

> **Status (2026-10-11):** synthesis only. Nothing was built, flashed, installed or
> committed, and no Nexus Q was touched while writing it. Every statement comes
> from the seven RE notes in [re/](re/blob-abi.md), the groundwork note
> [../2026-10-11-gpu-sgx540-groundwork.md](../2026-10-11-gpu-sgx540-groundwork.md)
> and its detail notes. Each RE note was re-checked by an adversarial pass the same
> day. Where a note's body and its **Verification (2026-10-11)** section disagree,
> this note follows the verification section.
>
> This is the RE master note: it gives the verdicts the decisions need, the
> licence limits on further RE, the ordered RE work list, and the places where
> the RE notes and the groundwork note disagree. The plan, roadmap and risk
> register stay in the groundwork note.

**Evidence convention.** Every claim carries a pointer: an RE note and section
(`[br §7]` = [re/km-um-bridge-abi.md](re/km-um-bridge-abi.md) §7, `[abi V6]` =
row or block V6 of that note's verification), a repo `file:line`, a stock address
(`vmlinux.bin @0x…`), a commit, or **UNVERIFIED** with the reasoning.

| Tag | Note | Subject |
|---|---|---|
| `abi` | [re/blob-abi.md](re/blob-abi.md) | RE 1/7: ELF/ABI of the Linux blob drops A/B/C, musl loader behaviour |
| `hyb` | [re/stock-android-blobs-libhybris.md](re/stock-android-blobs-libhybris.md) | RE 2/7: stock 1.8@785978 Android userspace, libhybris |
| `br` | [re/km-um-bridge-abi.md](re/km-um-bridge-abi.md) | RE 3/7: kernel↔userspace bridge ABI, KM×UM matrix |
| `sys` | [re/stock-sysconfig.md](re/stock-sysconfig.md) | RE 4/7: stock system layer (clocks, DVFS, IRQ, PM) against 6.18 and letux |
| `fw` | [re/firmware-microkernel.md](re/firmware-microkernel.md) | RE 5/7: the microkernel (uKernel/EDM) and init-time firmware |
| `odf` | [re/open-driver-feasibility.md](re/open-driver-feasibility.md) | RE 6/7: a fully open SGX540 driver |
| `vis` | [re/visualizer-gl.md](re/visualizer-gl.md) | RE 7/7: the stock HDMI visualizer on the GPU |
| `gw` | [../2026-10-11-gpu-sgx540-groundwork.md](../2026-10-11-gpu-sgx540-groundwork.md) | groundwork master note (plan, matrix, roadmap) |
| `ub`, `kdp`, `pm`, `stk`, `ml`, `cd`, `ur` | [userspace-blobs.md](userspace-blobs.md), [kernel-driver-port.md](kernel-driver-port.md), [power-clocks-pm.md](power-clocks-pm.md), [stock-ground-truth.md](stock-ground-truth.md), [mainline-6.18.md](mainline-6.18.md), [compositor-display.md](compositor-display.md), [usecases-roadmap.md](usecases-roadmap.md) | the groundwork detail notes, same tags as `gw` uses |

Blob drops, as `abi` names them: **A** = DDK 1.9@2253347 (`maemo-leste/pvr-omap4`),
**B** = TI 1.17@4948957 `ti443x` committed 2020-02-12 (`ce7b96b`, unchanged at
`551665b` and `742cf38`), **C** = TI 1.17@4948957 `ti443x_linux` rebuild of
2024-10-16 (`84a396a4`, byte-identical to Maemo Leste `sgx-ddk-um` leste15's git tree, not its debs [ub Addendum B.4])
[abi §2, V1, V2]. The groundwork plan ships **C** [gw §3 Primary path].

---

## TL;DR

1. **The primary path needs no further reverse engineering of closed binaries.**
   Every bridge, handshake and loader question it raises is either answered
   statically already [br §7, abi §6-§7, fw §2] or is answered better, and within
   the licence, by observation: logging in our own GPL kernel module, `strace`,
   API queries, and black-box error-path tests (§2, §10). The RE still worth doing
   reads **sources** (our KM tree, AOSP Apache/GPL code) and the GPL stock kernel:
   about **4.5-8 engineer-days** spread over groundwork Phases 0-4 (UNVERIFIED
   estimate, §10). A fully open driver is a different order of magnitude:
   **9-19 person-months** for a minimal compositor engine, **4-7 person-years**
   for upstream-quality GLES2 [odf TL;DR 6].
2. **One process, one libc.** A musl process can host the glibc-built TI blobs only
   because musl impersonates glibc for them; it can never load real glibc beside
   musl, and no musl process can load the stock bionic blobs [abi §7.5, hyb §2.4].
   Route B (the GL consumer entirely inside the glibc island) has no ABI unknowns;
   route A (musl process + drop C + shim) resolves every import on paper and leaves
   two hazards that the RE set rates lower than the groundwork note does (§3.4).
3. **KM×UM: TI 1.17 `ti443x` against letux 1.17 passes every bridge check on paper.**
   Transport, package layout, 35/35 ioctl ids, DDK words `0x00011100`/4948957 and
   build options `0x00360018` on both sides (corrected from `0x00260018`) [br TL;DR 3,
   Verif. 7-9]. Two gaps remain for the drop the plan ships: per-call sizes were
   measured on the 2020 build only, and drop C loads an unexplained `0x360b14`
   [abi synthesis, br open 4]. The stock UM pairs with exactly one KM: the
   stock one, whose GPL source (AOSP `03a9286b`) is public [br TL;DR 2].
4. **Stock blobs + libhybris: partly viable, offscreen only, not recommended**
   [hyb §5]. Keep them as reference data, not as an oracle we run (§5, §11).
5. **Stock sysconfig parity: 12 MATCH, 11 MISMATCH, 4 MISSING, 1 EXTRA, 3 UNKNOWN**
   [sys §6]. The kernel side must add the DPLL_PER clock block, OMAP4 timing values
   (307.2 MHz, 100 Hz HW recovery, 100 ms APM), a preemptible kernel, and must
   never select 384 MHz without VDD_CORE scaling (§6).
6. **There is no SGX firmware file.** The microkernel is four USE plus five PDS
   programs inside `libsrv_init.so`, patched at 15 placeholders by `SrvInit()`; the
   KM only receives handles and register scripts and never checks the code bytes;
   the 1.17 KM no longer checks the uKernel's DDK build at all [fw TL;DR 1-4, §2.6].
7. **The TI TSPA forbids reverse engineering, decompilation and disassembly** of the
   TI blobs [ub §8]. The RE set disassembled TI binaries well beyond the "two call
   sites" the groundwork compliance note records (§11, §12 item 1). No further
   disassembly of TI or stock IMG blobs; what remains is done by observation.
8. **The stock visualizer is plain GLES 2.0**: 40 point sprites when idle; a
   960×540 RGBA8 feedback FBO with six distortion shaders and five scenes when
   music plays. Only the music path needs the GPU [vis TL;DR, §6.2].

---

## 1. Scope

The seven RE notes answer one question each; this note puts their answers next to
each other and next to the plan. It does not repeat their evidence; the tags point
to it. Everything the RE set did was static: `readelf`, `nm`, `strings`,
`objdump`, `debugfs -R dump` from `system.raw.img`, header preprocessing, and
public source trees at fixed commits. Nothing ran on a device, so **every
runtime statement below is UNVERIFIED until the matching Phase test runs**
[br Verif. net effect, abi §8].

## 2. Does the project need reverse engineering?

| Question the plan raises | Answered by | What is left | More RE of closed binaries needed? |
|---|---|---|---|
| Which UM pairs with which KM | br §3-§7, fw §2-§3 | runtime confirmation of `SGXInit … [ OK ]` | no; Phase 1 observation |
| Do drop C's per-call bridge sizes match the KM | br §6 (2020 build only) | sizes for drop C | no; log them in our KM (§10 item 3) |
| Can the blobs load in a musl process | abi §6-§7, ub §4 | the `ld-linux-armhf.so.3` design choice, two hazards | no; strace and black-box tests (§10 item 4) |
| Is there a firmware file to ship or fetch | fw TL;DR 1-2 | nothing | no |
| What clock, rate, timing values the KM needs | sys §2-§7 | live VDD_CORE | no; device measurement |
| Does APM work with the `ti443x` uKernel | open (§4.4) | everything | no; observe in our KM (§10 item 5) |
| What the visualizer does | vis §2-§5 | FFT scaling, frame rate, EGL config, texture premultiplication | no; read AOSP source (§10 item 6) |
| Can we drop the blobs (open driver) | odf §9 | person-years | yes, and largely blocked by licences (§11) |

**Verdict.** For the closed-blob product the RE phase is over: the remaining unknowns
are runtime facts. RE stays relevant in three narrow places, all licence-clean:
our own KM's build-option and bridge tables (preprocessing our GPL tree), the GPL
stock kernel as parity ground truth, and Apache-2.0 AOSP sources for the
visualizer's audio details. The open driver is the only item that would need deep
RE, and it is research, not product work [odf §10].

## 3. musl/libc verdict

### 3.1 The rule: one process, one libc

A musl process cannot host real glibc [abi §7.5]:

1. musl's loader resolves any `DT_NEEDED libc.so.6` to itself (`ldso/dynlink.c:1070-1080`, musl v1.2.6).
2. glibc's `libc.so.6` needs `ld-linux-armhf.so.3` GLIBC_PRIVATE internals
   (`_rtld_global_ro`, `_dl_allocate_tls`, …; 17 such imports in trixie `libc.so.6`)
   that exist only when glibc's own loader started the process [abi V-row 14].
3. Both libcs claim the ARM thread pointer (TPIDRURO) for their thread descriptor.
4. Two mallocs cannot exchange pointers; Mesa and the blobs do exchange allocations.

So for every process that loads GL, the whole process is either musl (blobs
impersonated) or glibc (a separate userland island). The same reasoning rules out
bionic: musl's `ld.so` cannot load the stock blobs at all [hyb TL;DR 5].

### 3.2 Per consumer process

| Process | Loads the GL blobs? | Route B: glibc island | Route A: musl | Verdict |
|---|---|---|---|---|
| `pvrsrvinit` (open, Maemo `pvrsrvinit.c`; `dlopen("libsrv_init.so.1")` + `SrvInit()`) | `libsrv_init` + `libsrv_um` | glibc build inside the sandbox | native musl build. `libsrv_init` imports only `__cxa_finalize` and `__stack_chk_guard`, but in drop C it still has `DT_NEEDED libc.so.6` and `ld-linux-armhf.so.3` [fw §5 Verif., abi §3.1] | both work on paper; runs as root (`CAP_SYS_MODULE`), once per KM load [fw §2.1] |
| kmscube, `nexusq-visualizer` (GBM/KMS, no compositor) | Mesa-sgx → `libpvr_dri_support` → GLES, `libsrv_um`, `libusc`, `libglslcompiler` | Maemo daedalus debs in a copy of `/opt/glibc-rt` (glibc 2.36 ≥ 2.34) [ub §6 B] | Mesa-sgx built for musl + drop C + shim [abi §7.1] | **B for first light, A for the product** [gw §3 rows 1-2] |
| Weston 16 `renderer=gl` | same | inside the sandbox | Alpine Weston + private-prefix Mesa-sgx; needs `GL_EXT_unpack_subimage` (B1) | P [gw §3 row 3] |
| labwc / wlroots 0.20 | same | n/a (Alpine labwc is musl) | blocked by B1 and B2 | B [gw §3 row 4] |
| LXQt, Qt, GTK clients | no (stay on `wl_shm`) | — | — | keep software rendering [ub §6] |
| any process mixing musl with glibc's own `libc.so.6` | — | — | — | impossible (§3.1) |
| stock 1.8 bionic softfp blobs | — | — | only libhybris in-process (`jb` linker, `FP_ATTRIB`), or a separate pure-bionic process under the stock `/system/bin/linker` (untested on 6.18) [hyb §4, V-row 7] | not for the product (§5) |
| RoonBridge (existing `/opt/glibc-rt` user) | no | unaffected | — | — |

### 3.3 What musl 1.2.6 does for drop C (route A)

| Mechanism | Effect on the blobs | Evidence |
|---|---|---|
| Reserved names `libc.`, `libpthread.`, `librt.`, `libm.`, `libdl.`, `libutil.`, `libxnet.` | map to musl itself, before any path search | abi §4, `dynlink.c:1070-1080` |
| `ld-linux-armhf.so.3` | **not** reserved: must be found on disk in all 11 drop C files; it supplies only `__stack_chk_guard` (musl exports it) | abi V2 |
| Symbol versions | ignored (`GLIBC_2.34` harmless) | abi §4, `dynlink.c:264,283` |
| LFS64 names (`mmap64`, `lseek64` in TI `libdbm`) | remapped at relocation (`get_lfs64()`, `dynlink.c:350-376`) | abi §4, ub Verif. corrected 1 |
| time32 names (`clock_gettime`, `clock_nanosleep`, `select`, …) | musl exports them as time32 compat shims: layouts match | abi §4; the stat family does not match, but no blob imports it [abi V4] |
| pthread object sizes | equal to glibc armhf (24/48/36/32/20 B) | abi §4, glibc-2.41 `pthreadtypes-arch.h:31-39` |
| `DT_INIT`/`DT_FINI` | skipped on ARM; each blob's `_init` only calls `__gmon_start__` | abi §4 |
| TLS | none in any PVR blob | abi §4 |
| 9 fortify `__*_chk` imports | not in musl; all 9 in gcompat 1.1.0, or in our own shim | abi §6.2 |
| gcompat injection | `LD_PRELOAD` overrides 20 musl names process-wide (incl. GNU `strerror_r`); `dlopen(…, RTLD_GLOBAL)` after startup keeps musl first | abi §6.4 |

Three ways to satisfy `DT_NEEDED ld-linux-armhf.so.3` were proposed; none modifies a blob
except the third, which the licence excludes (§11):

1. our own small musl DSO with SONAME `ld-linux-armhf.so.3` that exports the 9 `__*_chk`
   functions, so no gcompat at all (it collides with gcompat's `/lib/ld-linux-armhf.so.3`,
   so gcompat must not be installed) [abi §7.1];
2. a private directory with `ld-linux-armhf.so.3 → /lib/ld-musl-armhf.so.1`; musl detects a
   DSO defining `__libc_start_main` + `stdin` and substitutes itself (`dynlink.c:1185-1193`),
   plus gcompat loaded explicitly [ub §4.4.2];
3. `patchelf --remove-needed` (a binary modification: excluded).

Drop B would need none of this (0 unresolved, 0 gcompat-only imports) but pairs only
with the classic-DRI `mesa-pvr-dri-classic` 20.3.2, because it lacks
`PVRDRIRegisterVersionedCallbacksV0`, which every current Mesa-sgx requires
[abi V6, ub Verif. "Mesa coupling"]. That route is dead [gw §3 row 7].

### 3.4 The two route-A hazards, reconciled

| Hazard | groundwork / `ub` reading | RE reading | Status |
|---|---|---|---|
| `libsrv_um` calls glibc's 32-bit-`off_t` `mmap@GLIBC_2.4` in `PVRSRVMapDmaBuf`; musl reads a 64-bit `off_t` from `[sp+8..15]` | "likely on the hot path of GBM/Wayland rendering" (*inference*) [ub §4.4.4] | the branch runs only with flag `0x8000000` clear **and** a zero 64-bit 5th argument; the offset passed is always 0. Drop B: statically unreachable from its only blob caller. Drop C: the caller passes flags 3 and a non-zero high word (`mul.w r7,r2,r1` @0x5a1c), so probably not reached [abi §4, V5, open 1] | UNVERIFIED either way; measure with `strace -e trace=mmap,mmap2` (Phase 2). Not reached by the blobs' own callers; `mesa-sgx` was not searched for a direct call [abi open 1] |
| `strerror_r`: the blob imports GNU `strerror_r` and XSI `__xpg_strerror_r`; musl's is XSI, gcompat's is GNU | the blob "would treat the `int` 0 as a string pointer"; a crash while reporting an error [ub §4.4.8] | the call site tests the return (`cbz r0`) and prints its own buffer, so under musl's XSI version the "no text" branch is taken; no crash expected; only error paths [abi §4 `strerror_r` row] | UNVERIFIED at runtime; test by provoking an error path (§10 item 4). Never `LD_PRELOAD` gcompat: that hands GNU `strerror_r` to every musl caller [abi §6.4] |

Both hazards were characterised by disassembling TI code, so both stay hypotheses
to be confirmed by observation, never by more disassembly [gw §6, ub §4.4.4].
The fix the RE notes keep in reserve (`patchelf --rename-dynamic-symbols`) is a
binary modification and is out under the TSPA reading in §11.

## 4. KM×UM compatibility

### 4.1 The handshake, check by check

"Versions must match" is six bridge checks plus the microkernel checks. The KM
validates only V and O on the bridge; I, P and S are never validated, so a wrong
pairing is misread rather than rejected [br TL;DR 1].

| # | Check | 1.17 (`ti443x` UM, letux KM) | ≤ 1.12 (stock 1.8, Linux 1.9) | Validated by | Evidence |
|---|---|---|---|---|---|
| T | Transport | UM `drmOpenRender(128..143)`, accepts only a driver named `"pvr"`, falls back to `/dev/dri/card%d`; bridge = `drmCommandWrite(fd, 0, &pkg, 28)` (DRM nr 0x40); probes `drmCommandNone(fd, 3)` (`PVR_IS_MASTER`) | stock: `open("/dev/pvrsrvkm")` + `ioctl(fd, 0xC01C67nn, &pkg)`; 1.9: `drmOpen("omapdrm")` + `drmCommandWriteRead(fd, 2, "omapdrm_pvr", 72)` (TI omapdrm plugin) | open fails | br §2, Verif. 11, 17 |
| P | `PVRSRV_BRIDGE_PACKAGE` layout, 28 B | `{ID, Size, hParamIn, hParamOut, InSize, OutSize, hKernelServices}` | `{ID, Size, pIn, InSize, pOut, OutSize, h}` | **never** | br §2, Verif. 10 |
| I | Command index table | 35/35 with `SUPPORT_DMABUF`; `UM_KM_COMPAT_CHECK` at 0 shifts all by +1 | stock table: 122 slots, KM checks only id ≤ 0x79 | **never** (bounds only) | br §3, Verif. 2 |
| V | DDK version | UM sends ioctl 0 (`0xC01C6700`, in 8/out 8) `{0x00011100, 4948957}` → `PVRSRVCompatCheckKM` (`common/pvrsrv.c:173-188`) → `(FAIL) UM-KM DDK Mismatch` | KM compares the **uKernel's** `0x00010812`/785978 (stock) or `0x00010913`/2253347 (1.9); UM `SGXConnectionCheck` compares the KM's `DRIVER_SGXREV` reply, returns 25 on mismatch | KM and UM | br §4, fw §2.6 Verif. |
| O | `SGX_BUILD_OPTIONS` | KM: client options (srvinit constant in `SGX_BRIDGE_INIT_INFO`) vs KM, exact on b618 (`sgxinit.c:2714`), masked on b72 (`0xffc5fc86`, `:2720, :2847`); then uKernel options vs KM; UM: exact `SGXConnectionCheck` (2020 build @0x7dee) returns 26 on mismatch | same, exact everywhere | KM and UM | br §5, Verif. 7-9; fw §2.6 |
| S | Per-call in/out sizes | 2020 build: 102/103 match; one `FREE_DEVICEMEM` site passes out 8 against a 4-byte KM struct (benign) | — | **never** (only ≤ 0x1000) | br §6, Verif. 12 |
| uK-rev | HW `EUR_CR_CORE_REVISION` (reg 0x24) vs uKernel `CoreRevSW` | all three OMAP4 uKernels report 0x10200; exceptions 0x10100/0x10101; skipped if 0 | same | KM | fw §5, Verif. 12 |
| uK-size | 13 SGXMKIF struct sizes | uKernel vs the sizes `libsrv_init` passes; **never against the KM's own `sizeof`** | same | KM, but blind to KM layouts | br §4, Verif. 15 |
| init | init-server gate and script format | `CAP_SYS_MODULE`, once per KM load; `SGX_INIT_OP_HALT` = 4 in 1.17 (2 in 1.8), so a 1.8 script is misread by a 1.17 KM | — | KM | fw §2, Verif. 14, 16 |

### 4.2 The matrix

Cells: ✔ pass, ✘ fail, ~ passes only with a KM build change. From [br §7] with the
2026-10-11 corrections; the drop C row adds [abi synthesis notes].

| UM ↓ / KM → | stock 1.8@785978 (`vmlinux` = AOSP `03a9286b`) | letux 1.8.869593 | letux 1.9.2188537 | TI/letux 1.9.2253347 | 1.14.3699939 | letux 1.17 (b618 `pvrsrvkm-6.18-rc6`, b72 `pvrsrvkm-7.2`) |
|---|---|---|---|---|---|---|
| **stock 1.8@785978** (bionic, softfp) | **all ✔** (41/41 ids, `0x10812`/785978, `0x36801C`); KM is 3.0-era, needs a 6.18 port | I✘ 8/41, V✘ 869593, O✘ `0x360018` lacks bits 2 and 15, S✘ 114/132 | I✘ 21/41, V✘ | T✘ (plugin), I✘ | T✘, I✘ 0/41 | T✘ P✘ I✘ 0/41 S✘; b72 with `PVR_ABI_COMPAT=1,7,862890`: P✔ but I✘ 16/41, V✘ |
| Android 1.8@905891 (reference) | I✘ 21/41 | I✘ | I✔ 41/41, V✘, O✘, S✘ 121/137 | I✘ | ✘ | ✘ |
| **Linux 1.9@2253347** (drop A) | ✘ | ✘ | ✘ | **T✘ on 6.18** (`DRM_OMAP_GET_BASE` absent from `omap_drm.h`); P✔ I✔ 41/41 V✔ O~ (`0x68018`) S✔ 149/149; letux tree has no Makefile | ✘ | ✘ |
| **TI 1.17 2020** (drop B) | ✘ | ✘ | ✘ | ✘ | T✔ **P✘** V✘ (3699939) | **T✔ P✔ I✔ 35/35 V✔ O✔ `0x360018` S✔ 102/103** (static) |
| **TI 1.17 2024** (drop C, the plan's UM) | ✘ | ✘ | ✘ | ✘ | as B | T✔ P✔ I✔ 35/35 V✔ (same words) O✔ (`0x360018` @0x88c8) **S UNVERIFIED** (sizes never measured on this build; unexplained `0x360b14` in `SGXDevInitPart2` @0x8430) |

The microkernel stamps agree with this: drop C's `libsrv_init` reports DDK build
4948957, CoreIdSW 540, CoreRevSW 0x10200, options `0x00360018` [fw §3].

### 4.3 Build-options words

| Side | `SGX_BUILD_OPTIONS` | Bits | Evidence |
|---|---|---|---|
| stock KM, stock UM, stock `libsrv_init`, stock uKernel | `0x0036801C` | 2, 3, 4, 15, 17, 18, 20, 21 | br §5, sys §2.8, fw §3 |
| Linux 1.9@2253347 UM and uKernel | `0x00068018` | 3, 4, 15, 17, 18 | br §5, fw §3 |
| TI 1.17 `ti443x` UM (B and C) and uKernel | `0x00360018` | 3, 4, 17, 18, 20, 21 | br §5, fw §3 |
| letux 1.17 KM (b618, b72) as built | `0x00360018` (bit 20 from `SUPPORT_SGX_LOW_LATENCY_SCHEDULING` via `sgxfeaturedefs.h:282-284`; bit 15 forced to 0 by `include4/sgx_options.h:151` while `-DSUPPORT_ACTIVE_POWER_MANAGEMENT` is still passed) | 3, 4, 17, 18, 20, 21 | br Verif. 7, fw §3 Verif. |
| letux 1.8.869593 KM as built | `0x00360018` (lacks `0x8004` against stock) | 3, 4, 17, 18, 20, 21 | sys Corrected 15 |
| letux 1.9.2188537 KM | `0x00368018` | 3, 4, 15, 17, 18, 20, 21 | fw §3 Verif. |

### 4.4 Consequences for our KM build

- **No extra define is needed** for the 1.17 pairing; the original "bit 20 gap" was
  an artefact of evaluating `sgx_options.h` without `sgxfeaturedefs.h` [br Verif. 7].
  Re-evaluate the word for our exact Kbuild flags at the compile gate (§10 item 2).
- **APM is the open point.** The letux KM compiles APM in but reports bit 15 = 0
  (openpvrsgx `84db121f1016`, "HACK: missing userspace flag") [kdp claim 20]; the
  `ti443x` uKernel was built without bit 15 [fw §3]; TI's own `ti443x` KM sets
  `SUPPORT_ACTIVE_POWER_MANAGEMENT := 0` [ub §3.7]. Stock's idle path is driven by
  microkernel active-power events (`SGXTestActivePowerEvent` @0xc0295ae8 →
  `SysSGXIdleTransition`) [sys §2.7, stk §5.4]. Whether those events arrive from a
  uKernel built without APM is **UNVERIFIED (reasoning: the option word is the
  only evidence and it says "off")**. The plan's 100 ms APM latency, risks P3 and
  P9, and the Phase 4 exit "GFX off within `sgx_apm_latency` + ε" assume it works
  [gw §2, §5]. Observe it in Phase 1 (§10 item 5).
  *Narrowed 2026-10-11 [pm Addendum APM]:* the KM side is settled from source. The
  `ACTIVE_POWER` request is written only by the microkernel; the KM has no idle timer;
  `pvrsrvinit`'s compatibility check and every client clean-up power the device ON.
  Without microkernel APM events, GFX therefore stays ON from `SGXInit` until suspend,
  whether or not patch (d) is applied. TI keeps the SGX clocks on from load to suspend
  for all its OMAP/AM products. Only the microkernel side remains UNVERIFIED. Against
  it: bit 15 is off. For it: Lindgren's commit claims in `84db121f1016` and Maemo
  `2cd8d74ec61a`, neither of them measured. The fallback is (h), a host-side idle
  power-down.
- **The KM never cross-checks its own SGXMKIF layouts against the uKernel**
  [br §4, Verif. 15]. With one DDK (1.17) on both sides this is low risk; it is
  why mixing a 1.17 KM with any other uKernel must never be tried by faking the
  version words [fw §4 conclusion].
- **A deliberate options mismatch for the Phase 1 "seen failing" test** has to be
  made on the KM side (an extra define such as `PVRSRV_USSE_EDM_STATUS_DEBUG`,
  bit 2), not by editing a blob (§11). On b618 any bit is refused; on b72 (fallback
  F2) bits 0, 3, 4, 5, 6, 8, 9, 17, 19, and 20/21 on non-5XT cores are masked
  [br §5].

## 5. libhybris and the stock blobs

**Verdict: partly viable at best, and only offscreen; not a product path** [hyb TL;DR 9, §5, Verif. V].

- **Pairing.** The 13 IMG blobs on the Q are byte-identical to Google's public
  `imgtec-maguro-imm76d-0f59ea74.tgz` [hyb §1.1, Verif. 2]. They pair only with a
  KM built as 1.8@785978 with options `0x0036801C`; AOSP `kernel/omap`
  `android-omap-steelhead-3.0-ics-aah` @ `03a9286bb61a` is that KM's GPL source by
  version and by dispatch table (41/41), not proven byte-identical (the stock
  banner is `3.0.8-gad584da`, and `ad584da` is not in AOSP) [hyb Verif. 3, br Verif. 4].
  No letux tree fits: 869593 shifts every id from 31 upward [hyb §3.2].
- **ABI.** Pure bionic, softfp (no `Tag_ABI_VFP_args`), GCC 4.4.3; imports `__errno`,
  `__sF`, `__srget`, `__page_size`, 4-byte bionic mutexes [hyb §2]. libhybris master
  `7079712a` still builds the `jb` linker and wraps softfp with
  `FP_ATTRIB = pcs("aapcs")`; ICS (SDK 15) falls into `jb` + `hooks_common` [hyb §4.1-§4.2].
- **Blockers on our rootfs.** pmOS removed hybris on 2020-08-03 (`e1a3324e`); its musl
  patch predates musl 1.2's 64-bit `time_t`; upstream `hooks.c` has no time64 handling;
  bionic `__errno` writes `TP+8`, which is musl's first static-TLS word, from every
  unhooked failing syscall stub; `jb` skips `libc.so` constructors, so bionic globals
  are never initialised (impact UNVERIFIED) [hyb §4.4, Verif. 13-14, "New risk"].
- **Display.** Zero-copy on-screen output is dead on mainline: gralloc needs
  `omaplfb` and the stock `omaplfb` calls `dsscomp_gralloc_queue`; `hwcomposer.omap4`
  needs `/dev/dsscomp`. HWC 0.1 itself is consumable (`qt5-qpa-hwcomposer-plugin`
  `HwComposerBackend_v0`). Offscreen (`null` platform) plus a CPU copy is not ruled
  out [hyb §5, Verif. 10].
- **Licence.** The imgtec package licence limits use to the Galaxy Nexus,
  non-commercial, and withholds the right to "disassemble, decompile, reverse
  engineer" (§3.b(i)) [hyb §1.1, Verif. 18].
- **What we keep.** The 785978 UM/KM pair is a byte-exact, public reference for
  SGX540 rev 120 on OMAP4: the bridge table, the compat constants and the uKernel
  layout are recorded [hyb §5]. Its use as a *running* oracle (odf T1-T3 on stock
  Android) is limited by the same licence (§11).

## 6. Stock sysconfig parity and what the kernel side must add

### 6.1 Parity (31 rows of sys §6, updated where a groundwork note has since answered a row)

"Ours" = mainline 6.18.48 DT and clock data + `kernel/dts/omap4-steelhead.dts` +
`kernel/configs/steelhead_defconfig` + the letux glue at `d2f1e031`.

| # | Item | Stock | Ours | Verdict | Kernel action |
|---|---|---|---|---|---|
| 1 | Register base | 0x56000000 | target-module `ranges` 0x56000000 | MATCH | — |
| 2 | Register window | 64 KiB | 32 MiB, fully ioremapped by `pvr-drv.c` | MISMATCH | none (benign) |
| 3 | IRQ | GIC SPI 21 (Linux 53) | `GIC_SPI 21` | MATCH | — |
| 4 | OCP sysc, idle modes | rev 0xFE00, sysc 0xFE10, all SIDLE/MSTANDBY | same | MATCH | — |
| 5 | Module clkctrl | `0x4A009220`, MODULEMODE SW | `l3_gfx_clkctrl` clk@20 | MATCH | — |
| 6 | Power domain | `gfx_pwrdm`, PRM 0x1200 | `prm_gfx` genpd | MATCH | stock also allowed INACTIVE (pwrsts `0x0d`), mainline is OFF_ON; fine [pm §1.2] |
| 7 | fck source (mux bit 24) | `dpll_per_m7x2_ck` (board code `@0xc0075f40`) | `dpll_core_m7x2_ck`, **266 666 667 Hz measured** (`nq-captures/20261010-185940/snapshot.txt:467-470`) | **MISMATCH** | `&sgx_module` assigned-clocks block (draft [0062](drafts/0062-ARM-dts-omap4-steelhead-run-the-SGX-from-DPLL_PER-like-stock.patch.draft)) |
| 8 | `dpll_per_m7x2_ck` boot rate | 307.2 MHz (x-loader PER M7=5) | inherited | MATCH | make it explicit with `assigned-clock-rates` |
| 9 | GPU OPP table | 153.6 / 307.2 / 384 MHz | none | MISSING | fixed 307.2 MHz; DVFS only with groundwork Phase 7 |
| 10 | VDD_CORE scaling with GPU OPP | 962 / 1127 / 1250 mV | static; VC ON target 1.2 V (patch 0027, never sent), runtime value expected 1.139 V from the x-loader, unmeasured [pm Addendum "Live VDD_CORE without a device"] | MISSING | **never 384 MHz**; 307.2 MHz only after VDD_CORE ≥ 1.127 V is measured |
| 11 | DVFS policy (`sgx_idle` mode 2) | idle → 153.6 MHz after 1-3 ms | none | MISSING | optional idle down-clock 307.2 ↔ 153.6 MHz |
| 12 | sgxfreq governors | absent | not built | MATCH | — |
| 13 | Core clock reported to the uKernel | current OPP | 1.17 OMAP4: 200 MHz (`sysconfig-am4.h`) | **MISMATCH** | `SYS_SGX_CLOCK_SPEED` 307 200 000, or `clk_get_rate()` of the fck |
| 14 | HW recovery rate | 100 Hz | 1.17: 50 Hz | MISMATCH | 100 Hz |
| 15 | uKernel timer | 1000 Hz | 1000 Hz | MATCH | — |
| 16 | Active power management | on, 100 ms | 1.17: on, 2 ms (bit 15 hidden, §4.4) | MISMATCH | 100 ms; confirm APM works at all |
| 17 | runtime-PM coupling | `get_sync`/`put_sync` | sysconfig layer equivalent, **but `pvr_probe()` holds a reference until remove** | MATCH in `sys`; superseded by [pm TL;DR 8] | patch (d) [gw §3] |
| 18 | OCP IRQ path | IRQSTATUS_2 / ENABLE_SET_2 / CLR_2 only | letux also writes `DEBUG_CONFIG = BIT(31)` (THALIA_INT_BYPASS) | **MISMATCH** | drop the bit for the OMAP4 quirk if IRQ anomalies appear |
| 19 | OCP SYSCONFIG owner | hwmod | ti-sysc | MATCH | — |
| 20 | Platform data `device_scale` | `omap_device_scale` | none | MISSING | only with DVFS |
| 21 | Device binding | `pvrsrvkm.0` from hwmod `gpu` | `ti,omap4430-gpu` via `pvr-drv.c` | MATCH | — |
| 22 | UM interface | `/dev/pvrsrvkm` + ION client | DRM `"pvr"`; no ION | MISMATCH | none for 1.17 |
| 23 | DDK build gate | uKernel must be 785978 | 1.17: UM must be 4948957 | MISMATCH (stock UM only) | none for 1.17 |
| 24 | KM build options | `0x0036801C` | `0x00360018` | MISMATCH (stock UM only) | none for 1.17 (both sides `0x00360018`) |
| 25 | Core revision | {120,121} from errata code | `SGX_REV=120` | MATCH | — |
| 26 | Preemption | `SMP PREEMPT` | `CONFIG_PREEMPT_NONE=y` | **MISMATCH** | `PREEMPT_VOLUNTARY` or `PREEMPT`; compile-enforced by `#error` in `osfunc.c:126-135` [kdp TL;DR 8] |
| 27 | HZ | 128 | 100 | MISMATCH | none |
| 28 | `sgx_idle` params, debugfs | present | absent | EXTRA | port only the 100 ms APM value |
| 29 | Reset value of CLKSEL_SGX_FCLK | — | was UNKNOWN in `sys`; now **CORE** by measurement (row 7) | answered | — |
| 30 | Runtime VDD_CORE | per OPP | unmeasured; expected 1.139 V (x-loader VCORE1 vsel 0x23) | UNKNOWN | read in Phase 0 with `nexusq-gpu-probe.sh --pmic` [pm §4, pm Addendum "Live VDD_CORE without a device"] |
| 31 | `omap_prm` GFX instance in 6.18 | stock pwrdm | was UNKNOWN in `sys` (partial tree); mainline carries the OMAP4 glue [gw §1 "SoC glue", ml §7.1] | answered | — |

### 6.2 What the kernel side must add (consolidated)

1. **DT clock block** on `&sgx_module`: parent `dpll_per_m7x2_ck`, rate 307 200 000
   [sys rec. 1; draft 0062].
2. **A rate gate:** no 384 MHz ever without VDD_CORE scaling; 307.2 MHz only after a
   live VDD_CORE ≥ 1.127 V; otherwise 153.6 MHz [sys rows 9-10, gw P8].
3. **An OMAP4 sysconfig header** replacing the AM437x values: 307 200 000 Hz (or
   `clk_get_rate()`), HW recovery 100 Hz, uKernel 1000 Hz, APM latency 100 ms [sys rec. 3;
   gw patch (c)].
4. **A preemptible kernel** [sys row 26, kdp §8 k].
5. **Balanced runtime PM in `pvr_probe()`** [pm TL;DR 8; gw patch (d)].
6. *Optional, on evidence:* no `DEBUG_CONFIG` BIT(31) for OMAP4 [sys row 18]; this item is
   not in the groundwork patch list (a)-(g) (§12 item 15).

## 7. Firmware and microkernel

[fw TL;DR, §1-§5, Verif.]

- **No file.** None of the 1.8.869593, 1.9.2188537, 1.9.2253347 or 1.17.4948957 KM
  trees calls `request_firmware`; stock `/vendor/firmware` has no SGX file. The June
  note's `sgx540_*.fw` statement is wrong.
- **Where it lives.** Stock `libsrv_init.so` (sha256 `c4dee422…`) `.rodata`
  0x2074-0x1ad6c is exactly: uKernel 24 800 B, TA 23 104 B, SPM 21 408 B, 3D 31 088 B,
  then five PDS programs of 44/76/44/880/180 B, then strings. Drop C's image sizes are
  22 112 / 21 744 / 18 480 / 23 680 B; drop A's 20 224 / 18 848 / 17 504 / 21 984 B.
  All twelve image hashes differ: no image is shared between DDKs.
- **Loading.** `SrvInit()` allocates device memory through the normal bridge, copies
  the programs, patches 15 placeholders (`0xDEADBEEF` encoded as a split 64-bit
  `mov rN, #imm`: `w0[20:0]`, `w1[8:4]`, `w1[17:12]`), builds register-write scripts
  (`EUR_CR_USE_CODE_BASE(15)` = EDM at the uKernel heap, `PDS_EXEC_BASE`,
  `EVENT_KICKER`, plus registers no public header names) and sends meminfo handles and
  scripts via `SGX_DEVINITPART2`. The KM runs the scripts, kicks, and waits for
  `PVRSRV_USSE_EDM_INIT_COMPLETE`; the code stays resident.
- **Identity.** Each uKernel stamps DDK version, build, CoreIdSW 540, CoreRevSW
  0x10200 and its options word (table in §4.3). Rev-specific by design; only TI OMAP4
  userspace fits our core.
- **Checks.** 1.8/1.9 KMs check the uKernel's DDK build; the 1.17 KM does not, it
  checks the UM's build over ioctl 0 instead (§4.1).
- **Tooling.** No open USSE1 disassembler or encoding spec exists. Garnet's
  `sgx540-reversing` (`c15884751ad8`) ships a partial open assembler whose
  long-immediate split matches the srvinit patch encoding exactly; its disassembler
  hijacks Imagination's closed x86 `GLSLESCompiler_Series5`. We cannot modify or
  re-target the uKernel; faking the four version/option immediates would hide real
  SGXMKIF differences and is not a fix.
- **Partitions.** No other stock partition holds SGX content.

## 8. Open-driver feasibility

[odf TL;DR, §9, Verif.] One experienced GPU-RE engineer, full time, P50-P90;
judgements, not measurements [odf Verif. 18-19].

| Target | Effort |
|---|---|
| M0 closed stack running + tracer/KM capture/shader-dump tooling | 1.5-3 PM |
| Minimal engine: clear + textured quad + alpha blend, open userspace, closed uKernel reused (M0-M4) | **9-19 PM** |
| Wired into Mesa for weston/wlroots (M5) | +4-8 PM |
| Real NIR→USSE compiler, dEQP-GLES2-grade GLES2 (M6-M7) | +21-42 PM |
| Fully open uKernel or host-driven scheduling (M9) | +6-18 PM, least certain |
| Upstreamable DRM driver (M8) | +6-12 PM plus review |
| Fully open, upstream-quality GLES2 | **≈ 4-7 person-years** |

- The minimal compositor target is 25-35 % of the full effort, but keeps the fixed
  costs (TA/PB/DPM setup, PDS, uKernel kick semantics, MMU, texture state) [odf §9.3].
- Closed parts that would need RE: the uKernel microcode, the client command layouts
  (TA/3D register blocks, PDS programs) and two ISAs (USSE1, PDS). Open already: the KM,
  the MMU format, the CCB host interface [odf TL;DR 4].
- The strongest recent signal is on SGX535 (SGX535-reMESA first triangle 2026-10-06),
  not SGX540; transfer of its ISA findings is UNVERIFIED [odf §3.4].
- Recommendation kept: do not start an open driver to get acceleration on the Q;
  re-decide only after a replayed captured triangle (M1) within about 2 PM and a second
  contributor [odf §10]. §11 adds that most of the tooling (T1, T3, T4, T6) would analyse
  blobs whose licences forbid it.

## 9. Visualizer spec summary

[vis TL;DR, §2-§7, Verif.]

| Aspect | Stock behaviour | Evidence |
|---|---|---|
| API | GLES 2.0 through `GLSurfaceView` (`setEGLContextClientVersion(2)`); no RenderScript, no GLES1, no native code | vis Verif. 1 |
| Shaders | 31 GLSL ES 1.00 files in `res/raw`; text not copied into this repo, sha256 in vis Appendix A | vis Verif. 2 |
| Global GL state | only `GL_BLEND` enabled; `(SRC_ALPHA, ONE_MINUS_SRC_ALPHA)`; clear `(0,0,0,1)`; no depth test, no VBOs, no mipmaps, no extensions | vis §2.1, Verif. 17 |
| Idle screensaver | 40 `GL_POINTS`, `gl_PointSize` 60 px, `particle2.png`, colour `(0, 0.6, 0.8, 0.6·alpha)`, blend `(SRC_ALPHA, ONE)`, drawn straight into the screen framebuffer at HDMI size; ring radius 1.5-1.7 minus `0.5·throb`, z = −13 − 2·throb, 10 s throb period, 45° vertical FOV | vis §3, Verif. 3-4 |
| Music path | per frame: fresh 960×540 RGBA8 FBO from a pool of 3; previous frame redrawn through 1 of 6 distortion shaders (zoom/rotate normalised to 30 fps); current scene on top, additive; linear upscale blit to the screen | vis §4.1, Verif. 6 |
| Scenes | Waveform, WaveformSolid, Circles (256 sprites up to 192 px), PointMorph (258 points, 4 models), StarField (100 quads, 100 draw calls); order from `java.util.Random(0)`, 10 s each, 5 s cross-fade | vis §2.2, §4, Verif. 8 |
| Decay | per frame, not per second: `rgb' = (rgb − 0.002)·0.95`; trail length depends on the frame rate | vis §4.1, Verif. 9 |
| Audio | `Visualizer(0)`, 20 segments/s × 1024 samples; per-buffer power-of-two AGC up to 32× in `libvisualizer.so`; beat tracker with 833 Gaussian combs, 50-179 BPM | vis §5, Verif. 10-12 |
| Sync | scene clock aligned to `android.os.CommonClock`, so grouped units show the same scene (code-level only) | vis Verif. 13 |
| Cost | idle: ≈ 144 k blended fragments/frame, ≲ 10 % of one core in software at 1080p with damage-rect clearing; music: ≈ 3.2-4.1 M fragments/frame at 1080p, 60-90 % of one A9 core at 30 fps in software | vis §6, Verif. 5, 15 (estimates) |
| Side finding | the LED ring dims to 20 % on mute; `nexusqd` does not implement it, and `docs/2026-06-19-particle-screensaver-RE.md` says the opposite | vis Verif. 16 |

## 10. RE work items, in recommended order

Only items that are licence-clean under §11. Efforts are focused engineer-days,
UNVERIFIED estimates.

| # | Item | Object and method | Phase | Effort | Closes |
|---|---|---|---|---|---|
| 1 | Freeze further disassembly of TI and stock IMG blobs; Petr decides what happens to the disassembly-derived passages already in `abi`, `br`, `fw` (§11) | policy | now | < 0.5 | §12 item 1 |
| 2 | Evaluate our exact KM build: preprocess the tree we ship with the real include order (`sgxdefs.h` → `sgxfeaturedefs.h` before `sgx_options.h`), emit `SGX_BUILD_OPTIONS`, the mask, and the bridge index table with `SUPPORT_DMABUF` | our GPL KM source | 1 (compile gate) | 0.5-1 | §4.3; the tracer table drift in §12.2 item 3 |
| 3 | KM-side bridge logger behind a debug knob: per call id, `InBufferSize`, `OutBufferSize`, return code; the `PVRSRVCompatCheckKM` words; the `SGXDevInitCompatCheck` values incl. HW reg 0x24 and the uKernel-reported struct sizes | our GPL KM at runtime | 1-2 | 1-2 | drop C size check (S), core rev 0x10200, `br` open 2-3 |
| 4 | Black-box route-A probes: `strace -f -e trace=mmap,mmap2,openat,ioctl` of kmscube; provoke an error path (KM unloaded, so `OpenServices` fails) and check the message prints without a crash; list unresolved symbols with musl `ldd` | the system boundary | 2 | 0.5-1 | §3.4 both hazards, `abi` open 1, `ub` open 1 and 10 |
| 5 | APM with the `ti443x` uKernel: with a client open but idle, log active-power events in the KM and watch genpd `prm_gfx` | our KM + PRM state | 1 and 4 | 0.5-1 | §4.4 |
| 6 | Visualizer details from Apache-2.0 AOSP source instead of binaries: `Visualizer::doFft` scaling, the visualizer effect's AGC, the `GLSurfaceView` default EGL config, `GLUtils.texImage2D` premultiplication; cross-check against the constants `vis` already derived (128/1024, 20000 mHz, the AGC shift formula). File locations in AOSP `android-4.0.4_r*` are UNVERIFIED (from knowledge) | public source | 4 | 1-2 | `vis` open 2, 4, 5, 6 |
| 7 | Stock frame rate and HDMI mode: a video of a stock unit, or a stock RAM boot with logging | observation | 4 | 0.5 + device time | `vis` open 1, the decay calibration |
| 8 | Read the AOSP steelhead `drivers/gpu/pvr/omap4/` sources for `sgx_idle` and the timing constants (already used by `stk` §5.4, `src:sysconfig.c:1201`) | GPL source | optional | 0.5 | `sys` and `hyb` open questions on `sgx_idle` source |
| 9 | Open-driver tooling, only after Phase 4 and with a committed contributor: T2 (capture in our own KM) first; T1 (an `LD_PRELOAD` ioctl tracer) only after the legal reading in §11; T3, T4, T6 blocked | — | after 4 | ≥ 3-5 PM | `odf` §7 |

Items 2-8 total about 4.5-8 engineer-days. None needs a closed binary to be read.

## 11. The TI TSPA and the other licences: which RE we may do on what

The TI 1.17 `LICENSE` at `84a396a` ("TEXAS INSTRUMENTS TEXT FILE LICENSE",
`LicenseRef-TI-TSPA` in meta-ti), lines 18-31: "Redistribution and use in binary form,
**without modification**, are permitted provided that … No reverse engineering,
decompilation, or disassembly of this software is permitted … for use only with TI
Devices" [ub §8]. `pvr-omap4` 1.9 carries the same no-RE and no-modification terms
[ub §8]. *Corrected 2026-10-11 [ub Addendum B.2]:* drop B's commits have no `LICENSE`;
their terms are the 2013 "TECHNOLOGY AND SOFTWARE PUBLICLY AVAILABLE SOFTWARE LICENSE FOR
OMAP(TM) USER SPACE GRAPHICS DRIVER BINARY" inside `TI-Linux-Graphics-DDK-UM-Manifest.doc`:
the same binary-without-modification and no-RE terms, but no "for use only with TI
Devices" clause. Everything below is a **legal reading, not advice**; EU Directive
2009/24/EC Art. 6 (decompilation for interoperability) may apply, and its reach is a
question for a lawyer [hyb §1.1, odf §8].

| Object | Licence | RE we may do | RE we may not do |
|---|---|---|---|
| TI DDK 1.17 drops B and C, `pvr-omap4` 1.9 (drop A) | TSPA / TI text licence | run the binaries unmodified; read ELF metadata needed to install and link them (`readelf -d/-V`, dynamic symbols, sha256); observe the system boundary (`strace`, KM-side logging, dmesg, `/proc`, `eglinfo`/`glGetString`, `glGetFloatv` limits); black-box tests | disassembly or decompilation (objdump, Ghidra, decoding embedded uKernel immediates); `patchelf`, symbol weakening, `dd` string patches, `strip` (all are modification, on the device too [ub §8]); creating a mismatched UM by editing a blob (§4.4) |
| Disassembly-derived facts already in `abi` (§4 mmap/`strerror_r`/`fcntl`/syscall sites), `br` (1.17 2020/2024 and 1.9 `libsrv_um` functions, 1.14 constant scans) and `fw` (USE immediates of the 1.9 and 1.17 `libsrv_init`) | — | treat as hypotheses to confirm by observation | extend them; whether they stay in the repo (and in any public copy of it) is Petr's call |
| Stock IAN67K / Galaxy Nexus IMG blobs (1.8@785978) | imgtec package licence: Galaxy Nexus only, non-commercial, §3.b(i) no "disassemble, decompile, reverse engineer"; the Q's factory-image terms were not read [hyb §1.1, Verif. 18] | reference use of facts already recorded; take the bridge ABI from the GPL KM source (AOSP `03a9286b`) instead of from the UM | further disassembly; running them as an RE oracle (odf T1/T3 on stock Android) without a legal opinion |
| Stock kernel `reverse-eng/vmlinux.bin` incl. the built-in PVR KM | GPL-2 (the DDK identity string says `…_GPL`; source at AOSP `03a9286b`) | full static analysis (what `sys`, `br`, `fw` did on it) | — |
| Stock x-loader and bootloader images | U-Boot code, GPL-2.0+: the bootloader's uImage name is "U-Boot 2011.09-rc1 for tungsten", and the x-loader's clock/voltage code matches upstream U-Boot `omap4/clocks.c` [pm Addendum "Live VDD_CORE without a device"]. The x-loader's TI HS header/PPA part ("PPA", "CertPK_" strings) is TI's; its terms are not checked (UNVERIFIED) | read-only analysis as done in `sys` §3.5 and the pm Addendum; never write those partitions (AGENTS.md hard rule) | anything beyond reading the PPA part until its terms are known |
| Stock `Visualizer.apk`/`.odex` (Google, "Copyright 2011 Google Inc.") | no grant found; factory-image terms not read | the behavioural spec already in `vis`; re-author shaders for public images [gw §6] | redistributing the shader text or PNGs |
| AOSP-built native libraries (`libvisualizer.so`, `libaudioeffect_jni.so`, `libmedia.so`, `libdvm.so`) | built from Apache-2.0 AOSP sources (UNVERIFIED that IAN67K matches a public tag) | read the source (§10 item 6) | — |
| Imagination `GLSLESCompiler_Series5` (Garnet's disassembler hijack) | PVRShaderEditor terms not checked; the disassembling package is NDA-only [odf §3.2] | nothing until the terms are read | the hijack workflow |
| The 2014 leaked SGX DDK source | — | — | never look at it; contributor attestation if an open driver starts [odf §8] |
| openpvrsgx KM, AOSP KM, Maemo `libdbm`, MobiAqua `pvrsrvinit`, Mesa-sgx | GPL / MIT / LGPL (*corrected 2026-10-11:* Maemo's own `pvrsrvinit.c` has no licence [ub Addendum B.1]) | everything | — |

## 12. Inconsistencies

### 12.1 Between the RE notes and the groundwork note

Not edited anywhere; listed for the next pass over [gw]. *Applied 2026-10-11:* every
row is now a dated correction in [gw] (marked *Corrected 2026-10-11 [re §12.1 row N]*;
list in [gw]'s addendum); rows 10-13, where [gw] holds, were corrected in `sys`
instead. Row 1's disassembly passages stay as written, pending Petr's decision
(§10 item 1).

| # | Groundwork says | RE notes say | Which holds |
|---|---|---|---|
| 1 | "two call sites of a TI binary were disassembled … no further disassembly" [gw §6 compliance note] | TI binaries were disassembled much more widely: `libsrv_um` and `libpvr_dri_support` of drops B and C, drop A's `libsrv_um` [abi §4, V5, V8]; 1.17 2020/2024 and 1.9 `libsrv_um` functions, 1.14 constant scans [br §1-§5, Verif. 8-17]; USE immediates of the 1.9 and 1.17 `libsrv_init` [fw §3] | RE notes; the compliance record understates (§11) |
| 2 | the `mmap@GLIBC_2.4` hazard is a structural risk "likely on the hot path" [gw TL;DR 9, ub §4.4.4] | not reached from either drop's own caller (B: unreachable; C: probably not) [abi V5] | RE more specific; both stay UNVERIFIED until strace (§3.4) |
| 3 | `strerror_r` GNU/XSI clash, a crash while reporting errors [gw TL;DR 9, ub §4.4.8] | the blob tests the return and prints its own buffer; under musl's XSI version no crash is expected [abi §4] | RE more specific; test the error path (§10 item 4) |
| 4 | route A = "musl + gcompat + a small shim" [gw TL;DR 9, §2] | `abi` §7.1 prefers our own `ld-linux-armhf.so.3`-named DSO with the 9 `__*_chk` and **no** gcompat package; `ub` §4.4.2 a symlink to `ld-musl` plus gcompat; `abi` §6.4 warns never to `LD_PRELOAD` gcompat | open design choice for Phase 2 |
| 5 | the plan ships drop C on the strength of the bridge match [gw §3] | per-call sizes (check S) were measured on the 2020 build only; drop C's S is UNVERIFIED and loads an unexplained `0x360b14` [abi synthesis, br open 4] | gap; close by KM logging (§10 item 3) |
| 6 | APM on, 100 ms latency; risks P3/P9 and the Phase 4 exit rely on it [gw §2, §5, §4] | the `ti443x` uKernel has no APM bit; letux hides the bit; TI's `ti443x` KM disables APM [fw §3, kdp claim 20, ub §3.7] | UNVERIFIED that APM works (§4.4); KM side settled, microkernel side open, fallback (h) [pm Addendum APM] |
| 7 | "KM and UM must be the same DDK build with the same build-options mask" [gw §2] | correct for 1.17, but the 1.17 KM checks the UM's build (ioctl 0), not the uKernel's, and never checks SGXMKIF layouts against its own `sizeof` [br §4, fw §2.6] | both; a precision |
| 8 | matrix row 8: openpvrsgx 1.9.2253347 × `pvr-omap4`: "P but obsolete" [gw §3] | transport dead on 6.18 (`DRM_OMAP_GET_BASE` absent); letux tree has no Makefile [br TL;DR 4, §7] | RE: B on mainline (gw's "Rejected" list already says "no OMAP4 KM") |
| 9 | stock 1.8 blobs rejected for "wrong KM build"; matrix row 9 pairs them with 1.8.869593 [gw §3] | a version-matched GPL KM source exists (AOSP `03a9286b`) [hyb TL;DR 3, br TL;DR 2, fw Verif. 7] | rejection stands for other reasons (bionic softfp, libhybris on musl, dead display path, licence); "wrong KM build" is true only of letux |
| 10 | stock GFX power states OFF/INACTIVE/ON [gw §2] | `sys` left the `gfx_pwrdm` words undecoded | groundwork, via [pm §1.2] (pwrsts `0x0d`) |
| 11 | preemption is compile-enforced (`osfunc.c:126-135` `#error`) [gw TL;DR 4] | "nothing enforces it" [sys row 26] | groundwork (kdp) |
| 12 | the mux sits on `dpll_core_m7x2_ck` at 266.67 MHz, measured [gw TL;DR 5] | reset value UNKNOWN, "presumably CORE" [sys rows 7, 29] | groundwork (measurement) |
| 13 | `pvr_probe()` pins the GFX domain ON [gw TL;DR 6] | runtime-PM coupling "MATCH, functionally equivalent" [sys row 17] | groundwork; `sys` looked only at the sysconfig layer |
| 14 | open question 24: render-target size, particle blend, `setEGLContextClientVersion` argument [gw §8] | answered: 960×540 RGBA8 FBO ×3; screensaver `(SRC_ALPHA, ONE)` straight to the screen; scenes additive into the FBO; version 2 confirmed [vis §2.3, §3.2, Verif. 1, 3, 6] | RE; the question can close |
| 15 | driver patch list (a)-(g) [gw §3] | stock never writes OCP `DEBUG_CONFIG` BIT(31); letux does [sys row 18, rec. 5] | not in the list; optional, on evidence |
| 16 | idle screensaver on CPU+NEON at 640×360 with DSS upscaling [gw TL;DR 8, F1] | stock draws it at HDMI size with fixed 60 px sprites; at 1080p with damage-rect clearing it is ≲ 10 % of one core [vis §3.2, §6.2] | both workable; full-size rendering keeps the stock look (visual impact of upscaling UNVERIFIED) |
| 17 | 30 fps cap for the visualizer [gw §4 Phase 3-4, §5] | the feedback decay is per frame; trails change with the frame rate; stock's rate is unknown [vis §4.1, open 1] | port must pin stock's rate or rescale the decay per dt |
| 18 | Phase 4 scene list: particle field, blur chain, point-morph, track-info [gw §4] | five scenes plus screensaver and mute quad; LED ring ×0.2 on mute missing in `nexusqd` [vis §4, Verif. 16] | RE; Phase 4 scope should name all five |
| 19 | stock 1.8 blobs: "no redistribution grant" [gw §6] | the imgtec licence also forbids RE (§3.b(i)) [hyb §1.1] | both; groundwork silent on RE |
| 20 | Phase 1 test: load against a mismatched UM build-options mask [gw §4] | blobs may not be modified; the b72 mask hides several bits [br §5] | make the mismatch on the KM side with an unmasked bit (§4.4) |

### 12.2 Inside the RE set

| # | Where | Disagreement | Resolution |
|---|---|---|---|
| 1 | `fw` Verif. 10 vs `sys` §5 | `fw`: `SOC`, `SGX`, `SGX_REV` assigned nowhere, module name inferred (at `letux/pvrsrvkm-1.17.4948957` @ `584dd33a`); `sys`: top-level `drivers/gpu/drm/pvrsgx/Makefile:95` sets them (at `d2f1e031`) | different branches; the name is confirmed by Maemo's shipped module path [ub Verif.] |
| 2 | `odf` §3.3 vs `fw` §1.3 | "no `0xDEADBEEF` in stock `libsrv_init`" vs 15 split-immediate placeholders | `fw` (already in `odf`'s synthesis notes) |
| 3 | `odf` §5.2 vs `br` App. A | `odf`'s 1.17 bridge table is for a build **without** `SUPPORT_DMABUF` (DOKICK 88); the letux Makefile builds **with** it (DOKICK 90) | use the +DMABUF table for any tracer; regenerate it from our build (§10 item 2) |
| 4 | `br` §8 vs `abi` §8 / `ub` §6 | "Path A/B/C" = stock / TI 1.17 / 1.9 UM; "Plan A/B" and "route A/B" = musl / glibc | naming collision only |
| 5 | `sys` open question and `hyb` synthesis | "`sgx_idle` source not opened (UNVERIFIED)" | `stk` §5.4 already cites it (`src:sysconfig.c:1201` in AOSP steelhead) |
| 6 | `odf` §7 caveat | "whether the TI blobs are softfp or hard-float was not checked" | hard-float [abi §4] (already in `odf`'s synthesis notes) |

### 12.3 Repo state found while cross-checking

- [gw] links `gpu-sgx540/README.md`, `gpu-sgx540/drafts/README.md`,
  `drafts/nq-gpu-probe.sh`, `drafts/measurement-protocol.md`, and names a <!-- docs-check: ignore -->
  `linux-google-steelhead-pvrsgx.APKBUILD-fragment.draft`, and seven detail notes link a
  `README.md` in this directory. When this note was written (2026-10-11) none of those
  files existed; the drafts directory held the 0062 DTS draft and, appearing during the
  same session, `linux-google-steelhead.APKBUILD.fragment.draft` and
  `sgx-ddk-um.APKBUILD.draft` (names differ from what [gw] cites). Re-check the links
  once the drafts are complete.
  *Resolved 2026-10-11:* [README.md](README.md) exists, all five drafts and
  `drafts/README.md` exist, and [gw] now links the real draft names
  (`nexusq-gpu-probe.sh`, `linux-google-steelhead.APKBUILD.fragment.draft`,
  `sgx-ddk-um.APKBUILD.draft`); `tools/dev/docs-check.py` is clean.

## Open questions

1. Does the KM's APM path work with the `ti443x` uKernel built without bit 15 (§4.4)?
2. Do drop C's per-call bridge sizes match the letux 1.17 KM (check S), and what is the
   `0x360b14` constant? Only observation may answer the second (§11).
3. Does the hardware's `EUR_CR_CORE_REVISION` read 0x10200 [fw open 1]?
4. Under route A, is the 32-bit-`off_t` `mmap` ever reached, and does the `strerror_r`
   error path survive (§3.4)? Does `mesa-sgx` call `PVRSRVMapDmaBuf` directly [abi open 1]?
5. Which of the three `ld-linux-armhf.so.3` designs does route A use (§3.3)?
6. Legal: does EU 2009/24/EC Art. 6 cover any of the analysis done on TI and stock IMG
   blobs; may the disassembly-derived passages stay in the repo; is on-device
   modification ever acceptable [ub §8, hyb §1.1]?
7. Does Maemo excalibur's 6.18.51 + leste15 stack actually render on a Droid 4 today
   [ub open 11]? *Partly answered 2026-10-11:* Maemo developers state on IRC that pvr
   works on the Droid 4 with their 6.18 kernels (2026-06-03, 2026-08-04). No log or
   benchmark backs this, and none of it names 6.18.51.1. A Droid 3 (same SGX540-120)
   on 5.15/6.1 rendered but reset with GPU runtime PM `auto` [kdp Addendum A.5].
8. Is the unpublished stock commit `ad584da` identical to `03a9286b` in
   `drivers/gpu/pvr` [gw §8 Q15]? Relevant only if the stock UM is ever revisited.
9. Visualizer: stock frame rate and HDMI mode, FFT byte scaling, premultiplied
   texture upload, EGL config, and the 1.17 DDK's point-size and line-width limits
   (`glGetFloatv`, an API query) [vis open 1-6].
10. Does the LED ring really dim to 20 % on mute on a stock unit [vis open 9]?

## Sources

RE notes (this directory), each with its own full source list and verification
record: [re/blob-abi.md](re/blob-abi.md),
[re/stock-android-blobs-libhybris.md](re/stock-android-blobs-libhybris.md),
[re/km-um-bridge-abi.md](re/km-um-bridge-abi.md),
[re/stock-sysconfig.md](re/stock-sysconfig.md),
[re/firmware-microkernel.md](re/firmware-microkernel.md),
[re/open-driver-feasibility.md](re/open-driver-feasibility.md),
[re/visualizer-gl.md](re/visualizer-gl.md).

Groundwork: [../2026-10-11-gpu-sgx540-groundwork.md](../2026-10-11-gpu-sgx540-groundwork.md),
[userspace-blobs.md](userspace-blobs.md) (§3.6, §3.7, §4.4, §6, §8, Verification),
[kernel-driver-port.md](kernel-driver-port.md) (§8, §11, Verification claim 20),
[power-clocks-pm.md](power-clocks-pm.md) (§1.2, TL;DR 8),
[stock-ground-truth.md](stock-ground-truth.md) (§5.4),
[mainline-6.18.md](mainline-6.18.md),
[drafts/0062-…](drafts/0062-ARM-dts-omap4-steelhead-run-the-SGX-from-DPLL_PER-like-stock.patch.draft).

Local evidence read for this note: `nq-captures/20261010-185940/snapshot.txt:467-470`
(the SGX mux under `dpll_core_m7x2_ck` at 266 666 667 Hz on 6.18.48-r20).

Primary external sources, as cited by the RE notes:

- TI `omap5-sgx-ddk-um-linux` — https://git.ti.com/git/graphics/omap5-sgx-ddk-um-linux.git
  (`84a396a4fb379f10931421e489ac8a199d6a9f2c`, `742cf38aba13e1ba1a910cf1f036a1a212c263b6`,
  `551665bf9c321bc3e7721416e6ebbc9f65c18155`; `LICENSE` lines 18-31).
- openpvrsgx — https://github.com/openpvrsgx-devgroup/linux_openpvrsgx (`pvrsrvkm-6.18-rc6`
  `d2f1e031d58a`, `pvrsrvkm-7.2` `2342ce92fdde`, `letux/pvrsrvkm-1.17.4948957` `584dd33a1557`,
  `letux/pvrsrvkm-1.8.869593` `214f07dd8fe4`, `letux/pvrsrvkm-1.9.2253347` `d05540a4a44b`).
- AOSP `kernel/omap` `android-omap-steelhead-3.0-ics-aah` @ `03a9286bb61a9acd28027206c4937990ac817f1b` —
  https://android.googlesource.com/kernel/omap
- Maemo Leste — https://github.com/maemo-leste/sgx-ddk-um (`6fb7fa24d8aa`, blobs `f4fb2c46e83f`),
  https://github.com/maemo-leste/pvr-omap4 (`46e9839510a3`).
- mobiaqua — https://github.com/mobiaqua/mesa-sgx (`mesa-22.3-sgx` @ `a698020be688`, `sgx_compat.c:43,110,177-181`),
  https://github.com/mobiaqua/yocto.
- musl v1.2.6 `ldso/dynlink.c` — https://git.musl-libc.org/git/musl; gcompat 1.1.0
  (`b7bfe0b08c52`) — https://git.adelielinux.org/adelie/gcompat.
- libhybris master `7079712a42ea2754adf747e70c6cc75764c8596e` — https://github.com/libhybris/libhybris.
- Google imgtec driver package `imgtec-maguro-imm76d-0f59ea74.tgz` — https://developers.google.com/android/drivers
- Garnet/sgx540-reversing `c15884751ad870b3e06abd3d8b5a6ab00e2fb3cd` — https://codeberg.org/Garnet/sgx540-reversing
- Stock firmware (gitignored): `reverse-eng/vmlinux.bin`, `reverse-eng/tools/kallsyms.txt`,
  `reverse-eng/factory/tungsten-ian67k/system.raw.img` read with `debugfs -R`.
