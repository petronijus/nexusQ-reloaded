# SGX540 RE 1/7: ELF/ABI of the Linux SGX540 userspace blobs, and how to run them next to musl

> **Status (2026-10-11):** static reverse engineering only. Nothing in this note was
> built, flashed or committed, and no Nexus Q was touched. Downloads were kept as
> untrusted data and only read (readelf, objdump, nm, strings, Python run with `-I`).
> A second, adversarial agent re-checked every key claim the same day. Its
> corrections are folded into the text (marked *Corrected* / *Verification
> 2026-10-11*) and its full record is the **Verification (2026-10-11)** section at
> the end. **Where the body and the verification section disagree, the
> verification section wins.**
>
> Part of the reverse-engineering set; the synthesis, the decision-relevant
> verdicts and the ordered work list are in
> [../reverse-engineering.md](../reverse-engineering.md).
>
> Paths under `<session scratch>/` were scratch copies made during the research
> session (extracted blobs, disassembly listings, helper scripts, clones). They
> were not kept and are not in the repo. Every one of them can be re-derived from
> the sources listed in the note: the gitignored `reverse-eng/` tree (stock
> factory image, `vmlinux.bin`, `kallsyms.txt`) and the public URLs with the
> commits given. Paths written as `owner/repo:path` are files in that external
> repository, not in this one.

## Synthesis notes (cross-workstream, 2026-10-11)

- **Which drop pairs with which Mesa is settled by symbol evidence, not by the
  ELF layer.** `mobiaqua/mesa-sgx` needs `PVRDRIRegisterVersionedCallbacksV0`,
  which only drop C (TI 84a396a, 2024 = Maemo Leste today) exports. Drop B (TI
  ce7b96b, 2020, what pmOS ran) pairs with `mesa-pvr-dri-classic` 20.3.2. See
  Verification V6.
- **B and C against the letux 1.17 kernel module** (the open question 2 below),
  from [km-um-bridge-abi.md](km-um-bridge-abi.md): both builds use the same 35
  bridge ioctl ids (35/35 against letux 1.17 with `SUPPORT_DMABUF`), the same
  `UM_KM_COMPAT_CHECK` words (`0x00011100` / 4948957) and the same
  `SGXConnectionCheck` build-option word `0x00360018` (2020 build at `0x7de8`,
  2024 build at `0x88c8`). The per-call in/out struct sizes (102/103) were
  measured on the **2020 build only**. The 2024 build also loads an unexplained
  constant `0x360b14` in `SGXDevInitPart2` at `0x8430`. So for drop C the
  id/version/option checks pass on paper and the size check is UNVERIFIED.
- **Drop A (DDK 1.9.6.0) is also dead at the bridge**, not only at the
  window-system layer (open question 4 below): its `libsrv_um` finds the PVR
  ioctl base through the TI vendor omapdrm plugin ioctl `DRM_OMAP_GET_BASE`
  (0x02), which 6.18 `include/uapi/drm/omap_drm.h` does not define
  ([km-um-bridge-abi.md](km-um-bridge-abi.md) §2). Its true DDK build is
  1.9@**2253347**, not 1.9@2188537 ([firmware-microkernel.md](firmware-microkernel.md)).
- `libsrv_init` (the microkernel carrier) imports nothing from libc beyond
  `__cxa_finalize`, but it is still a hard-float glibc ELF with `DT_NEEDED
  libc.so.6`, so the same loader rules apply to it
  ([firmware-microkernel.md](firmware-microkernel.md) §5).

---

Date: 2026-10-11. Workstream: reverse-engineering groundwork for SGX540 (OMAP4460) GPU acceleration on the Nexus Q.
Nothing was built, flashed or committed. Every download sits in its own directory under
`<session scratch>/gpu/re-downloads/`. The blobs were only inspected with readelf, nm, objdump, strings and Python run with `-I`
from `<session scratch>/gpu/re/tools/`.

## TL;DR

1. **There are three real SGX540 Linux blob drops. Only one is a sensible base for a musl system.**
   - **A — DDK 1.9.6.0** (`maemo-leste/pvr-omap4`, repackaged Ubuntu/TI `sgx-lib 1.9.0.8.1-2glp1`, fetched 2013-02-05).
     It ships the closed `libEGL` and `libIMGegl` with WSEGL plugins, and that whole window-system side is dead against a modern stack.
     `libpvrws_WAYLAND` needs the pre-1.0 Wayland client API (`wl_display_bind`, `wl_display_iterate`, `wl_display_get_global`,
     `wl_display_sync`), which is absent from libwayland-client 1.26. `gbm_pvr.so` exports the `gbm_backend` entry point that only
     Mesa ≤ 10.x libgbm loads.
   - **B — DDK 1.17.4948957, TI build committed 2020-02-12** (TI `omap5-sgx-ddk-um-linux` `targetfs/ti443x`; binaries added in
     ce7b96b "Update all targets to latest UM libraries" and unchanged through 551665b, which pmOS MR !1868 used, and 742cf38).
     *[Corrected 2026-10-11: an earlier draft said "built 2020-09 / last changed in 7519eda"; 7519eda (2020-09-16) only deleted 10
     header files under `ti443x/include`.]* It is built with Arm GNU Toolchain 9.2 and has **no fortify `__*_chk` imports, no
     `ld-linux-armhf.so.3` DT_NEEDED and no TLS**. The maximum symbol version is GLIBC_2.29.
     **Every import resolves on Alpine's musl 1.2.6 alone**, plus libgcc, libstdc++ and libdrm. That is why pmOS could run it
     with only `libc6-compat`.
     **But B does not speak mobiaqua `mesa-sgx`'s loader interface:** its `libpvr_dri_support` exports only
     `PVRDRIRegisterCallbacks`, while `mesa-sgx` requires `PVRDRIRegisterVersionedCallbacksV0`, which only drop C exports
     (see Verification V6). pmOS ran B with `mesa-pvr-dri-classic` 20.3.2 (xc-racer99/mesa-pvr, a classic DRI driver), not with `mesa-sgx`.
   - **C — DDK 1.17.4948957, TI rebuild from 2024-10** (`1.17.4948957/mesa/glibc-2.35`, 84a396a, Ubuntu GCC 11.4). It is
     byte-identical to what Maemo Leste ships today (`maemo-leste/sgx-ddk-um` f4fb2c4). It adds 9 glibc fortify imports that
     musl lacks (gcompat 1.1.0 has all 9). It also adds **`ld-linux-armhf.so.3` to the DT_NEEDED of every library**, and that
     dependency only supplies `__stack_chk_guard`. The maximum symbol version is GLIBC_2.34.
2. **The architecture and float ABI match the target.** All three drops are ARMv7-A, Thumb-2, VFPv3 + NEONv1, hard-float
   (`Tag_ABI_VFP_args: VFP registers`). That matches Alpine armv7 and the Cortex-A9. None of the PVR blobs has TLS
   (no PT_TLS, no `R_ARM_TLS_*`, no `__tls_get_addr`); the GL contexts use `pthread_key`. Only the Mesa parts TI bundled in the
   2020 drop use TLS, and we would not use those.
3. **musl's loader works in favour of these blobs.**
   - It maps DT_NEEDED `libc.so.6`, `libm.so.6`, `libpthread.so.0`, `libdl.so.2` and `librt.so.1` onto itself
     (`ldso/dynlink.c` v1.2.6, lines 1070-1080).
   - It ignores symbol-version requirements altogether.
   - It remaps `mmap64` → `mmap`, `lseek64` → `lseek` and similar LFS64 names (`get_lfs64()`, line 350).
   - It exports glibc-ABI names: `__ctype_b_loc`, `_IO_getc`, `__xpg_strerror_r`, `__errno_location`, `__stack_chk_guard`.
   - Its plain `clock_gettime`, `clock_nanosleep`, `gettimeofday`, `nanosleep`, `select`, `pthread_cond_timedwait` and similar
     names are the **time32 compatibility symbols** (`compat/time32/time32.h`), so glibc-time32 callers get the `timespec`/`timeval`
     layout they expect. *[Corrected: this does **not** hold for `stat`/`fstat`/`lstat`/`fstatat`. musl's time32 `stat` copies musl's
     own `struct stat` prefix (64-bit `st_size`, padded `st_dev`, 64-bit `st_ino` field), which is glibc's `struct stat64`
     layout, not glibc armhf's 32-bit-`off_t` `struct stat`. No PVR blob in any drop imports a stat-family function, so there is
     no impact here; see Verification V4.]*
   - The pthread object sizes are equal to glibc armhf: mutex 24, cond 48, attr 36, rwlock 32, barrier 20 bytes.
   - musl skips DT_INIT/DT_FINI on ARM (`NO_LEGACY_INITFINI`). That is harmless here: every blob's `_init` only calls `__gmon_start__`.
4. **One real ABI trap remains, and symbol coverage cannot see it.**
   - The 1.17 `libsrv_um` (B and C) calls plain **`mmap` with the glibc 32-bit `off_t`** ABI inside `PVRSRVMapDmaBuf`
     (B: 0x5920, C: 0x5af6; the offset is at `[sp+4]`).
   - musl's `mmap` takes a 64-bit `off_t` and reads it from `[sp+8..15]`, which here is uninitialised low word plus the caller's
     6th argument. The result would be EINVAL or a wrong offset.
   - The branch is taken only when flag bit `0x8000000` (arg 3) is clear **and** the 64-bit 5th argument is 0. The offset the
     blob passes is always that zero register (C 0x5af2 `strd r6,r5,[sp]` with r5 = 0; B 0x591a `str r4,[sp,#4]` with r4 = 0).
     *[Corrected per drop:]*
     - **Drop B:** the only caller (`libpvr_dri_support` B 0x59f0 `mov.w r2,#0x8000000` before `blx PVRSRVMapDmaBuf` at 0x59f4)
       sets the flag, and B `libsrv_um` branches away on it (0x57c4 `ands.w sl,sl,#0x8000000` … 0x57de `bne 58ce`). So the
       mmap branch is **statically unreachable** from the blob caller in B. Only an external direct caller of the exported
       `PVRSRVMapDmaBuf` could reach it.
     - **Drop C:** the caller (C 0x5a38) passes flags = 3 (clear) and a 5th argument of {low: its own 5th argument, high: `r2*r1`
       = arg3 × arg6 (0x5a1c)}. The branch is taken only if both words are 0, so it is probably not reached; UNVERIFIED on hardware.
   - The main mapping path is safe: it is a raw `syscall(192 = mmap2, …)` (B: 0x988a, C: 0xa81e; DDK 1.9.6: 0x9ee4).
   - If the trap is hit, the fix is to rename the import to a shim symbol (`patchelf --rename-dynamic-symbols`, patchelf ≥ 0.18).
     *[Corrected:]* An LD_PRELOAD interposer *would* win the lookup, because musl loads preloads before the program's
     DT_NEEDED (`dynlink.c:1961-1962`). But it replaces `mmap` for every caller in the process, and all the musl-built callers
     (Mesa, wlroots, libdrm) use the 64-bit `off_t` ABI. A library loaded later (dlopen) cannot interpose at all. So only the
     per-DSO rename is safe.
5. **One process, one libc.** A musl wlroots/labwc process can host these glibc-built blobs only because musl stands in for glibc
   underneath them (strategy 1). It can never load real glibc beside musl:
   - musl's loader maps any `libc.so.6` to itself.
   - glibc's `libc.so.6` needs `ld-linux-armhf.so.3` GLIBC_PRIVATE internals (`_rtld_global_ro`, `_dl_allocate_tls`, …).
   - Both libcs claim the thread pointer.

   So the choice is binary. Either the whole GL-using process is musl (blobs + shims), or the whole process (compositor or app,
   Mesa, libdrm, wayland, …) is glibc in a separate userland island.
6. **Recommendation (for the decision, not built).** *[Revised 2026-10-11 after verification. The earlier "B + mesa-sgx"
   pairing does not load: `mesa-sgx`'s `PVRDRICompatInit` looks up `PVRDRIRegisterVersionedCallbacksV0`
   (`sgx_compat.c:177-181` @ a698020) and B does not export it.]*
   - **Primary:** strategy 1 with **drop C + `mobiaqua/mesa-sgx`** built natively for musl. That is the UM/Mesa pairing mobiaqua
     itself ships for Panda/OMAP4 (`mobiaqua/yocto` `meta-ti/recipes-bsp/libgles/ti-sgx-ddk-um_1.17.4948957.bb`: SRCREV 84a396a,
     `TARGET_PRODUCT:panda = "ti443x_linux"`), and the one Maemo Leste runs. It costs the small musl shim DSO named
     `ld-linux-armhf.so.3` that provides the 9 `__*_chk` functions (§7.1). The open `dbm` (Maemo) and `pvrsrvinit.c` are rebuilt
     natively.
   - **Alternative musl path:** drop B + `mesa-pvr-dri-classic` 20.3.2 (xc-racer99/mesa-pvr, classic DRI), which is exactly
     what pmOS ran on musl in 2021 and needs no shim. Its cost is an old classic-DRI Mesa fork. Classic DRI drivers were removed
     upstream in Mesa 22.0 (from knowledge, UNVERIFIED here), so that path is frozen.
   - Keep the `mmap` rename in reserve for either drop.
   - **Fallback:** strategy 4. Run the GL consumer (kmscube, then the visualizer) inside a glibc island, such as a Maemo Leste or
     Debian armhf rootfs subtree, with drop C and Maemo's `mesa 22.3.6+sgx`. That is the exact stack known to work on the
     Droid 4 (same SGX540).
   - Strategy 3 (glibc renderer + musl compositor joined by dma-buf/Wayland) is possible but brings the most moving parts.
   - **Do not choose DDK 1.9.6 for a Wayland/GBM stack.**

---

## 1. Method and tools

| Step | Tool / command | Notes |
|---|---|---|
| ELF inventory | `<session scratch>/gpu/re/tools/elfabi.py` (wraps `readelf -hdVAlSrW`, `readelf --dyn-syms -W`, `strings -a`) | Output JSON: `<session scratch>/gpu/re/tools/A.json` (1.9.6), `B.json` (TI 2020), `C.json` (TI 2024), `D.json` (Maemo current), `E.json` (TI OMAP5 1.9 for comparison), `P.json` (Alpine providers) |
| Symbol → provider mapping | `<session scratch>/gpu/re/tools/symfile.py` (maps each `UND sym@VER (n)` to its `.gnu.version_r` file entry) | Shows which glibc file each import was linked against |
| Coverage vs musl/gcompat | `<session scratch>/gpu/re/tools/cover2.py` | Uses the real exports of Alpine edge armv7 `musl-1.2.6-r5`, `gcompat-1.1.0-r4`, `libgcc/libstdc++-15.2.0-r9`, `libdrm-2.4.134-r0`, and musl's LFS64 remap list copied from `ldso/dynlink.c` v1.2.6 |
| Disassembly | `arm-linux-gnueabihf-objdump -d` | `re/srvum117.dis` (C libsrv_um), `re/srvum196.dis` (A libsrv_um), `re/tmp/srvumB.dis`, `re/tmp/pvrdrisup117.dis` |
| Per-file tables | `<session scratch>/gpu/re/tools/table.py` → `<session scratch>/gpu/re/tools/tables.md` | Full sha256 of every analysed file |

A caveat on disassembly scans: the blobs are stripped and have no `$a`/`$t`/`$d` mapping symbols. A grep for
"instructions the Cortex-A9 lacks" (`sdiv`, `udiv`, `vfma`, `vmaxnm`, `ldaex`) therefore hits literal pools decoded as code,
for example `udiv r9, r1, pc`, which is UNPREDICTABLE and clearly data. That scan is inconclusive.
The authoritative evidence is the build attributes:
- `Tag_CPU_arch: v7`, `Tag_FP_arch: VFPv3`, `Tag_Advanced_SIMD_arch: NEONv1` on every PVR blob.
- `Tag_DIV_use: Not allowed` on all of the 1.9.6 drop.

## 2. Blob sets obtained (provenance)

| Id | Source (URL, ref) | Content / version | Build toolchain (from `.comment`) | Local dir (`re-downloads/…`) |
|---|---|---|---|---|
| A | https://github.com/maemo-leste/pvr-omap4, `master` 46e9839510a395ac42e7276132e01c7f6cbdcc3d (2021-04-26); `maemo/beowulf` 10d0652c (2021-12-11) differs only in `debian/` | `usr/lib/arm-linux-gnueabihf/*.so.1.9.6.0`. Per `fetch-pvr-omap/log.txt`, taken on 2013-02-05 from Ubuntu/TI debs `sgx-lib_1.9.0.8.1-2glp1_armhf.deb`, `sgx-lib-data`, `sgx-lib-dev`, `sgx-lib-dbgsym` (.ddeb, which is why `usr/lib/debug` holds **unstripped debug files**), `xserver-xorg-video-omap-pvr_0.3.5-1ubuntu3`. Package version `1.9.0.8.1.3-1`. Original control: `Depends: libc6 (>= 2.15-0ubuntu8) … libgbm1, libwayland0, libstdc++6 (>= 4.1.1)` | no `GCC:` ident survived | `pvr-omap4-git/pvr-omap4` |
| B | https://git.ti.com/git/graphics/omap5-sgx-ddk-um-linux.git, branch `1.17.4948957-next` / `ti-img-sgx/dunfell/1.17.4948957` @ 742cf38aba13e1ba1a910cf1f036a1a212c263b6 (2021-04-17). The `targetfs/ti443x` binaries were added in ce7b96b (2020-02-12, Andrew F. Davis, "Update all targets to latest UM libraries") and not changed afterwards: `git log 742cf38 -- targetfs/ti443x/lib targetfs/ti443x/bin` lists only ce7b96b. *[Corrected: 7519eda (2020-09-16) only deleted 10 headers under `ti443x/include`.]* | `targetfs/ti443x/lib/*`: the PVR UM blobs plus TI-built Mesa parts (`libEGL.so.1.0.0`, `libgbm.so.1.0.0`, `libglapi`, `dri/pvr_dri.so`). The same files sit at `kirkstone-ws` 76251c0 (sha256 equal). README: "DDK dependencies: libdrm 2.4.83, libgbm 10.0.0, Wayland 2.0" | `GCC: (GNU Toolchain for the A-profile Architecture 9.2-2019.12 (arm-9.10)) 9.2.1 20191025`. The Mesa parts carry `/mnt/ssd512/yocto/build/arago-tmp-external-arm-toolchain/work/pandaboard-linux-gnueabi/ti-sgx-ddk-um/1.17.4948957-r34/…`. **Pandaboard = OMAP4**, which corroborates that `ti443x` means OMAP4/SGX540 | `ti-1.17-next-742cf38` |
| B′ | pmOS MR !1868 used TI commit 551665bf9c321bc3e7721416e6ebbc9f65c18155 (2020-09-17). Between 551665b and 742cf38 `git diff --stat` for `targetfs/ti443x` touches only `include/EGL/eglplatform.h`, so **B′ = B for every binary** | — | — | (same repo) |
| C | same TI repo, branch `1.17.4948957/mesa/glibc-2.35` @ 84a396a4fb379f10931421e489ac8a199d6a9f2c (2024-10-16, "all: rebuild with major fixes applied"); earlier rebuild 337832d (2023-10-13) | `targetfs/ti443x_linux/lws-generic/release/usr/{lib,bin}`: PVR UM blobs only, without Mesa. README.md: "DDK dependencies: glibc 2.35, libdrm 2.4.110" | `GCC: (Ubuntu 11.4.0-1ubuntu1~22.04) 11.4.0` | `ti-1.17-glibc235-84a396a` |
| D | https://github.com/maemo-leste/sgx-ddk-um `master` 6fb7fa24d8aa (2025-11-12). Blobs from f4fb2c46e83f (2025-01-08), "add upstream blobs, https://git.ti.com/cgit/graphics/omap5-sgx-ddk-um-linux@84a396a4fb37" | `ti443x/usr/lib/*`. **All 10 files are byte-identical to C** (`<session scratch>/gpu/re/tools/D.json` vs `C.json`). Maemo drops TI's `libdbm` and builds its own reverse-engineered `dbm/dbm.c` (commit cfd8e0f, 2022-02-18). Package `sgx-ddk-um 1.17.4948957+leste15-1` | as C | `sgx-ddk-um-git/sgx-ddk-um` |
| E | TI repo branch `infoadas/1.9/next` @ da68cf8afa248ca7601bab6b5f71f25d8c354df5 (2016-07-13) | DDK 1.9.6.0 for **OMAP5/DRA7 (SGX544), not SGX540**. Kept only as an ABI comparison: the same 1.9 family, but a newer Wayland (registry/queue) API | `Linaro GCC 2013.03 4.7.3` | `ti-1.9-infoadas-da68cf8` |
| — | TI `ti-img-sgx/kirkstone/1.17.4948957` @ 905809029b87 (2022-10-25) | **No `ti443x`** (only ti335x/437x/572x/654x). TI dropped OMAP4 from that branch | — | (deleted after inspection) |
| — | Goldelico `letux-pvrsgx-1.17_0.20200413112912_all.deb` (URL given by H. N. Schaller, beagleboard group, 2020-10-04) | **HTTP 404 on 2026-10-11** at `https://download.goldelico.com/quantumstep/debian/dists/buster/main/binary-all/`. Per the post it was a build-on-install wrapper around TI's zeus branch, so not a separate blob set | — | — |
| — | mobiaqua (GitHub org) | **No userspace blob repo today.** *[Corrected: the org has 25 repos, not 5; `gh api users/mobiaqua/repos --paginate` also lists apps, oe, yocto, linux-arm, ti-* and others.]* `mobiaqua/yocto` fetches TI drop **C** (84a396a, `ti443x_linux`) for panda. The older `mobiaqua/oe` `omap4-sgx-libs_git.bb` (PV 1.9.6) fetched `github.com/mobiaqua/pvr-omap4` @ 4df1d855, which is now HTTP 404. It also carries open `gbm_pvr.c` and `pvrws_GBM.c`, a re-implemented 1.9.6 WSEGL GBM plugin (last change b8b54d24e0c6, 2020-04-26) that still exports the old `gbm_backend` entry (`gbm_pvr.c:373`). `mesa-sgx` (`mesa-22.3-sgx` @ a698020be688, 2024-11-22) `src/gallium/frontends/sgx/sgx_compat.c:43` (`#define PVRDRI_SUPPORT_LIB "libpvr_dri_support.so"`) and `:110` (`dlopen(path, RTLD_NOW)`) consume the DDK 1.17 interface, and **only drop C's flavour of it** (`PVRDRIRegisterVersionedCallbacksV0`, `:177`) | — | — |

The Alpine providers used for the coverage check are all from `https://dl-cdn.alpinelinux.org/alpine/edge/main/armv7/`,
APKINDEX of 2026-10-10. The sha256 values are of the `.apk` files.

| Package | sha256 |
|---|---|
| musl-1.2.6-r5 | 4eafab1f832d064dd98d1497f5cd2ce37f6e3f1fa81c2b4a50776284fe6de8f7 |
| gcompat-1.1.0-r4 | 5af1c85d891489849f48a8386485ff106d94a8649861f813b679a1f62ba740d1. The APK was built 2023-07-31 from gcompat tag 1.1.0 = b7bfe0b08c52 (2022-10-21); upstream master 06600632 (2026-04-21) is 19 commits further |
| libgcc-15.2.0-r9 | 0c27ef422d18e6b7c81da589846cba163177b32d286ba0071ca01f08efb9768c |
| libstdc++-15.2.0-r9 | a5df52be28d961b7a6cbd8cf05132f9eaa62ab61ce27c0bcd2bc929a8c770fa6 |
| libucontext-1.5.2-r0 | bb340cb414d5dbded164b3e56d8f90314bdf6918a5546eb43410e7d06b5f4be0 |
| libdrm-2.4.134-r0 | 3be9dfc0e8892f8cb0547318c1e939845243f0d218a2b0bf7418b6c247f01162 |
| wayland-libs-client-1.26.0-r0 | f63737d6a893194e4c33c813eefe0adf436dab52db536177b058cfe3cfb8573e |
| wayland-libs-server-1.26.0-r0 | 84886896ed5edec95f52165ef5b2e9f17e9e593c4fb582a3cf5c4f30ed990f4b |
| mesa-gbm-26.2.4-r1 | fa774027f2ced74dd444e041976f669640d74f58b858624d094be62c13b4d4eb |

For the glibc island the Debian trixie `libc6_2.41-12+deb13u4_armhf.deb` was used, sha256
4fc6fed8d77d01c0dacb5fda8b880a8c8a669575936de5761b693077a6f6c2ec
(`deb.debian.org/debian/pool/main/g/glibc/`, extracted with `ar x` + `tar`).

## 3. Per-file ELF facts

### 3.1 Drop C — TI 1.17.4948957 rebuild of 2024-10 (= Maemo Leste today)

| File | Size | sha256 | SONAME | DT_NEEDED | max GLIBC | other versions | VFP args / FP / SIMD | TLS | UND |
|---|---|---|---|---|---|---|---|---|---|
| libGLESv1_PVR_MESA.so.1.17.4948957 | 403684 | `3896bb0154fb9318cf97c6951b21b83806165a923bf2d39509cdd3491f29bc48` | libGLESv1_PVR_MESA.so.1 | libsrv_um.so.1, libpvr_dri_support.so.1, libusc.so.1, libm.so.6, libc.so.6, ld-linux-armhf.so.3 | GLIBC_2.34 | - | VFP regs / VFPv3 / NEONv1 | none | 75 |
| libGLESv2_PVR_MESA.so.1.17.4948957 | 370912 | `b8bcd405e8e310b2c1894757c850d2dc68b782ee951012f2fe1acca7e414c118` | libGLESv2_PVR_MESA.so.1 | libsrv_um.so.1, libpvr_dri_support.so.1, libm.so.6, libc.so.6, ld-linux-armhf.so.3 | GLIBC_2.34 | - | VFP regs / VFPv3 / NEONv1 | none | 68 |
| libPVRScopeServices.so.1.17.4948957 | 9640 | `b5c6db168bfdebf3cc8903b5bfe1cbad296f3e5b508a218b1e1c9987b864b9ff` | libPVRScopeServices.so.1 | libsrv_um.so.1, libstdc++.so.6, libc.so.6, ld-linux-armhf.so.3 | GLIBC_2.4 | CXXABI_1.3.9, GLIBCXX_3.4 | VFP regs / VFPv3 / NEONv1 | none | 18 |
| libdbm.so.1.17.4948957 | 9708 | `c294a8279484eeee07d450fb05a58d89ea658a421a2ea6dde3b65a9caebd22dc` | libdbm.so.1 | libdrm.so.2, libc.so.6, ld-linux-armhf.so.3 | GLIBC_2.4 | - | VFP regs / VFPv3 / NEONv1 | none | 25 |
| libglslcompiler.so.1.17.4948957 | 243332 | `cf65d40e941580e4490924f0897b0dda3d2d2da34975801a3acca8be8e19b9dc` | libglslcompiler.so.1 | libsrv_um.so.1, libusc.so.1, libm.so.6, libc.so.6, ld-linux-armhf.so.3 | GLIBC_2.29 | - | VFP regs / VFPv3 / NEONv1 | none | 53 |
| libpvr2d.so.1.17.4948957 | 17912 | `ba924676fabd81a7a0b326cd7d68d58dade7ea8404b2e17c22132a09e6d32fd2` | libpvr2d.so.1 | libsrv_um.so.1, libc.so.6, ld-linux-armhf.so.3 | GLIBC_2.4 | - | VFP regs / VFPv3 / NEONv1 | none | 40 |
| libpvr_dri_support.so.1.17.4948957 | 104232 | `1a14a453a4db7cb4266cfb3de54bf476e25d10b5cf45b4d85ab52810889905bb` | libpvr_dri_support.so.1 | libsrv_um.so.1, libdbm.so.1, libdrm.so.2, libc.so.6, ld-linux-armhf.so.3 | GLIBC_2.4 | - | VFP regs / VFPv3 / NEONv1 | none | 84 |
| libsrv_init.so.1.17.4948957 | 103852 | `ac329c21ef7507d4663634385f7ee58358cafc1aecff54d4cb3ba01344b0a2f9` | libsrv_init.so.1 | libsrv_um.so.1, libc.so.6, ld-linux-armhf.so.3 | GLIBC_2.4 | - | VFP regs / VFPv3 / NEONv1 | none | 21 |
| libsrv_um.so.1.17.4948957 | 169720 | `6bdfe93ac40248dd066f0f6f4d85438042194827b49e6140ab926879c576b9f1` | libsrv_um.so.1 | libdrm.so.2, libc.so.6, ld-linux-armhf.so.3 | GLIBC_2.34 | - | VFP regs / VFPv3 / NEONv1 | none | 72 |
| libusc.so.1.17.4948957 | 738144 | `61cb7a4e7cd91265ea6b0646a1d23c72bd8fa3873984c6a7f4a1acb72d0f23ba` | libusc.so.1 | libc.so.6, ld-linux-armhf.so.3 | GLIBC_2.11 | - | VFP regs / VFPv3 / NEONv1 | none | 16 |
| pvrsrvctl | 9624 | `c2adbdf3aaa13edc9461264f2ce78bb7053ee29f159bd35534ccf6e58e75037d` | - | libsrv_init.so.1, libsrv_um.so.1, libc.so.6, ld-linux-armhf.so.3 | GLIBC_2.34 | - | VFP regs / VFPv3 / NEONv1 | none | 25 |

- e_flags `0x5000400` (EABI5, hard-float).
- No RPATH or RUNPATH.
- `GNU_STACK RW` (non-executable).
- No TEXTREL.
- `DT_INIT` → 12-byte `.init`; `INIT_ARRAYSZ` 4 or 8.
- **What GLIBC_2.34 comes from:** in libsrv_um it is `dlopen/dlsym/dlclose@GLIBC_2.34`, `pthread_create/join/mutexattr_*@GLIBC_2.34`
  and `__libc_start_main@GLIBC_2.34` (pvrsrvctl). These are the 2.34 libpthread/libdl merge into libc
  (`readelf --dyn-syms`, `<session scratch>/gpu/re/tools/C.json`).
- **What the `ld-linux-armhf.so.3` dependency supplies:** only `__stack_chk_guard@GLIBC_2.4` (`<session scratch>/gpu/re/tools/symfile.py`, every C library).
- `pvrsrvctl` has the hard-coded string `/lib/modules/6.1.83/extrapvrsrvkm.ko` (strings), which is useless for us.

### 3.2 Drop B — TI 1.17.4948957 build of 2020-09 (what pmOS ran; PVR files only)

| File | Size | sha256 | SONAME | DT_NEEDED | max GLIBC | other versions | VFP args / FP / SIMD | TLS | UND |
|---|---|---|---|---|---|---|---|---|---|
| libGLESv1_PVR_MESA.so.1.17.4948957 | 366844 | `6b827227f3faee3f06a6d64db476d7d37d4afd84274923b0cfaa7e491f3b0ec1` | libGLESv1_PVR_MESA.so.1 | libsrv_um.so.1, libpvr_dri_support.so.1, libusc.so.1, libm.so.6, libpthread.so.0, libc.so.6 | GLIBC_2.29 | - | VFP regs / VFPv3 / NEONv1 | none | 73 |
| libGLESv2_PVR_MESA.so.1.17.4948957 | 346364 | `37bda4eb841621f3b7c9f87234aa619fa5f7c67ce2c3aa94ab9afec7908cf353` | libGLESv2_PVR_MESA.so.1 | libsrv_um.so.1, libpvr_dri_support.so.1, libm.so.6, libpthread.so.0, libc.so.6 | GLIBC_2.4 | - | VFP regs / VFPv3 / NEONv1 | none | 67 |
| libPVRScopeServices.so.1.17.4948957 | 9656 | `2e9df7ed6aa3ba023e804910e7ab8a6d8230fb4ea7c5fca58e19446163955760` | libPVRScopeServices.so.1 | libsrv_um.so.1, libstdc++.so.6, libm.so.6, libc.so.6, libgcc_s.so.1 | GLIBC_2.4 | (C++ imports unversioned) | VFP regs / VFPv3 / NEONv1 | none | 15 |
| libdbm.so.1.17.4948957 | 9732 | `3f0e382ebabbf2aeab753101ae45704a3354cdbdc0e97ac9c09c6d8ee482bfb4` | libdbm.so.1 | libdl.so.2, libdrm.so.2, libc.so.6 | GLIBC_2.4 | - | VFP regs / VFPv3 / NEONv1 | none | 23 |
| libglslcompiler.so.1.17.4948957 | 214672 | `a7a54329ba574d8e5c8a3a6adafa44ff90fb368bbed05b732d9308aa467ea2bf` | libglslcompiler.so.1 | libsrv_um.so.1, libusc.so.1, libm.so.6, libc.so.6 | GLIBC_2.29 | - | VFP regs / VFPv3 / NEONv1 | none | 48 |
| libpvr2d.so.1.17.4948957 | 17932 | `026c5fa4629039d9677f6a43304a09a489987b60b39b3c85f3b45a07c4b9349c` | libpvr2d.so.1 | libsrv_um.so.1, libc.so.6 | GLIBC_2.4 | - | VFP regs / VFPv3 / NEONv1 | none | 38 |
| libpvr_dri_support.so.1.17.4948957 | 104248 | `3ae9c06c0c907e050c71db801585e65e37831819735c8778490ce884ad53c827` | libpvr_dri_support.so.1 | libsrv_um.so.1, libdbm.so.1, libdl.so.2, libdrm.so.2, libc.so.6 | GLIBC_2.4 | - | VFP regs / VFPv3 / NEONv1 | none | 81 |
| libsrv_init.so.1.17.4948957 | 99776 | `3a140250f217970ab5ae9196a108a457f0d274b6fc84994fd71e9214f469624a` | libsrv_init.so.1 | libsrv_um.so.1, libc.so.6 | GLIBC_2.4 | - | VFP regs / VFPv3 / NEONv1 | none | 19 |
| libsrv_um.so.1.17.4948957 | 161544 | `c4faa93c6ca54b57ad13700329e80d7fc6a15e3270d1f6dacac9ddbae7fe84b6` | libsrv_um.so.1 | libdl.so.2, libpthread.so.0, librt.so.1, libdrm.so.2, libc.so.6 | GLIBC_2.28 | - | VFP regs / VFPv3 / NEONv1 | none | 69 |
| libusc.so.1.17.4948957 | 697168 | `2eb77b967e236e87cb660f5178a0985a74267b72d30b0117bacfd04173335043` | libusc.so.1 | libc.so.6 | GLIBC_2.4 | - | VFP regs / VFPv3 / NEONv1 | none | 13 |
| pvrsrvctl | 9800 | `04e58a1862dce478f65ce82698bab6c865f9474465731db14af8f4a5cac50edf` | - | libsrv_init.so.1, libsrv_um.so.1, libc.so.6 | GLIBC_2.4 | - | VFP regs / VFPv3 / NEONv1 | none | 29 |

- Same e_flags as C.
- `DT_FLAGS: SYMBOLIC` on most libraries. `pvrsrvctl` is PIE.
- GLIBC_2.28 is `fcntl@GLIBC_2.28`; GLIBC_2.17 is `clock_gettime/clock_nanosleep@GLIBC_2.17`; GLIBC_2.29 is `exp/log/pow@GLIBC_2.29`.
- On Debian beowulf (glibc 2.28) Maemo once **weakened** the GLIBC_2.29 vernaux of libGLESv1 with a 1-byte `dd`
  (`maemo-leste/sgx-ddk-um:scripts/weaken-glibc-symbols.sh`, commit b679e21, 2022-02-13). That is a glibc-side issue only; musl never checks versions.
- The same 2020 drop also contains TI-built Mesa: `libEGL.so.1.0.0` (sha256 9cf48a61…), `libgbm.so.1.0.0`, `libglapi.so.0.0.0`
  and `dri/pvr_dri.so` (28 MB). The TI-built Mesa parts are the **only** files with TLS: `libglapi` defines `_glapi_tls_Dispatch`
  and `_glapi_tls_Context` (PT_TLS, 2× `R_ARM_TLS_TPOFF32`); `libEGL` has PT_TLS, 1× TPOFF32 and `DT_FLAGS SYMBOLIC STATIC_TLS`;
  `pvr_dri` has PT_TLS, `DTPMOD32` + 2× TPOFF32 and imports `__tls_get_addr`. *[Corrected: `libgbm.so.1.0.0` has no TLS. The
  Mesa GL wrappers `libGLESv1_CM.so.1.1.0` and `libGLESv2.so.2.0.0` each carry 1× `R_ARM_TLS_TPOFF32` without their own PT_TLS.
  `libEGL` and `libgbm` also import `fcntl64@GLIBC_2.28`.]*
  They are replaced by a natively built `mesa-sgx`, so they do not matter here.

### 3.3 Drop A — DDK 1.9.6.0 (Maemo `pvr-omap4`, Ubuntu `sgx-lib 1.9.0.8.1-2glp1`)

| File | Size | sha256 | SONAME | DT_NEEDED | max GLIBC | other | VFP args / FP / SIMD | TLS | UND |
|---|---|---|---|---|---|---|---|---|---|
| gbm_pvr.so.1.9.6.0 | 5508 | `d244788ee697e46af55d03a7adeb26e4aa8d908cfc27e3d140617903dd5d1539` | gbm_pvr.so | libsrv_um.so, libIMGegl.so, libdrm_omap.so.1, libgbm.so.1, libc.so.6 | GLIBC_2.4 | - | VFP regs / VFPv3 / NEONv1 | none | 19 |
| libEGL.so.1.9.6.0 | 9620 | `6ceda0794a158bb1632d63baa8acdfde9b765148c49266c1379f4a7ee85725cb` | libEGL.so.1 | libIMGegl.so, libc.so.6 | GLIBC_2.4 | - | VFP regs / VFPv3 / NEONv1 | none | 37 |
| libGLESv1_CM.so.1.9.6.0 | 338180 | `10a2732dae3dced2d6e9bf64b8eea53d58a572a1d8a76e672ab5e37579fd0f98` | libGLESv1_CM.so.1 | libsrv_um.so, libIMGegl.so, libusc.so, libm.so.6, libpthread.so.0, libc.so.6, ld-linux-armhf.so.3 | GLIBC_2.11 | - | VFP regs / VFPv3 / NEONv1 | none | 101 |
| libGLESv2.so.1.9.6.0 | 301100 | `13e085c701f3f084a00649964aa2643021bf40f87acc55f3fb8ebd05352d9294` | libGLESv2.so.2 | libsrv_um.so, libIMGegl.so, libm.so.6, libpthread.so.0, libc.so.6, ld-linux-armhf.so.3 | GLIBC_2.4 | - | VFP regs / VFPv3 / NEONv1 | none | 62 |
| libIMGegl.so.1.9.6.0 | 71540 | `1e09f9fbb3d83ef611efd8480c4c47de6e523689e83cc61cd60d3f6cabe79b91` | libIMGegl.so | libsrv_um.so, libpthread.so.0, libwayland-server.so.0, libdrm.so.2, libdrm_omap.so.1, libgcc_s.so.1, libc.so.6, ld-linux-armhf.so.3 | GLIBC_2.4 | GCC_3.5 | VFP regs / VFPv3 / NEONv1 | none | 86 |
| libPVRScopeServices.so.1.9.6.0 | 9596 | `75eb62d3cccabbf42c2de75feb2383c71d2146cae2385037d0333b087f2714a4` | libPVRScopeServices.so | libsrv_um.so, libstdc++.so.6, libc.so.6, ld-linux-armhf.so.3 | GLIBC_2.4 | GLIBCXX_3.4 | VFP regs / VFPv3 / NEONv1 | none | 16 |
| libglslcompiler.so.1.9.6.0 | 185948 | `58d3c97b62353fc2c64383245fd5d5aba36d41927eaeeb8a929d9086ba101e02` | libglslcompiler.so | libsrv_um.so, libusc.so, libm.so.6, libc.so.6, ld-linux-armhf.so.3 | GLIBC_2.4 | - | VFP regs / VFPv3 / NEONv1 | none | 51 |
| libpvr2d.so.1.9.6.0 | 22072 | `30476cf2f56ea6b5fcf4a60728ceb865604d4f71ede752055f71ac61a6fdf0f3` | libpvr2d.so | libsrv_um.so, libdrm_omap.so.1, libc.so.6, ld-linux-armhf.so.3 | GLIBC_2.4 | - | VFP regs / VFPv3 / NEONv1 | none | 66 |
| libpvr_wlegl.so.1.9.6.0 | 5400 | `4c7243a49a8f4f04a5fd3663ab6292f26fd17c31205e12d6402c7af5783b2e6c` | libpvr_wlegl.so | libc.so.6 | GLIBC_2.4 | - | VFP regs / VFPv3 / NEONv1 | none | 5 |
| libpvrws_KMS.so.1.9.6.0 | 9748 | `897d2e300b2ca71e667ef09ceb269a5d34769ace17b84e8678ee725c132556dc` | libpvrws_KMS.so | libpvr2d.so, libdrm_omap.so.1, libgbm.so.1, libc.so.6 | GLIBC_2.4 | - | VFP regs / VFPv3 / NEONv1 | none | 18 |
| libpvrws_OMAPDRI2.so.1.9.6.0 | 13936 | `8e5bfbd42945f6e8b9aa82d7b959c079b902d290cdbfcececa1be583d026a7d9` | libpvrws_OMAPDRI2.so | libpvr2d.so, libsrv_um.so, libdl.so.2, libdrm.so.2, libdrm_omap.so.1, libX11.so.6, libXfixes.so.3, libdri2.so.1, libc.so.6, ld-linux-armhf.so.3 | GLIBC_2.4 | - | VFP regs / VFPv3 / NEONv1 | none | 55 |
| libpvrws_WAYLAND.so.1.9.6.0 | 9856 | `c78077f4f43f0510b3da0240e930a8c2e5797068aa23c5dc9190f69291011dc6` | libpvrws_WAYLAND.so | libpvr2d.so, libsrv_um.so, libIMGegl.so, libdrm.so.2, libdrm_omap.so.1, libwayland-client.so.0, libc.so.6 | GLIBC_2.4 | - | VFP regs / VFPv3 / NEONv1 | none | 44 |
| libsrv_init.so.1.9.6.0 | 91520 | `0865dfe303eaefe9292ab2a42863b50345488512d1924455e9ca2893f17c30b5` | libsrv_init.so | libsrv_um.so, libc.so.6 | GLIBC_2.4 | - | VFP regs / VFPv3 / NEONv1 | none | 19 |
| libsrv_um.so.1.9.6.0 | 161464 | `fcee4e03fb46a496b7bdd8655ec6799ebaf5ec6bc8c8e4fe852655e78b40b635` | libsrv_um.so | libdl.so.2, libpthread.so.0, librt.so.1, libdrm.so.2, libgcc_s.so.1, libc.so.6, ld-linux-armhf.so.3 | GLIBC_2.4 | GCC_3.5 | VFP regs / VFPv3 / NEONv1 | none | 63 |
| libusc.so.1.9.6.0 | 611884 | `4693899cd0414c07e8f63a6578a48205ed3c56fd968c239366c99c5cfd5eeec8` | libusc.so | libc.so.6, ld-linux-armhf.so.3 | GLIBC_2.11 | - | VFP regs / VFPv3 / NEONv1 | none | 16 |
| pvrsrvinit | 5588 | `2940a7fb821522c3ecae78058e93cfb5cac2ed13ec21eeef59c9adf9bb1dd3cc` | - | libsrv_init.so, libsrv_um.so, libc.so.6 | GLIBC_2.4 | - | VFP regs / VFPv3 / NEONv1 | none | 6 |
| omap_pvr_drv.so (Xorg) | 59416 | `83d0d1eb814af339e8d32d17f9e6aa40ab7921c67827d47efc588fbfa29ef101` | omap_pvr_drv.so | libpixman-1.so.0, libdrm.so.2, libdrm_omap.so.1, libpvr2d.so, libc.so.6 | GLIBC_2.4 | - | VFP regs / VFPv3-D16 / – | none | 50 |

The X11 test programs `xeglinfo`, `xgles1test1`, `xgles2test1`, `xmultiegltest` and `sgx_init_test` are listed in `<session scratch>/gpu/re/tools/tables.md`.

- e_flags `0x5000002` (EABI5, neither the hard nor the soft float flag set; the attributes still say `VFP registers`).
- Every library has `RPATH [/usr/lib]`.
- `Tag_ABI_HardFP_use: Deprecated`, `Tag_DIV_use: Not allowed`.
- `libpvrws_OMAPDRI2` requests an **executable stack** (`GNU_STACK RWE`). glibc ≥ 2.41 refuses to dlopen such objects unless
  the `glibc.rtld.execstack` tunable is set (glibc 2.41 NEWS; UNVERIFIED here, from memory). It is the X11 plugin and is not
  needed. musl ignores PT_GNU_STACK.
- The DDK version is visible only in file names (`1.9.6.0`) and in `pvr-omap4` `debian/changelog`; there is no
  `1.9.xxxxxxx` build string inside (`strings`).

## 4. Cross-cutting ABI facts

| Topic | Finding | Evidence |
|---|---|---|
| ISA / float ABI | All PVR blobs: `Tag_CPU_name "7-A"`, `Tag_CPU_arch v7`, `Tag_THUMB_ISA_use Thumb-2`, `Tag_FP_arch VFPv3`, `Tag_Advanced_SIMD_arch NEONv1`, `Tag_ABI_VFP_args VFP registers`. Alpine armv7 is hard-float; the OMAP4460 A9 has VFPv3 + NEON | `readelf -A` (`<session scratch>/gpu/re/tools/*.json` `attrs`) |
| TLS | None in any PVR blob: no PT_TLS, no `R_ARM_TLS_*`, no STT_TLS, no `__tls_get_addr`. Per-thread GL state uses `pthread_key_create`, `pthread_getspecific`, `pthread_setspecific`, `pthread_once` (libGLES*, libIMGegl) | `readelf -lrW`, `<session scratch>/gpu/re/tools/summ.py` output |
| C++ | Only `libPVRScopeServices` (operators `new`/`delete`: `_Znwj`, `_Znaj`, `_ZdlPv`, `_ZdaPv`, and in 1.17 `_ZdlPvj@CXXABI_1.3.9`). Alpine's libstdc++ 15.2 exports these **unversioned** (`readelf --dyn-syms`: `4665: … _Znwj`, no `@@GLIBCXX`). No exceptions or RTTI in PVR blobs | `<session scratch>/gpu/re/tools/symfile.py`; Alpine libstdc++ dynsym |
| libgcc | 1.9.6 `libsrv_um`/`libIMGegl` need `libgcc_s.so.1` for `__aeabi_unwind_cpp_pr0@GCC_3.5`; the 1.17 drop B needs it in `libPVRScopeServices`. Alpine `libgcc` provides it | `readelf -V` |
| DT_INIT on musl | musl/arm defines `NO_LEGACY_INITFINI` (`arch/arm/reloc.h`; commit 1da53dad, 2013-07-22, "disable legacy init/fini processing on ARM"), so DT_INIT/DT_FINI are **not run** (`dynlink.c:1490-1493`, `1599-1602`). Every blob's `.init` is the glibc crti stub: `push {r3,lr}; bl call_weak_fn; pop {r3,pc}`. `call_weak_fn` only tail-calls `__gmon_start__` if non-null (C `libsrv_um` 0x2638-0x2650: `ldr r2,[r3,r2]; cmp r2,#0; bxeq lr; b __gmon_start__@plt`). Constructors are in `.init_array`, which musl runs | `objdump -d -j .init`; musl source |
| Symbol versions on musl | musl never reads DT_VERNEED/`.gnu.version_r`; `versym` is only used to skip hidden *definitions* (`dynlink.c:264,283`). So `@GLIBC_2.34` requirements are ignored | musl v1.2.6 source |
| Reserved libc names on musl | `libc.`, `libpthread.`, `librt.`, `libm.`, `libdl.`, `libutil.`, `libxnet.` all map to musl itself (`dynlink.c:1070-1080`, `reserved[] = "c.pthread.rt.m.dl.util.xnet."`). **`ld-linux-armhf.so.3` is not in the list**, so it must exist on disk or be removed | musl source |
| LFS64 on musl ≥ 1.2.4 | The `*64` symbols are no longer exported, but the loader remaps them at relocation time: `get_lfs64()` (`dynlink.c:350-376`, called at `:432`). The list includes `mmap`, `lseek`, `open`, `fopen`, `stat`, `fstat`, `readdir`, `scandir`, `alphasort`, `ftruncate`, `mkostemp`, `__xstat`, `__fxstat`, `__fxstatat`, `__lxstat`, plus `readdir64_r`. **`fcntl64` is not in it** (needed only by TI's Mesa `libEGL`/`libgbm`, drop B) | musl commit 246f1c81 (2022-09-26) "remove LFS64 symbol aliases; replace with dynamic linker remapping" |
| time64 on musl/armv7 | musl's exported plain names are the time32 ABI: `int __clock_gettime32() __asm__("clock_gettime")`, and likewise for `clock_nanosleep`, `fstat`, `stat`, `lstat`, `fstatat`, `gettimeofday`, `nanosleep`, `select`, `pselect`, `pthread_cond_timedwait` (`compat/time32/time32.h:33-69`). Glibc-time32 callers therefore get a matching `timespec32`/`timeval32` layout. *[Corrected: the stat family is the exception. `compat/time32/stat_time32.c` memcpy's musl's `struct stat` prefix (`arch/arm/bits/stat.h`: 64-bit `st_size`, 64-bit `st_ino`), which is glibc's `stat64` layout, not glibc's 32-bit-`off_t` `struct stat`. No blob imports any stat function (`readelf --dyn-syms`, all drops), so there is no impact.]* C `libsrv_um` calls `clock_gettime(1,&ts)` at 0x9224 and `clock_nanosleep` at 0x92ee | musl source; disassembly |
| pthread type sizes | musl 32-bit: `pthread_attr_t` 9 ints (36 B), `pthread_mutex_t` 6 ints (24 B), `pthread_cond_t` 12 ints (48 B), `pthread_rwlock_t` 8 ints (32 B), `pthread_barrier_t` 5 ints (20 B) (`include/alltypes.h.in:85-91`). The glibc armhf sizes are the same: verified at tag glibc-2.41, `sysdeps/nptl/bits/pthreadtypes-arch.h:31-39`, 32-bit branch: ATTR 36, MUTEX 24, RWLOCK 32, BARRIER 20, COND 48. ARM has no arch-specific copy of that header in 2.41. The blobs create mutexes with `pthread_mutex_init` plus `pthread_mutexattr_settype` (C `libsrv_um` imports `pthread_mutexattr_*`), not glibc static recursive initialisers | musl source; UND lists |
| ctype / stdio | musl provides a glibc-layout `__ctype_b_loc` table (`src/ctype/__ctype_b_loc.c`, byte-swapped glibc bit values) and `weak_alias(getc, _IO_getc)` (`src/stdio/getc.c:9`). C `libsrv_um` calls `__ctype_b_loc` at 0x9700, 0x97bc, 0x9824 and 0x985e (`/etc/powervr.ini` parsing) | musl source; disassembly |
| `strerror_r` | C `libsrv_um` imports both `__xpg_strerror_r` (XSI, fine) and **GNU `strerror_r`** (0xa836, 0xa9fa). The code tests the return value (`cbz r0`) and then prints its own buffer `r4`. On musl the XSI return of 0 just takes the "no text" branch. Only error paths after a failed `mmap2` or ioctl are affected; no crash expected (UNVERIFIED at run time) | disassembly `re/srvum117.dis` |
| `fcntl` | B 0x8ff6 / C 0x9cfa / A 0x9824: `fcntl(fd, 2 /*F_SETFD*/, 1 /*FD_CLOEXEC*/)`. No `struct flock`, so there is no `off_t` layout issue | disassembly |
| Raw syscalls | The only `syscall()` sites in libsrv_um are `syscall(192 /*__NR_mmap2*/, addr, len, 3 /*RW*/, 1 /*MAP_SHARED*/, fd, pgoff)`: A 0x9ee4, B 0x988a, C 0xa81e. This is the bridge-memory mapping path and it does not depend on the libc ABI | disassembly |
| **`mmap` (32-bit off_t)** | B/C `libsrv_um` `PVRSRVMapDmaBuf` calls `mmap@GLIBC_2.4` (B 0x5920: `str.w fp,[sp]` = fd, `str r4,[sp,#4]` = offset; C 0x5af6: `strd r6,r5,[sp]`). glibc's 32-bit `mmap` reads the offset as 4 bytes at `[sp+4]`. musl's `__mmap(…, off_t off)` takes a 64-bit `off_t` (`src/mman/mmap.c`), which AAPCS places 8-aligned at `[sp+8..15]`. In C that is uninitialised `[sp+8]` plus `[sp+12]`, which the prologue at 0x5940 loads with the caller's 6th argument. musl then rejects it (`off & OFF_MASK` → EINVAL) or maps at a wrong offset. Reachability: taken only if flag bit `0x8000000` of arg 3 is clear and the 64-bit 5th argument is zero (C 0x59ec-0x59fa; B 0x57c4-0x57e8). The offset the blob passes is always 0 (the register just tested). In C, `[sp+8]` is never written; in B both `[sp+8]` and `[sp+12]` are stale on this path. **Drop C:** the sole blob caller, `libpvr_dri_support` (C 0x5a38), passes flags = 3 and a 5th argument whose high word is `r7 = r2*r1` (0x5a1c), so the branch is probably not taken (**UNVERIFIED on hardware**). **Drop B** *[added]*: the sole caller (B 0x59f4) passes flags = `0x8000000` (0x59f0), so the branch is statically unreachable from it. The error text `PVRSRVMapDmaBuf: Failed to acquire user CPU mapping` (seen by Maemo, `sgx-ddk-um` commit 17ba023) is this call | disassembly; musl source |
| 1.9.6 `libsrv_um` mmap | Imports only `munmap`; maps through raw `mmap2` | `nm -D`; `re/srvum196.dis` |
| Hard-coded names | 1.9.6 `libsrv_um`: `omapdrm` (off 112149) and exported object `pvr_ioctl_base`. The bridge rides on omapdrm's driver-private ioctl range via `drmOpen("omapdrm")` and `drmCommandWrite[Read]` (UNVERIFIED interpretation; KM workstream). 1.17 `libsrv_um`: `/dev/dri` (B off 110620 / C 117276), `omapdrm` (110644 / 117300), `pvr` (110652 / 117308), with `drmOpenRender`, `drmGetVersion`, `drmSetInterfaceVersion`, `drmDropMaster`. pmOS patched `omapdrm` → `exynos` at offset 110644 for S5PV210 (MR !1868 post-install), which confirms that offset in B. TI `libdbm`: `omapdrm` at 5960; Maemo's open `dbm.c:549` checks `strcmp("omapdrm", ver->name)` | `strings -t d`; MR !1868 diff |
| Config / env | `/etc/powervr.ini` and `/proc/self/cmdline` are read by `libsrv_um` in every drop (app hints). No `PVR_*` environment variable strings beyond the error-name table | `strings` |

## 5. dlopen'd names (plugins and modules)

| Blob | Names it dlopens (strings, minus its own DT_NEEDED) |
|---|---|
| A `libIMGegl` | `libpvrws_KMS.so`, `libpvrws_WAYLAND.so`, `libpvrws_OMAPDRI2.so` (WSEGL), `libGLESv1_CM.so.1`, `libGLESv2.so.2`, `libPVROGL.so`, `libOpenVG.so.1`, `libPVROCL.so`. It also exports `WSEGL_GetFunctionTablePointer` |
| A `libGLESv2` | `libglslcompiler.so` |
| A `gbm_pvr.so` | Is itself a module and exports `gbm_backend` and `pvr_device_create` |
| A `libpvrws_KMS` | Takes a `gbm_device *` as its native display (imports `gbm_create_device`); uses `mincore` to validate pointers ("gbmpvr: ERROR … mincore failed") |
| B/C `libpvr_dri_support` | `libGLESv1_PVR_MESA.so`, `libGLESv2_PVR_MESA.so`, `libPVROGL.so`, `libPVROCL.so` (unversioned `.so` names, so the dev symlinks must exist; Maemo ships them, see `ls -la ti443x/usr/lib`) |
| B/C `libGLESv2_PVR_MESA` | `libglslcompiler.so` |
| mobiaqua `mesa-sgx` | `libpvr_dri_support.so` (`sgx_compat.c:43,110`, `RTLD_NOW`) |
| pvrsrvinit (open replacements) | pmOS: `dlopen("libsrv_init.so", RTLD_LAZY)` + `SrvInit()`. Maemo `pvrsrvinit/pvrsrvinit.c`: `dlopen("libsrv_init.so.1", RTLD_LAZY)`. Both are open source, so a native musl build is trivial |

## 6. Import coverage against Alpine edge musl 1.2.6 / gcompat 1.1.0

Method: every UND symbol name in the set (versions stripped, since musl ignores them) is classified by the first match:
- defined inside the set;
- exported by `ld-musl-armhf.so.1`;
- LFS64-remapped by musl;
- exported by `libgcompat.so.0`;
- exported by libgcc_s or libstdc++;
- exported by libdrm or libdrm_omap;
- weak and optional;
- unresolved.

Script: `<session scratch>/gpu/re/tools/cover2.py`.

### 6.1 Drop B (TI 2020, the 11 PVR files)

- musl: 105 symbols. libgcc/libstdc++: 4. libdrm: 12. Intra-set: 110.
- **gcompat-only: 0. Unresolved: 0.**
- LFS64 remap: `lseek64`, `mmap64` (both in TI `libdbm`; Maemo's open `dbm` replaces that library anyway).
- Weak and optional: `_ITM_deregisterTMCloneTable`, `_ITM_registerTMCloneTable`, `__gmon_start__`.
- **So drop B loads on pure musl with no gcompat.** The `depends="libc6-compat"` in pmOS's APKBUILD (MR !1868) was not
  needed for the libraries; it would matter only for running TI's glibc `pvrsrvctl`, which pmOS replaced with its own
  `pvrsrvinit.c` built with `gcc … -ldl`.

### 6.2 Drop C (TI 2024 = Maemo Leste current, 11 files)

- musl: 97. LFS64 remap: 2 (`lseek64`, `mmap64` in `libdbm`). libgcc/libstdc++: 4. libdrm: 13. Unresolved: 0.
- **gcompat-only: 9.** These fortify functions are absent from musl 1.2.6 and all present in gcompat 1.1.0
  (`libgcompat/stdio.c:115-232`, `string.c:20-244`, `setjmp.c:4`):

| Symbol | Used by |
|---|---|
| `__fprintf_chk` | pvrsrvctl |
| `__longjmp_chk` | libGLESv1_PVR_MESA, libusc |
| `__memcpy_chk` | libglslcompiler, libusc |
| `__printf_chk` | libglslcompiler, libsrv_um |
| `__snprintf_chk` | libGLESv1/2_PVR_MESA, libglslcompiler, libsrv_um |
| `__stpcpy_chk` | libglslcompiler |
| `__strcat_chk` | libglslcompiler |
| `__strcpy_chk` | libglslcompiler, libpvr_dri_support |
| `__vsnprintf_chk` | libGLESv1/2_PVR_MESA, libglslcompiler, libsrv_um |

- Plus **DT_NEEDED `ld-linux-armhf.so.3` in all 11 files**, which only supplies `__stack_chk_guard`. musl exports that symbol,
  but the *file* must be found or the dlopen fails.

### 6.3 Drop A (1.9.6, the 15 files usable outside X11)

- musl: 91. libgcc/libstdc++: 5. libdrm + libdrm_omap: 18.
- **gcompat-only: 11:** `__fprintf_chk`, `__longjmp_chk`, `__memcpy_chk`, `__printf_chk`, `__snprintf_chk`, `__sprintf_chk`,
  `__strcat_chk`, `__strcpy_chk`, `__vfprintf_chk`, `__vsnprintf_chk`, `__vsprintf_chk`.
- **Unresolved: 26, all window-system.**
  - **`wl_display_bind`, `wl_display_iterate`, `wl_display_get_global`, `wl_display_sync`** (libpvrws_WAYLAND) do not exist in
    libwayland-client 1.26 (`nm -D`, Alpine `wayland-libs-client-1.26.0-r0`). That is the pre-1.0 Wayland API.
  - The `libIMGegl` server-side calls (`wl_display_add_global`, `wl_client_add_object`, …) *are* still exported by
    libwayland-server 1.26.
  - `gbm_pvr.so` exports `gbm_backend`. Mesa's libgbm dlsym'd that entry point only in Mesa 9.0-10.5
    (`src/gbm/main/backend.c` at `mesa-9.0`, `mesa-10.0`, `mesa-10.4.0`, `mesa-10.5.0`: `const char *entrypoint = "gbm_backend"`).
    *[Corrected: "10.x" overreached. At `mesa-10.6.0` backend.c is already built-in only.]* Mesa 10.6-21.1 had built-in backends only. Mesa ≥ 21.2 uses `GBM_GET_BACKEND_PROC_NAME` (`gbmint_get_backend`), and so
    does mobiaqua `libgbm`.
  - Therefore **the 1.9.6 KMS/GBM and Wayland window-system plugins cannot work with any libgbm or libwayland we would ship.**
    1.9.6 stays usable only through its X11 DRI2 plugin (Xorg 1.10-era ABI) or a re-implemented WSEGL.

### 6.4 What gcompat itself brings, and why it is not loaded automatically

- `gcompat-1.1.0-r4` installs:
  - `/lib/libgcompat.so.0`, with symlinks `libc.so.6`, `libm.so.6`, `libpthread.so.0`, `librt.so.1`, `libresolv.so.2`,
    `libutil.so.1`, `libcrypt.so.1` → `libgcompat.so.0`;
  - `/lib/ld-linux-armhf.so.3`, a 5316-byte **PIE executable** (`readelf -h`: `DYN (Position-Independent Executable)`,
    interpreter `/lib/ld-musl-armhf.so.1`).
- The `ld-linux-armhf.so.3` "loader" (`loader/loader.c`) runs only when a **glibc executable** is started. It re-execs musl's
  loader with `--preload libgcompat.so.0 -- <target>`.
- Inside a **musl** process that dlopens the blobs, nothing loads libgcompat:
  - DT_NEEDED `libc.so.6` is caught by musl's reserved-name rule *before* path search and maps to musl itself, so the gcompat
    symlink is never opened;
  - DT_NEEDED `ld-linux-armhf.so.3` (drops A and C) would resolve to gcompat's PIE stub and load an executable as a library
    (undefined behaviour; UNVERIFIED).
- Making gcompat's symbols visible therefore needs one of these:
  - `LD_PRELOAD=libgcompat.so.0` (process-wide, see below);
  - an explicit `dlopen("libgcompat.so.0", RTLD_GLOBAL)` before loading the blobs;
  - `patchelf --add-needed libgcompat.so.0` on the blobs.
- **Process-wide side effects of preloading gcompat.** gcompat redefines 20 names that musl also exports (18 if you leave out
  the per-DSO `_init`/`_fini`). *[Corrected from "19"; the list below always had 20 entries.]* The names: `__duplocale`,
  `duplocale`, `execv`, `execve`, `execvp`, `_fini`, `finite`, `finitef`, `fopen`, `__getauxval`, `_init`, `__newlocale`,
  `newlocale`, `pthread_getname_np`, `readlink`, `realpath`, `secure_getenv`, `setrlimit`, **`strerror_r` (GNU semantics,
  returns `char *`)**, `__strtol_internal` (`comm` of `nm -D` export lists). With LD_PRELOAD these interpose for the whole
  compositor, so a musl caller of XSI `strerror_r` would get a pointer back. With `dlopen(…, RTLD_GLOBAL)` *after* startup,
  musl stays first in lookup order and only the missing names come from gcompat. That is the safer injection.

## 7. Strategy assessment

### 7.1 Strategy 1 — run the blobs inside a musl process (gcompat or a purpose-built shim)

**Drop B (TI, committed 2020-02) + a matching Mesa built for Alpine.** *[Corrected: this was "+ mobiaqua `mesa-sgx`". That
pairing fails at load time: `mesa-sgx` @ a698020 `sgx_compat.c:177` dlsym's `PVRDRIRegisterVersionedCallbacksV0`, and
`PVRDRICompatInit` returns false when it is missing (`:179-181`). B's `libpvr_dri_support` exports only `PVRDRIRegisterCallbacks`
(readelf; the `Versioned…V0` string appears only in C). The Mesa that matches B is `mesa-pvr-dri-classic` 20.3.2
(xc-racer99/mesa-pvr tag `mesa-pvr-20.3.2`), as in pmOS MR !1868. Porting `mesa-sgx` back to the unversioned callback API
would be our own work, with unknown struct differences (UNVERIFIED).]*
- No unresolved and no gcompat-only imports (§6.1).
- No TLS and no C++ exceptions.
- Remaining work:
  1. The `mmap` 32-bit `off_t` trap in `PVRSRVMapDmaBuf` (§4). In B it cannot be reached from `libpvr_dri_support` (the caller
     sets flag `0x8000000`). In C it is probably not reached. If it is, the fix is a local symbol rename:
     `patchelf --rename-dynamic-symbols` (added in patchelf 0.18.0, released 2023-04-23; PR #459 merged 2023-02-23).
     For example rename `mmap` to a 4-character name such as `pmm3`, provided by a tiny musl shim:
     `void *pmm3(void *a, size_t l, int p, int f, int fd, uint32_t off) { return mmap(a, l, p, f, fd, (off_t)off); }`.
     **A global interposer cannot replace the rename.** *[Reasoning corrected:]* An LD_PRELOAD object does precede musl's libc in
     lookup (`dynlink.c:1961-1962`), but it would change `mmap` for every musl caller, all of which use the 64-bit `off_t` ABI.
     A dlopen'd library comes after libc and cannot interpose.
  2. GNU `strerror_r`: cosmetic, error paths only.
  3. Native builds of the open pieces: `pvrsrvinit.c`; Maemo's open `dbm` instead of TI's `libdbm`; the matching Mesa.
     Maemo's `dbm` carries the wlroots render-node fix, ce20a6af by Tony Lindgren, 2022-02-17.
- Evidence that B works on musl (with `mesa-pvr-dri-classic`, not `mesa-sgx`): pmOS MR !1868, merged 2021-02-23 (pmaports f247bf1e). Its description:
  "The OpenGL and initialization libraries are still closed source, but fortunately they can be loaded the dlsym and work
  properly under musl", and "known to work with wlroots-based compositors … as well as Plasma mobile".
  pmOS removed the packages on 2022-05-27 (MR !3162, as a policy decision against proprietary pvr userspace, not because of
  a technical failure).

**Drop C (TI 2024) + mobiaqua `mesa-sgx` in a musl process.** This is the pairing `mesa-sgx` is written for: mobiaqua's own
`yocto` recipe uses SRCREV 84a396a with `ti443x_linux` for panda (OMAP4). It needs, in addition:
- something that provides the 9 `_chk` functions. gcompat via `dlopen RTLD_GLOBAL`, or our own shim;
- something that satisfies DT_NEEDED `ld-linux-armhf.so.3`. Two options:
  - `patchelf --remove-needed ld-linux-armhf.so.3` on the 11 files;
  - **without touching the blobs:** install our own tiny musl DSO named `ld-linux-armhf.so.3` (SONAME the same) in a directory on
    the musl search path, for example via `/etc/ld-musl-armhf.path`. It exports the 9 `_chk` functions. Every blob then pulls
    it in as a normal dependency, so the drop needs no gcompat and no LD_PRELOAD.
    This conflicts with the `gcompat` package's `/lib/ld-linux-armhf.so.3`, so gcompat must not be installed on the image
    (UNVERIFIED design; not built).

**Licensing constraint on any patchelf step.** pmaports f247bf1e records the TI licence as: "they must not be redistributed
in a modified form … Due to the license restrictions, it must be done in a post-install script". Any blob modification must
therefore happen on the device at install time, not in a published image or OTA apk. That is a decision for the licensing
workstream.

**Hard limits of strategy 1:** none found in the ELF layer for drop B. The remaining risks are behavioural: KM/UM pairing,
dma-buf flows, wlroots EGL extension needs. Those belong to other workstreams.

### 7.2 Strategy 2 — a private glibc runtime (`/usr/lib/glibc-sgx`, patchelf `--set-interpreter` / `--set-rpath`)

- **Version floor:**

  | Drop | Minimum glibc |
  |---|---|
  | B | ≥ 2.29 |
  | C | ≥ 2.34 |
  | A | ≥ 2.11 |

  Debian trixie `libc6 2.41-12+deb13u4` armhf (hard-float, `Tag_FP_arch VFPv3`, NEONv1) covers all of them.
  Its `libc.so.6` exports `mmap@@GLIBC_2.4`, `dlopen@@GLIBC_2.34`, `__libc_start_main@@GLIBC_2.34`, `pthread_create@@GLIBC_2.34`.
- **Mechanics.** The loader only applies to an **executable**. One of:
  - `patchelf --set-interpreter /usr/lib/glibc-sgx/ld-linux-armhf.so.3 --set-rpath /usr/lib/glibc-sgx <exe>`;
  - run it as `/usr/lib/glibc-sgx/ld-linux-armhf.so.3 --library-path /usr/lib/glibc-sgx --inhibit-cache <exe>`.

  The executable itself must be **glibc-built**.
- **Search-path hazard on an Alpine root.** Debian's `ld-linux-armhf.so.3` has the built-in system directories
  `/lib/arm-linux-gnueabihf/`, `/usr/lib/arm-linux-gnueabihf/`, `/lib/`, `/usr/lib/`, and it reads `/etc/ld.so.cache` and
  `/etc/ld.so.preload` (`strings` of the trixie ld.so).
  - Any dependency not found in the island falls through to `/lib` and `/usr/lib`. There it finds **musl-built** `libdrm.so.2`,
    `libwayland-*.so.0`, `libexpat.so.1` and so on. Their DT_NEEDED `libc.musl-armv7.so.1` would pull musl into a glibc
    process, and that crashes.
  - Mitigations:
    - put the island at the multiarch paths `/usr/lib/arm-linux-gnueabihf`, which Alpine never uses;
    - or build glibc with its own prefix;
    - and check every closure with `ld.so --list`.
- **Consequence: the island must hold the GL consumer's entire dependency closure.** That is Mesa-sgx, libdrm, libgbm,
  libwayland, libexpat, libffi, libstdc++/libgcc and libz, and for a compositor also libinput, libudev or libudev-zero,
  libxkbcommon, pixman, libseat, cairo and pango for labwc. In practice it is a second distribution, which is strategy 4.

### 7.3 Strategy 3 — a glibc helper process or container, musl for the rest

- The libc boundary becomes a process boundary. Things that cross it without caring about the libc:
  - Wayland (Unix socket + fds);
  - dma-buf fds;
  - DRM master hand-over.
- **Variant 3a: a GL client in the glibc island, a musl compositor.**
  - The client uses Mesa-sgx's EGL Wayland platform and sends `zwp_linux_dmabuf_v1` buffers.
  - A musl wlroots/labwc with the **pixman** renderer would need either CPU access to those omapdrm dma-bufs or direct scan-out
    on a DRM plane.
  - Whether wlroots' pixman renderer accepts dma-buf client buffers is UNVERIFIED and must be checked in wlroots
    `render/pixman`.
  - Fullscreen direct scan-out avoids that question for a single fullscreen visualizer.
- **Variant 3b: a GPU render service.**
  - A small glibc daemon renders into GBM BOs and exports dma-buf fds over a socket to a musl consumer.
  - That consumer does its own KMS page flip, or hands the fds to a compositor.
  - This is more custom IPC with no existing project to reuse.
- **Variant 3c: container or chroot.**
  - systemd-nspawn or a plain chroot with bind mounts of `/dev/dri`, `/dev/pvrsrvkm` (if exposed), `/run/udev` and the input
    devices.
  - It is operationally the same as strategy 4.
- The cost of strategy 3 is two libc worlds plus inter-process buffer sharing on a 2-core A9.

### 7.4 Strategy 4 — build the consumer entirely against glibc

- kmscube, the particle visualizer and, if needed, a compositor are built against glibc and installed in a glibc subtree:
  Maemo Leste excalibur or Debian armhf.
- Maemo Leste already ships this exact stack on the Droid 4 (same SGX540):
  - `sgx-ddk-um 1.17.4948957+leste15-1` (drop C) with an OpenRC `pvrsrvinit` service;
  - `mesa 22.3.6+sgx2-1` (`maemo-leste/mesa` `maemo/excalibur` 60902e8a, changelog "sgx: add missing __DRI2_CONFIG_QUERY
    extension", 2025-01-12; plus branch `mesa-pvr-ti` 5bd40a45, 2021-10-30);
  - `/etc/profile.d/mesa.sh`: `export MESA_LOADER_DRIVER_OVERRIDE=pvr`.
- There are no ABI unknowns: the blobs run on the glibc they were built for. C needs ≥ 2.34. Excalibur is Devuan/Debian-trixie
  based (UNVERIFIED glibc 2.41).
- Costs:
  - a second userland on the 13 GB rootfs (size UNVERIFIED; order of 100-300 MB);
  - security updates for that userland are on us;
  - the OTA and `PUBLIC_RELEASE` pipeline must learn to carry a glibc subtree.
- It is also the **fastest way to a first triangle**: kmscube on Maemo's stack, once the KM side pairs.

### 7.5 "One process, one libc" — precisely, for wlroots/labwc on musl

- Alpine's `labwc` and wlroots are linked to `libc.musl-armv7.so.1`. wlroots' GLES2 renderer uses Mesa `libEGL`/`libGLESv2`,
  which are also musl-built.
- For GPU rendering, Mesa (here `mesa-sgx`) dlopens `pvr_dri` logic → `libpvr_dri_support.so` → `libsrv_um.so.1` and the
  others **into the compositor process**.
- That process has exactly one libc, musl. The glibc-built blobs work only because musl *impersonates* glibc for them:
  - reserved-name mapping;
  - ignored versions;
  - glibc-compatible exports;
  - time32 shims;
  - LFS64 remap.
- It is **not** possible to load real glibc beside musl:
  1. musl's loader resolves any `libc.so.6` DT_NEEDED to itself (`dynlink.c:1070-1080`), so a renamed copy would be needed.
  2. Even then, glibc's `libc.so.6` has DT_NEEDED `ld-linux-armhf.so.3` and imports GLIBC_PRIVATE symbols from it:
     `_rtld_global_ro`, `_dl_allocate_tls`, `_dl_deallocate_tls`, `_dl_argv`, `_dl_find_dso_for_object`,
     `__libc_enable_secure`, `_dl_signal_error`, `__tunable_is_initialized`, … (`readelf --dyn-syms` of trixie `libc.so.6`).
     Those exist only when glibc's own loader started the process.
  3. glibc's `libc.so.6` has its own PT_TLS (memsz 0x50) and finds its thread descriptor through the ARM thread pointer
     (TPIDRURO). musl already owns that register for its `struct pthread`, so `errno`, stdio locking, malloc arenas and
     cancellation would misinterpret each other.
  4. Two mallocs are a separate problem: pointers freed across the boundary crash. Mesa and the blobs already exchange
     allocations, for example `PVRSRVAllocUserModeMem` / `PVRSRVFreeUserModeMem` versus caller `free`.
- Therefore, for a GPU-accelerated wlroots/labwc on our musl system, **only strategy 1 keeps the compositor musl**. Under
  strategy 2 or 4 the compositor and everything it links become glibc. Under strategy 3 the compositor stays musl but does not
  itself use the GPU; GL lives only in the glibc clients.
- For the headless-plus-occasional-HDMI product, strategy 3 or 4 with **no compositor at all** is a valid shape: a single
  glibc KMS/GBM GL application such as the visualizer owns the DRM master while it shows. The musl system stays untouched.

## 8. Recommendation for the decision (nothing built)

1. **Pick DDK 1.17.4948957 userspace.** 1.9.6 is unusable for Wayland or GBM (§6.3).
2. **Choose the drop by the Mesa it must pair with, not by the ELF layer alone.** *[Revised 2026-10-11.]*
   - **Drop C (TI 84a396a, 2024)** is the only drop whose `libpvr_dri_support` exports `PVRDRIRegisterVersionedCallbacksV0`,
     which `mesa-sgx` requires. It is what mobiaqua (Panda/OMAP4) and Maemo Leste (Droid 4) ship. On musl it needs the
     `ld-linux-armhf.so.3`-named shim DSO with 9 `__*_chk` functions (§7.1).
   - **Drop B (TI ce7b96b, committed 2020-02-12; identical at 551665b and 742cf38)** is clean on pure musl and proven by pmOS,
     but only with the classic-DRI `mesa-pvr-dri-classic` 20.3.2.
   - Whether B and C talk the same bridge ABI to a given KM is still a KM/UM pairing question for the other workstreams.
3. **Plan A = strategy 1:** Alpine/musl `mesa-sgx` (mobiaqua `mesa-22.3-sgx`) + **C** blobs + the `ld-linux-armhf.so.3` shim DSO
   + native `pvrsrvinit` + native Maemo `dbm`. Fallback inside strategy 1: B blobs + `mesa-pvr-dri-classic` 20.3.2.
4. **Plan B = strategy 4 for the first light-up:** a Maemo Leste armhf subtree with its packaged `sgx-ddk-um` + `mesa 22.3.6+sgx`
   + kmscube. It is the known-good reference on the same GPU, and it lets KM bring-up be debugged independently of musl questions.
5. Before any musl run, test the `mmap` hazard deliberately. Have a test harness call `PVRSRVMapDmaBuf` with a zero 5th
   argument, and watch it fail on musl before the rename fix counts (project rule: a test must be seen failing).

## Open questions

1. Does anything in the Mesa-sgx/wlroots path call `PVRSRVMapDmaBuf` with a zero 64-bit 5th argument, and so hit the musl
   `mmap` `off_t` mismatch? The static reading says the C `libpvr_dri_support` call site passes a non-zero high word (C 0x5a1c
   `mul.w r7,r2,r1`). Hardware confirmation is needed. For B the question is closed statically: its caller sets flag `0x8000000`
   (B 0x59f0). It remains to check whether `mesa-sgx` itself calls `PVRSRVMapDmaBuf` directly (not checked).
2. Are drops B (2020) and C (2024) bridge-compatible with the same `pvrsrvkm` 1.17.4948957 KM (letux/openpvrsgx branch)?
   What did "rebuild with major fixes applied" (84a396a) change: build options, `SGX_FEATURE` flags, the bridge structs?
   This is for the KM/UM pairing workstream. Diffing `libsrv_init` and `libsrv_um` exports between B and C would be a start:
   B has 103 definitions in `libsrv_um`, C 101.
3. Does TI's licence for `omap5-sgx-ddk-um-linux` allow putting unmodified B blobs into a public pmOS-style apk or OTA repo?
   And is an on-device `patchelf` step (rename `mmap`, remove the `ld-linux` NEEDED) acceptable as "post-install"? The
   licence text is in the TI repo `LICENSE` / `TI-Linux-Graphics-DDK-UM-Manifest.doc` and was not read in this run.
   *Read 2026-10-11 (userspace-blobs.md Addendum B.2):* B's commits have only the `.doc`, whose 2013 TSPA text allows
   unmodified binary redistribution with the licence reproduced, forbids RE, and has no TI-devices-only clause; C's
   `LICENSE` (added 2023-10-13) is TI's Text File License, which adds it.
4. What exactly does the 1.9.6 bridge go through (`drmOpen("omapdrm")` + `pvr_ioctl_base`)? Does it require the TI 3.x
   omapdrm plugin interface, which no mainline kernel has? It is relevant only if 1.9.x is ever reconsidered.
5. Can wlroots' pixman renderer consume omapdrm dma-buf client buffers (strategy 3a), or only shm?
6. In an `ld.so --list` check, is the dependency closure of a glibc-island kmscube really free of fall-through into Alpine's
   `/usr/lib`? (Strategy 2/4 hazard, §7.2.)
7. ~~glibc armhf pthread type sizes~~: closed. Verified at glibc-2.41 `sysdeps/nptl/bits/pthreadtypes-arch.h:31-39`; the
   `sysdeps/arm/nptl/...` path no longer exists there.
8. The Goldelico `letux-pvrsgx-1.17` .deb is gone (HTTP 404). Is there an archived copy, and did its postinst do anything
   OMAP4-specific?

## Sources

- maemo-leste/pvr-omap4 — https://github.com/maemo-leste/pvr-omap4 (master 46e9839510a395ac42e7276132e01c7f6cbdcc3d; maemo/beowulf 10d0652c4478238a192f50745fc1c8a9a462605d); files `fetch-pvr-omap/log.txt`, `fetch-pvr-omap/sgx-lib/control`, `debian/control`, `debian/changelog`.
- maemo-leste/sgx-ddk-um — https://github.com/maemo-leste/sgx-ddk-um (master 6fb7fa24d8aa3d7d97b835b42e464e95bbdf0588; blob commit f4fb2c46e83faff36da2e43a7d2d617b7b8d56dd; weaken commit b679e214411868ec0f118f71c6a4dcf4c66ac26d; dbm commits cfd8e0f9a4be, ce20a6afdd46, 17ba0239c097); files `maemo-leste/sgx-ddk-um:scripts/weaken-glibc-symbols.sh`, `pvrsrvinit/pvrsrvinit.c`, `dbm/dbm.c`, `debian/control`, `etc/profile.d/mesa.sh`.
- TI omap5-sgx-ddk-um-linux — https://git.ti.com/git/graphics/omap5-sgx-ddk-um-linux.git (742cf38aba13e1ba1a910cf1f036a1a212c263b6; 551665bf9c321bc3e7721416e6ebbc9f65c18155; 7519eda; 84a396a4fb379f10931421e489ac8a199d6a9f2c; 337832d; 76251c0a88c172eb69a84324f033e4035b8a7a4e; 905809029b877fea42e91b9738825a6294ff1775; da68cf8afa248ca7601bab6b5f71f25d8c354df5); READMEs at 742cf38 and 84a396a.
- postmarketOS pmaports MR !1868 "PowerVR SGX Acceleration" — https://gitlab.postmarketos.org/postmarketOS/pmaports/-/merge_requests/1868 (merged 2021-02-23; commit f247bf1e2a2ec9ae248dc98cbb58e24cf157ddad; `non-free/sgx-ddk-um/APKBUILD`, `pvrsrvinit.c`, `sgx-ddk-um-s5pv210.post-install`).
- pmaports MR !3162 (removal) — https://gitlab.postmarketos.org/postmarketOS/pmaports/-/merge_requests/3162 (merged 2022-05-27; commits cecfb418c0da, 023f8cc1c36c).
- musl — https://git.musl-libc.org/git/musl tag v1.2.6: `ldso/dynlink.c` (lines 264, 283, 350-376, 432, 1070-1100, 1490-1493, 1599-1602), `arch/arm/reloc.h`, `compat/time32/time32.h`, `compat/time32/clock_gettime32.c`, `src/mman/mmap.c`, `src/stat/__xstat.c`, `src/ctype/__ctype_b_loc.c`, `src/stdio/getc.c`, `include/alltypes.h.in`, `WHATSNEW`; commits 246f1c811448f37a44b41cd8df8d0ef9736d95f4, 25e6fee27f4a293728dd15b659170e7b9c7db9bc, 1da53dad278f98b7712ac002162afaa8815ba580.
- gcompat — https://git.adelielinux.org/adelie/gcompat (tag 1.1.0 = b7bfe0b08c52fdc72e0c1d9d4dcb2129f1642bd6; master 06600632096b14e03e32b234ec0b02a9d4d045e9): `loader/loader.c`, `libgcompat/stdio.c`, `libgcompat/string.c`, `libgcompat/setjmp.c`, `README.rst`.
- Alpine edge armv7 packages — https://dl-cdn.alpinelinux.org/alpine/edge/main/armv7/ (`musl-1.2.6-r5`, `gcompat-1.1.0-r4`, `libgcc-15.2.0-r9`, `libstdc++-15.2.0-r9`, `libucontext-1.5.2-r0`, `libdrm-2.4.134-r0`, `wayland-libs-client-1.26.0-r0`, `wayland-libs-server-1.26.0-r0`, `mesa-gbm-26.2.4-r1`; sha256 values in §2).
- Debian trixie glibc — https://deb.debian.org/debian/pool/main/g/glibc/libc6_2.41-12+deb13u4_armhf.deb (sha256 4fc6fed8…c2ec), index `dists/trixie/main/binary-armhf/Packages.xz`.
- Mesa gbm backend loader — https://gitlab.freedesktop.org/mesa/mesa/-/raw/{mesa-9.0,mesa-10.0,mesa-11.0.0,mesa-17.0.0,mesa-21.1.0,mesa-21.2.0,mesa-21.3.0}/src/gbm/main/backend.c.
- mobiaqua — https://github.com/mobiaqua/mesa-sgx (`mesa-22.3-sgx` @ a698020be6888af99daeac6470018a5d85313912, `src/gallium/frontends/sgx/sgx_compat.c`); https://github.com/mobiaqua/libgbm (master f83489d7744cdc8d9de2e4fc5b809d0d5218e6e0, `backend.c`).
- maemo-leste/mesa — https://github.com/maemo-leste/mesa (`maemo/excalibur` 60902e8a0873d7e8549db34d15415f340edc60a2, `debian/changelog`; branch `mesa-pvr-ti` 5bd40a453e1484efea842be9a3f388adb5fac93c).
- patchelf 0.18.0 release notes — https://github.com/NixOS/patchelf/releases/tag/0.18.0 (tag object 99c24238981b7b1084313aca8f5c493bb46f302c; "Add feature to rename dynamic symbols", PR #459).
- Goldelico letux-pvrsgx-1.17 announcement — https://groups.google.com/g/beagleboard/c/HIApL_Mkp2Q/m/4dg7akn0BgAJ (H. N. Schaller, 2020-10-04); package URL returned HTTP 404 on 2026-10-11.
- Prior project note — `docs/2026-06-19-gpu-sgx540-acceleration-research.md` (repo).

## Verification (2026-10-11)

Adversarial re-check of the 18 key claims. Every check was re-run on the files already in `<session scratch>/gpu/re-downloads/`
with host binutils (`readelf`, `arm-linux-gnueabihf-objdump`, `strings`), `git` on the local clones (musl, gcompat, TI), `gh api`,
and `curl` of public raw files. Fresh downloads went to new directories `re-downloads/vfy01-*`; scratch output is in `re/tmp/vfy01/`.
Nothing from a download was executed. The default verdict was "wrong unless reproduced".

### Summary

| # | Claim (short) | Verdict | Note |
|---|---|---|---|
| 1 | B: 0 unresolved / 0 gcompat-only on musl+libgcc+libstdc+++libdrm; no ld-linux NEEDED; max GLIBC_2.29; B′ = B | **Confirmed, with a date correction** | Independent `comm` coverage: the leftovers are only `lseek64`, `mmap64` (LFS64 remap) and the weak `__gmon_start__`/`_ITM_*`. `git diff --stat 551665b 742cf38 -- targetfs/ti443x` = only `include/EGL/eglplatform.h`. **Wrong:** "built 2020-09 / last changed in 7519eda". The binaries were added in **ce7b96b (2020-02-12)**; 7519eda only deleted 10 headers (V1) |
| 2 | C = Maemo current; GLIBC_2.34; 9 `_chk`; ld-linux NEEDED in all 11 only for `__stack_chk_guard` | **Confirmed** | sha256 of all 10 shared files equal (Maemo omits `libdbm`). The ld-linux vernaux index binds only `__stack_chk_guard@GLIBC_2.4` in all 11 files. All 9 `_chk` are absent from musl's exports and present in libgcompat |
| 3 | ARMv7/Thumb-2/VFPv3/NEON hard-float, no TLS, pthread keys | **Confirmed, with nuances** | All PVR blobs: `Tag_ABI_VFP_args: VFP registers`, no PT_TLS, no TLS relocs. GLES libs import `pthread_key_create/once/get/setspecific`. Nuances: drop A has e_flags 0x5000002 (no EF_ARM_ABI_FLOAT_HARD bit), but its attributes are hard-float; A's Xorg `omap_pvr_drv.so` is VFPv3-D16 without NEON; the TI Mesa TLS list is corrected in §3.2 (libgbm has none; Mesa libGLESv1_CM/libGLESv2 have TPOFF32) |
| 4 | musl reserved names; ld-linux not reserved | **Confirmed** | At v1.2.6 tag `dynlink.c:1071-1092`, the check happens before any path search |
| 5 | Versions ignored; LFS64 remap; no `fcntl64` | **Confirmed** | v1.2.6 `dynlink.c:264,283,350-376,432`. 246f1c81 was authored 2022-09-26 and committed 2022-10-19. Note: the local clone HEAD is v1.2.6-67 (b1efda5b), where line numbers differ by +4; the report's numbers match the **tag** |
| 6 | NO_LEGACY_INITFINI on ARM; `_init` only calls `__gmon_start__` | **Confirmed** | `arch/arm/reloc.h:15`; `dynlink.c:1490,1599`. All 34 A/B/C `.so` `.init` stubs branch to a `call_weak_fn` that reaches only `__gmon_start__@plt` |
| 7 | time32 plain names give glibc-time32 layout incl. `stat`/`fstat` | **Partly wrong** | True for the timespec/timeval functions. **False for the stat family** (V4). No blob imports stat, so there is no practical impact |
| 8 | `PVRSRVMapDmaBuf` mmap with 32-bit off_t | **Confirmed** | C 0x5af2 `strd r6,r5,[sp]` → 0x5af6 `blx mmap@plt`; B 0x591a/0x591c/0x5920; C prologue 0x593e/0x5940 `ldr r4,[sp,#216]; str r4,[sp,#12]` (6th argument, an out-pointer). musl `__mmap` has an `off & OFF_MASK` → EINVAL check. Added: the passed offset is always 0 |
| 9 | mmap branch probably unreachable from `libpvr_dri_support` | **Confirmed for C; stronger for B** | B caller 0x59f0 `mov.w r2,#0x8000000` → B `libsrv_um` 0x57c4/0x57de branches away: unreachable from the blob caller (V5) |
| 10 | Raw `syscall(192)` mmap2 path | **Confirmed** | A 0x9ed8/0x9ee4, B 0x9884/0x988a, C 0xa810/0xa81e |
| 11 | 1.9.6 WSEGL plugins dead; `gbm_backend` only Mesa 9.0–10.x; 21.2+/mobiaqua use `gbmint_get_backend` | **Confirmed with a range fix** | The 4 `wl_display_*` names are absent from wayland-client 1.26. `gbm_backend` dlopen is present at mesa-9.0/10.0/10.4.0/10.5.0 and **gone at mesa-10.6.0**, so "9.0–10.5", not "10.x" (V7). mobiaqua libgbm `backend.c:126` + `gbm_backend_abi.h:299` = `gbmint_get_backend` |
| 12 | mesa-sgx loads the 1.17 interface (B/C); mobiaqua has no blob repo (5 repos listed) | **Wrong in two parts** | The dlopen is real (`sgx_compat.c:43` define, `:110` dlopen). But mesa-sgx needs `PVRDRIRegisterVersionedCallbacksV0`, which is **C-only**, so it does not work with B (V6). The repo list is wrong: 25 repos, including `oe` and `yocto`; `yocto` pins TI drop C (V8) |
| 13 | gcompat not auto-loaded; PIE stub; 19 overridden names incl. GNU `strerror_r` | **Confirmed, count wrong** | 20 names (the report's own list had 20). gcompat 1.1.0 = b7bfe0b0; `string.c:229` defines `char *strerror_r`; `ld-linux-armhf.so.3` is a 5316-byte PIE with interpreter `/lib/ld-musl-armhf.so.1` |
| 14 | glibc cannot share a process with musl | **Confirmed** | trixie `libc.so.6`: NEEDED `ld-linux-armhf.so.3`; 17 GLIBC_PRIVATE imports incl. `_rtld_global_ro`, `_dl_allocate_tls`, `_dl_argv`; PT_TLS memsz 0x50 |
| 15 | Debian ld.so falls back to `/lib`, `/usr/lib` | **Confirmed** | `strings`: the multiarch dirs, `/lib/`, `/usr/lib/`, `/etc/ld.so.cache`, `/etc/ld.so.preload` |
| 16 | pmOS MR !1868 / !3162 facts, licence wording | **Confirmed** | GitLab API: !1868 merged 2021-02-23T21:13Z; APKBUILD `_commit=551665bf…`, `depends="libc6-compat"`; s5pv210 post-install `dd … seek=110644` (and `libdbm` seek=5960); commit f247bf1e message "must not be redistributed in a modified form … it must be done in a post-install script". !3162 merged 2022-05-27 with the policy quote. Added: pmOS's Mesa was `mesa-pvr-dri-classic` 20.3.2 |
| 17 | patchelf 0.18.0 rename; interposer cannot fix | **Feature confirmed, reasoning wrong** | Release 0.18.0 published 2023-04-23; notes line "Add feature to rename dynamic symbols … pull/459" (PR merged 2023-02-23). **Wrong reasoning:** musl loads LD_PRELOAD objects before the app's DT_NEEDED (`dynlink.c:1961-1962`), so a preload *does* interpose. It is unusable only because it is process-wide (V9). The conclusion (use a per-DSO rename) stands |
| 18 | pthread sizes equal | **Now verified** (was "likely") | glibc-2.41 `sysdeps/nptl/bits/pthreadtypes-arch.h:31-39`: 36/24/32/20, cond 48 |
| 19 | Maemo Leste stack (drop C + mesa 22.3.6+sgx2 + `MESA_LOADER_DRIVER_OVERRIDE=pvr`) | **Confirmed** | `gh api`: f4fb2c46 (2025-01-08) "add upstream blobs … @84a396a4fb37"; `etc/profile.d/mesa.sh`; changelog `1.17.4948957+leste15-1`; maemo-leste/mesa `maemo/excalibur` HEAD = 60902e8a, changelog `22.3.6+sgx2-1` (2025-01-12) |

(The orchestrator's list has 18 entries; the Maemo claim is #18 there, and pthread sizes are #17. Rows 18/19 above cover both.)

### V1 — Drop B commit history (date correction)

```
$ git log --format='%h %ci %s' 742cf38 -- targetfs/ti443x
742cf38 2021-04-17 15:51:56 -0500 eglplatform.h: update to newer no x11 macro
7519eda 2020-09-16 20:29:48 -0500 Update all target artifacts
ce7b96b 2020-02-12 18:44:53 -0500 Update all targets to latest UM libraries
$ git log --format='%h %ci %s' 742cf38 -- targetfs/ti443x/lib targetfs/ti443x/bin
ce7b96b 2020-02-12 18:44:53 -0500 Update all targets to latest UM libraries
$ git show --stat 7519eda -- targetfs/ti443x   →  10 files changed, 30071 deletions(-)   (all under include/)
$ git show --stat ce7b96b -- targetfs/ti443x   →  bin/pvrsrvctl Bin 0 -> 9800, lib/libGLESv1_PVR_MESA.so.1.17.4948957 Bin 0 -> 366844, …
```
551665b (2020-09-17) and 742cf38 are both descendants of ce7b96b. The binary bytes are therefore the February 2020 build
(GCC 9.2-2019.12, consistent). The B′ = B conclusion is unaffected.

### V2 — Drop C ld-linux dependency

For every C file, the `.gnu.version_r` index for `File: ld-linux-armhf.so.3` (3 or 4) is used by exactly one UND symbol:
`__stack_chk_guard@GLIBC_2.4`. `diff` of sha256 lists (C `lib/*.so.1.17.4948957` + `bin/pvrsrvctl` vs Maemo `ti443x/usr`):
only `libdbm` is missing on the Maemo side; the other 10 hashes are identical.

### V3 — Coverage of drop B, recomputed independently

Exports of `ld-musl-armhf.so.1` (1726 names), libgcc_s + libstdc++ 15.2 (7072), `libdrm.so.2.134.0` (214), minus B's intra-set
definitions (462), against B's 236 distinct UND names. Left over: `__gmon_start__` (WEAK), `_ITM_deregisterTMCloneTable`
(WEAK), `_ITM_registerTMCloneTable` (WEAK), `lseek64`, `mmap64` (musl `get_lfs64` remaps both). The intersection with the
gcompat exports is empty. This matches §6.1.

### V4 — musl time32 `stat` is not glibc's 32-bit `struct stat`

`compat/time32/stat_time32.c` (v1.2.6): `struct stat st; int r = stat(path, &st); if (!r) memcpy(st32, &st, offsetof(struct stat, st_atim));`.
`arch/arm/bits/stat.h`: `dev_t st_dev; int __st_dev_padding; long __st_ino_truncated; … off_t st_size; …` with 64-bit `off_t`
and a 64-bit `ino_t` near the end. That is the kernel `stat64`/glibc `struct stat64` shape. A glibc armhf caller built without
`_FILE_OFFSET_BITS=64` that calls `stat` (glibc ≥ 2.33 exports `stat`) expects a 32-bit `st_size`/`st_ino` and would misread
the fields. Import scan of all drops (`readelf --dyn-syms`, UND names matching `stat|xstat`): **none**. So there is no impact
on these blobs, but the general sentence was wrong.

### V5 — Drop B's `PVRSRVMapDmaBuf` mmap branch is unreachable from its only blob caller

```
libpvr_dri_support (B) 59e0: mul.w r2,r2,r6 ; 59ec: strd r2,r7,[sp,#4] ; 59f0: mov.w r2,#134217728 ; 59f4: blx PVRSRVMapDmaBuf@plt
libsrv_um (B)          5762: mov sl,r2 ; … 57c4: ands.w sl,sl,#0x8000000 ; … 57de: bne.n 58ce   (skips 57e0-5920, the mmap call)
```
In drop C the caller passes `movs r2,#3` (0x5a22), so C's path depends on the 64-bit 5th argument as the report says. The only
importer of `PVRSRVMapDmaBuf` in each drop's own file set is `libpvr_dri_support`.

### V6 — mesa-sgx and drop B are not interface-compatible (major correction)

- `mobiaqua/mesa-sgx` @ a698020be6888af99daeac6470018a5d85313912, `src/gallium/frontends/sgx/sgx_compat.c`:
  `:177 LookupFunc(PVRDRIRegisterVersionedCallbacksV0, pfPVRDRIRegisterCallbacks);`
  `:179 res = (pfPVRDRIRegisterCallbacks != NULL); :180 if (!res) goto Exit;` → `CompatDeinit()`, so the init fails.
  No fallback to the unversioned name exists in the file.
- Exported GLOBAL names of `libpvr_dri_support.so.1.17.4948957`: B 74, C 75. The **only** difference (`comm`) is
  `PVRDRIRegisterVersionedCallbacksV0`, present only in C. B has just `PVRDRIRegisterCallbacks`. The string
  `PVRDRIRegisterVersionedCallbacksV0` occurs only in C (`strings -a`).
- So "B + mesa-sgx" (the report's original Plan A) would fail when Mesa initialises the driver. The proven pairings are
  **B + `mesa-pvr-dri-classic` 20.3.2** (pmOS MR !1868 APKBUILD: `_tag=mesa-pvr-20.3.2`, `url=https://github.com/xc-racer99/mesa-pvr/`,
  classic `-Ddri-drivers=exynos,tidss,tilcdc,omapdrm`) and **C + mesa-sgx/mesa 22.3.6+sgx** (mobiaqua, Maemo Leste).
  The TL;DR, §2, §7.1 and §8 are revised to match.

### V7 — Mesa gbm `gbm_backend` range

`curl https://gitlab.freedesktop.org/mesa/mesa/-/raw/<tag>/src/gbm/main/backend.c`. The tags mesa-10.1.0/10.2.0/10.3.0 did not
resolve (fetch failed), so they were not checked.

| tag | `entrypoint = "gbm_backend"` + dlopen | builtin `backends[]` | `GBM_GET_BACKEND_PROC_NAME` |
|---|---|---|---|
| mesa-9.0, 10.0, 10.4.0, 10.5.0 | yes | yes | – |
| mesa-10.6.0, 11.0.0, 17.0.0, 21.1.0 | – | yes | – |
| mesa-21.2.0, 21.3.0 | – | builtin_backends | yes |

### V8 — mobiaqua organisation

`gh api users/mobiaqua/repos --paginate` lists 25 repos: apps, igep-x-loader, kmscube, libgbm, linux-arm, mesa-sgx,
mplayer-mini, mpv-gui, mpv-mini, oe, python, sgx-pvr5-module, ti-ce, ti-codecs, ti-ducati-fw, ti-fc, ti-gc320-driver,
ti-ipcdev, ti-ipumm, ti-libdce, ti-libmmrpc, ti-osal, ti-sysbios, ti-sysbios-c64t, ti-xdais, yocto. Relevant contents:
- `yocto` `meta-ti/recipes-bsp/libgles/ti-sgx-ddk-um_1.17.4948957.bb` (last change 4b76cb210344, 2025-08-31):
  `BRANCH = "${PV}/mesa/glibc-2.35"`, `SRCREV = "84a396a4fb379f10931421e489ac8a199d6a9f2c"`, `TARGET_PRODUCT:panda = "ti443x_linux"`,
  installs into `/usr/lib/gles-${TARGET_PRODUCT}` with `LD_LIBRARY_PATH`. **mobiaqua pairs mesa-sgx with drop C.**
- `oe` `oe/recipes/powervr/omap4-sgx-libs_git.bb`: PV 1.9.6, `SRC_URI = git://github.com/mobiaqua/pvr-omap4.git` @ 4df1d855
  (that repository now returns HTTP 404). It ships open `gbm_pvr.c`, `pvrws_GBM.c/.h`, `egl-wrapper.c`, `wayland-dummy.c`,
  a self-written WSEGL GBM plugin for 1.9.6 (last change b8b54d24e0c6, 2020-04-26). `gbm_pvr.c:373` still defines
  `struct gbm_backend gbm_backend`, which is the Mesa ≤ 10.5 libgbm ABI. That is a concrete reference if 1.9.6 is ever
  revisited (§6.3: "a re-implemented WSEGL").

### V9 — Interposition order in musl

`ldso/dynlink.c` v1.2.6: `1961: if (env_preload) load_preload(env_preload); 1962: load_deps(&app);`. Preloaded objects
therefore sit before libc in the global lookup chain and would bind the blob's `mmap`. They do so for every caller, though.
The rename is still the right fix, but "musl always resolves mmap to libc first" was incorrect.

### Not re-checked in this pass

- sha256 values of the Alpine `.apk` files and of the A-drop files (§2/§3.3 tables). The B and C file sets were re-hashed only
  for the C-vs-D comparison.
- `__ctype_b_loc` call sites (C 0x9700…), GNU `strerror_r` call sites (C 0xa836, 0xa9fa), `fcntl(F_SETFD)` sites, and the
  `/etc/powervr.ini` strings.
- The glibc 2.41 execstack tunable remark (§3.3, already marked UNVERIFIED).
- The Goldelico 404 and the maemo `pvr-omap4` provenance chain.
- Whether `mesa-sgx` calls `PVRSRVMapDmaBuf` directly (it was not searched; Open question 1).
