# SGX540 groundwork 4/7: Closed SGX540 userspace, the open glue, musl/glibc ABI and licensing

> **Status (2026-10-11):** research and planning only. Nothing in this note was
> built, flashed or committed, and no unit was touched except where a section
> says so explicitly (one read-only probe in [power-clocks-pm.md](power-clocks-pm.md)).
> An independent adversarial pass re-checked every claim the same day; its
> corrections are folded into the text (marked *Corrected 2026-10-11*) and its
> full record is the **Verification (2026-10-11)** section at the end. Where the
> two disagree, the verification section wins.
>
> Part of the GPU groundwork set: the summary, decision matrix and roadmap are in
> [../2026-10-11-gpu-sgx540-groundwork.md](../2026-10-11-gpu-sgx540-groundwork.md);
> the folder index is [README.md](README.md). Inside this note, "workstream NN" or
> "report NN" refers to:
>
> | NN | Detail note |
> |---|---|
> | 01 | [stock-ground-truth.md](stock-ground-truth.md) |
> | 02 | [mainline-6.18.md](mainline-6.18.md) |
> | 03 | [kernel-driver-port.md](kernel-driver-port.md) |
> | 04 | [userspace-blobs.md](userspace-blobs.md) |
> | 05 | [compositor-display.md](compositor-display.md) |
> | 06 | [power-clocks-pm.md](power-clocks-pm.md) |
> | 07 | [usecases-roadmap.md](usecases-roadmap.md) |
>
> Paths under `<session scratch>/` were scratch copies made during the research
> session (extracted blobs, clones, venvs); they were not kept. Everything they held
> can be re-derived from the sources listed at the end.

*Original working title: 04 — SGX540 closed userspace (EGL/GLES + services) and the open glue on musl/armv7 postmarketOS*

**Workstream:** userspace DDK, ABI, open glue, licensing — groundwork for GPU acceleration on the
Nexus Q (steelhead, OMAP4460, PowerVR SGX540 rev 1.2.0 = "120").
**Date:** 2026-10-11 (Europe/Prague). Research/planning only: nothing was built, flashed or committed,
no device was touched.
**Evidence convention:** every claim carries a source: `repo:file:line`, a URL plus what was seen and
when (commit hash/tag/date), a symbol/string in a binary, or **UNVERIFIED (reasoning)**. *Inference*
is labelled as such.

---

## TL;DR

1. **The newest userspace for SGX540 rev 120 in 2026, and the only one current distributions still
   ship, is TI's DDK `1.17@4948957`, target `ti443x_linux`** ("maintained" is too strong: its last
   commit is 2024-10-16 and TI's own 6.18 BSP no longer carries SGX — see §3.1), branch `1.17.4948957/mesa/glibc-2.35`, commit
   `84a396a4fb379f10931421e489ac8a199d6a9f2c` (2024-10-16) of
   `git.ti.com/git/graphics/omap5-sgx-ddk-um-linux.git`. Maemo Leste (daedalus + excalibur) ships
   **byte-identical** copies of those blobs (`sgx-ddk-um-ti443x 1.17.4948957+leste15`, 2025-01-08;
   all of them except the `libdbm` blob, which Maemo replaces with its open re-implementation),
   and MobiAqua's Yocto layer pins the very same commit for PandaBoard (OMAP4). The core config in
   the matching KM is `SGXCORE 540 / SGX_CORE_REV 120` — the same core as stock's
   `libEGL_POWERVR_SGX540_120.so`.
2. **The blobs are armhf, hard-float, glibc** (`Tag_ABI_VFP_args: VFP registers`, highest symbol
   version `GLIBC_2.34`, TI README says "glibc 2.35, libdrm 2.4.110"). Alpine armv7 is also
   hard-float (`ld-musl-armhf.so.1`), so **the float ABI matches**; the libc does not.
3. **Stock is useless as a userspace source:** the stock image carries DDK **1.8@785978**
   (Android ICS, bionic, softfp, KM built into the 3.0.8 kernel with `omaplfb`). No modern KM
   matches 785978 and the blobs need bionic → only via libhybris, which pmOS rejected.
4. **The microkernel firmware is not a separate `.fw` file** in any of these DDKs (1.8, 1.9, 1.17):
   the USE programs live in `libsrv_init.so` `.rodata` and are uploaded by `SrvInit()`
   (`SetupuKernel`/`LoaduKernelProgram` strings); the 1.17 KM has no `request_firmware`. **The June
   note's "sgx540_*.fw must ship" is wrong.**
5. **The open glue that exists today:** a Gallium **`sgx` frontend** in TI/IMG's Mesa forks that
   `dlopen`s the closed `libpvr_dri_support.so` and lets stock Mesa EGL provide GBM/DRM, Wayland,
   surfaceless and X11 platforms. Live branches: TI `powervr/24.0.1`
   (head `7c82c1eb…` 2026-03-13, a C23 build fix; last commit under `src/gallium/frontends/sgx`
   2025-01-08), MobiAqua `mesa-sgx` `mesa-22.3-sgx` (22.3.7,
   2024-09-11), Maemo `mesa` 22.3.6+sgx2 (daedalus) / 24.0.9-sgx1 (excalibur binary). **TI's newest
   `powervr/25.2.8` has no `sgx` driver any more**, and TI's 6.18 BSP has no SGX provider at all —
   SGX ends at TI's 6.12 BSP. The current `libpvr_dri_support` exports
   `PVRDRIRegisterVersionedCallbacksV0`, which every current SGX Mesa frontend requires → **current
   Mesa forks pin us to the 2024 blobs**.
6. **Maemo Leste is the closest stack to ours:** its excalibur suite **ships together** kernel
   `linux-image-omap 6.18.51` with `pvrsrvkm_omap4_sgx540_120.ko` (module path
   `drivers/gpu/drm/pvrsgx/1.17.4948957/eurasia_km/`, i.e. the openpvrsgx tree), the TI 2024 blobs, an
   **open (LGPL, reverse-engineered) `libdbm`**, a `pvrsrvinit` (no licence statement, Addendum B.1), and Mesa+sgx — on the same
   kernel series we run (6.18.48). That the pieces are co-shipped is verified from Maemo's apt
   indexes. That this combination **renders on Maemo's 6.18 kernels** rests on Maemo developers'
   IRC statements for the Droid 4 (2026-06-03, 2026-08-04). Nothing measured backs them, and none is
   specific to 6.18.51.1 ([kdp](kernel-driver-port.md) Addendum A.5). The Droid 4 GPU is also documented
   as working on older kernels, e.g. the April 2022 Maemo update.
7. **musl:** pmOS !1868 (merged 2021-02-23, **removed 2022-05-27**: primarily a policy decision
   against proprietary userspace, but the removal commit also states the package was unused,
   unmaintained and no longer building) ran the *2020* blobs on musl with `libc6-compat`. The
   **2024 blobs are harder**: they are `_FORTIFY_SOURCE` builds needing nine `__*_chk` symbols (only
   gcompat has them), and musl's dynamic linker maps `NEEDED libc.so.6` to itself, so gcompat must be
   loaded explicitly. Measured against Alpine edge `musl 1.2.6-r5 + gcompat 1.1.0-r4`, **every glibc
   symbol resolves** — `mmap64`/`lseek64` (only in the `libdbm` blob) are absent from musl's dynsym
   but musl 1.2.6's dynamic linker remaps LFS64 names to the base symbol at relocation time
   (`get_lfs64()`, ldso/dynlink.c:350-376, called at :432), and on 32-bit ARM glibc's `mmap64`/`lseek64`
   have the same 64-bit-offset ABI as musl's `mmap`/`lseek`. Two true ABI hazards remain:
   **`libsrv_um` imports the 32-bit-`off_t` `mmap@GLIBC_2.4`** while musl's `mmap` takes a 64-bit
   `off_t` (structural, follows from the import alone; whether it bites at runtime must be confirmed
   with strace on the device), and **`strerror_r` is defined with different return types** by musl
   (XSI, `int`) and gcompat (GNU, `char *`), which one process can only resolve one way (§4.4.8).
8. **Two viable libc routes**, both cheap thanks to what we already have:
   **(A) native musl** — Mesa-sgx built for musl + blobs loaded through a small open "glibc-ABI shim"
   (loads libgcompat, fixes the 32-bit `mmap` and the `strerror_r` clash; LFS64 needs nothing);
   **(B) glibc sandbox** — run the
   GPU consumer (compositor or visualizer) inside our existing Debian-bookworm `/opt/glibc-rt`
   (glibc 2.36 ≥ 2.34) under bubblewrap, exactly like Roon, using Maemo's daedalus (= bookworm-based)
   debs. Route B is the fastest path to a first pixel; route A is the clean end state.
9. **Both compositors relevant to us refuse SGX's GLES2 unpatched** (other compositors were not
   checked): wlroots 0.20.2 (Alpine labwc 0.20.2)
   and Weston 16.0.0 (Alpine) both hard-require `GL_EXT_unpack_subimage`, which no SGX blob
   advertises. TI maintains a small Weston revert patch (2 files, +23/−5 lines) for exactly Weston 16.0
   (`meta-ti` 2026-08-11). Weston (already in our image) is the low-risk compositor; labwc needs a
   wlroots patch nobody maintains. An open alternative is to **emulate the extension inside our
   Mesa-sgx frontend**, which fixes every compositor without touching Alpine packages.
10. **Licensing:** TI's "Text File License"/TSPA permits **redistribution of the binaries unmodified**,
    with the license text, **for use only with TI devices** (OMAP4460 is one), and forbids reverse
    engineering/disassembly. So: shipping unmodified blobs (with `!strip`) in our OTA apk repo is
    within the grant (*legal reading, not advice*); anything patched (patchelf, symbol weakening) must
    not be redistributed, and because the grant reads "Redistribution **and use** in binary form,
    without modification", even on-device patching is **not clearly permitted** — prefer designs that
    need no binary modification. A fetch-at-install variant (pinned TI commit + per-file sha256) is designed in §8
    as the fallback.

**Recommended pairing (matrix §9, row 1):** KM openpvrsgx 1.17.4948957 (`omap4_sgx540_120`) ×
TI 2024 ti443x blobs × Maemo open `libdbm` + MobiAqua MIT `pvrsrvinit` × Mesa 24.0.x-sgx × first on **GBM/KMS**
(particle visualizer, kmscube) then **Weston 16 + TI patch**, libc route **B first, A second**.

---

## 1. Ground truth: what the stock firmware shipped

Read from `reverse-eng/factory/tungsten-ian67k/system.raw.img` with `debugfs -R` (no mount) on
2026-10-11:

| Path in stock /system | Size | Notes |
|---|---|---|
| `/vendor/lib/egl/libEGL_POWERVR_SGX540_120.so` | 5140 | EGL shim |
| `/vendor/lib/egl/libGLESv2_POWERVR_SGX540_120.so` | 372324 | string `OpenGL ES 2.0 build 1.8@785978` |
| `/vendor/lib/egl/libGLESv1_CM_POWERVR_SGX540_120.so` | 446184 | |
| `/vendor/lib/libIMGegl.so` | 71532 | string `1.4 build 1.8@785978` |
| `/vendor/lib/libsrv_um.so`, `libsrv_init.so`, `libusc.so`, `libglslcompiler.so`, `libpvr2d.so`, `libpvrANDROID_WSEGL.so`, `libPVRScopeServices.so` | | services/compiler/WSEGL |
| `/vendor/bin/pvrsrvinit` | 5432 | interpreter `/system/bin/linker` (bionic), NEEDED `libsrv_init.so libsrv_um.so libc.so libdl.so libcutils.so` |
| `/vendor/lib/hw/gralloc.omap4.so`, `hwcomposer.omap4.so` | | Android HALs |
| `/lib/egl/egl.cfg` | 36 | `0 1 POWERVR_SGX540_120` |
| `/build.prop` | | `ro.build.id=IAN67K`, Android 4.0.4, `ro.opengles.version=131072` (GLES 2.0) |

- The ARM attributes have **no `Tag_ABI_VFP_args`** (i.e. softfp/base AAPCS), `Tag_FP_arch: VFPv3`,
  NEON present (`readelf -A libGLESv2_POWERVR_SGX540_120.so`).
- The stock **KM is built into the kernel**: `reverse-eng/vmlinux.bin` contains the string
  `CustomerGoogle_Android_ogles1_ogles2_GPL sgxddk 18 1.8@785978` and symbols `PVRCore_Init`
  (`c0025920`), `OMAPLFB_Init` (`c0025af0`), `SGXInitialise` (`c0294048`), `RequestSGXFreq`
  (`c0290c28`), `SGXInitClocks` (`c0295488`) in `reverse-eng/tools/kallsyms.txt`; plus the
  `omaplfb` display-class driver (strings `drivers/gpu/pvr/omaplfb/omaplfb_displayclass.c`).
- **No `/etc/powervr.ini`** in stock /system (no apphints were used by Google).
- **Microkernel:** stock `libsrv_init.so` contains `SetupuKernel : Failed to allocate 0x%x bytes for
  %s USE program` — the microkernel is embedded (see §3.6).

**Consequence.** Stock UM = DDK **1.8@785978**, bionic, softfp, display through Android's
`omaplfb`/gralloc/hwcomposer. The closest open KM is openpvrsgx `letux/pvrsrvkm-1.8.869593`
(different build number; libsrv_um checks `SGXConnectionCheck: Incompatible client DDK revision
(%d)/device DDK revision (%d)` and `PVRSRV_ERROR_DDK_VERSION_MISMATCH` — strings in stock
`libsrv_um.so`). Running stock UM would need (a) the exact 1.8@785978 KM source ported to 6.18 and
(b) libhybris to load bionic libs. **Not recommended** (§6 option E). Stock remains valuable as
hardware ground truth for the KM workstream (clock setup via `dpll_per_m7x2_ck`/`gpu_fck`, DVFS,
`sgx_idle_*` — strings in `vmlinux.bin`), not as a userspace source.

---

## 2. Inventory of userspace DDK builds for SGX540 rev 120 (as of 2026-10)

### 2.1 TI `omap5-sgx-ddk-um-linux`, DDK 1.17@4948957 — **the live one**

Cloned `https://git.ti.com/git/graphics/omap5-sgx-ddk-um-linux.git` on 2026-10-11 (the cgit web UI
returned HTTP 503; the git endpoint worked).

Relevant branches (head commit, date, subject — from `git log --all`):

| Branch | Head | Date | Note |
|---|---|---|---|
| `1.17.4948957/mesa/glibc-2.35` | `84a396a` | 2024-10-16 | "all: rebuild with major fixes applied" — **newest**; targets `ti335x_linux ti343x_linux ti437x_linux ti443x_linux ti572x_linux ti654x_linux` |
| `ti-img-sgx/kirkstone-mesa/1.17.4948957` | `bbae721` | 2023-01-26 | **no ti443x** (`ti335x ti437x ti572x ti654x`) |
| `ti-img-sgx/kirkstone/1.17.4948957` | `9058090` | 2022-10-25 | no ti443x |
| `ti-img-sgx/dunfell/1.17.4948957` | `742cf38` | 2021-04-17 | has `ti443x` |
| `ti-img-sgx/zeus/1.17.4948957` | `551665b` | 2020-09-17 | has `ti443x`; **the commit pmOS !1868 used** |
| `ti-img-sgx/thud/1.17.4948957` | `2a2e5bb` | 2019-10-25 | "Mesa3D based frontend UM libraries" switch happened here (2019-09/10) |
| `infoadas/1.9/*`, `ti-img-sgx/1.14.3699939*` | | 2018–2019 | older DDKs (OMAP5/DRA7/AM) |

The README of `84a396a` lists "Allowed values for the SoC: ti335x, ti437x, ti572x, ti654x" — **it does
not list ti443x although the directory is there**; meta-ti's `ti-sgx-ddk-um_1.17.4948957.bb` also has
`COMPATIBLE_MACHINE = "ti33x|ti43x|am57xx|am65xx"` (no OMAP4). OMAP4 is therefore *shipped but
officially unsupported* by TI; its users are Maemo Leste and MobiAqua (both pin this commit, see
2.2/2.3).

**File list, `targetfs/ti443x_linux/lws-generic/release/usr/` @ `84a396a`** (size in bytes; sha256
prefix computed 2026-10-11; byte-identical in Maemo's leste15 git tree, but **not** in its `.deb`s,
whose blobs lack the `.comment` section — Addendum B.4):

| File | Size | sha256 (first 12) | NEEDED |
|---|---|---|---|
| `bin/pvrsrvctl` | 9624 | `c2adbdf3aaa1` | libsrv_init.so.1 libsrv_um.so.1 libc.so.6 ld-linux-armhf.so.3 |
| `lib/libsrv_um.so.1.17.4948957` | 169720 | `6bdfe93ac402` | libdrm.so.2 libc.so.6 ld-linux-armhf.so.3 |
| `lib/libsrv_init.so.1.17.4948957` | 103852 | `ac329c21ef75` | libsrv_um.so.1 libc.so.6 |
| `lib/libusc.so.1.17.4948957` | 738144 | `61cb7a4e7cd9` | libc.so.6 |
| `lib/libglslcompiler.so.1.17.4948957` | 243332 | `cf65d40e9415` | libsrv_um libusc libm.so.6 libc.so.6 |
| `lib/libGLESv2_PVR_MESA.so.1.17.4948957` | 370912 | `b8bcd405e8e3` | libsrv_um libpvr_dri_support libm libc |
| `lib/libGLESv1_PVR_MESA.so.1.17.4948957` | 403684 | `3896bb0154fb` | + libusc |
| `lib/libpvr_dri_support.so.1.17.4948957` | 104232 | `1a14a453a4db` | libsrv_um libdbm libdrm libc |
| `lib/libdbm.so.1.17.4948957` | 9708 | (replaced by open REed lib, §3.3) | libdrm libc |
| `lib/libpvr2d.so.1.17.4948957` | 17912 | `ba924676fabd` | libsrv_um libc |
| `lib/libPVRScopeServices.so.1.17.4948957` | 9640 | `b5c6db168bfd` | libsrv_um **libstdc++.so.6** libc (profiling only) |
| plus `.so` and `.so.1` symlinks for each | | | |
| `targetfs/common/etc/init.d/rc.pvr`, `pvrsrvctl.service.template`, `50-pvrsrvctl.rules.template` | | | MIT-licensed IMG init glue |

Total runtime payload ≈ 2.2 MB. Strings: `OpenGL ES 2.0 build 1.17@4948957`.
Not shipped any more: EGL/GBM/glapi (provided by Mesa since 2019, commit `790f225` "Switch to using
Mesa as frontend provider", `ce1a77e` "Remove libGBM from all targets").

The **2020 commit `551665b`** `targetfs/ti443x/` additionally carried TI's prebuilt **Mesa** bits
(`libEGL.so.1.0.0`, `libgbm.so.1.0.0`, `libglapi.so.0.0.0`, `libGLESv2.so.2.0.0`,
`libGLESv1_CM.so.1.1.0`, `dri/pvr_dri.so`, headers, `rc.pvr`) built for glibc; and its DDK libs
differ in hash from 2024 (e.g. `libsrv_um` `c4faa93c6ca5`) and NEED the pre-2.34 split libs
(`libdl.so.2 libpthread.so.0 librt.so.1`).

### 2.2 Maemo Leste `sgx-ddk-um` — TI blobs + open pieces (the reference integration)

`https://github.com/maemo-leste/sgx-ddk-um` (cloned 2026-10-11): `master` = `6fb7fa2`
(2025-11-12, "Add forgejo workflow"), same tree as `maemo/excalibur`; tag `1.17.4948957+leste15` =
`a9dbdc7` (2025-01-08, "pull latest blobs"; parent `f4fb2c4` "add upstream blobs").

- `ti443x/usr/{bin/pvrsrvctl, lib/*.so.1.17.4948957}` — **sha256-identical to TI `84a396a`** (all 10
  files compared; table above). Maemo's **git tree** therefore carries **unmodified** TI blobs; its
  binary `.deb`s do not (`dh_strip` drops `.comment`) and carry no licence file (Addendum B.4).
  (The older `scripts/weaken-glibc-symbols.sh` was added 2021-11-22 (`e076383`, Merlijn Wajer) and <!-- docs-check: ignore -->
  applied to `libGLESv1`'s `GLIBC_2.29` version entry in `b679e21` (2022-02-13, changelog leste12
  "Weaking libGLESv1 symbols"); it is not applied to the leste15 binaries since they hash-match TI.)
- **`dbm/dbm.c` (730 lines) + `dbm_helpers.c`** — LGPL re-implementation of TI's `libdbm` by Ivaylo
  Dimitrov (2022; changelog leste14 "use REed libdbm instead of a blob"; `ce20a6a` 2022-02-17 by
  Tony Lindgren "dbm: Fix render node usage for wlroots"; `17ba023` 2025-01-08 "dbm: Fix
  drmPrimeHandleToFD() flags"). It checks `strcmp("omapdrm", ver->name)` (dbm.c:549) and
  `drmGetNodeTypeFromFd(fd) != DRM_NODE_PRIMARY` (dbm.c:589).
- **`pvrsrvinit/pvrsrvinit.c`** — 29-line replacement for `pvrsrvctl`:
  `dlopen("libsrv_init.so.1", RTLD_LAZY)` → `dlsym("SrvInit")` → call. No licence header and no
  COPYING; it is a copy of pmOS's 2020 `pvrsrvinit.c` (pmaports, GPL-3.0 repo licence), so not the
  one to build — use MobiAqua's MIT file (Addendum B.1).
- `headers/usr/include/pvrsgx/...` (hwdefs incl. `sgx540defs.h`, services headers, `pvr2d.h`) and
  `sgx-ddk-um.pc` — for building the open bits.
- `etc/profile.d/mesa.sh`: `export MESA_LOADER_DRIVER_OVERRIDE=pvr`.
- `debian/sgx-ddk-um-tools.powervr.init` (OpenRC): `before logger; after eudev; start: /usr/bin/pvrsrvinit`.
- `debian/control`: `sgx-ddk-um-ti443x` **Conflicts/Replaces/Provides `pvr-omap4`,
  `libegl1-sgx-omap4`, …** — i.e. Maemo retired the DDK 1.9 `pvr-omap4` stack in favour of 1.17.

Binary packages (Maemo apt index, fetched 2026-10-11, `https://maedevu.maemo.org/leste/dists/…`):

| Suite | `sgx-ddk-um-ti443x` | Mesa | Kernel |
|---|---|---|---|
| daedalus (Devuan 5 = Debian bookworm base) | `1.17.4948957+leste15-1+4m7`, Depends `libc6 (>= 2.34), libdrm2 (>= 2.4.60), libstdc++6 (>= 5)` | `22.3.6+sgx2-1+4m7` (`libegl-mesa0`, `libgbm1`, `libgl1-mesa-dri` → `libllvm15`) | `linux-image-omap 6.6.58.4-1+4m7` |
| excalibur (Devuan 6; Release dated 2026-09-22) | `1.17.4948957+leste15-1+5m7` | `24.0.9-sgx1+5m7` (`libc6 (>= 2.38)`, `libllvm17t64`) | `linux-image-omap 6.18.51.1-1+5m7` |

`Contents-armhf` (excalibur) lists
`lib/modules/6.18.51/kernel/drivers/gpu/drm/pvrsgx/1.17.4948957/eurasia_km/pvrsrvkm_omap4_sgx540_120.ko`
(package `linux-image-omap`), `usr/bin/pvrsrvinit` (`sgx-ddk-um-tools`), `etc/init.d/powervr`, and
`etc/powervr.ini.leste` (package `leste-config-mapphone`) whose content on GitHub
(`maemo-leste/leste-config`, `leste-config-mapphone/etc/powervr.ini.leste`) is:

```ini
[default]
DisableHWTQTextureUpload=1
```

**This is the stack Maemo ships for OMAP4430/SGX540-120 (Droid 4) on a 6.18 kernel.** Whether it
actually renders on 6.18.51 is **not measured**. The apt indexes prove co-distribution only. The
only 2026 reports are IRC statements by Maemo developers that pvr works on the Droid 4 with their
6.18 kernels (2026-06-03, 2026-08-04). There are also N900 (SGX530) reports both ways on 6.18. See
[kdp](kernel-driver-port.md) Addendum A.5. Note also that the daedalus `Contents-armhf`
lists the module under `lib/modules/6.6.53/` while daedalus `Packages` lists `linux-image-omap
6.6.58.4-1+4m7` — the Contents index may lag the Packages index. The source of
Maemo's Mesa 24.0.9-sgx1 is on Maemo's Forgejo, not on GitHub: `git.maemo.org/leste-upstream-forks/mesa`
branch `maemo/excalibur` = tag `powervr-24.0.9` @ `72c93be7aa29141dc53168bb5afbc814545ad0fc`
(2025-12-27); the GitHub mirror's `maemo/excalibur` (head `60902e8a087`, 2025-12-05, VERSION 22.3.6)
lags it (corrected 2026-10-11, see the Addendum at the end).

### 2.3 MobiAqua (PandaBoard = OMAP4) — Yocto recipes, same TI commit

`https://github.com/mobiaqua/yocto` (shallow clone 2026-10-11; repo pushed 2026-04-15):

- `meta-ti/recipes-bsp/libgles/ti-sgx-ddk-um_1.17.4948957.bb`: `BRANCH=${PV}/mesa/glibc-2.35`,
  `SRCREV=84a396a4fb379f10931421e489ac8a199d6a9f2c`, `TARGET_PRODUCT:panda = "ti443x_linux"`;
  installs to `${libdir}/gles-ti443x_linux/` (as unversioned `.so` + `.so.1` links) and exports
  `LD_LIBRARY_PATH=/usr/lib/gles-ti443x_linux` from `/etc/profile.d/sgx_gles.sh` — i.e. **blobs in a
  private directory, not in /usr/lib** (useful pattern for us).
- `meta-ti/recipes-graphics/mesa/mesa-sgx_22.3.7.bb`: `git://github.com/mobiaqua/mesa-sgx.git`,
  branch `mesa-22.3-sgx`, `SRCREV=9d86c74493ec194ed01958eca71c5532b626df27`,
  `GALLIUMDRIVERS = "sgx"`, `-Dgallium-sgx-alias=omapdrm`.
- `meta-ti/recipes-bsp/powervr/sgx-module-series5_git.bb`: `mobiaqua/sgx-pvr5-module` @
  `7589b68513a1179f800128340ee7d5278dee1da9` (2025-04-06 "synced with upstream"), module
  `omapdrm_pvr_ti443x.ko`; `sgx-pvrsrvinit/pvrsrvinit.c` (MIT, `dlopen("libsrv_init.so",
  RTLD_NOW|RTLD_GLOBAL)`); `sgx-module-init/panda/rc.pvr` = `modprobe omapdrm_pvr_ti443x;
  /usr/bin/pvrsrvinit`.
- Kernel patches `meta-ti/recipes-kernel/linux/linux-ti_6.x/0007_omap4-sgx.patch` up to 6.8.

**Correction of the brief:** GitHub has **no** `mobiaqua/pvr-omap4`, `mobiaqua/sgx-ddk-um`,
`mobiaqua/ti-sgx-ddk-um` or `mobiaqua/pvr-omap4-dkms` repositories (`git ls-remote` → "Repository not
found"; the full repo list via the GitHub API on 2026-10-11 has `yocto, linux-arm, mpv-mini, python,
mpv-gui, sgx-pvr5-module, mesa-sgx, ti-ducati-fw, mplayer-mini, apps, kmscube, ti-libdce,
ti-gc320-driver, ti-ipcdev, libgbm, …`). MobiAqua's UM is TI's repo fetched by Yocto.

### 2.4 Maemo/Ubuntu `pvr-omap4` — DDK 1.9@2253347 (legacy)

`https://github.com/maemo-leste/pvr-omap4` (cloned 2026-10-11): last commit `46e9839` 2021-04-26;
package `1.9.0.8.1.3-1` (2020-05-27), imported from TI's Ubuntu `sgx-lib_1.9.0.8.1-2glp1`
(2013-02-05, `fetch-pvr-omap/log.txt`). Files `usr/lib/arm-linux-gnueabihf/*.so.1.9.6.0`:
`libEGL, libGLESv1_CM, libGLESv2, libIMGegl, libsrv_um, libsrv_init, libusc, libglslcompiler,
libpvr2d, libPVRScopeServices, libpvr_wlegl, libpvrws_WAYLAND, libpvrws_KMS, libpvrws_OMAPDRI2,
gbm/gbm_pvr.so`, `usr/bin/pvrsrvinit` + X11 test tools, `etc/X11/xorg.conf.d/99-omap.conf`.

- Version string: `OpenGL ES 2.0 build 1.9@2253347` (libGLESv2), `1.4 build 1.9@2253347` (libIMGegl).
- Hard-float glibc (`Tag_ABI_VFP_args: VFP registers`, max `GLIBC_2.11`); NEEDS **`libdrm_omap.so.1`**,
  `libgbm.so.1` (a 2013 GBM *backend* ABI: `gbm_pvr.so` + "libgbm (>= 9.0.0-8)" in debian/control),
  `libwayland-client/server.so.0` (2013-era), `libX11`, `libdri2.so.1`, `libXfixes`.
- Has its own WSEGL window-system plugins (`libpvrws_KMS/WAYLAND/OMAPDRI2`, `libpvr_wlegl`) — this
  is the "WSEGL Wayland plugin" generation; it predates Mesa-as-frontend.
- KM: openpvrsgx `letux/pvrsrvkm-1.9.2253347` exists and is still rebased (head `d05540a4a44b`,
  2026-08-16 — via `gh api`, 2026-10-11).
- **Status: obsolete.** Maemo moved off it in Nov 2021 (sgx-ddk-um `Replaces: pvr-omap4`); its GBM
  backend ABI and libwayland ABI are a decade old. Kept in the matrix for completeness only.

### 2.5 TI Graphics SDK 4.x (`gfx_rel_es7.x`) — not usable

The Maemo wiki page (rev. 629, last edited 2020-02-17) records: "Last SDK supporting SGX540:
4.04.00.04 (SGX core revision 1.2.0, gfx_dbg_es7.x / gfx_rel_es7.x)", "last SDK with the X11 DRI/DRM
Xorg driver: 4.10.00.01". TI's RN 4.04.00.02 names the **CodeSourcery 2010q1-202** toolchain for SGX540
on Panda (search result summary; the TI wiki page itself returned HTTP 421 on 2026-10-11). CodeSourcery
2010q1 `arm-none-linux-gnueabi` defaults to **softfp/armel** → **ABI-incompatible with hard-float
Alpine** (*inference from the named toolchain; not confirmed on a binary*). Also framebuffer/X11-era
WSEGL only.

**Correction of the brief / June note:** openpvrsgx's `drivers/gpu/drm/pvrsgx/Kconfig`
(`pvrsrvkm-7.2`, fetched via `gh api` 2026-10-11) labels **`PVRSGX_1_9_2188537` "should work on
OMAP3530, AM3517"** and **`PVRSGX_1_8_869593` "should work on OMAP4430, 4460, 4470, OMAP5"** — so
1.9.2188537 is *not* "the canonical OMAP4 SGX540 userspace" (docs/2026-06-19-gpu-sgx540-acceleration-research.md:67).

### 2.6 Letux (goldelico) userspace

Letux does not ship its own blob set: per the letux-kernel list (2019–2022 posts) the
`letux-pvrsgx-1.17` package's `postinst` clones TI's `omap5-sgx-ddk-um-linux` and runs `make install`
at install time; Letux noted 1.17 "requires libc6 >= 2.29" (Debian bullseye) and, for OMAP5, a "check
for DRA7 in libsrv_um.so which has to be disabled" (binary patch). The postinst itself could not be
read (git.goldelico.com returned a 404/placeholder page on 2026-10-11) — **UNVERIFIED** beyond the
list posts. Relevant as a **precedent for fetch-at-install** (§8).

### 2.7 pmOS 2021 `sgx-ddk-um` (historic)

See §5. Packaged TI `551665b` (2020) with a `ti443x` subpackage, an open `pvrsrvinit.c`, and
`depends="libc6-compat"`.

---

## 3. The open glue

### 3.1 Mesa with the `sgx` Gallium frontend (IMG/TI)

All current SGX Mesa forks share IMG's "shim SGX Gallium driver": `src/gallium/frontends/sgx/*.c`
(`sgx_dri.c, sgx_context.c, sgx_drawable.c, sgx_ext.c, sgx_compat.c, sgx_util.c,
sgx_object_cache.c`) + `src/gallium/drivers/sgx{,_alias}/meson.build` (MIT, "Copyright (c)
Imagination Technologies Ltd."). Mechanism (TI `powervr/24.0.1`
`src/gallium/frontends/sgx/sgx_compat.c:43,110,177`):

```c
#define PVRDRI_SUPPORT_LIB "libpvr_dri_support.so"
handle = dlopen(path, RTLD_NOW);
LookupFunc(PVRDRIRegisterVersionedCallbacksV0, pfPVRDRIRegisterCallbacks);
```

i.e. the closed `libpvr_dri_support` is the real driver; Mesa provides glapi dispatch, the DRI
interface, `egl_dri2` platforms (drm/GBM, wayland, surfaceless, x11) and **libgbm**. The blob then
loads the GLES implementation by *unversioned* name: strings in `libpvr_dri_support.so.1.17.4948957`
`LoadOGLES2AndGetFunctions: Couldn't load OGL module libGLESv2_PVR_MESA.so` (same for v1), and
`libGLESv2_PVR_MESA` references `libglslcompiler.so` → **the unversioned `.so` symlinks are runtime
requirements**, not dev files.

Driver naming: commit `68af6a1` (Andrew Davis, authored 2023-09-08, committed to `powervr/24.0.1`
2025-07-11, "dri: Add a default set of PVR/SGX aliases") installs the SGX frontend as `sgx_dri.so`, `pvr_dri.so`, `tilcdc_dri.so`,
`omapdrm_dri.so`, `tidss_dri.so` and defines loader entrypoints for `omapdrm` etc., so Mesa's loader
picks it for the **omapdrm** KMS device without `MESA_LOADER_DRIVER_OVERRIDE` (older forks needed
the override; Maemo still exports `MESA_LOADER_DRIVER_OVERRIDE=pvr`). Meson options:
`-Dgallium-drivers=sgx[,softpipe]`, `-Dgallium-sgx-alias=<kms driver name>` (MobiAqua uses
`omapdrm`). Commit `82e6a92` (Randolph Sapp, 2025-01-08) "sgx_dri: reuse the pipe loader to get a
render node" — the frontend opens the **pvr render node** separately from the omapdrm KMS node.

Live forks (verified 2026-10-11):

| Fork / branch | Base | Head | SGX? | Notes |
|---|---|---|---|---|
| TI `github.com/TexasInstruments/mesa` `powervr/24.0.1` (= `gitlab.freedesktop.org/StaticRocket/mesa`) | 24.0.1 | `7c82c1eebc67f5a62a347a84d42fe795cf7f523b` (2026-03-13, "c11/threads: fix build on c23") | **yes** | used by meta-ti `mesa-pvr_24.0.1.bb` (TI BSP 6.6/6.12); last commits under `frontends/sgx` 2025-01-08 |
| TI `powervr/25.2.8` | 25.2.8 | `7b6e8de7b0acdaff684f1109c6acb575644a93ea` (2026-07-23) | **no** | `meson.options` `gallium-drivers` choices have `pvr` (Rogue) but no `sgx`; TI's 6.18 BSP sets no `BSP_SGX_DRIVER_PROVIDER` (meta-ti `ti-bsp.inc`, master `bd0c69b1` 2026-10-06) |
| TI `powervr/23.2.1`, `powervr/kirkstone/22.3.5`, `/22.0` | | `0e75e7d…`, `c9f0919…`, `651bd17…` | yes (22.3.5+) | older |
| MobiAqua `mesa-sgx` `mesa-22.3-sgx` | 22.3.7 | `a698020` (2024-09-11; GitHub pushed 2024-11-22) | yes | IMG patch stack squashed; Yocto pins older `9d86c74` |
| Maemo `maemo-leste/mesa` `maemo/excalibur` (GitHub mirror, lags Forgejo) | 22.3.6 | `60902e8a087` (2025-12-05) | yes | `963202f2ae8` 2025-01-12 "sgx: add missing __DRI2_CONFIG_QUERY extension"; debian/rules adds `sgx` on armhf, `EGL_PLATFORMS = x11` + `wayland` |
| Maemo `git.maemo.org/leste-upstream-forks/mesa` `maemo/excalibur` (tag `powervr-24.0.9`; built as `24.0.9-sgx1+5m7`) | 24.0.9 | `72c93be7aa29` (2025-12-27) | yes | TI's `powervr/24.0.1` sgx frontend byte-identical except Maemo's 2-line `__DRI2_CONFIG_QUERY` fix; see the Addendum |
| `freemangordon/mesa` (`mesa-pvr-ti`, `mesa-pvr-meamo`) / `xc-racer99/mesa-pvr` tag `mesa-pvr-20.3.2` | 20.3/21.2 | pmOS used `5bd40a45…` | classic `pvr` DRI | pre-Gallium "classic" driver (ChromiumOS `arc-mesa-img` lineage); dead since Mesa 22 dropped classic drivers |

**Interface coupling (verified by `readelf --dyn-syms`):** 2024 `libpvr_dri_support` exports
`PVRDRIRegisterVersionedCallbacksV0` **and** `PVRDRIRegisterCallbacks`; the 2020 one exports only
`PVRDRIRegisterCallbacks`. TI's frontend moved to the versioned interface on 2023-10-03
("sgx: move to versioned callback structure"; `00d6988` on TI `powervr/24.0.1`, the same change is
`01b0e0f8e7d` in Maemo's `maemo-leste/mesa`). So **Mesa 22.3.6+sgx2 / 22.3.7-sgx HEAD /
24.0.1-sgx → 2024 blobs**; the 2020 blobs pair only with pre-2023 frontends.

**Mesa toolchain risk on Alpine edge (GCC 15, C23, LLVM 2x):** meta-ti had to carry
`0001-gallium-Fix-build-with-llvm-17.patch`, `…llvm-19.patch`, `0001-gallivm-Fix-armhf-build-against-LLVM-22.patch`
and `a77f6ead` (2026-03-13) "mesa-pvr: fix compilation errors with c23" for 24.0.1. We should build
with **`-Dllvm=disabled -Dgallium-drivers=sgx,softpipe`** to drop the LLVM churn entirely
(*inference: softpipe as the fallback swrast needs no LLVM*).

### 3.2 libgbm

`mobiaqua/libgbm` (head `f83489d`, 2023-02-19, "fork of GBM library for TI SOCs with SGX 5 series
GPUs") is a standalone loader-style libgbm with a backend ABI (`gbm_backend_abi.h`, `backend.c`) —
the companion of the **pre-2019 TI UM that shipped its own GBM backend** (`gbm_pvr.so` in 1.9/1.14).
For 1.17-with-Mesa, GBM comes from Mesa itself (TI `ce1a77e` 2019-09-17 "Remove libGBM from all
targets"). **We do not need mobiaqua/libgbm** (correction of docs/2026-06-19…:69).

### 3.3 libdbm (display buffer manager) — open replacement exists

TI's `libdbm` is the allocator bridge between the SGX stack and the KMS driver: it opens the
**primary** node of the KMS device named `omapdrm`, allocates dumb buffers, PRIME-exports them
(`drmPrimeHandleToFD`, `drmPrimeFDToHandle`, `drmIoctl` imports in the blob). The blob is also the
only TI library importing `mmap64`/`lseek64` — which musl 1.2.6 still resolves through its LFS64
remapping (§4.3), so this is *not* a reason the blob would fail on musl. Maemo's LGPL `dbm/` re-implementation is a
drop-in (`soname libdbm.so.1` from configure.ac `lt_cur=1+17, lt_age=17`) and is what Maemo ships
since leste14 (2022-02-18). **Use it**: one blob less, builds natively against musl, and contains
the wlroots render-node fix. Note: the s5pv210 hack in pmOS (`dd`-patching the string `omapdrm` →
`exynos` inside `libsrv_um`/`libdbm`, §5) shows the KMS driver name is hard-wired in the blobs —
on our board the KMS driver *is* `omapdrm` (kernel/configs/steelhead_defconfig:2869
`CONFIG_DRM_OMAP=y`), so no patching is needed.

### 3.4 Services start: `pvrsrvctl` / `pvrsrvinit`

- TI: `pvrsrvctl --start --no-module` (usage text in the binary; it can also `finit_module`
  `"/lib/modules/6.1.83/extrapvrsrvkm.ko"` — hard-coded TI path, which is why everyone passes
  `--no-module`). Templates: systemd oneshot `ExecStart=… --start --no-module`,
  `ExecStop=… --stop --no-module`, `Before=graphical.target`; udev
  `SUBSYSTEM=="platform", ACTION=="bind", ENV{DRIVER}=="pvrsrvkm", RUN+="…pvrsrvctl --start --no-module"`.
- Open replacements: Maemo `pvrsrvinit.c` (29 lines), MobiAqua `pvrsrvinit.c` (MIT), pmOS 2021
  `pvrsrvinit.c` — all `dlopen("libsrv_init.so[.1]")` + `SrvInit()`. **Build MobiAqua's against
  musl** — the only one with an explicit licence grant (MIT; Maemo's is an unlicensed copy of pmOS's,
  Addendum B.1) (the only executable in the set; avoids running a glibc `__libc_start_main`).
- Root required (pmOS pkgdesc "(WARNING: runs as root)"); pmOS retried up to 6× with 5 s sleeps
  (`sgx-ddk-um.initd`) to wait for the KM. On systemd: oneshot `After=systemd-modules-load.service`,
  bound to the pvr device (udev `TAG+="systemd"` + `BindsTo=`), *inference*.
- Device discovery in `libsrv_um`: strings `/dev/dri`, `%s/card%d`, `pvr`, `omapdrm`,
  `drmOpenRender`, `_PVRDRMOpenRender`, `_PVRDRMOpenDisplay` — it opens the **pvr** DRM device
  (render node) for services and the **omapdrm** device for display (*inference from strings*).
- KM module name differs per tree: openpvrsgx builds `pvrsrvkm_omap4_sgx540_120.ko` (Maemo
  Contents) and probes by DT `compatible`; TI/MobiAqua build `omapdrm_pvr_ti443x.ko`
  (`PVRSRV_MODNAME := omapdrm_pvr_$(TARGET_PRODUCT)`, sgx-pvr5-module
  `eurasiacon/build/linux2/ti443x_linux/Makefile`).

### 3.5 Apphints (`/etc/powervr.ini`)

`libsrv_um` reads `/etc/powervr.ini` (strings `FindAppHintInFile …`, `/etc/powervr.ini`); sections
`[default]` or per-process name (`GetApplicationName : Can't open cmdline pseudofile`). Hint names
present as strings (2024 blobs): `libsrv_um: PVRDebugLevel PBGrowSize MTModePixelThreshold`;
`libsrv_init: DisableClockGating MaxEDMTasks DisableAlphaCoefficientReOrdering`;
`libpvr_dri_support: ParamBufferSize MaxParamBufferSize PDSFragBufferSize ExternalZBufferMode …`;
`libGLESv2_PVR_MESA: DisableHWTQTextureUpload DisableHWTQBufferBlit DisableHWTQMipGen
DisableHWTextureUpload FlushBehaviour KickTAMode DefaultVertexBufferSize …`. Maemo's Droid 4 runs with
`DisableHWTQTextureUpload=1` (§2.2) — the first candidate setting for us.

### 3.6 The SGX microkernel firmware

Embedded in `libsrv_init.so` for all three DDK generations we inspected:

| DDK | `libsrv_init` `.rodata` | Evidence string |
|---|---|---|
| 1.17@4948957 (TI 2024) | 0x15b94 (≈ 88.9 KB) | `SetupuKernel : Failed to allocate 0x%x bytes for %s USE program`, `LoaduKernelProgram : %s program Device Addr: 0x%x invalid alignment` |
| 1.9@2253347 (pvr-omap4) | 0x13f5e (≈ 81.9 KB) | `SetupuKernel …USE program` |
| 1.8@785978 (stock) | — | `SetupuKernel …USE program` |

The 1.17 KM (`mobiaqua/sgx-pvr5-module` @ `7589b68`) contains no `request_firmware` (grep, 0 hits).
⇒ **No `.fw` file to package or fetch**; the firmware travels with — and must exactly match — the
UM blobs. (Corrects docs/2026-06-19-gpu-sgx540-acceleration-research.md:106-107.)

### 3.7 KM ↔ UM build-option coupling (hand-off to the KM workstream)

`libsrv_um` prints `Build options %s: client/UM 0x%x, driver/KM 0x%x` and checks DDK build numbers.
openpvrsgx `Kconfig` (`pvrsrvkm-7.2`): `menuconfig SGX_ABI … "These options must match your
usermode libraries and firmware in order for anything to work. If disabled, a known OEM
configuration will be assumed."` with `PVRSGX_1_17_4948957_ABI`, `SGX_PB_*` (per-context/shared/
hybrid), `SGX_HW_PERF` (default y), `SGX_HW_RECOVERY` (default y). The TI ti443x reference KM
config (`sgx-pvr5-module` ti443x Makefile): `SGXCORE := 540`, `SGX_CORE_REV := 120`,
`SUPPORT_ACTIVE_POWER_MANAGEMENT := 0`, `SUPPORT_DRI_DRM := 1`, `SUPPORT_DMABUF := 1`,
`PVR_DRM_MODESET_DRIVER_NAME := omapdrm`, `PVR_LWS_NOBC := 1`, `SYS_CFLAGS … -mfloat-abi=hard`.
Known-good combination: Maemo's 6.18.51 build of openpvrsgx 1.17 with these blobs. openpvrsgx branch
heads (2026-10-11, `gh api`): `pvrsrvkm-6.18-rc6` `d2f1e031d58a` (2025-11-21), `pvrsrvkm-6.19-rc6`
`f0f6774c85c3` (2026-01-20), `pvrsrvkm-7.2` `2342ce92fdde` (2026-08-26, merges `pvrsrvkm-1.17.4948957-v3`);
`letux/pvrsrvkm-1.17.4948957` `584dd33a1557` (2025-05-04) — but the branch `pvrsrvkm-7.2` merges is
`letux/pvrsrvkm-1.17.4948957-v3`, head `e5de75568819` (2026-08-21, "1.17.4948957: more strncpy ->
strscpy"), which is the one to track. TI's own KM repo stops at branch
`1.17.4948957/mesa/k6.1`. (Note for the KM workstream: `SGX_DRM` still `select DRM_LEGACY` in the
7.2 Kconfig.)

---

## 4. ABI analysis: can these glibc blobs live in our musl rootfs?

All numbers below were measured on 2026-10-11 against Alpine **edge** armv7 packages downloaded from
`dl-cdn.alpinelinux.org/alpine/edge/main/armv7/`: `musl-1.2.6-r5`, `gcompat-1.1.0-r4`,
`libdrm-2.4.134-r0` (our pmaports pin `11e89dfb…` is docker-build.sh:164; that the build uses the
edge / systemd-edge channel is stated at docker-build.sh:785 and :821-825).

### 4.1 Float ABI and CPU features — compatible

- All 2024/2020 TI blobs and pvr-omap4: `Tag_CPU_arch: v7`, `Tag_FP_arch: VFPv3`,
  `Tag_ABI_VFP_args: VFP registers` (hard-float).
- Alpine armv7 musl ships `/lib/ld-musl-armhf.so.1` (hard-float loader) in `musl-1.2.6-r5`.
- Stock 1.8 blobs: no `Tag_ABI_VFP_args` → softfp → **incompatible** without an armel world.
- TI KM build uses `-march=armv7-a+fp -mfpu=neon -mfloat-abi=hard` (sgx-pvr5-module ti443x Makefile);
  the A9 in OMAP4460 has NEON (our NEON speexdsp rebuild already relies on that).

### 4.2 glibc version requirements

| Set | Highest `GLIBC_` | Split libs NEEDED | Notes |
|---|---|---|---|
| TI 2024 (`84a396a`) | `GLIBC_2.34` (`dlopen/dlsym/pthread_*` moved into libc), `pow/exp/log@2.29`, `fcntl@2.28` | `libc.so.6 libm.so.6 ld-linux-armhf.so.3` (+ `libstdc++.so.6` for Scope only) | TI README: "glibc 2.35, libdrm 2.4.110" |
| TI 2020 (`551665b`) | `GLIBC_2.29` | `libdl.so.2 libpthread.so.0 librt.so.1` too | |
| pvr-omap4 1.9 | `GLIBC_2.11` | + `libdrm_omap`, `libgbm`, `libwayland-*`, X11 | |

Our `/opt/glibc-rt` is Debian bookworm armhf (pmos/nexusq-glibc-rt/APKBUILD:2-18) → glibc **2.36 ≥
2.34**: the 2024 blobs run there natively.

### 4.3 Symbol coverage under musl (+gcompat)

Imported versioned symbols (all TI libs incl. `pvrsrvctl`): 2024 = 111 unique names, of which 108 are
`@GLIBC_*` and 3 are `@GLIBCXX_3.4`; 2020 = 107. Exported by `libc.musl-armv7.so.1` ∪
`libgcompat.so.0`: ≈1971–1975 unique names (count depends on how versioned duplicates are folded).
Absent from the **dynsym** tables:

| Set | Not in musl's dynsym | Not in musl + gcompat dynsym |
|---|---|---|
| TI 2024 | `__fprintf_chk __longjmp_chk __memcpy_chk __printf_chk __snprintf_chk __stpcpy_chk __strcat_chk __strcpy_chk __vsnprintf_chk mmap64 lseek64` | `mmap64 lseek64` (only `libdbm`) |
| TI 2020 | `mmap64 lseek64` | `mmap64 lseek64` |

**Correction (verification 2026-10-11):** absence from dynsym does not mean unresolved. musl 1.2.6
`ldso/dynlink.c:350-376` (`get_lfs64()`) maps any undefined `xxx64` name from a fixed LFS64 list
(which contains `lseek` and `mmap`) to the base symbol, and `do_relocs()` calls it whenever normal
lookup fails (dynlink.c:432). On 32-bit ARM, glibc's `mmap64(…, off64_t)` and `lseek64` already take
/return a 64-bit offset, which is exactly musl's `off_t`, so the remap is ABI-correct. **Net result:
with musl 1.2.6 + gcompat 1.1.0, every glibc symbol the 2024 blobs import resolves** (the `GLIBCXX`
ones from Alpine's `libstdc++`, Scope only).

(`_Znwj/_Znaj/_ZdaPv` are `GLIBCXX` symbols from Alpine's `libstdc++`, only for `libPVRScopeServices`.)

Per library, what needs gcompat (2024): `libsrv_um: __printf_chk __snprintf_chk __vsnprintf_chk`;
`libusc: __longjmp_chk __memcpy_chk`; `libglslcompiler: __memcpy_chk __printf_chk __snprintf_chk
__stpcpy_chk __strcat_chk __strcpy_chk __vsnprintf_chk`; `libGLESv2_PVR_MESA: __snprintf_chk
__vsnprintf_chk`; `libGLESv1_PVR_MESA: __longjmp_chk __snprintf_chk __vsnprintf_chk`;
`libpvr_dri_support: __strcpy_chk`; `libsrv_init`, `libpvr2d`: nothing.

**Why 2021 pmOS "just worked":** the 2020 blobs needed nothing beyond musl except LFS64 names,
which musl ≤1.2.3 exported as symbols and musl 1.2.6 still resolves via the dynamic-linker remap
above. The 2024 blobs differ only by the `_FORTIFY_SOURCE` `__*_chk` imports (gcompat-only). (The
musl 1.2.4 WHATSNEW line "the LFS64 macros are no longer exposed without _LARGEFILE64_SOURCE" is
about *headers* for code compiled against musl; it does not affect pre-built binaries.)

All DRM imports (`drmClose drmCommandNone drmCommandWrite drmDropMaster drmFreeVersion
drmGetNodeTypeFromFd drmGetVersion drmIoctl drmOpen drmOpenRender drmPrimeFDToHandle
drmPrimeHandleToFD drmSetInterfaceVersion`) are exported by Alpine `libdrm-2.4.134` (0 missing);
Alpine also ships `libdrm_omap.so.1`.

No blob has a `PT_TLS` segment (checked all 2024 libs) → no glibc-vs-musl TLS-model trouble.

### 4.4 Loader traps specific to musl (verified in musl 1.2.6 source, `ldso/dynlink.c`)

1. **Reserved names.** dynlink.c:1070-1092: any NEEDED name starting `lib` + `c.`/`pthread.`/`rt.`/
   `m.`/`dl.`/`util.`/`xnet.` resolves to **musl itself**. So `NEEDED libc.so.6` never reaches
   gcompat's `/lib/libc.so.6 → libgcompat.so.0` symlink (the `gcompat-1.1.0-r4` apk contains that
   symlink set — created by gcompat's own `make install`, not by a loop in the APKBUILD:
   `libc.so.6 libcrypt.so.1 libm.so.6 libpthread.so.0 libresolv.so.2 librt.so.1 libutil.so.1`).
   ⇒ **`libgcompat.so.0` must be loaded explicitly** (DT_NEEDED of our own shim, or `LD_PRELOAD`),
   and it must be in the **global** scope before the blobs are `dlopen`ed (Mesa's frontend opens
   them `RTLD_NOW`, local). Load order matters for names both libraries define (see item 8): musl
   puts `LD_PRELOAD` objects in the global chain *before* libc (dynlink.c:1952-1962), whereas a
   gcompat pulled in later (DT_NEEDED of a dlopened shim) comes *after* libc, so libc's definition wins.
2. **`NEEDED ld-linux-armhf.so.3`** (2024 blobs). Not a reserved name → path search. gcompat's
   `/lib/ld-linux-armhf.so.3` is a **PIE executable** (the gcompat loader that re-execs musl with
   `--preload libgcompat.so`; `ELF … pie executable, interpreter /lib/ld-musl-armhf.so.1`), designed
   for glibc *executables*, not for being mapped as a DSO (it would be; it only exports `_init/_fini`
   — probably harmless, *inference*). Cleaner: a private library directory containing
   `ld-linux-armhf.so.3 → /lib/ld-musl-armhf.so.1`; musl detects a DSO defining
   `__libc_start_main` + `stdin` and substitutes itself (dynlink.c:1185-1193).
3. **Symbol versions are ignored** (only hidden versyms are skipped, dynlink.c:264/283) → the
   `GLIBC_2.34` tags are harmless.
4. **`mmap@GLIBC_2.4` with 32-bit `off_t` (real hazard).** glibc armhf `mmap` (without
   `_FILE_OFFSET_BITS=64`) takes a 32-bit offset at `[sp+4]`; musl exports only
   `mmap(…, off_t)` with 64-bit `off_t` (`src/mman/mmap.c:14,39`, `weak_alias(__mmap, mmap)`), which
   AAPCS places 8-byte aligned at `[sp+8]`. The 2024 `libsrv_um` has exactly **one** `mmap` call
   site, in `PVRSRVMapDmaBuf`, storing `fd` at `[sp]` and the offset at `[sp+4]` (`strd r6, r5, [sp]`
   before `blx mmap@plt`); under musl the offset would be read from two unrelated stack words.
   *Verification note:* the hazard itself follows from the import alone, without disassembly —
   `libsrv_um` imports `mmap@GLIBC_2.4` (glibc's non-LFS `mmap`, 32-bit `off_t`), not `mmap64`; the
   call-site count and register layout are the author's disassembly and were deliberately **not**
   re-derived (license). Likely failure mode: musl's `__mmap` rejects any offset with bits in
   `OFF_MASK` (mmap.c:12,17-20: not page-aligned, or ≥ 2^44) with `EINVAL`, so stack garbage most
   probably makes `PVRSRVMapDmaBuf` fail loudly rather than map the wrong range (*inference*). The
   2020 `libsrv_um` imports the same `mmap@GLIBC_2.4`.
   `PVRSRVMapDmaBuf` is the dma-buf import path, i.e. KMS scanout / client dma-buf buffers →
   **likely on the hot path of GBM/Wayland rendering** (*inference*). The 2020 `libsrv_um` has the
   same import, so pmOS 2021 presumably got lucky with zeroed stack words (*inference*). Device-memory
   mappings do **not** go through libc: the only other relevant call is `syscall(192 = __NR_mmap2,
   …)` in `_PVRDRMClose`'s neighbourhood — libc-agnostic. **Must be confirmed on the device with
   `strace -e trace=mmap2` before relying on it.**
   *Licensing note:* establishing this required disassembling two call sites of a TI binary; the TSPA
   forbids disassembly (§8). The project should treat this paragraph as a hypothesis to verify
   empirically (strace) and avoid further disassembly of TI blobs.
   Fixes: (a) route B (glibc sandbox) — no issue; (b) on-device `patchelf --rename-dynamic-symbols`
   (`mmap` → `nq_mmap_off32`) on `libsrv_um` plus a shim exporting `nq_mmap_off32(…, int32_t off)`;
   patchelf **0.18.0** (Alpine `main/patchelf 0.18.0-r3`) has the option (manpage line 126) — a
   *modification*, which the license's "use … without modification" wording arguably forbids even on
   the device (§8); (c) a global interposer is **wrong**
   (musl-built Mesa/libdrm call `mmap` with 64-bit `off_t`).
5. **`clock_gettime@GLIBC_2.17`** (time32 `struct timespec`): musl 1.2.6 exports the legacy name as the
   time32 compat shim (`clock_gettime` at 0x50419 next to `clock_nanosleep` 0x50459, while the real
   implementation is `__clock_gettime64` at 0x381a9; `compat/time32/clock_gettime32.c`). Compatible
   (*inference from symbol layout + source*).
6. `open@GLIBC_2.4` (musl adds `O_LARGEFILE`, harmless), `fcntl@GLIBC_2.28` (fine for non-lock
   commands), `stderr` (data object via GOT, both pointer-sized), `pthread_mutex_t`/`pthread_cond_t`
   sizes (24/48 bytes on both 32-bit ABIs) — compatible (*inference*).
7. Unversioned `dlopen` names (`libpvr_dri_support.so`, `libGLESv2_PVR_MESA.so`,
   `libglslcompiler.so`, `libsrv_init.so[.1]`) must exist in the search path.
8. **`strerror_r` clash (found in verification, 2026-10-11).** `libsrv_um` (2024 and 2020) imports
   both `strerror_r@GLIBC_2.4` (GNU: returns `char *`) and `__xpg_strerror_r@GLIBC_2.4` (XSI:
   returns `int`). musl exports `strerror_r` as the XSI function (same address as its
   `__xpg_strerror_r`), and gcompat exports its own GNU `strerror_r`. Only one definition can win in
   a process: if gcompat comes after libc (DT_NEEDED of a dlopened shim), the blob gets musl's XSI
   version and would treat the `int` 0 as a string pointer on that error path; if gcompat is
   `LD_PRELOAD`ed, every musl-built library in the process (Mesa, libdrm, the compositor) gets the GNU
   version instead. Consequence: likely only on error-reporting paths, but a crash *while* reporting
   an error hides the real error. Fix options for route A: rename the blob's import (a binary
   modification — §8), or accept it and verify that the path is cold (strace/gdb on device). Route B
   is unaffected. The only other name both libraries define and the blobs import is `fopen` (gcompat
   wraps it; benign — *inference*).

---

## 5. pmaports MR !1868 — what really happened

GitLab API (`gitlab.postmarketos.org/api/v4/projects/226/merge_requests/1868`, read 2026-10-11; the web
UI is behind Anubis):

- **Title** "PowerVR SGX Acceleration", **state merged**, created 2021-01-11, merged 2021-02-23,
  52 notes (the notes endpoint requires auth → not read), source branch `sgx-v4`. Description: "TI
  publishes [1] binary blobs … built against GLIBC and only include wayland support … patches for
  Chromium [2] … include the DRI driver under the MIT license. The OpenGL and initialization
  libraries are still closed source, but fortunately they can be loaded the dlsym and work properly
  under musl … two new aports … known to work with wlroots-based compositors (when there's a patch
  for the unpack subimage extension included) as well as Plasma mobile. X-based DEs do not currently
  work due to some bugs around OpenGL ES2 support in glamor/modesetting." (`[1]`
  `git.ti.com/cgit/graphics/omap5-sgx-ddk-um-linux`, `[2]` ChromiumOS `arc-mesa-img`.)
- **Aports (diff):** `non-free/sgx-ddk-um` `pkgver=1.17.494857`,
  `_commit=551665bf9c321bc3e7721416e6ebbc9f65c18155`, `depends="libc6-compat"`, `options="!check !strip"`,
  subpackages `-s5pv210 -ti335x -ti343x -ti437x -ti443x -ti654x -openrc`, each `provides=sgx-ddk-um-soc`;
  `copy_soc_files` takes `libglslcompiler libGLESv1_PVR_MESA libGLESv2_PVR_MESA libpvr2d libdbm
  libsrv_um libpvr_dri_support libPVRScopeServices libsrv_init libusc`; `pvrsrvinit.c` compiled with
  `gcc … -ldl`; `s5pv210.post-install` `dd`-patches `exynos\0` over `omapdrm` at fixed offsets in
  `libsrv_um.so.1.17.4948957` (110644) and `libdbm.so.1.17.4948957` (5960). `main/mesa-pvr-dri-classic`
  `20.3.2` from `xc-racer99/mesa-pvr`, `-Ddri-drivers=…omapdrm` classic driver, later (MR 2702,
  2021-12-14) switched to `freemangordon/mesa@5bd40a45…` "much more stable … got firefox running"
  and (MR 2790, 2022-01-04) `pvr-wayland.sh: export MESA_LOADER_DRIVER_OVERRIDE=pvr`.
- **Removal:** commits `023f8cc1` + `cecfb418` (2022-05-27, MR 3162): "We decided against pvr hacks,
  quoting craftyguy from issue 1316: … supporting pvr in pmaports/pmOS has many of the same problems
  that we saw when trying to support hallium/libhybris … we want to avoid adding the proprietary
  userspace components required to support pvr in pmOS. No device port is using this package
  anymore … it doesn't build anymore." Issue #1316 "Embrace PowerVR or not?" (closed 2022-01-25)
  centred on `samsung-espresso3g` (Galaxy Tab 2 = **OMAP4430 + SGX540**) needing patched Mesa **and a
  patched wlroots** (which pmOS refused to package).
- **Lessons for us:** (1) it was primarily a **policy** removal — the commit message also records
  that no device port used the packages any more, that `mesa-pvr-dri-classic` was unmaintained, and
  that it "doesn't build anymore" (bit-rot, not a runtime failure); (2) the open-recipe
  shape (blob package split per SoC + open pvrsrvinit + Mesa fork + env var) is sound; (3) its musl
  success was with the **2020** blobs — the 2024 ones need §4's extra care; (4) the compositor
  extension problem (§7) was already the blocker then.

---

## 6. Realistic options for Alpine armv7 hard-float musl

| # | Option | How | Pros | Cons / risk |
|---|---|---|---|---|
| **A** | **Native musl + glibc-ABI shim** | Build Mesa-sgx (TI 24.0.1 or Maemo 22.3.6+sgx2) and Maemo's open `libdbm` + `pvrsrvinit` **for musl**; install TI blobs unmodified into a private dir (`/usr/lib/sgx-ddk/`, MobiAqua-style); a small open `libnq-sgxcompat.so` that is `DT_NEEDED` by our Mesa build (or preloaded): pulls `libgcompat.so.0` into the global scope, provides the private `ld-linux-armhf.so.3 → ld-musl` link, and (if confirmed and if the license question in §8 is settled) the 32-bit `mmap` thunk for a `patchelf`-renamed `libsrv_um` | Whole system stays musl; any app (labwc clients, visualizer) can use GLES; no second rootfs; we own every open piece | Mesa fork build on edge toolchain (C23/GCC 15); the `mmap` off32 hazard and the `strerror_r` clash (§4.4.8) need either binary patching (license-doubtful even on device, §8) or proof the paths never matter; gcompat semantics differ subtly (e.g. `__ctype_b_loc` tables); first-of-its-kind for the **2024** blobs on musl (no known-working precedent) |
| **B** | **glibc sandbox (reuse `/opt/glibc-rt`)** | Overlay Maemo **daedalus** debs (bookworm-based: `sgx-ddk-um-ti443x`, `sgx-ddk-um-tools`, `libgbm1`/`libegl-mesa0`/`libgl1-mesa-dri 22.3.6+sgx2`, + Weston/kmscube from Debian) into the existing Debian bookworm armhf base; run the GPU consumer under bubblewrap with `/dev/dri` bound, exactly as `roon-nexusq` runs RoonBridge | Binaries Maemo ships for Droid 4 (daedalus, 6.6 kernel; runtime status not re-verified here) on glibc 2.36; zero ABI hacks; the bwrap pattern already exists (pmos/device-google-steelhead/roon-nexusq, nexusq-glibc-rt) | Second userland for graphics (**> 100 MB**: Debian bookworm armhf `libllvm15` alone is 100,245 kB installed per packages.debian.org, and Maemo's `libgl1-mesa-dri` depends on it — the earlier "40-60 MB" estimate was too low; avoiding LLVM needs a rebuilt Mesa); the compositor lives in the sandbox, musl apps talk to it over the Wayland socket (protocol is libc-agnostic) but cannot themselves use GLES; `/opt/glibc-rt` is flash-only (not in OTA, nexusq-glibc-rt/APKBUILD:9-12) → a separate `nexusq-gpu-rt` package/overlay is needed for OTA |
| **C** | **Dedicated glibc container for the compositor** | Same as B but a separate rootfs (Debian bookworm or trixie / Maemo excalibur) only for Weston/visualizer | Isolation from Roon's base; can track Maemo excalibur (Mesa 24.0.9-sgx1, glibc 2.41) | Even more disk; duplicated base; two glibc bases to keep patched |
| **D** | **patchelf'd blobs + private glibc in `/usr/glibc-compat`** | Ship a minimal glibc (e.g. from `/opt/glibc-rt`) and `patchelf --set-interpreter`/`--set-rpath` on the blobs, loading them into a musl process | — | **Does not work for libraries**: one process cannot host two libcs; only works for whole executables (then it is option B without the sandbox). Patching = modification (license, §8). Rejected. |
| **E** | **libhybris + stock 1.8@785978** | bionic blobs from stock /system + libhybris + a port of the 2012 KM | Exact stock firmware | Needs the 1.8@785978 KM (no maintained branch; openpvrsgx has 1.8.**869593**); libhybris on musl unmaintained; pmOS rejected hybris; softfp/bionic; Android gralloc/hwcomposer model. Rejected. |

**Recommendation:** **B for the first milestone** (prove KM + blobs + Mesa on our kernel with the
least unknowns — any failure is then a KM/DT/clock problem, not an ABI one), then **A as the
product** (so labwc/LXQt and the visualizer run natively). Keep the particle visualizer on
**GBM/KMS directly** (no compositor) in both routes.

Design notes for **A**:
- Install path `/usr/lib/sgx-ddk/` (blobs + `.so`/`.so.1` links + `ld-linux-armhf.so.3` link);
  Mesa-sgx in `/usr/lib/sgx-mesa/` (its own `libEGL.so.1`, `libgbm.so.1`, `libGLESv2.so.2`,
  `dri/omapdrm_dri.so`); the GPU-using processes get
  `LD_LIBRARY_PATH=/usr/lib/sgx-mesa:/usr/lib/sgx-ddk`. This sits **next to** Alpine's Mesa 26.2.4
  (`main/mesa`) instead of replacing it — consistent with the "no frozen override" rule (CLAUDE.md:
  option 2, "a small addition that sits next to upstream"). Alpine's own Mesa (llvmpipe) stays the
  default for everything else; pmos/device-google-steelhead/APKBUILD:45 already pulls
  `mesa-dri-gallium`.
- libgbm ABI: wlroots 0.20 / Weston 16 built against Mesa 26 headers resolve every `gbm_*`, `egl*`
  and `gl*` symbol they import against a 22.3.7-sgx or 24.0.x-sgx prefix — checked 2026-10-11 with
  `readelf --dyn-syms` on Alpine's armv7 binaries against the candidates' symbol lists (Addendum
  §A.2). The prefix must supply `libEGL`, `libgbm`, `libGLESv2` and `libglapi` together: Mesa's EGL
  reaches into libgbm's private `struct gbm_dri_device` (`platform_drm.c:82,723` at TI `7c82c1e`).
- Clients: force Qt/GTK clients of the LXQt session to stay on wl_shm (no per-client blob loading)
  unless needed: `QT_QUICK_BACKEND=software`, `GDK_GL=disable` (*inference*).

---

## 7. The compositor constraint: `GL_EXT_unpack_subimage`

GLES2 extension strings in the blobs (`strings`): the 1.17 `libGLESv2_PVR_MESA` advertises
`GL_EXT_texture_format_BGRA8888 GL_OES_EGL_image GL_OES_EGL_image_external GL_OES_surfaceless_context
GL_OES_rgb8_rgba8 GL_OES_mapbuffer GL_KHR_debug GL_EXT_texture_rg GL_EXT_texture_storage …` but **not**
`GL_EXT_unpack_subimage` nor `GL_EXT_read_format_bgra`; stock 1.8 and pvr-omap4 1.9 also lack it.

- **wlroots** `render/gles2/renderer.c` at tags 0.19 and 0.20 (latest 0.20.2, 2026-07-07): lines
  549-558 — `GL_EXT_texture_format_BGRA8888` and **`GL_EXT_unpack_subimage` are hard requirements**
  (`"GL_EXT_unpack_subimage not supported"` → `return NULL`). Alpine edge: `labwc 0.20.2` on
  `wlroots0.20 0.20.2`.
- **Weston** `libweston/renderer-gl/gl-renderer.c` (re-read at tag 16.0.0, lines 5655-5656; tagged 2026-07-14): `if (gr->gl_version
  < gl_version(3, 0) && !gl_extensions_has(gr, EXTENSION_EXT_UNPACK_SUBIMAGE)) { weston_log("GL_EXT_unpack_subimage
  not available.\n"); return -1; }`. Introduced by commit `593d5af4` (2020-12-15, "gl-renderer:
  require GL_EXT_unpack_subimage"), first tag 10.0.0 → **Debian bookworm's Weston is affected too**.
  Alpine edge: `weston 16.0.0` (already a device dependency, APKBUILD:51).
- **TI's fix:** meta-ti `recipes-graphics/wayland/weston/0001-Revert-require-GL_EXT_unpack_subimage-commit.patch`
  (Ryan Eatmon 2026-03-24, "Upstream-Status: Inappropriate [specific to TI SGX]"; 2 files, adds
  `has_unpack_subimage` + a full-row upload fallback, `2 files changed, 23 insertions(+), 5
  deletions(-)`; it reverts weston commit `593d5af43a8e`), applied via `weston-ti-version.inc` by
  `weston_16.0.%.bbappend` (updated 2026-08-11, `2db87cfc`) — **maintained for exactly Alpine's
  Weston version**.
- labwc/wlroots: no maintained patch found (pmOS 2021 had one; the RenderDoc issue #2988 reports that
  merely skipping the check on other drivers crashed later in swapchain allocation).
- X11/glamor: broken on SGX blobs (pmOS !1868; Maemo bug #524 "PowerVR DDK 1.17 Glamor/Xorg") — our
  desktop is already Wayland (PLAN.md:2160-2164).

Options: (i) **Weston + TI patch** — as a separately named package (e.g. `weston-sgx` installed under
its own prefix, or in the glibc sandbox for route B) rather than overriding Alpine's `weston`;
(ii) **emulate `GL_EXT_unpack_subimage` in our Mesa-sgx frontend** (intercept `glPixelStorei(
GL_UNPACK_ROW_LENGTH/SKIP_PIXELS/SKIP_ROWS)` and repack before `glTex(Sub)Image2D`, then append the
name to the extension string) — fixes wlroots, Weston and any client without touching Alpine packages;
our code, open, CPU cost only on partial uploads (*design inference; no fork does this today — grep
of TI 24.0.1, MobiAqua and Maemo sgx frontends found nothing*); (iii) patch wlroots (override of an
Alpine package → needs the update-path machinery the rules require). **Prefer (ii) long-term, (i) for
the first demo.**

---

## 8. Licensing and redistribution (PUBLIC_RELEASE=1 images and the gh-pages OTA repo)

**TI 1.17 (`84a396a` `LICENSE`, "TEXAS INSTRUMENTS TEXT FILE LICENSE", meta-ti calls it
`LicenseRef-TI-TSPA`, although the text is meta-ti's `TI-TFL` template — Addendum B.2)**, quoted
lines 18-31:

> Redistributions must preserve existing copyright notices and reproduce this license … in the
> documentation and/or other materials provided with the distribution.
> Redistribution and use in binary form, **without modification**, are permitted provided that …
> * No reverse engineering, decompilation, or disassembly of this software is permitted …
> * any redistribution and use are licensed by TI **for use only with TI Devices**.

Plus a patent clause limited to combinations with TI devices, and Khronos/SGI notices for headers.
pvr-omap4 1.9 (`license.txt`, "TECHNOLOGY AND SOFTWARE PUBLICLY AVAILABLE … OMAP 4 USER SPACE GRAPHICS
DRIVER BINARY") has the same redistribution/no-RE terms.

**Assessment (not legal advice):**
- OMAP4460 is a TI device → shipping **unmodified** blobs with the license file is within the grant.
  Precedents: Maemo Leste redistributes the files in its public apt repo (`main`) — but `.comment`-stripped
  and without the licence text, so a precedent for distribution, not for compliance (Addendum B.4); pmOS did
  in 2021-2022 (`non-free/`); our OTA repo already carries proprietary stock Broadcom firmware
  (`device-google-steelhead-nonfree-firmware`, APKBUILD:88; docker-build.sh:296-380).
- **Anything modified must not be redistributed:** no `strip` (abuild strips by default →
  `options="!strip"`), no `patchelf`, no symbol weakening, no `dd` string patches in the published
  apk. If route A needs `patchelf --rename-dynamic-symbols` (§4.4), doing it in a
  `post-install`/trigger **on the device** keeps it out of the redistributed payload, **but** the
  grant's wording (LICENSE:22, "Redistribution **and use** in binary form, without modification, are
  permitted") ties *use* to unmodified binaries as well, so on-device patching is **not clearly
  permitted** either (*legal reading, UNVERIFIED — not advice*). Prefer a route that runs the blobs
  unmodified (route B, or proving the hazards are cold paths). Note: Maemo leste12 (2022) shipped a
  symbol-weakened `libGLESv1`, so the precedent exists, but it is not evidence of permission.
- The no-RE clause covers our own work too: the disassembly in §4.4 should not be extended; verify
  behaviour with strace/ltrace instead.
- Maemo's REed `libdbm` is LGPL-licensed source by its author — fine for us to build and ship; any
  legal exposure of its clean-room status is theirs, but note it. No version is named, so by the
  LGPL's own rule any FSF-published version may be chosen: `LGPL-2.0-or-later` (Addendum B.1).
- The stock Google/IMG 1.8 blobs carry no redistribution grant (the factory image is
  non-redistributable, reverse-eng/README.md) → never ship them.
- Size is a non-issue: ≈ 2.2 MB of blobs vs. the 100 MB GitHub Pages limit noted in
  scripts/publish-ota-repo.sh.

**Packaging design (preferred: redistribute unmodified):**
- `sgx-ddk-um-ti443x` (arch armv7, `license="LicenseRef-TI-TSPA"`, `options="!strip !check !tracedeps
  !archcheck"`): `source=` the TI git snapshot at `84a396a4…` (or a GitHub release asset of the
  untouched tarball, like nexusq-glibc-rt does — nexusq-glibc-rt/APKBUILD:29-31), `sha512sums`
  pinned; installs the 9 runtime libs + links into `/usr/lib/sgx-ddk/`, the LICENSE into
  `/usr/share/licenses/sgx-ddk-um-ti443x/`; **no `libdbm` blob, no `pvrsrvctl`, no Scope**.
- `sgx-ddk-um-open` (LGPL-2.0-or-later AND MIT): Maemo `libdbm` + MobiAqua `pvrsrvinit` built for musl, the compat shim,
  `/etc/powervr.ini` (`DisableHWTQTextureUpload=1` initially), systemd unit + udev rule.
- `mesa-sgx` (sgx frontend MIT; the package as a whole `MIT AND SGI-B-2.0 AND BSL-1.0` like Alpine's
  Mesa — Addendum B.2): private prefix.
- `scripts/release-preflight-no-secrets.sh` gains a check that `usr/share/licenses/sgx-ddk-um-ti443x/LICENSE`
  exists whenever `/usr/lib/sgx-ddk` is present (the "reproduce this license" condition), and that the
  shipped blob hashes equal the pinned TI ones (proves "without modification"). The full check list is
  Addendum B.5.

**Fallback design: fetch-at-install** (if Petr prefers not to redistribute at all, or for
PUBLIC_RELEASE images):
- Ship only `sgx-ddk-um-fetch` (open): a oneshot `nq-sgx-fetch.service`
  (`ConditionPathExists=!/var/lib/sgx-ddk/.complete`, `After=network-online.target`) that downloads
  the TI tarball/blobs at the **pinned commit**, verifies **per-file sha256** against a list embedded in
  the package, installs into `/var/lib/sgx-ddk/` (persist store so a reflash with persist kept does not
  re-download — pattern of `nq-persist`), writes the LICENSE next to it, then (route A only, and only if
  the license question in §8 is settled in favour of on-device modification) performs the
  on-device patchelf step. Sources in priority order *(revised 2026-10-11, Addendum B.3)*: the
  `rcn-ee/ti-omap5-sgx-ddk-um-linux` GitHub archive at `84a396a4` (full mirror of TI's refs, LICENSE
  included), Maemo's GitHub archive at `a9dbdc75` (blobs identical, no LICENSE), the `git.ti.com`
  snapshot (cgit snapshot still 503 on 2026-10-11 — fragile), our own GitHub release asset as last
  resort (which is redistribution again). **Not** Maemo's `.deb`: its blobs are `.comment`-stripped
  and fail the per-file sha256.
- Letux's `letux-pvrsgx-1.17.postinst` (clone TI git + `make install`) is the precedent (§2.6).
- Cons: first boot needs network; failure modes must be loud (nq-diag check), and the companion app
  should show "GPU userspace not installed".

---

## 9. Matrix: (KM DDK) × (UM source) × (libc) × (EGL platform)

Legend: **KW** known-working somewhere (named), **P** plausible, **B** blocked/rejected.

| KM DDK (where) | UM source | libc route | EGL / window platform | Status | Evidence |
|---|---|---|---|---|---|
| openpvrsgx 1.17.4948957 `omap4_sgx540_120` (Maemo 6.18.51) | TI 2024 `84a396a` ti443x + Maemo open dbm/pvrsrvinit | glibc (Devuan) | Mesa 22.3.6+sgx2 / 24.0.9-sgx1: X11 (hildon/clutter), GBM | **Shipped** (Droid 4, OMAP4430); works-on-6.18.51 **UNVERIFIED** | Maemo apt index + Contents (2026-09-22) — proves co-distribution only |
| same KM (our 6.18.48 build) | TI 2024 + Maemo daedalus debs | **glibc sandbox** (`/opt/glibc-rt`, bookworm) | GBM/KMS (kmscube, visualizer) | **P — best first target** | §6 B; glibc 2.36 ≥ 2.34; Maemo daedalus = bookworm base |
| same | same | glibc sandbox | Wayland: Weston 16 (or bookworm 10) **+ TI unpack_subimage patch** | P | meta-ti weston_16.0 bbappend (2026-08-11) |
| same | TI 2024 + open dbm/pvrsrvinit + Mesa-sgx built for musl | **musl + gcompat + shim** | GBM/KMS | P (needs §4.4 confirmation) | §4.3 coverage; no precedent with 2024 blobs |
| same | same | musl + shim | Wayland: labwc 0.20.2/wlroots 0.20.2 | **B** unless wlroots patched or extension emulated in Mesa | wlroots renderer.c:554-558 |
| same | same | musl + shim | Wayland: Weston 16.0.0 + TI patch, or emulated extension | P | §7 |
| TI KM 1.17 `k6.1` / `mobiaqua/sgx-pvr5-module` (`omapdrm_pvr_ti443x`) | TI 2024 | glibc | Mesa-sgx 22.3.7, GBM (kmscube) | **KW** per recipes (MobiAqua PandaBoard; its `0007_omap4-sgx.patch` series stops at `linux-ti_6.8`) | mobiaqua yocto recipes |
| openpvrsgx 1.17 (pmOS 2021 kernels) | TI 2020 `551665b` ti443x | musl + `libc6-compat` | freemangordon Mesa 20.3/21.2 classic `pvr`: wlroots(patched), Plasma Mobile | **KW** in 2021 (pmOS !1868; espresso3g = OMAP4430), **dead** since 2022-05-27 | MR 1868/2702/2790/3162 |
| openpvrsgx 1.17 | TI 2020 | musl | current Mesa-sgx (versioned callbacks) | **B** (2020 `libpvr_dri_support` lacks `PVRDRIRegisterVersionedCallbacksV0`) | §3.1 |
| openpvrsgx 1.9.2253347 (still rebased, 2026-08-16) | Maemo/Ubuntu `pvr-omap4` 1.9@2253347 | glibc | WSEGL: X11 DRI2, KMS, Wayland-1.0 plugin | P-but-obsolete (Maemo until 2021) | §2.4; needs 2013 libgbm backend ABI + libdrm_omap |
| openpvrsgx 1.9.2188537 | TI Graphics SDK 4.04 es7.x | **armel** glibc | fbdev/X11 | **B** (softfp; Kconfig says OMAP3530/AM3517) | §2.5 |
| openpvrsgx 1.8.869593 | stock 1.8@**785978** | bionic via libhybris | Android EGL | **B** (build-number mismatch; hybris rejected) | §1 |
| any | TI `powervr/25.2.8` Mesa | any | any | **B** (no `sgx` driver in 25.2.8) | §3.1 |
| any | anything | any | X11 + glamor/modesetting | **B** (glamor ES2 bugs) | pmOS !1868, Maemo #524 |

---

## 10. Suggested sequence (userspace side) and what to measure

1. **Pin the set:** TI `84a396a4fb379f10931421e489ac8a199d6a9f2c` ti443x; Maemo `sgx-ddk-um` tag
   `1.17.4948957+leste15` (`a9dbdc7`) for `dbm/` + `pvrsrvinit/`; Mesa: TI `powervr/24.0.1`
   `7c82c1eebc67…` (has the 2025-01 render-node fix) or Maemo `maemo/excalibur` 22.3.6+sgx2 (has
   `__DRI2_CONFIG_QUERY`); compare both, pick one.
2. **Route B smoke test** (once the KM workstream has `pvrsrvkm_omap4_sgx540_120` loading and
   `/dev/dri/renderD*` appearing): inside a bwrap'd copy of the glibc base with Maemo daedalus debs —
   `pvrsrvinit` → expect exit 0 and the KM's init messages; `cat /proc/pvr/*` (openpvrsgx TODO);
   `kmscube` on HDMI (`es2gears`/`glmark2-es2-drm` if available). Check first for the KM↔UM
   coupling test (§3.7): in `dmesg` the KM logs `(FAIL) SGXInit: Mismatch in client-side and KM
   driver build options.` (sgx-pvr5-module `services4/srvkm/devices/sgx/sgxinit.c`, ~line 2719; the
   openpvrsgx 1.17 tree was not grepped for it), and on the client's stderr `libsrv_um` prints
   `Build options %s: client/UM 0x%x, driver/KM 0x%x` (a userspace string, not a dmesg one).
3. **Measure, don't guess:** `strace -f -e trace=mmap,mmap2,openat,ioctl` of `kmscube` to (a) confirm
   which DRM nodes are opened, (b) observe `PVRSRVMapDmaBuf`'s `mmap2` offset (the §4.4 hazard),
   (c) see apphint file reads. Device rules: wrap in `timeout` + `nice`; no audio path involvement.
4. **Route A**: build `mesa-sgx` (musl, `-Dllvm=disabled -Dgallium-drivers=sgx,softpipe
   -Dgallium-sgx-alias=omapdrm -Dplatforms=wayland -Dgbm=enabled`), open dbm/pvrsrvinit, the shim;
   repeat 2-3 natively; then `LD_DEBUG`-equivalent (musl has none: use `ldd` from musl on each blob
   with the shim preloaded) to list unresolved symbols on target.
5. **Compositor:** Weston 16.0 + TI patch in a private prefix (or the Mesa-side extension emulation),
   `renderer=gl` instead of `pixman` (pmos/device-google-steelhead/weston.ini:11), compare CPU at idle
   and during the visualizer vs. today's pixman baseline; `WLR_RENDERER=pixman` stays for labwc
   (nexusq-wayland.sh:8) until wlroots is solved.
6. **Bake every working step into the build** (AGENTS.md hard rule): packages per §8, unit + udev
   rule, `powervr.ini`, nq-diag check for "services initialised" and DDK build match.

---

## Open questions

1. Does `PVRSRVMapDmaBuf`'s libc `mmap` (32-bit `off_t` call) actually misbehave under musl on the
   device, or is the offset always 0 and the stale stack words happen to be 0? (strace test, §10.3.)
   Answer decides whether route A needs the on-device patchelf step (itself license-doubtful, §8).
   Note musl's `mmap` returns `EINVAL` for a non-page-aligned offset, so a failure would most
   likely be loud (§4.4.4).
2. ~~Where is the source of Maemo's Mesa `24.0.9-sgx1+5m7` (excalibur)? Is it TI `powervr/24.0.1`
   rebased, and does it carry Maemo's `__DRI2_CONFIG_QUERY` fix?~~ **Answered 2026-10-11:** Forgejo
   `leste-upstream-forks/mesa` tag `powervr-24.0.9` @ `72c93be7aa29`; yes and yes (Addendum §A.1).
3. Do Maemo's daedalus Mesa debs run against **our** KM build without the Maemo kernel's exact
   `SGX_ABI` options? Needs the KM workstream to replicate Maemo's 6.18.51 `.config` for pvrsgx
   (the config fragment was not found on GitHub; `maemo-leste/droid4-linux` `maemo-6.12.y` shows
   `CONFIG_PVRSGX_1_14_3699939=y`, which contradicts the excalibur module path — UNVERIFIED which tree
   builds `linux-image-omap 6.18.51`). *Answered 2026-10-11 ([kdp](kernel-driver-port.md) Addendum
   A.2):* the tree is tag `maemo-kernel-6.18.51.1`, built with plain `omap2plus_defconfig`. Its
   appended "Leste changes" block sets `CONFIG_PVRSGX_1_17_4948957=y` after the upstream 1.14 line,
   and the shipped `/boot/config-6.18.51` confirms 1.17. With the 6.18-rc6 tree there are no `SGX_ABI`
   Kconfig options: the options set is the fixed one in the 1.17 Makefile.
4. Is OMAP4460's SGX clock (stock: `gpu_fck` from `dpll_per_m7x2_ck`, DVFS via `RequestSGXFreq`)
   relevant to UM apphints (e.g. `DisableClockGating`)? Probably not, but note for the KM workstream.
5. Policy: does Petr accept redistributing TI binaries in the public OTA repo (license permits it), or
   should PUBLIC_RELEASE images use fetch-at-install?
6. Is libgbm from Mesa 24.0 fully ABI-compatible with Alpine's wlroots 0.20.2 / Weston 16.0.0 built
   against Mesa 26.2.4 headers (route A, private prefix)? **Symbol level answered 2026-10-11: yes**
   (Addendum §A.2, from the source symbol lists). Still open: `readelf` on our own build output and
   a runtime test.
7. Should the `GL_EXT_unpack_subimage` emulation live in our Mesa-sgx fork (preferred) — and is it
   worth upstreaming to TI/Maemo/MobiAqua?
8. Does gcompat's `__ctype_b_loc`/`setlocale` behaviour matter for `libglslcompiler`'s shader parser
   (locale-dependent `strtod`)? Test with shader-heavy demos (glmark2) in route A.
9. Can the TI cgit outage (HTTP 503 on 2026-10-11) be tolerated for fetch-at-install, or must we mirror
   the untouched tarball as a GitHub release asset? **Answered 2026-10-11 (Addendum B.3):** a second
   origin exists without our own mirror (`rcn-ee` archive, Maemo archive; Software Heritage as the
   archival backstop); none of them is TI-operated.
10. Route A: which `strerror_r` will `libsrv_um` get in the final load order (§4.4.8), and is the GNU
    `strerror_r` call reachable outside error paths? (gdb breakpoint on device.)
11. Does Maemo excalibur's 6.18.51 + leste15 stack actually render on a Droid 4 today? (Ask on the
    maemo-leste list / bugtracker before treating it as a known-good reference.)

---

## Sources

Repository (this project), read 2026-10-11:
- docs/2026-06-19-gpu-sgx540-acceleration-research.md:58-59, 65-72, 106-107 (claims corrected above)
- pmos/device-google-steelhead/APKBUILD:45, 48-51, 67-68, 88, 798-802
- pmos/device-google-steelhead/nexusq-wayland.sh:2-9; pmos/device-google-steelhead/weston.ini:7-11
- pmos/nexusq-glibc-rt/APKBUILD:2-14, 29-31; pmos/ota-packages.list
- scripts/release-preflight-no-secrets.sh; scripts/publish-ota-repo.sh (header)
- docker-build.sh:164 (pmaports pin), 296-380 (proprietary firmware handling)
- kernel/configs/steelhead_defconfig:2830, 2869; PLAN.md:2160-2175
- reverse-eng/factory/tungsten-ian67k/system.raw.img (`/vendor/lib/egl/*`, `/vendor/lib/*`, `/vendor/bin/pvrsrvinit`, `/lib/egl/egl.cfg`, `/build.prop`)
- reverse-eng/vmlinux.bin strings; reverse-eng/tools/kallsyms.txt (`PVRCore_Init c0025920`, `OMAPLFB_Init c0025af0`, `SGXInitialise c0294048`, `RequestSGXFreq c0290c28`, `SGXInitClocks c0295488`)

Primary external sources (all accessed 2026-10-11):
- TI UM: https://git.ti.com/git/graphics/omap5-sgx-ddk-um-linux.git — branches/commits `84a396a` (2024-10-16), `551665b` (2020-09-17), `bbae721`, `9058090`, `742cf38`, `790f225`, `ce1a77e`; `LICENSE`, `README.md`, `Makefile`, `targetfs/common/*` (cgit UI https://git.ti.com/cgit/graphics/omap5-sgx-ddk-um-linux/ returned 503)
- TI KM branch list: https://git.ti.com/git/graphics/omap5-sgx-ddk-linux.git (`1.17.4948957/mesa/k6.1` newest)
- meta-ti: https://git.yoctoproject.org/meta-ti master `bd0c69b1` (2026-10-06): `ti-sgx-ddk-um_1.17.4948957.bb`, `ti-sgx-ddk-km_1.17.4948957.bb`, `mesa-pvr_24.0.1.bb`, `mesa-pvr_25.2.8.bb`, `conf/machine/include/ti-bsp.inc`, `mesa-pvr.inc`, `recipes-graphics/wayland/weston_16.0.%.bbappend`, `weston/0001-Revert-require-GL_EXT_unpack_subimage-commit.patch`; commits `04408c57`, `2db87cfc`, `a77f6ead`
- meta-ti weston 15.0.0 thread: https://ratatoskr.run/yocto-meta-ti/2026/03/16983011/t
- TI Mesa: https://github.com/TexasInstruments/mesa branches `powervr/24.0.1` (`7c82c1eebc67f5a62a347a84d42fe795cf7f523b`), `powervr/25.2.8` (`7b6e8de7b0acdaff684f1109c6acb575644a93ea`); https://gitlab.freedesktop.org/StaticRocket/mesa.git (same branch heads)
- MobiAqua: https://github.com/mobiaqua/mesa-sgx (`mesa-22.3-sgx`, head `a698020`), https://github.com/mobiaqua/libgbm (`f83489d`), https://github.com/mobiaqua/kmscube (`a9d0523`), https://github.com/mobiaqua/sgx-pvr5-module (`7589b68`), https://github.com/mobiaqua/yocto (`meta-ti/recipes-*` as cited); repo list via https://api.github.com/users/mobiaqua/repos
- Maemo Leste: https://github.com/maemo-leste/sgx-ddk-um (`6fb7fa2`, tag `1.17.4948957+leste15` `a9dbdc7`), https://github.com/maemo-leste/mesa (`maemo/excalibur` `60902e8a087`), https://github.com/maemo-leste/pvr-omap4 (`46e9839`), https://raw.githubusercontent.com/maemo-leste/leste-config/master/leste-config-mapphone/etc/powervr.ini.leste, https://github.com/maemo-leste/droid4-linux (branches), apt indexes https://maedevu.maemo.org/leste/dists/{daedalus,excalibur}/main/binary-armhf/Packages.gz and `Contents-armhf.gz`, `dists/excalibur/Release`
- Maemo wiki (stale, rev 629, 2020-02-17): https://leste.maemo.org/Motorola_Droid_4/PowerVR
- Maemo news (2022): https://maemo-leste.github.io/maemo-leste-sixteenth-update-november-and-december-2021-january-april-2022.html
- Maemo bug: https://github.com/maemo-leste/bugtracker/issues/524 (title only, via search)
- openpvrsgx: https://github.com/openpvrsgx-devgroup/linux_openpvrsgx — branch list (`git ls-remote`), heads via GitHub API (`pvrsrvkm-6.18-rc6` `d2f1e031d58a`, `pvrsrvkm-6.19-rc6` `f0f6774c85c3`, `pvrsrvkm-7.2` `2342ce92fdde`, `letux/pvrsrvkm-1.17.4948957` `584dd33a1557`, `letux/pvrsrvkm-1.9.2253347` `d05540a4a44b`), `drivers/gpu/drm/pvrsgx/Kconfig` and `TODO` @ `pvrsrvkm-7.2`
- pmaports: API https://gitlab.postmarketos.org/api/v4/projects/226/merge_requests/1868 (+ `/changes`), MR 3162, MR 2702, issue 1316; commits `f247bf1e`, `ea4d3837`, `07ce5f6a`, `a878c81c`, `023f8cc1`, `cecfb418`; web: https://gitlab.postmarketos.org/postmarketOS/pmaports/-/merge_requests/1868
- Alpine aports (master): https://gitlab.alpinelinux.org/alpine/aports/-/raw/master/main/gcompat/APKBUILD, `main/musl`, `community/labwc`, `community/wlroots0.20`, `community/weston`, `main/mesa`, `main/patchelf`; binary apks https://dl-cdn.alpinelinux.org/alpine/edge/main/armv7/ (`musl-1.2.6-r5`, `gcompat-1.1.0-r4`, `libdrm-2.4.134-r0`, `libucontext-1.5.2-r0`, `musl-obstack-1.2.3-r2`)
- gcompat source: https://git.adelielinux.org/adelie/gcompat (tag 1.1.0: `Makefile`, `loader/loader.c`)
- musl source: https://git.musl-libc.org/git/musl tag v1.2.6 (`ldso/dynlink.c`, `src/mman/mmap.c`, `include/sys/mman.h`, `include/time.h`, `compat/time32/clock_gettime32.c`, `WHATSNEW`)
- patchelf 0.18.0: https://raw.githubusercontent.com/NixOS/patchelf/0.18.0/patchelf.1 (line 126 `--rename-dynamic-symbols`)
- wlroots: https://gitlab.freedesktop.org/wlroots/wlroots/-/raw/0.20/render/gles2/renderer.c (lines 549-558), tags via API (0.20.2 2026-07-07)
- Weston: https://gitlab.freedesktop.org/wayland/weston/-/raw/main/libweston/renderer-gl/gl-renderer.c (~5600-5607), commit `593d5af4` (2020-12-15) and its tags; tag list (16.0.0 2026-07-14)
- Khronos: https://registry.khronos.org/OpenGL/extensions/EXT/EXT_unpack_subimage.txt
- RenderDoc issue: https://github.com/baldurk/renderdoc/issues/2988
- Letux list: https://lists.goldelico.com/pipermail/letux-kernel/2021-July/006888.html, https://lists.goldelico.com/pipermail/letux-kernel/2020-April/005171.html, https://lists.goldelico.com/pipermail/openpvrsgx-devgroup/2022-July/000537.html (via search summaries)
- TI Graphics SDK RN 4.04.00.02: http://processors.wiki.ti.com/index.php/RN_4_04_00_02 (HTTP 421 on fetch; content only via search summary)
- TI E2E: https://e2e.ti.com/support/processors-group/processors/f/processors-forum/131070/graphicssdk-error-loading-module-pvrsrvkm-unknown-symbol-v7_dma_map_area (search summary)

---

## Verification (2026-10-11)

Adversarial re-check of this report by an independent pass. Everything below was re-opened from
the primary source on 2026-10-11; nothing was taken from the report itself. No device was touched;
no TI binary was disassembled (only `readelf`/`nm`/`strings`).

### Confirmed (reproduced)

- **TI UM repo** (`git ls-remote https://git.ti.com/git/graphics/omap5-sgx-ddk-um-linux.git`):
  `1.17.4948957/mesa/glibc-2.35` = `84a396a4fb379f10931421e489ac8a199d6a9f2c` (Randolph Sapp,
  2024-10-16, "all: rebuild with major fixes applied"); other heads `bbae721` (2023-01-26),
  `9058090` (authored 2022-10-25, committed 2023-01-04), `742cf38` (2021-04-17), `551665b`
  (2020-09-17), `2a2e5bb` (2019-10-25) re-fetched at depth 1. `targetfs/` of `bbae721`/`9058090`
  has no ti443x; `742cf38`/`551665b` have `ti443x`; `2a2e5bb` has no ti443x. README at `84a396a`:
  "DDK dependencies: glibc 2.35, libdrm 2.4.110", allowed SoCs ti335x/ti437x/ti572x/ti654x only.
  LICENSE lines 18-31 quoted correctly. meta-ti `ti-sgx-ddk-um_1.17.4948957.bb` @ `bd0c69b1`:
  `COMPATIBLE_MACHINE = "ti33x|ti43x|am57xx|am65xx"`, same SRCREV.
- **ti443x file table** (§2.1): all 11 sizes, sha256 prefixes and NEEDED lists reproduced; the
  extracted files are git-object-identical to `84a396a`. 2020 `libsrv_um` sha256 prefix
  `c4faa93c6ca5` and the 2020 prebuilt Mesa files in `551665b:targetfs/ti443x/` reproduced.
- **Maemo `sgx-ddk-um`**: tag `1.17.4948957+leste15` = `a9dbdc75…` (= `maemo/daedalus` head),
  `master` = `maemo/excalibur` = `6fb7fa24…`; all 10 files in `ti443x/` (pvrsrvctl + 9 libs; no
  `libdbm` blob) are sha256-identical to TI `84a396a`. `dbm/dbm.c` 730 lines, LGPL, `strcmp("omapdrm"`
  at :549, `DRM_NODE_PRIMARY` at :589; `pvrsrvinit.c` 29 lines; changelog leste14/leste15 dates;
  `debian/control` Conflicts/Replaces/Provides `pvr-omap4…`; OpenRC init text.
- **Maemo apt indexes** (re-fetched from maedevu.maemo.org): excalibur `Release` dated
  2026-09-22 08:59:15 UTC; excalibur `main/Contents-armhf` lists
  `lib/modules/6.18.51/kernel/drivers/gpu/drm/pvrsgx/1.17.4948957/eurasia_km/pvrsrvkm_omap4_sgx540_120.ko`
  in `kernel/linux-image-omap`; `linux-image-omap 6.18.51.1-1+5m7`, `sgx-ddk-um-ti443x
  1.17.4948957+leste15-1+5m7`, Mesa `24.0.9-sgx1+5m7` (`libc6 >= 2.38`, `libllvm17t64`); daedalus
  `linux-image-omap 6.6.58.4-1+4m7`, Mesa `22.3.6+sgx2-1+4m7` (`libc6 >= 2.34`, `libllvm15`),
  `sgx-ddk-um-ti443x` Depends `libc6 (>= 2.34), libdrm2 (>= 2.4.60), libstdc++6 (>= 5)`.
  `powervr.ini.leste` content reproduced.
- **SGX core/rev**: `mobiaqua/sgx-pvr5-module` @ `7589b685…` ti443x Makefile: `SGXCORE := 540` (:44),
  `SGX_CORE_REV := 120` (:45), `SUPPORT_ACTIVE_POWER_MANAGEMENT := 0`, `-mfloat-abi=hard`,
  `PVRSRV_MODNAME := omapdrm_pvr_$(TARGET_PRODUCT)`, `PVR_DRM_MODESET_DRIVER_NAME := omapdrm`.
  Stock `egl.cfg` = `0 0 android` / `0 1 POWERVR_SGX540_120` (36 bytes).
- **Stock**: `debugfs` listing of `/vendor/lib/egl`, `/vendor/lib`, `/vendor/bin/pvrsrvinit` (sizes as
  in §1), no `/etc/powervr.ini`, `ro.build.id=IAN67K`, 4.0.4, `ro.opengles.version=131072`; strings
  `OpenGL ES 2.0 build 1.8@785978`, `1.4 build 1.8@785978`; vmlinux.bin string
  `CustomerGoogle_Android_ogles1_ogles2_GPL sgxddk 18 1.8@785978`; kallsyms `PVRCore_Init c0025920`,
  `OMAPLFB_Init c0025af0`, `RequestSGXFreq c0290c28`, `SGXInitialise c0294048`, `SGXInitClocks
  c0295488`; no `Tag_ABI_VFP_args`, `Tag_FP_arch: VFPv3`, NEON; pvrsrvinit interpreter
  `/system/bin/linker`. The extracted stock `libGLESv2` is sha256-identical to the image's copy.
- **Microkernel embedded**: 2024 `libsrv_init` `.rodata` size `0x15b94`, pvr-omap4 1.9 `0x13f5e`,
  `SetupuKernel … USE program` strings in all three generations. `request_firmware`: 0 hits in
  sgx-pvr5-module; in openpvrsgx `drivers/gpu/drm/pvrsgx/` the only hit is the 1.7.862890 Cedarview
  video decoder (`imgv/psb_msvdxinit.c`), not the 1.17 KM.
- **Float ABI / glibc**: every 2024 blob has `Tag_ABI_VFP_args: VFP registers`; highest version
  `GLIBC_2.34`; no `PT_TLS`; 2020 set max `GLIBC_2.29`; Alpine `musl-1.2.6-r5` ships
  `/lib/ld-musl-armhf.so.1`.
- **Symbol coverage** (recomputed from the Alpine edge armv7 apks): missing from musl dynsym =
  the nine `__*_chk` + `mmap64` + `lseek64`; gcompat supplies all nine `__*_chk`; per-library
  import lists in §4.3 reproduced (plus `pvrsrvctl` needs `__fprintf_chk`). `GLIBCXX` imports only
  in `libPVRScopeServices`.
- **musl loader**: reserved-name list at v1.2.6 `ldso/dynlink.c:1070-1094`; libc substitution on
  `__libc_start_main`+`stdin` at :1185-1193; hidden-versym skip at :264/:283; gcompat's
  `ld-linux-armhf.so.3` is an ARM PIE executable with interpreter `/lib/ld-musl-armhf.so.1`; musl
  1.2.6 exports `clock_gettime`/`clock_nanosleep` as the time32 shims (`compat/time32/time32.h:33-34`
  `__asm__("clock_gettime")`, `__asm__("clock_nanosleep")`). `src/mman/mmap.c:14,39` as cited.
- **pmaports !1868** (GitLab API): title, merged state, created 2021-01-11, merged 2021-02-23,
  `sgx-v4`, 52 notes, description text; diff: `pkgver=1.17.494857` (sic), `_commit=551665bf…`,
  `depends="libc6-compat"`, `options="!check !strip"`, s5pv210 `dd` offsets 110644/5960. Commits
  `023f8cc1` / `cecfb418` (2022-05-27, MR 3162) and issue #1316 ("Embrace PowerVR or not?",
  closed 2022-01-25) reproduced.
- **Mesa coupling**: 2020 `libpvr_dri_support` exports only `PVRDRIRegisterCallbacks`; 2024 exports
  both. `src/gallium/frontends/sgx/sgx_compat.c:43,110,147,177` identical in TI `powervr/24.0.1`
  (`7c82c1e…`), MobiAqua `mesa-22.3-sgx` (`a698020…`) and Maemo `maemo/excalibur` (`60902e8a…`,
  VERSION 22.3.6) — all look up `PVRDRIRegisterVersionedCallbacksV0`. Branch heads re-checked with
  `git ls-remote`.
- **TI 25.2.8 / BSP 6.18**: `powervr/25.2.8` = `7b6e8de7…` (2026-07-23); `meson.options`
  `gallium-drivers` choices contain `pvr` but no `sgx`; no `src/gallium/drivers/sgx`. meta-ti
  master `bd0c69b1` (2026-10-06) `ti-bsp.inc`: `BSP_SGX_DRIVER_PROVIDER` set for ti-6_12 and ti-6_6
  only; ti-6_18 sets Rogue + `BSP_MESA_PVR_VERSION = "25%"`. TI KM repo newest branch
  `1.17.4948957/mesa/k6.1` (used by meta-ti `ti-sgx-ddk-km` for 6.6/6.12).
- **Unversioned dlopen names**: strings `LoadOGLES2AndGetFunctions: Couldn't load OGL module
  libGLESv2_PVR_MESA.so` (and v1) in 2024 `libpvr_dri_support`.
- **Compositors**: wlroots `render/gles2/renderer.c` at tags 0.19 and 0.20.2, lines 554-558 (0.20.2
  tagged 2026-07-07); Weston 16.0.0 (tagged 2026-07-14) `gl-renderer.c:5655-5656`; commit
  `593d5af43a` (2020-12-15) is contained in tag 10.0.0 onward; no 1.17 or stock blob contains the
  string `unpack_subimage`. meta-ti patch: Ryan Eatmon 2026-03-24, "Upstream-Status: Inappropriate
  [specific to TI SGX]", applied through `weston-ti-version.inc` from `weston_16.0.%.bbappend`
  (`2db87cfc`, authored 2026-08-11).
- **Alpine edge armv7 APKINDEX** (2026-10-11): `musl 1.2.6-r5`, `gcompat 1.1.0-r4`, `libdrm
  2.4.134-r0`, `mesa 26.2.4-r1`, `labwc 0.20.2-r0` (depends `so:libwlroots-0.20.so`),
  `wlroots0.20 0.20.2-r1`, `weston 16.0.0-r0`, `patchelf 0.18.0-r3`; patchelf 0.18.0 manpage line 126
  is `--rename-dynamic-symbols`.
- **openpvrsgx** (`gh api`): Kconfig at `pvrsrvkm-7.2` labels `PVRSGX_1_8_869593` "OMAP4430, 4460,
  4470, OMAP5" and `PVRSGX_1_9_2188537` "OMAP3530, AM3517"; `SGX_ABI` help text and `SGX_DRM select
  DRM_LEGACY` as quoted; branch heads `d2f1e031d58a`, `f0f6774c85c3`, `2342ce92fdde`, `584dd33a1557`,
  `d05540a4a44b` with the dates given. pvr-omap4: `build 1.9@2253347`, NEEDs `libdrm_omap.so.1`,
  `libgbm.so.1`, `libwayland-*`, X11; debian/control `libgbm1 (>= 9.0.0-8)`; same no-RE /
  "without modification" license terms.
- **MobiAqua yocto**: `ti-sgx-ddk-um_1.17.4948957.bb` (`SRCREV=84a396a…`, `TARGET_PRODUCT:panda =
  "ti443x_linux"`, private `gles-${TARGET_PRODUCT}` dir, `LD_LIBRARY_PATH`), `mesa-sgx_22.3.7.bb`
  (`SRCREV=9d86c744…`, `-Dgallium-sgx-alias=omapdrm`, `GALLIUMDRIVERS = "sgx"`), module recipe
  (`SRCREV=7589b685…`, `omapdrm_pvr_${TARGET_PRODUCT}.ko`).
- **Repo citations**: steelhead_defconfig:2869 `CONFIG_DRM_OMAP=y`; docker-build.sh:164 pmaports pin;
  device APKBUILD:45 `mesa-dri-gallium`, :51 `weston`, :88 nonfree subpackage; weston.ini:11
  `renderer=pixman`; nexusq-wayland.sh:8 `WLR_RENDERER=pixman`; nexusq-glibc-rt APKBUILD (Debian
  bookworm armhf base, not in the OTA repo); June note lines 67/69/106-107 say what §2.5/§3.2/§3.6
  say they say.

### Corrected (edited in place above)

1. **`mmap64`/`lseek64` do resolve under musl 1.2.6** (TL;DR 7, §3.3, §4.3, "Why 2021 pmOS just
   worked"). The original claim "every glibc symbol resolves except `mmap64` and `lseek64`" was
   wrong: musl's dynamic linker falls back to `get_lfs64()` (v1.2.6 `ldso/dynlink.c:350-376`,
   called from `do_relocs()` at :432), which maps `lseek64`→`lseek`, `mmap64`→`mmap` and the rest of
   the LFS64 list, and the 64-bit-offset ABIs match on 32-bit ARM. The `libdbm` blob is therefore
   not blocked by LFS64 (replacing it with Maemo's open one is still sensible).
2. **New ABI hazard: `strerror_r`** (§4.4.8, TL;DR 7, §6 A, open question 10). `libsrv_um` imports
   GNU `strerror_r` (and XSI `__xpg_strerror_r`); musl and gcompat define `strerror_r` with
   different return types, and musl's load order (`LD_PRELOAD` before libc, later DSOs after it,
   dynlink.c:1952-1962) means one side of a mixed musl/glibc process always gets the wrong one.
3. **"Known-working on 6.18" downgraded** (TL;DR 6, §2.2, matrix row 1, §6 B): the Maemo indexes
   prove the 6.18.51 kernel, the KM and the blobs are *shipped together*, not that they render;
   no 2026 report of SGX working on Maemo excalibur was found (web search 2026-10-11). Status:
   UNVERIFIED.
4. **pmOS removal reason** (TL;DR 7, §5): primarily policy, but commit `023f8cc1` also says no
   device used the packages, the Mesa fork was unmaintained and "it doesn't build anymore". "Not
   for technical failure" was too absolute.
5. **License: on-device patching** (TL;DR 10, §4.4.4, §6 A, §8): the grant reads "Redistribution
   **and use** in binary form, without modification, are permitted" (LICENSE:22), so modifying
   the binaries on the device is not clearly covered either. Downgraded from "permitted at install
   time" to "license-doubtful (UNVERIFIED legal reading)".
6. **Route B size** (§6 B): Debian bookworm armhf `libllvm15` alone is 100,245 kB installed
   (packages.debian.org, 2026-10-11), so the "~40-60 MB" estimate was too low.
7. **TI Weston patch size** (TL;DR 9, §7): `2 files changed, 23 insertions(+), 5 deletions(-)`, not
   "25 changed lines".
8. **Commit attribution/dates** (§3.1): the "versioned callback" commit `01b0e0f8e7d` is Maemo's hash;
   on TI `powervr/24.0.1` it is `00d6988` (same author date 2023-10-03). `68af6a1` was authored
   2023-09-08 but committed 2025-07-11. TI `powervr/24.0.1` head `7c82c1e…` is dated 2026-03-13 (a
   C23 build fix); "latest SGX commit 2025-01-08" holds only for `src/gallium/frontends/sgx`.
9. **Maemo weaken script** (§2.2): the script was added 2021-11-22 (`e076383`); `b679e21`
   (2022-02-13) applied it to `libGLESv1`.
10. **openpvrsgx 1.17 branch** (§3.7): `pvrsrvkm-7.2` merges `letux/pvrsrvkm-1.17.4948957-v3`
    (head `e5de75568819`, 2026-08-21), not `letux/pvrsrvkm-1.17.4948957` (`584dd33a1557`,
    2025-05-04); the KM workstream should track `-v3`.
11. **§10.2 KM↔UM mismatch message**: the `Build options … client/UM … driver/KM` string is a
    `libsrv_um` userspace string; the KM's dmesg message is `(FAIL) SGXInit: Mismatch in client-side
    and KM driver build options.` (sgx-pvr5-module `sgxinit.c`).
12. **Small precision fixes**: imported versioned symbols = 108 `GLIBC_*` + 3 `GLIBCXX` (=111);
    gcompat's `libc.so.6` etc. symlinks come from gcompat's `make install`, not an APKBUILD loop;
    the Alpine edge channel is evidenced at docker-build.sh:785/:821-825 rather than :164;
    MobiAqua's OMAP4 SGX kernel patch series ends at `linux-ti_6.8`; "every modern compositor"
    narrowed to wlroots and Weston (the only ones checked); "only maintained" narrowed to "newest,
    still shipped by distributions"; Maemo daedalus `Contents-armhf` (modules under 6.6.53) lags its
    `Packages` (6.6.58.4).

### Could not reproduce / left as stated with a caveat

- `PVRSRVMapDmaBuf` call-site layout (`strd r6, r5, [sp]`) and "exactly one `mmap` call site":
  deliberately **not** re-derived (would require disassembling a TI binary, which the license
  forbids). The *existence* of the hazard is confirmed from the `mmap@GLIBC_2.4` import alone; its
  runtime effect remains UNVERIFIED (strace on device).
- TI UM commits `790f225` ("Switch to using Mesa as frontend provider") and `ce1a77e` (2019-09-17,
  "Remove libGBM from all targets"): not re-fetched (abbreviated hashes are not fetchable by
  `git fetch <sha>`; a full clone exceeded the scratch quota). UNVERIFIED by this pass.
- Source location of Maemo Mesa `24.0.9-sgx1+5m7`: confirmed missing from GitHub `maemo-leste/mesa`
  (only tags `22.3.6+sgx1`, `22.3.6-1+deb12u1+sgx1`; `maemo/excalibur` changelog still
  `22.3.6+sgx2-1`); the excalibur `Sources.gz` index has no `mesa` stanza. *Resolved by the
  2026-10-11 Addendum §A.1: the source is on Maemo's Forgejo (`git.maemo.org`).*
- Letux `letux-pvrsgx-1.17.postinst`, TI Graphics SDK 4.04 release notes (softfp toolchain), Maemo
  bug #524, RenderDoc issue #2988, pmaports MR 2702/2790 contents, `mobiaqua/libgbm` head date: not
  re-opened in this pass; they remain as the author reported them.
- Legal conclusions in §8 are readings of the license text, not verified legal advice.

---

## Addendum (2026-10-11): Mesa-sgx choice and libgbm ABI against Alpine consumers (kmscube, weston 16)

Closes groundwork Phase 0 step 8 (Mesa choice) and open questions 19-20 there (= this note's open
questions 2 and 6). Method: blobless/sparse git fetches of the three candidates at pinned commits;
Alpine edge **armv7** `.apk`s and Maemo excalibur **armhf** `.deb`s downloaded into empty scratch
directories and inspected with `readelf`/`nm`/`strings` only (never executed); Weston and Alpine
`aports` read at tags/commits. Nothing was configured, built or run.

### A.1 The three candidates, side by side

| | TI `powervr/24.0.1` | MobiAqua `mesa-22.3-sgx` | Maemo `powervr-24.0.9` |
|---|---|---|---|
| Repo, commit | `github.com/TexasInstruments/mesa` @ `7c82c1eebc67f5a62a347a84d42fe795cf7f523b` (author 2025-11-07 Dave Airlie, committed 2026-03-13) | `github.com/mobiaqua/mesa-sgx` @ `a698020be6888af99daeac6470018a5d85313912` (2024-09-11; committed 2024-11-22) | `git.maemo.org/leste-upstream-forks/mesa` branch `maemo/excalibur` = tag `powervr-24.0.9` @ `72c93be7aa29141dc53168bb5afbc814545ad0fc` (2025-12-27) |
| `VERSION` | 24.0.1 | 22.3.7 | 24.0.9 |
| sgx frontend history | full IMG→TI series, last `82e6a9293c47` 2025-01-08 (GitHub API, path `src/gallium/frontends/sgx`) | two commits only: IMG squash `9d86c744` + `a698020` | TI's series cherry-picked one-for-one (`d25a654` = TI `82e6a92`, `12672ab` = `397da64`, `8bd7c78` = `18b2568`, `0278ee9` = `b58adda`, `5405d87` = `68af6a1` aliases, …) + Maemo `30bfcd3` |
| `diff -r src/gallium/frontends/sgx` vs TI | — | 748 diff lines, almost all Mesa 22.3 → 24.0 DRI API churn (`__DRIscreen` → `struct dri_screen`, …) | **identical except 2 lines** in `sgx_ext.c` (`&dri2ConfigQueryExtension.base` and its version-info entry) |
| Render-node fix (`PVRDRIQueryCompatibleRenderOnlyDeviceFd` via `__DRI_MESA.queryCompatibleRenderOnlyDeviceFd`, `sgx_dri.c:1121-1147` at TI) | **yes** (`82e6a92`, "reuse the pipe loader to get a render node") | **no** (that loader hook does not exist in 22.3) | **yes**; the symbol is in the shipped binary (`nm` on `libgl1-mesa-dri-dbgsym_24.0.9-sgx1+5m7_armhf.deb`) |
| `__DRI2_CONFIG_QUERY` in the screen extensions | **no** | **no** | **yes** (`30bfcd3`, the excalibur port of Maemo `963202f2ae8`, Ivaylo Dimitrov, 2025-01-12) |
| `__DRIimageExtension` version (`PVR_DRI_IMAGE_VERSION`) | **7** (`sgx_ext.c:79`) | **7** (`sgx_ext.c:76`) | **7** (same file as TI); no `PVRDRICreateImageFromDmaBufs` symbol in the binary |
| → `EGL_EXT_image_dma_buf_import` | not advertised (needs ≥ 8, cd §3) | not advertised | not advertised |
| `gallium-sgx-alias` option; aliases | `meson_options.txt:106`; `sgx_dri.so`, `pvr_dri.so`, `omapdrm_dri.so`, `tidss`, `tilcdc` (`targets/dri/meson.build:132-137`) | `meson_options.txt:83`; `sgx_dri.so` + one `<alias>_dri.so` | as TI; the binary deb ships `sgx_dri.so`, `pvr_dri.so`, `omapdrm_dri.so`, `tidss_dri.so`, `tilcdc_dri.so` as hard links of one megadriver |
| Other | `c11/threads` C23 fix (glibc `__once_flag_defined`, irrelevant to musl) | — | Maemo `14b0f40` "egl/wayland: fix pbuffer support" (1 line); Debian 24.0.8-1 packaging; `debian/rules` adds `sgx` on armhf |
| Shipped for an SGX540 device | TI BSP 6.6/6.12 (AM/OMAP5 class SoCs; no OMAP4 product) | MobiAqua PandaBoard (Yocto pins the older `9d86c744`) | **Maemo excalibur `24.0.9-sgx1+5m7`** for the Droid 4 (OMAP4430/SGX540) — renders UNVERIFIED (§2.2) |

What `__DRI2_CONFIG_QUERY` buys: in Mesa 24.0 it is an *optional* extension
(`egl_dri2.c:841`, `optional_core_extensions`), and every use is NULL-guarded
(`egl_dri2.c:1147-1148`, `loader_dri_helper.c:81-82`); without it only the driconf `vblank_mode`
override is ignored. So it is a correctness nicety, not a GBM blocker — but it is free with the
Maemo tree.

Where Maemo's source is: `https://git.maemo.org/api/v1/repos/search?q=mesa` lists
`leste-upstream-forks/mesa` (Forgejo, `original_url` = the GitHub repo, `mirror: false`, updated
2025-12-28); its tags include `powervr-24.0.9` (→ `72c93be7aa29`), `22.3.6+sgx2` (→ `571d7abb76f8`),
`22.3.6+sgx1`. The binary `libgbm1_24.0.9-sgx1+5m7` `changelog.Debian.gz` reads
"mesa (24.0.9-sgx1) … * New upstream release. * enable SGX driver. — Ivaylo Dimitrov, Fri, 26 Dec
2025", on top of Debian's `24.0.8-1` (Timo Aaltonen); the Forgejo log matches ("Add debian packaging
from mesa (24.0.8-1)", "debian/rules: enable sgx driver", "update debian/changelog" 2025-12-27).
The `maedevu` pool has `.dsc`/`.orig.tar.gz` for 21.2.5+pvr* and 22.3.6+sgx2 but **none** for
24.0.9-sgx1, so the Forgejo branch is the only source; nobody has checked that it reproduces the
binary byte-for-byte (UNVERIFIED).

### A.2 libgbm / EGL / GLES ABI against Alpine's consumers (open question 20)

Exports of the candidates (from `src/gbm/gbm-symbols.txt` plus `GBM_EXPORT` in `gbm.c`, identical in
TI and MobiAqua) and of the binaries:

| Library | `gbm_*` exports | Note |
|---|---|---|
| Alpine `mesa-gbm-26.2.4-r1` armv7 `libgbm.so.1.0.0` | 38 | no symbol versioning (`readelf -V`: no verdef) |
| TI 24.0.1 / MobiAqua 22.3.7 source | 38 + `gbm_bo_blit` | the same 38 names; `gbm_bo_blit` is IMG's addition (`gbm.c:847-851`) |
| Maemo `libgbm1_24.0.9-sgx1+5m7` armhf | 38 + `gbm_bo_blit` | binary confirms the IMG GBM patch |

Imports of the consumers (`readelf -W --dyn-syms`, `UND` only):

| Alpine edge armv7 package | `gbm_*` imported | missing from the candidates |
|---|---|---|
| `kmscube-0_git20220902-r1` (`kmscube`, `texturator`) | 25 (19 GLOBAL, 6 WEAK), incl. `gbm_surface_create_with_modifiers`, `gbm_bo_map`/`unmap` | none |
| `weston-backend-drm-16.0.0-r0` `drm-backend.so` | 28, incl. `gbm_bo_import`, `gbm_bo_write`, `gbm_bo_get_fd_for_plane` | none |
| `weston-16.0.0-r0` `gl-renderer.so` | 11, incl. `gbm_bo_create_with_modifiers2` | none |
| `weston-clients` `simple-dmabuf-egl/-feedback` | 10 each | none |
| `wlroots0.20-0.20.2-r1` `libwlroots-0.20.so` | 15, incl. `gbm_device_get_backend_name` | none |

The 18 `egl*` imports of kmscube + `gl-renderer.so` + `drm-backend.so` (and wlroots') are all in
both candidates' `src/egl/egl-symbols.txt`; the 68 `gl*` imports of kmscube + `gl-renderer.so` are
all in `src/mapi/es2api/gles2-symbols.txt`. The `gbm.h` diff TI 24.0.1 → Alpine `mesa-dev-26.2.4`
changes no struct and no existing constant: 26.2 only adds `GBM_BO_FIXED_COMPRESSION_*` flag values
(bits 7-10 of `enum gbm_bo_flags`); TI's header additionally has `GBM_FORMAT_AXBXGXRX106106106106`,
`GBM_FORMAT_YVU444_PACK10_IMG` and `gbm_bo_blit`. Weston 16.0.0 uses only `GBM_BO_USE_{CURSOR,
CURSOR_64X64,LINEAR,RENDERING,SCANOUT,WRITE}` (grep of `libweston/`), so the new compression flags
never reach the old library. Weston's build-time `HAVE_GBM_BO_CREATE_WITH_MODIFIERS2` path is
satisfied at run time because 22.3.7 and 24.0.x export that symbol.

**Verdict, symbol level: a private-prefix libgbm/libEGL/libGLESv2 from either candidate satisfies
Alpine's kmscube, weston 16 (DRM backend + gl-renderer) and wlroots 0.20.2.** Open question 20 is
answered for name resolution; it is not answered for run-time behaviour (below).

Two packaging constraints follow from the source:

1. **The whole Mesa set must come from the prefix.** Mesa's EGL GBM platform dereferences libgbm's
   private `struct gbm_dri_device` (`platform_drm.c:82,723` at TI `7c82c1e`), and Alpine's
   `libEGL.so.1` 26.2.4 is `NEEDED`-linked to `libgallium-26.2.4.so` and `libgbm.so.1`. A process
   that resolves `libEGL` from `/usr/lib` and `libgbm` from the prefix (or the reverse) mixes two
   private ABIs. `LD_LIBRARY_PATH=/usr/lib/sgx-mesa:/usr/lib/sgx-ddk` must therefore cover
   `libEGL.so.1`, `libgbm.so.1`, `libGLESv2.so.2`, `libGLESv1_CM.so.1` and `libglapi.so.0`.
2. **GBM backend lookup** (`src/gbm/main/backend.c:150-235` at 24.0.1): `GBM_BACKEND` env →
   `<kms driver name>_gbm.so` (`omapdrm_gbm.so`) in `GBM_BACKENDS_PATH` or the compiled-in
   `<prefix>/lib/gbm` → the built-in `dri` backend. Build with an explicit
   `-Dgbm-backends-path=/usr/lib/sgx-mesa/gbm` so Alpine's `/usr/lib/gbm` is never consulted.

### A.3 Weston 16.0.0 hard requirements, re-checked at the tag

`weston` tag `16.0.0` = `d1882b0a544ae2197b597a6e39478e719bc54302` (2026-07-14). Every check in the
GBM start-up path of `libweston/renderer-gl/` that aborts renderer creation:

| # | Check | Location (16.0.0) | Who satisfies it on SGX |
|---|---|---|---|
| W1 | `EGL_EXT_platform_base` and `EGL_KHR_platform_gbm` or `EGL_MESA_platform_gbm` client extension (without platform_base: warning and `eglGetDisplay` fallback) | `egl-glue.c:690-739`, `:629-638` | Mesa EGL (both candidates) |
| W2 | display `EGL_EXTENSIONS` string non-NULL | `egl-glue.c:750-754` | Mesa EGL |
| W3 | **`EGL_KHR_surfaceless_context`** | `gl-renderer.c:5375-5376` | Mesa sets it unconditionally (`egl_dri2.c:1029` TI, `:1041` MobiAqua) |
| W4 | an EGL config for the output format, *unless* configless (`EGL_KHR_no_config_context`/`EGL_MESA_configless_context`) | `gl-renderer.c:5378-5388`, `egl-glue.c:806-808` | Mesa sets `KHR_no_config_context` unconditionally (`egl_dri2.c:1028`) |
| W5 | ≥ 1 config with `EGL_WINDOW_BIT` and a known `EGL_NATIVE_VISUAL_ID` | `gl-renderer.c:5394-5401` → `egl-glue.c:284-330` | depends on the sgx frontend's config list — **UNVERIFIED** until run |
| W6 | `eglBindAPI(EGL_OPENGL_ES_API)`; an ES3, else ES2 context | `gl-renderer.c:5559-5596` | blob (ES2) |
| W7 | `eglMakeCurrent(EGL_NO_SURFACE)` (surfaceless) | `gl-renderer.c:5612-5617` | blob advertises `GL_OES_surfaceless_context` (§7) |
| W8 | `GL_EXTENSIONS` non-NULL | `gl-renderer.c:5626-5629` | blob |
| W9 | `GL_RGBA8` renderable: GLES ≥ 3.0 or `GL_ARM_rgba8` / `GL_OES_rgb8_rgba8` / `GL_OES_required_internalformat` | `gl-renderer.c:5633-5636`, `gl-utils.c:1420-1424` | blob advertises `GL_OES_rgb8_rgba8` (§7) |
| W10 | **`GL_EXT_unpack_subimage` when GLES < 3.0** | `gl-renderer.c:5655-5658` | **nobody** — B1, the only failing check |

Everything else is optional: dma-buf import (`:5404-5425`, needs `EXT_image_dma_buf_import` +
`OES_EGL_image`; absent on all three candidates, so no linux-dmabuf for clients), the GBM allocator
(`gl_renderer_allocator_create`, failure only logged), buffer age, partial update, fences, context
priority. On the DRM side, `gbm_surface_create_with_modifiers` failing (24.0's `gbm_dri` returns
`ENOSYS` without `createImageWithModifiers`, `gbm_dri.c:1209-1210`) falls back to plain
`gbm_surface_create` (`drm-gbm.c:286-312`). So the groundwork §3 row 3 claim stands: **weston 16 on
the SGX stack needs exactly B1** (TI's revert patch or the emulation), plus the run-time W5 check.

### A.4 Building for musl on Alpine edge (`-Dllvm=disabled`)

Alpine edge today: `python3 3.14.8-r0`, `meson 1.12.1-r0`, `gcc 15.2.0-r9`, `musl 1.2.6-r5`,
`py3-mako 1.3.12-r0`, `py3-packaging 26.2-r0`, `libdrm 2.4.134-r0` (armv7 `APKINDEX`, 2026-10-11).

| Item | MobiAqua 22.3.7 | TI 24.0.1 / Maemo 24.0.9 | Evidence |
|---|---|---|---|
| Mako check imports `distutils` (removed in Python 3.12, PEP 632) | **blocker**: `from distutils.version import StrictVersion` unconditionally → configure stops with "Python (3.x) mako module >= 0.8.0 required" unless a `distutils` shim (setuptools' `_distutils_hack`) happens to be active | tries `packaging.version` first, `distutils` only as fallback → fine with `py3-packaging` | `meson.build:1016` (MobiAqua), `:1004` (TI), `:1003` (Maemo) |
| Other removed-Python-API use in build scripts (`ast.Str/Num`, `imp`, `pkg_resources`, `pipes`, …) | none found | none found | `git grep` over all `*.py`/`*.build` |
| C standard | `c_std=c11` pinned in `project()` → GCC 15's gnu23 default does not apply to C | same | `meson.build` `project()` |
| TI's C23 fix `7c82c1e` | n/a | glibc-only (`__once_flag_defined`); irrelevant on musl | commit diff |
| glibc-only APIs in the sgx frontend (`__GLIBC__`, `RTLD_DEEPBIND`, `dlinfo`, `secure_getenv`, `qsort_r`, `strerror_r`, `execinfo`, `*_np`) | none; only `dlopen(path, RTLD_NOW)` (`sgx_compat.c:110`) | same | grep |
| Alpine's own musl builds of those Mesa versions | `074d8014` (22.3.7): **no patches** | `26947225` (24.0.1): only `no-unlink-megadrivers.patch`; `496dc8ee` (24.0.7): + `enable-mali-t600.patch` — neither musl-related | `aports` `main/mesa/APKBUILD` at those commits |
| armv7 flag Alpine carried in both eras | `-mtls-dialect=gnu` ("gnu2 tlsdesc is broken in binutils") | same | same APKBUILDs |
| libdrm floor | ok | `_drm_ver = '2.4.109'` ≤ 2.4.134 | `meson.build:1714` (Maemo) |

So the **only known source-level blocker is MobiAqua's `distutils` import**; for the 24.0 lineage
no musl blocker is known. What remains unknown (not reproducible without running the build, which
this pass does not do): meson 1.12 against `meson_version >= 0.60`/`>= 0.53` projects
(deprecations turned into errors?), GCC 15 / libstdc++ 15 against the C++ parts that are always
built (`src/compiler/glsl`, …), and the `-Dllvm=disabled -Dgallium-drivers=sgx,softpipe` combination,
which no Alpine build ever exercised (Alpine always used `-Dllvm=enabled`).

### A.5 Recommendation

**Use the TI frontend lineage, built from Maemo's tree: `git.maemo.org/leste-upstream-forks/mesa`
tag `powervr-24.0.9` @ `72c93be7aa29141dc53168bb5afbc814545ad0fc`**, configured
`-Dllvm=disabled -Dgallium-drivers=sgx,softpipe -Dgallium-sgx-alias=omapdrm -Dplatforms=wayland
-Dgbm=enabled -Dgbm-backends-path=/usr/lib/sgx-mesa/gbm -Dshared-glapi=enabled`, plus Alpine's
armv7 `-mtls-dialect=gnu`, into `/usr/lib/sgx-mesa`. Reasons, strongest first:

1. It is the only one of the three that a distribution ships today for an SGX540 device
   (Droid 4), on a 6.18 kernel with the same `leste15` UM — the closest thing to a reference.
2. Its sgx frontend *is* TI's `powervr/24.0.1` frontend (diff = 2 lines), so it has TI's
   2024-10/2025-01 fixes (opaque DRI structs, dispatch table, `bDBModes`, render node) **and**
   `__DRI2_CONFIG_QUERY`; MobiAqua has none of these.
3. Mesa 24.0.9 = eight upstream point releases over TI's 24.0.1.
4. No known musl build blocker; MobiAqua has one (`distutils`).

Fallback: TI `powervr/24.0.1` @ `7c82c1eebc67` + cherry-pick Maemo `30bfcd3` (same frontend, older
core). MobiAqua is rejected except as a dma-buf reference: its **Yocto pin `9d86c744`** (image v8)
remains the only build that still advertises `EGL_EXT_image_dma_buf_import`, which the B2 probe in
cd §3.7 needs. Update path (CLAUDE.md "no frozen copies"): the APKBUILD fetches the Maemo tag by
commit and records TI `powervr/24.0.1` as the upstream to diff against on every bump. Route B
(glibc sandbox) keeps Maemo daedalus `22.3.6+sgx2` binaries for first light; this choice is for
route A.

### A.6 Corrections made in place (2026-10-11)

1. This note §2.2: the 24.0.9-sgx1 source is located (Forgejo), no longer UNVERIFIED.
2. This note §3.1 table: the Maemo binary row now names the source and commit; the GitHub
   `maemo/excalibur` row is marked as a lagging mirror.
3. This note §6 design notes for A: the libgbm "inference; verify" bullet replaced by the checked
   result and the "whole set from the prefix" constraint.
4. This note open questions 2 (answered) and 6 (symbol level answered); Verification "could not
   reproduce" bullet on the 24.0.9 source marked resolved.
5. `docs/2026-10-11-gpu-sgx540-groundwork.md`: stack diagram, §4 "Mesa" pin (the "pick by building
   both" deferral), Phase 0 step 8, open questions 19 and 20.
6. `docs/gpu-sgx540/usecases-roadmap.md`: open question 3 and the "could not verify" bullet on the
   24.0.9 source; the June-plan table row on the Mesa path.
7. `docs/gpu-sgx540/compositor-display.md` plan step 4: kmscube uses the chosen Mesa;
   `9d86c744` stays for the B2 probe only.

### A.7 Not reproduced / limits

- No configure, build or run of any candidate (rules of this pass); A.4's "unknown" rows stay
  unknown until the first `abuild` in the builder container.
- ABI checked at the level of exported/imported **names** and public header layout. Run-time
  semantics (W5 config list, `gbm_bo_map` on SGX BOs used by kmscube's checksum test, the blob's
  surfaceless make-current) are UNVERIFIED.
- The Maemo Forgejo tree was not rebuilt and compared with the shipped binaries; the link rests on
  matching changelog, version string (`Mesa 24.0.9-sgx1+5m7` in `sgx_dri.so`), `gbm_bo_blit` and
  `PVRDRIQueryCompatibleRenderOnlyDeviceFd` being present in the debs.
- The TI/Maemo symbol-name comparison by regex over `.c` files was too noisy to use beyond the
  specific symbols named above; the `diff -r` of the frontend directories is the evidence for
  "identical except 2 lines".
- Whether setuptools 84's `distutils` shim would rescue MobiAqua's configure was not tested.
- Sources: GitHub API (`TexasInstruments/mesa`, `mobiaqua/mesa-sgx`, `maemo-leste/mesa`,
  `freemangordon/mesa`); `https://git.maemo.org/api/v1/repos/leste-upstream-forks/mesa{,/branches,/tags}`;
  `https://maedevu.maemo.org/leste/pool/main/m/mesa/` (`libgbm1`, `libgl1-mesa-dri`,
  `libgl1-mesa-dri-dbgsym` `24.0.9-sgx1+5m7_armhf`); `https://dl-cdn.alpinelinux.org/alpine/edge/{main,community}/armv7/`
  (`mesa-gbm`, `mesa-egl`, `mesa-dev` 26.2.4-r1, `weston*`/`libweston` 16.0.0-r0, `kmscube
  0_git20220902-r1`, `wlroots0.20 0.20.2-r1`); `gitlab.freedesktop.org/wayland/weston` tag 16.0.0;
  `gitlab.alpinelinux.org/alpine/aports` `main/mesa/APKBUILD` at `074d8014`, `26947225`, `496dc8ee`.

---

## Addendum (2026-10-11): Licences and origins for public release: Maemo pvrsrvinit/libdbm, mesa-sgx sgx frontend, a second blob origin

Input for policy question 28 of the master note (redistribute or fetch at install). Method: full
clone of `maemo-leste/sgx-ddk-um` (65 commits) and `git.ti.com/git/graphics/omap5-sgx-ddk-um-linux.git`
(git smart HTTP worked; the server ignored `--filter`), sparse fetches of `mobiaqua/yocto`
@ `62073e04`, meta-ti @ `bd0c69b1`, TI Mesa @ `7c82c1eebc67` and Maemo Mesa @ `72c93be7aa29`;
pmaports files through the GitLab API; downloads (one GitHub archive, two Maemo `.deb`s) into empty
scratch directories, inspected with `sha256sum`, `readelf`, `strings`, `ar`/`tar` only. Nothing was
executed, built or installed. Everything below that reads a licence is a **legal reading, not advice**.

### B.1 `pvrsrvinit` and `libdbm`: provenance and the licence actually granted

| File | Lineage (evidence) | Licence actually granted | Use it? |
|---|---|---|---|
| Maemo `pvrsrvinit/pvrsrvinit.c` | Added by parazyd, `ebe9c631` 2021-11-23 "Add pvrsrvinit code." (with a 7-line Makefile); `8219f2a` same day switched to `libsrv_init.so.1`; `e21e113` 2022-01-09 (Ivaylo Dimitrov) moved it under autotools. The first version is the pmOS file **verbatim except whitespace and `main()` → `main(void)`**: pmaports `non-free/sgx-ddk-um/pvrsrvinit.c` @ `f247bf1e` (Jonathan Bakker, authored 2020-12-09, "new aport (MR 1868)"), same strings `failed to open libsrv_init.so`, `failed to find SrvInit symbol`, `failed to initialize server` | **None stated.** No header; Maemo's tree has no LICENSE/COPYING/`debian/copyright` (`git ls-tree -r` at `a9dbdc75` and `6fb7fa2`: no match); `AUTHORS` and `README` are empty. Its source file sits in pmaports, whose root `LICENSE` at `f247bf1e` is **GPL-3.0** (674 lines, sha256 `589ed823…`); the file itself has no header. Inherited GPL-3.0 is the most a reader could claim, and it is a guess | **No** |
| MobiAqua `meta-ti/recipes-bsp/powervr/sgx-pvrsrvinit/pvrsrvinit.c` (`mobiaqua/yocto` @ `62073e04`) | Paweł Kołodziejski: `mobiaqua/oe` `d692d69de95a` 2019-12-28 "Replace pvrsrvinit with simple initialisation code", `bb433c7a7371` the same day "Added headers" (adds the MIT text); moved to `mobiaqua/yocto` in `8e4813a` 2023-08-20; the current file adds `dlopen("libsrv_init.so", RTLD_NOW \| RTLD_GLOBAL)` + `dlsym` | **MIT**, by the file's own header (the standard MIT permission and disclaimer, no copyright line) and the recipe's `LICENSE = "MIT"` (`sgx-pvrsrvinit_1.0.bb:2`). Independent of the pmOS/Maemo line (different code and messages) | **Yes**: `source=` it from `mobiaqua/yocto` at the pinned commit (a fetch, not a copy into our tree). It opens the unversioned `libsrv_init.so`, which our package installs anyway (ub §3.1) |
| Older open `pvrsrvinit.c` (CyanogenMod `android_hardware_ti_omap4`, `00f927ad59b4` 2014-11-12, Michael Gernoth) | Links `SrvInit` directly (no `dlopen`); not the ancestor of any of the above | none stated | No |
| Maemo `dbm/dbm.c`, `dbm.h`, `dbm_helpers.c`, `dbm_helpers.h` | Only origin is Maemo (`b6e48b2` 2022-01-10 "Add libgbm REed code", Ivaylo Dimitrov; later `549254b`, `e2e1860`, `ce20a6a` Tony Lindgren, `0ef1321`, `f1117fe`, `17ba023` 2025-01-08). `freemangordon` (Ivaylo's GitHub) has `pvr` and `pvr_egl_shim` but no dbm repo; GitHub code search for `dbm_helpers` finds only Maemo | Every file: "Copyright (C) 2022 Ivaylo Dimitrov … GNU Lesser General Public License as published by the Free Software Foundation", **no version** (dbm.c:6-8 etc.). The LGPL itself settles that case: "If the Library does not specify a license version number, you may choose any version ever published by the Free Software Foundation" (LGPL-2.1 §13; LGPL-3.0 §6 has the same rule). SPDX: **`LGPL-2.0-or-later`**, as the draft already guessed. dbm includes only `xf86drm.h`, `drm.h`, `gbm.h` and libc headers, no TI/IMG header | **Yes**. The repo ships no LGPL text, so our package must carry it (`/usr/share/licenses/sgx-ddk-um-open/`) and the source must stay reachable (our public aport + the pinned Maemo archive) |

The `headers/usr/include/pvrsgx/` tree in Maemo's repo (28 files) is IMG "Dual MIT/GPLv2"; the open
glue does not include it (`dbm/Makefile.am`, `configure.ac` need only `libdrm` and `gbm`).

### B.2 Licence texts: drop C, drop B, and mesa-sgx

**Drop C (`84a396a4`, the one we ship).** `LICENSE` (6554 bytes, sha256 `37507b46…`, md5
`7232b98c1c58f99e3baa03de5207e76f`) was added on that lineage by `a864d75` 2023-10-13 (Randolph
Sapp, "LICENSE: add boilerplate TI text file license … present in rogue"). Its body is meta-ti's
`meta-ti-bsp/licenses/TI-TFL` template: a word diff differs only in the filled-in year, the quoting
of `("TI Devices")`, one full stop, two apostrophes, and the Khronos/SGI notices TI appended. meta-ti
nevertheless labels the recipe `LicenseRef-TI-TSPA` (`ti-sgx-ddk-um_1.17.4948957.bb:3`), and its own
`licenses/TI-TSPA` is a **different** document (a click-through "Technology and Software Publicly
Available Software License Agreement"). MobiAqua calls the same md5 `TI-TSPA` for SGX and `TI-TFL` for
Rogue. Recommendation: label our package `LicenseRef-TI-TFL` and ship the file verbatim.

**Drop B (`ce7b96b`, `551665b`, `742cf38`) — the text §11 of `re` marked unread.** These commits
have **no `LICENSE`**; the terms live only in `TI-Linux-Graphics-DDK-UM-Manifest.doc` (Word 97,
77,824 bytes, git blob `33505e1c…`, the same at all three commits), read with `strings -e l`. The
manifest lists "targetfs, 1.17, TI TSPA, Binary, Modified: Yes, Obtained from: IMG" and quotes
"TECHNOLOGY AND SOFTWARE PUBLICLY AVAILABLE SOFTWARE LICENSE FOR OMAP(TM) USER SPACE GRAPHICS DRIVER
BINARY, Copyright (c) 2013, Texas Instruments Incorporated. Portions (c), Imagination Technologies
Limited": redistribution and use in binary form without modification; reproduce the licence; no
endorsement; "No reverse engineering, decompilation, or disassembly"; a patent licence for "the
software alone" that excludes any combination; plus the same third-party, Khronos and SGI notices.
**It has no "for use only with TI Devices" clause**, so drop B's terms are no stricter than C's. The
practical burden is that reproducing it means extracting text from a `.doc`. Drop B stays unplanned.

**mesa-sgx.** At both candidate commits (TI `powervr/24.0.1` @ `7c82c1eebc67`, Maemo `powervr-24.0.9`
@ `72c93be7aa29`), all **17 files** under `src/gallium/frontends/sgx/`, `src/gallium/drivers/sgx/` and
`drivers/sgx_alias/` carry the MIT permission text (`grep -L` finds none without it). 16 say
"Copyright (c) Imagination Technologies Ltd." (7 with `@License MIT`); `sgx_context.c` carries Brian
Paul's Mesa MIT header. None mentions the GPL or TI terms, and the licence lines are identical between
the two commits. The frontend only `dlopen`s `libpvr_dri_support.so` at runtime (`sgx_compat.c:43`), so
no TI code is in the built package. The **package** licence is Mesa's mix, as Alpine declares it:
`license="MIT AND SGI-B-2.0 AND BSL-1.0"` (aports `main/mesa/APKBUILD:9`, master, pkgver 26.2.4).

### B.3 A second origin for `84a396a4fb379f10931421e489ac8a199d6a9f2c`

| Origin | State 2026-10-11 | TI-operated? | Carries TI's terms? | abuild-fetchable? |
|---|---|---|---|---|
| `git.ti.com` git (smart HTTP) | **works**: `git ls-remote` lists `84a396a4` on `1.17.4948957/mesa/glibc-2.35`; full clone OK | yes | yes (`LICENSE` in tree) | no (abuild has no git fetch) |
| `git.ti.com` cgit snapshot `…/snapshot/omap5-sgx-ddk-um-linux-84a396a4….tar.gz` | **HTTP 503** (ranged GET); HEAD → 400; the cgit index page answered 200 | yes | yes | yes, when it is up |
| `github.com/TexasInstruments/omap5-sgx-ddk-um-linux` | **does not exist** (404); the org has only `ti-img-rogue-driver`, `ti-img-rogue-umlibs`, `img-vxe-vxd`, `graphics-tests` | — | — | — |
| meta-ti `MIRRORS` (`meta-ti-bsp/conf/layer.conf:44-47` @ `bd0c69b1`): `git://git.ti.com/.* → git://github.com/TexasInstruments/BASENAME` | TI's own sanctioned fallback, which has **no target** for this repo (row above); meta-ti also does not build `ti443x` (`COMPATIBLE_MACHINE = "ti33x\|ti43x\|am57xx\|am65xx"`) | — | — | — |
| `github.com/rcn-ee/ti-omap5-sgx-ddk-um-linux` ("mirror of: http://git.ti.com/gitweb/?p=graphics/omap5-sgx-ddk-um-linux.git", pushed 2025-01-29) | **works**: all 40 branches with TI's head hashes, incl. `84a396a4`. `archive/84a396a4….tar.gz` = 8,208,927 bytes; its `LICENSE` sha256 `37507b46…` and all **11** `targetfs/ti443x_linux/…` files hash to the TI values (§2.1 table, drafts `ti443x.sha256`) | no (rcn-ee.com; no TI statement found) | **yes**: the tree, LICENSE included, is TI's commit | **yes** |
| `github.com/maemo-leste/sgx-ddk-um` archive at `a9dbdc75` | works (the draft's A3 source); `ti443x/` blobs = TI's bytes (§2.2) | no | **no** licence file in the tree (B.1) | yes |
| Maemo `.deb` `sgx-ddk-um-ti443x_1.17.4948957+leste15-1+{4m7,5m7}_armhf.deb` | downloadable (974,008 / 974,412 bytes) but **not usable**: see B.4 | no | no | yes |
| Software Heritage `swh:1:rev:84a396a4fb379f10931421e489ac8a199d6a9f2c` | the API returns the revision (TI's commit message); archived origins include `github.com/davisRoman/omap5-sgx-ddk-um-linux` | no | yes (same tree) | no: tarballs come from the asynchronous "vault", so it is an archival backstop only |

So **no TI-sanctioned second origin exists**, but a byte-faithful one does: the `rcn-ee` mirror
preserves TI's terms because the LICENSE travels inside the commit, and the per-file sha256 make any
origin trustworthy whoever operates it. For M2 (fetch at install) the order is `rcn-ee` archive →
Maemo archive → TI cgit snapshot, all verified per file against `ti443x.sha256`; never the tarball's
own hash (GitHub archives are not promised byte-stable; the one download here had sha512 prefix
`b08058ff…`, recorded, not pinned). For M1 the aport can take the blobs **and** `LICENSE` from the
`rcn-ee` archive; then we no longer carry a hand-copied `LICENSE.TI-TSPA` in our tree.

### B.4 Maemo's binary packages are not "unmodified" and carry no licence

Both Maemo `.deb`s (daedalus `+4m7`, excalibur `+5m7`) hold the blobs under
`usr/lib/arm-linux-gnueabihf/`, and **none of the 10 TI files hashes to TI's value** (e.g. `libsrv_um`
`8aab996f…` vs TI `6bdfe93a…`). Each is 92 bytes shorter; `readelf -SW` shows the `.comment` section
(`GCC: (Ubuntu 11.4.0-1ubuntu1~22.04) 11.4.0`) removed, while `.text`, `.rodata`, `.data`, `.dynsym`
and `.dynamic` are identical (`readelf -x` hashes, `libsrv_um`). Cause: `debian/rules` runs plain `dh`
with no `override_dh_strip`, so `dh_strip` edits the files. The debs' only doc file is
`changelog.Debian.gz`; Maemo's `debian/` has no `copyright`. The `libdbm.so.1.17.4948957` in that deb is
Maemo's open one (imports `drmHash*`, SONAME `libdbm.so.1`), not TI's.

Consequences:
- The deb cannot be a fetch-at-install origin: it fails our per-file pin by construction.
- Maemo is a **distribution** precedent, not a **compliance** precedent: its binary redistribution is
  neither byte-unmodified nor accompanied by the licence. Our design must not lean on it as proof
  that the terms are met.
- Route B (personal first light, drafts "route B" step 2 unpacks the daedalus debs) runs these
  `.comment`-stripped blobs. That is harmless technically, but it means route B is not "TI's bytes".
  If that matters, overlay the 8 files from the TI tree onto the unpacked debs (same paths, pinned
  hashes). Public images must never carry the deb's blobs; B.5 check 2 catches it.

### B.5 What the release preflight must check

For `scripts/release-preflight-no-secrets.sh` (debugfs on the ext4 image, like its existing checks),
keyed on the TI file **names** in the pin list:

1. **Pin list complete.** The list must name all 8 shipped TI files. *The draft's `ti443x.sha256`
   lists 7 and omits `libpvr2d.so.1.17.4948957`, which `_blobs` installs*, so its `prepare()` grep
   loop and the planned preflight both skip it. Add
   `ba924676fabd81a7a0b326cd7d68d58dade7ea8404b2e17c22132a09e6d32fd2  libpvr2d.so.1.17.4948957`
   (measured from the TI clone and the `rcn-ee` archive).
2. **Unmodified.** Every TI name present hashes to its pin. This also rejects Maemo-deb blobs
   (`.comment` stripped) and any `strip`, `patchelf` or `dd` edit.
3. **Licence present.** If any TI name is present, the verbatim `84a396a4:LICENSE` (sha256
   `37507b462edf97b59717d2d144daaac85fbca6080c3602b5128e446e97f9ad47`) is at the licence path. The
   Khronos/SGI notices are inside that file, so one file covers them.
4. **Nothing TI ships that we do not.** No `pvrsrvctl` (`c2adbdf3…`), no `libPVRScopeServices`
   (`b5c6db16…`), and no TI `libdbm` (`c294a827…`); the `libdbm.so.1.17.4948957` present must not
   hash to the TI value (the open one installs under the same name).
5. **M2 public images:** no TI name at all under `/usr/lib/sgx-ddk` or `/var/lib/sgx-ddk`.
6. **Open parts carry their notices.** `sgx-ddk-um-open` ships the LGPL text (dbm has none upstream)
   and MobiAqua's MIT notice for `pvrsrvinit`; `nexusq-sgx-mesa` ships Mesa's licence text (MIT/SGI-B
   notices), since the MIT terms require the notice in copies. Whether Alpine's own Mesa package does
   this was not checked; ours should regardless.
7. **No stock 1.8 blob** (§8): no file whose sha256 matches the stock `/vendor/lib` set
   (`re/km-um-bridge-abi.md` §1 inputs table: stock `libsrv_um` `f177b896…`). This is cheap to add with the others.

Seen failing first, as the draft already says: delete the licence, flip one byte of `libusc`, and
add for this addendum: swap in the Maemo-deb `libsrv_um`, and drop `libpvr2d`'s pin line. All four
must FAIL.

### B.6 For policy question 28

- **Option 1 (redistribute)** is no weaker than before. The text we ship is TI's, the blobs can come
  from an origin that carries it (`rcn-ee`), and the only clause specific to C, "for use only with TI
  Devices", is met by the Q (OMAP4460). The draft must change at adoption: `pvrsrvinit` from
  MobiAqua (MIT) instead of Maemo, `libpvr2d` in the pin list, licence label `LicenseRef-TI-TFL`.
- **Option 2 (fetch at install)** now has two working origins plus an archival one, none run by TI.
  Its advantage stays the same (no TI bytes in our repo); its cost stays first-boot networking.
- Neither option can cite Maemo's binary repo as evidence of compliance (B.4).

### B.7 Corrections made in place (2026-10-11)

1. This note §2.1 file-list caption: "byte-identical in Maemo's leste15 package" → git tree yes, debs no.
2. This note §2.2: Maemo "redistributes unmodified TI blobs" → only its git tree does; the
   `pvrsrvinit.c` bullet now states the missing licence and the pmOS lineage.
3. This note TL;DR 6 and the recommended pairing: `pvrsrvinit` from MobiAqua (MIT).
4. This note §3.4: build MobiAqua's `pvrsrvinit`, not "one of these".
5. This note §8: TI-TFL vs meta-ti's TSPA label; the Maemo precedent qualified; `libdbm` licence version;
   `sgx-ddk-um-open` licence; mesa-sgx package licence; fallback source order (Maemo `.deb` removed,
   `rcn-ee` added); pointer to B.5. Open question 9 answered.
6. `docs/2026-10-11-gpu-sgx540-groundwork.md`: TL;DR 3 ("byte-identical" blobs → git tree only);
   stack diagram (`pvrsrvinit (MobiAqua, MIT)`); §6 table (mesa-sgx row, `libdbm` and `pvrsrvinit`
   split, TI row label); option 1 precedent, option 2 origin and second origin; the preflight sentence
   points at B.5.
7. `docs/gpu-sgx540/reverse-engineering.md`: blob-drop paragraph (git tree, not debs); §11 drop B's
   licence now read; §11 table row on the open glue.
8. `docs/gpu-sgx540/re/blob-abi.md` open question 3: the licence texts are now read.

Not edited: `drafts/sgx-ddk-um.APKBUILD.draft` and `drafts/README.md` (drafts are adopted, not
patched by research; their statements are accurate but incomplete; B.6 lists what changes at adoption).

### B.8 Not reproduced / limits

- No statement from Ivaylo Dimitrov, parazyd, Jonathan Bakker or Paweł Kołodziejski was sought. The
  GPL-3.0 inheritance of pmOS's `pvrsrvinit.c` is a reading of the pmaports root `LICENSE`, not of
  the file. Avoiding that file makes the question moot.
- The 2013 TSPA text was read from UTF-16 strings of the `.doc`, not from a rendered document; field
  codes and table layout may have dropped words (the licence body reads continuously).
  `pvr-omap4`'s `license.txt` (drop A) was not re-read.
- Who operates `rcn-ee` and whether TI endorses that mirror: not established (the GitHub owner's
  profile names only `rcn-ee.com`). TI's software-dl/Processor SDK downloads were not searched for a
  `ti443x` tarball; since meta-ti excludes OMAP4, one is unlikely (UNVERIFIED).
- GitHub archive byte-stability over time: one download only.
- The `.comment`-only difference of the Maemo debs was shown section by section for `libsrv_um`; for
  the other 8 libraries and `pvrsrvctl` only the size delta (−92 bytes each) and the absent `.comment`
  (libraries) were checked.
- No legal opinion: whether removing `.comment` is "modification" in the TSPA's sense, and whether
  fetch-at-install changes who redistributes, are questions for a lawyer.
