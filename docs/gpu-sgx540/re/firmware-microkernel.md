# SGX540 RE 5/7: the microkernel (uKernel/EDM) and init-time firmware

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

- **The `0xDEADBEEF` question in [open-driver-feasibility.md](open-driver-feasibility.md)
  (open question 3) is answered here.** A raw-word scan of stock
  `libsrv_init.so` finds no `0xDEADBEEF`, because the placeholder is a 32-bit
  immediate split across a 64-bit USE `limm` instruction (`w0[20:0]`,
  `w1[8:4]`, `w1[17:12]`). Decoding that encoding finds exactly 15 placeholders
  (§1.3), the same scheme as in the 1.9 and 1.17 images.
- `SGX_DEVINITPART2` carries 2072 bytes in the stock 1.8 UM (also measured in
  [stock-android-blobs-libhybris.md](stock-android-blobs-libhybris.md) and
  [km-um-bridge-abi.md](km-um-bridge-abi.md)), 2068 in 1.9@2253347 and 2836 in
  1.17.
- The prior note `docs/2026-06-19-gpu-sgx540-acceleration-research.md` says a
  `sgx540_*.fw` file must ship with the module, and that DDK 1.9.2188537 is the
  canonical OMAP4 userspace. Both statements are wrong (TL;DR 1 and 5 below).

---

Date: 2026-10-11. Scope: where the SGX microkernel lives in each DDK generation, how the
kernel module (KM) receives it, whether it is tied to the core revision, whether it can be
disassembled with public tools, and whether stock partitions hold anything else.
Nothing was built, flashed or committed. No Nexus Q was touched.

Scratch evidence (not in the repo):
`<session scratch>/gpu/re/`
(`stock-fw/` = blobs dumped from the stock `system.raw.img`; `srv_init.annot`,
`srvinit-1.9.annot`, `srvinit-1.17-ti443x.annot` = annotated disassembly; `<session scratch>/gpu/re/tools/*.py` =
the analysis scripts used below, all run with `python3 -I` from outside the download dirs).

---

## TL;DR

1. **There is no SGX firmware file.** No KM generation loads one: the 1.8.869593, 1.9.2188537,
   1.9.2253347 and 1.17.4948957 openpvrsgx trees contain zero `request_firmware` calls. The
   prior note's statement (2026-06-19, §6) that "`sgx540_*.fw` must ship alongside the module"
   is **wrong** and should be dropped.
2. **The microkernel is closed userspace data inside `libsrv_init.so`.** It is four USE (USSE)
   programs ("SGX ukernel", "SGX TA", "SGX SPM", "SGX 3D") plus five small PDS programs, all in
   `.rodata`. `pvrsrvinit` (or `pvrsrvctl --start` on 1.17) calls `SrvInit()`, which allocates
   SGX device memory through the normal bridge, `memcpy`s the programs in, patches 15
   `limm 0xDEADBEEF` placeholders with device addresses, and builds register-write scripts.
   The KM then receives **only meminfo handles and scripts** in `SGX_BRIDGE_INIT_INFO`
   (`PVRSRV_BRIDGE_SGX_DEVINITPART2`). It never sees or validates the code bytes.
3. **The stock layout is fully mapped.** In the Nexus Q stock `libsrv_init.so` (sha256
   `c4dee422…`), rodata 0x2074–0x1ad6c is exactly ukernel 24 800 B + TA 23 104 B + SPM 21 408 B +
   3D 31 088 B + PDS 44/76/44/880/180 B, followed directly by the strings.
4. **Each uKernel carries its own identity, which the KM checks at init** (`SGXDevInitCompatCheck`
   via `SGXMKIF_CMD_GETMISCINFO`; *[verification 2026-10-11: the 1.8 and 1.9 KMs check the uKernel's
   DDK build; the 1.17 KM does not, it checks the UM's DDK build over a separate bridge call instead,
   see §2.6]*). I decoded the stamps from the USE immediates:

   | uKernel source | DDK build | CoreIdSW | CoreRevSW | build options |
   |---|---|---|---|---|
   | stock Nexus Q (IAN67K) | **785978** (1.8 branch 18) | 540 | 0x10200 | 0x0036801c |
   | maemo-leste pvr-omap4 (`libsrv_init.so.1.9.6.0`) | **2253347** (1.9 branch 19) | 540 | 0x10200 | 0x00068018 |
   | TI 1.17 `ti443x` (`libsrv_init.so.1.17.4948957`) | **4948957** (1.17) | 540 | 0x10200 | 0x00360018 |

   The stock KM in `vmlinux.bin` reports `sgxddk 18 1.8@785978` (file offset 0x678738), so the
   stock pair is a perfect match.
   *[Verification 2026-10-11]* The whole stock SGX userspace (`libsrv_init.so`, `libsrv_um.so`,
   GLES/EGL, `libusc.so`, `pvrsrvinit`, `gralloc.omap4.so`, ...) is **byte-identical** to Google's
   Galaxy Nexus "imgtec maguro" binary drops IML74K and IMM76D (same sha256, for example
   `libsrv_init.so` c4dee422…). The Panda 2012-04-30 drop has a different `libsrv_init.so` but the
   same 785978 / 0x36801c stamps. The GPL source of the matching **1.8@785978 KM is public**:
   AOSP `kernel/omap` branch `android-omap-steelhead-3.0-ics-aah` (HEAD 03a9286b…),
   `drivers/gpu/pvr/pvrversion.h` = MAJ 1 / MIN 8 / BRANCH 18 / BUILD 785978.
5. **KM/UM pairing consequences:**
   - The Maemo pvr-omap4 blobs are DDK **1.9@2253347**, *not* 1.9@2188537. Use them only with
     `letux/pvrsrvkm-1.9.2253347`. That branch (TI "1.9.11", d05540a4) ships no top-level
     Makefile, so the build glue still has to be written.
   - TI 1.17 `ti443x` matches `letux/pvrsrvkm-1.17.4948957`. Its default omap flags compose to
     exactly 0x360018 (`SGX_BUILD_OPTIONS`), and the module is built per rev as
     `pvrsrvkm_omap4_sgx540_120`.
6. **Rev-specific? Yes, by design.** The KM fails init (`PVRSRV_ERROR_BUILD_MISMATCH`) unless
   HW `EUR_CR_CORE_REVISION` equals the uKernel's CoreRevSW. The only exceptions are
   CoreRevSW = 0 (HEAD builds) and the pair 0x10100/0x10101. All three OMAP4 uKernels above are
   rev 1.2.0 (0x10200). A userspace from another SGX540 SoC only works if its uKernel says
   0x10200 *and* the DDK build/options match the KM. For example, jz4780 is SGX540 rev 130
   (`jz4780_linux/Makefile:70`) and runs on a MIPS CPU, so it is out.
7. **The microkernel cannot be disassembled with a public open tool.** No open USSE1
   disassembler or encoding spec exists. Garnet/sgx540-reversing (Codeberg, c1588475,
   2022-10-16) disassembles by `LD_PRELOAD`-hijacking Imagination's own closed x86
   `GLSLESCompiler_Series5`. It lists "Reverse engineer PDS" and "Reverse engineer the
   microkernel" as not done. What we *can* do is decode individual fields, as shown in §4.
   *[Verification 2026-10-11: the same repo does ship a small open, partial **assembler**
   (`hook-postmarket/asm.c` + `asm.h`) whose long-immediate constants match the srvinit patch
   encoding exactly; see §4.]*
8. **No other partition is involved.** Stock `boot.img` only `chmod 0666 /dev/pvrsrvkm` and
   starts `service pvrsrvinit /vendor/bin/pvrsrvinit`. Recovery, bootloader and xloader hold no
   SGX content. `reverse-eng/factory/partitions/` contains only `p8-recovery` (stock recovery)
   and `p9-boot` (our own mainline boot image).

---

## 1. Stock Android (DDK 1.8@785978): where the uKernel lives

### 1.1 Files (from `factory/tungsten-ian67k/system.raw.img`, `debugfs dump`)

| path | size | sha256 (first 16) | role |
|---|---|---|---|
| `/vendor/bin/pvrsrvinit` | 5 432 | 0e22700666cf4021 | tiny: `main` → `SrvInit()`; strings `main: SrvInit failed (%d)` |
| `/vendor/lib/libsrv_init.so` | 115 708 | c4dee422fb9c3364 | **contains the uKernel + PDS programs** |
| `/vendor/lib/libsrv_um.so` | 190 204 | f177b896e7b37e6a | services UM; holds DDK build 785978 as a constant at 0x9fcc |
| `/vendor/lib/libusc.so` | 898 564 | f94c73b7206ec306 | shader compiler; has `"tools/intern/useasm/useasm.c"` (a string inside the blob) at 0xcec40 |
| `/vendor/lib/libglslcompiler.so` | 253 264 | bd921d395704180e | GLSL front end; 785978 at 0x77d0 |
| `/vendor/lib/egl/lib{EGL,GLESv1_CM,GLESv2}_POWERVR_SGX540_120.so` | 5 140 / 446 184 / 372 324 | — | GLES; GLESv2 has 785978 at 0x9c78 |
| `/vendor/firmware/*` | — | — | bcm4330, ducati-m3, bcmdhd, pn544, sledadk, smc_pa — **no SGX file** |

`libsrv_init.so` (ARM, GCC 4.4.3, stripped). Sections: `.text` 0x650 + 0x1a24 (6.7 KB of code),
`.rodata` 0x2074 + 0x194a8 (103 KB). Exports only `SrvInit` (0x1e60, 532 B). Imports only
`PVRSRV*`/`SGX*` functions from `libsrv_um.so`: `PVRSRVAllocDeviceMem`, `PVRSRVMemCopy`,
`PVRSRVMemSet`, `SGXGetInfoForSrvInit`, `SGXDevInitPart2`, `PVRSRVInitSrvConnect/Disconnect`,
`PVRSRVEnumerateDevices`, `PVRSRVAcquireDeviceData`, AppHint and UserModeMem helpers. It imports
nothing from libc.

### 1.2 The rodata map, recovered from the code

Literal-pool PC-relative references were resolved with `<session scratch>/gpu/re/tools/annot.py` (`srv_init.annot`).
The USE loader is fn 0x768: `PVRSRVAllocDeviceMem(dev, heap, flags=9, size, align=0x8000, &mi)`
then `PVRSRVMemCopy(mi->pvLinAddr, src, size)`. Call sites:

| program | name string | src (file off) | size | call site | meminfo saved at |
|---|---|---|---|---|---|
| uKernel main | "SGX ukernel" (0x1b03b) | 0x2074 | 0x60e0 = 24 800 | 0xf9c (size `movw 0x60e0` @0xf8c) | init+0x68 |
| TA | "SGX TA" (0x1b047) | 0x8154 | 0x5a40 = 23 104 | 0xfd8 | init+0x6c |
| SPM | "SGX SPM" (0x1b04e) | 0xdb94 | 0x53a0 = 21 408 | 0x1018 | init+0x70 |
| 3D | "SGX 3D" (0x1b056) | 0x12f34 | 0x7970 = 31 088 | 0x1058 | init+0x74 |
| PDS primary 1 (uKernel init) | — | 0x1a8a4 | 0x2c = 44 | alloc 0x1098, copy 0x10e4 | init+0x78 |
| PDS secondary (uKernel init) | — | 0x1a8d0 | 0x4c = 76 | 0x1134 / 0x117c | init+0x7c |
| PDS primary 2 (uKernel init) | — | 0x1a91c | 0x2c = 44 | 0x11e0 / 0x1220 | init+0x80 |
| PDS "EDM other events" | — | 0x1a948 | 0x370 = 880 | 0x127c / 0x12c8 | init+0x84 |
| PDS "uKernel loopback events" | — | 0x1acb8 | 0xb4 = 180 | 0x1440 / 0x1484 | init+0x88 |

The regions are contiguous: 0x2074 + 0x60e0 = 0x8154, and so on up to 0x1acb8 + 0xb4 = 0x1ad6c,
where the strings begin ("SetupuKernel : Failed to allocate %s."). 0x1a014, the base register
used for the PDS copies, is a GCC section anchor inside the 3D image, not a separate table. Sum:
100 400 B USE + 1 224 B PDS = 101 624 B = 0x1ad6c − 0x2074. **Nothing else is in rodata.**

All USE programs go into one heap (`[sp+56]->hDevMemHeap`, heap type index 2 of the 32-entry
`SGX_BRIDGE_INFO_FOR_SRVINIT.asHeapInfo` returned by `SGXGetInfoForSrvInit`; the entries are
24 B, the type is decoded at 0x920–0x988). The PDS programs are in the same heap with 16-byte
alignment.

### 1.3 Patch-ups (relocations) done by srvinit

fn 0x650 writes a 32-bit value into a 64-bit USE `limm`-type instruction word:

```
w0[20:0]  = v[20:0]
w1[8:4]   = v[25:21]
w1[17:12] = v[31:26]
```

(`bic r2,r1,#0xff000000; bic r2,r2,#0xe00000` … `lsr r4,r1,#26` / `lsr r1,r1,#17; and #0x1f0`
… @0x650–0x694.) It is called on 15 sites (0x1518–0x1688). **Every patched site holds the
placeholder `limm 0xDEADBEEF` in the shipped image** (`<session scratch>/gpu/re/tools/patchpts.py`):

| image | placeholder offsets (image-relative) |
|---|---|
| ukernel | 0x1430, 0x1440, 0x1448, 0x1480, 0x1490, 0x14e0, 0x14f0, 0x4d58, 0x4d70 |
| TA | 0x46b8, 0x46d0 |
| SPM | 0x4018, 0x4030 |
| 3D | 0x65e8, 0x6600 |

The patched values are encodings such as `0x03000900`, `0x01801000`, `0x01000900`,
`((devVAddr − PDS_EXEC_BASE) >> 4) | 0x01000000`, the kernel-CCB devVAddr and `9`. In other
words, the PDS/USE cross-references only become known after device allocation. This
independently confirms the sgx540-reversing note that "patch points … are marked by the
constant 0xDEADBEEF … written to by pvrsrvinit".

fn 0x800 (`rsb r2,r2,r1 … and 0x7ff00`) builds a PDS-format address word from
(devVAddr − heap base). It is used when filling the PDS programs.

### 1.4 Init script (what the KM actually executes)

srvinit fills `SGX_INIT_COMMAND {eOp, ui32Offset, ui32Value}` (12 B; eOp 1 =
`SGX_INIT_OP_WRITE_HW_REG`, eOp 2 = `SGX_INIT_OP_HALT` in a non-PDUMP build, per `sgxscript.h`)
into its init block (Part-1 entries at init+0x3e8, limit 64 = `SGX_MAX_INIT_COMMANDS`, error
string "Increase SGX_MAX_INIT_COMMANDS"). The registers written include:

| reg | name (`sgx540defs.h`; *[verification: all four trees define these, e.g. 1.8 `EUR_CR_USE_CODE_BASE(X)` at line 538, `EUR_CR_PDS_EXEC_BASE` 430, `EUR_CR_EVENT_KICKER` 436]*) | value written |
|---|---|---|
| 0x0A0C–0x0A30 | `EUR_CR_USE_CODE_BASE(0..9)` | heap[4].base >> 8, step 0x80000 per entry, DM=1 (`0x1000000`) |
| 0x0A34–0x0A40 | `EUR_CR_USE_CODE_BASE(10..13)` | heap[5].base >> 8, step 0x80000 |
| **0x0A48** | **`EUR_CR_USE_CODE_BASE(15)`** = `SGX_KERNEL_USE_CODE_BASE_INDEX` 15 (`sgxinfo.h:340`) | heap[2].base >> 8, DM=3 (EDM) — **this points the EDM at the uKernel heap** |
| **0x0AB8** | **`EUR_CR_PDS_EXEC_BASE`** | init+0xb8 (heap[6] base, the PDS heap) |
| 0x0AC4 | `EUR_CR_EVENT_KICKER` | kernel-CCB event kicker devVAddr |
| 0x0130 / 0x0110 | `EUR_CR_EVENT_HOST_ENABLE` / `…ENABLE2` | 0 (DeInit) |
| 0x0A58, 0x0A68, 0x0A6C, 0x0A70, 0x0A74, 0x0A78, 0x0A7C, 0x0A80, 0x0ABC, 0x0B30, 0x0804, 0x0A00, 0x013C, 0x04E8 | **not named in any public KM header** (UNVERIFIED names; probably EVENT_PDS / DMS / timer registers) | e.g. 0x2204F00F → 0xA58, 0x13C01 → 0xA70, 0x208200 → 0xA74, 0x7C000 → 0xA00, 0xFFFF → 0x804 |

Hard-coded `SGX_BRIDGE_INIT_INFO` values set at 0x9c0–0xa84 include `ui32ClientBuildOptions =
0x0036801c` (init+0x20), clock-gating constants `0xaaa6a` / `0x2aaaaa` / `0xffeffff7`, and the
EDM task register offsets. srvinit's private init block is 0x7a8 = 1 960 B (alloc @0x98c). This
is *not* `sizeof(SGX_BRIDGE_INIT_INFO)`: `libsrv_um!SGXDevInitPart2` converts it to the bridge
struct (UNVERIFIED exact mapping; the libsrv_um side was not traced).

---

## 2. How the KM receives it (source-verified)

Sources: `openpvrsgx-devgroup/linux_openpvrsgx` branches `letux/pvrsrvkm-1.8.869593` @214f07dd,
`-1.9.2188537` @e4e33215, `-1.9.2253347` @d05540a4, `-1.17.4948957` @584dd33a.

1. **Init-server gating.** `PVRSRVInitSrvConnectBW` (`bridged_pvr_bridge.c`) requires
   `OSProcHasPrivSrvInit()` = `capable(CAP_SYS_MODULE)` (`osfunc.c:2260`, 1.8; `:3343`, 1.17).
   It also requires that the init server is neither RUNNING nor RAN, so it can run **once per
   KM load**. `InitSrvDisconnect` sets RAN and calls `PVRSRVFinaliseSystem`.
2. `PVRSRV_BRIDGE_SGXINFO_FOR_SRVINIT` → `SGXGetInfoForSrvinitKM` (stock `vmlinux` 0xc02939b0)
   returns `sPDDevPAddr` plus `asHeapInfo[PVRSRV_MAX_CLIENT_HEAPS]` (`sgxinfo.h:43-47`, 1.8).
3. Userspace allocates and fills device memory with the normal `ALLOC_DEVICEMEM` bridge.
4. `PVRSRV_BRIDGE_SGX_DEVINITPART2` → `DevInitSGXPart2KM` (stock 0xc0293a04) → `InitDevInfo()`.
   That function copies handles (`hKernelCCBMemInfo`, `hKernelCCBCtlMemInfo`,
   `hKernelCCBEventKickerMemInfo`, `hKernelSGXHostCtlMemInfo`, `hKernelSGXTA3DCtlMemInfo`,
   `hKernelSGXMiscMemInfo`, `hKernelHWPerfCBMemInfo`, TA/3D signature buffers, optional
   `hKernelEDMStatusBufferMemInfo`), `aui32HostKickAddr[11]`, `sScripts`,
   `ui32ClientBuildOptions`, `sSGXStructSizes`, `ui32EDMTaskReg0/1`, clock-gate registers and
   masks, `ui32CacheControl`, `asInitDevData[24]` and **`asInitMemHandles[18]`**
   (`sgxinfo.h:70-199`, 1.8). The uKernel/PDS meminfos are among these generic handles: the KM
   keeps references so it can free them, and never reads the bytes. Misleadingly, the KM's error
   string for an `InitDevInfo` failure is "DevInitSGXPart2KM: Failed to load EDM program"
   (`sgxinit.c:745`, 1.8), but no loading happens.
5. `SGXInitialise()` (stock 0xc0294048) runs `SGXRunScript(Part1)`, resets, runs Part2, sets
   `HostCtl->ui32InitStatus = 0`, kicks `EUR_CR_EVENT_KICK` (or `KICK2` with
   `SGX_FEATURE_MULTI_EVENT_KICK`, which the 1.17 headers define for SGX540), then polls for
   `PVRSRV_USSE_EDM_INIT_COMPLETE` ("Wait for uKernel initialisation failed" on timeout)
   (`sgxinit.c:380-545`, 1.8). `SGXPostPowerState` / HW recovery re-run `SGXInitialise`; the code
   stays resident in SGX-mapped RAM, so no reload is ever needed.
6. `SGXDevInitCompatCheck` (stock 0xc0292f1c; `sgxinit.c:1967+`, 1.8) checks, in order:
   - client build options == KM `SGX_BUILD_OPTIONS`;
   - **uKernel** `ui32DDKVersion == (MAJ<<16 | MIN<<8 | BRANCH)` and `ui32DDKBuild ==
     PVRVERSION_BUILD`;
   - HW `ui32CoreRev == ui32CoreRevSW` (skipped if CoreRevSW == 0, plus exception {0x10100,
     0x10101});
   - 13 SGXMKIF struct sizes reported by the uKernel equal the KM's sizes;
   - **uKernel** build options == KM `SGX_BUILD_OPTIONS`.

   All values except the first come from the uKernel via `SGXMKIF_CMD_GETMISCINFO` into
   `PVRSRV_SGX_MISCINFO_FEATURES {CoreRev, CoreID, DDKVersion, DDKBuild, CoreIdSW, CoreRevSW,
   BuildOptions, …}` (`sgxapi_km.h:248-264`, 1.8). `IGNORE_SGX_INIT_COMPATIBILITY_CHECK` turns
   the failures into warnings.

   *[Verification 2026-10-11, corrections]*
   - The **first** check (client build options) compares the KM against
     `ui32ClientBuildOptions`, which **srvinit** puts in `SGX_BRIDGE_INIT_INFO` (stock: literal
     0x0036801c at libsrv_init 0x1774, loaded at 0x9c8). That is a userspace constant, not a
     uKernel report.
   - The 13 struct sizes are 15 `CHECK_SIZE` lines minus `2DCMD`/`2DCMD_SHARED`, which sit under
     `#if defined(SGX_FEATURE_2D_HARDWARE)` (1.8 sgxinit.c:2107-2110). SGX540 does not have that
     feature.
   - **1.17 differs.** `SGXDevInitCompatCheck` in 1.17.4948957 (sgxinit.c:2672+) checks client
     options, CoreRev, struct sizes and uKernel options, but **not** the uKernel's DDKVersion or
     DDKBuild. The DDK check moved to `PVRSRVCompatCheckKM` (common/pvrsrv.c:173-188, bridge
     dispatch at bridged_pvr_bridge.c:4987). That function compares the **UM-supplied**
     `ui32DDKVersion == MAJ<<16|MIN<<8` and `ui32DDKBuild == 4948957`. The 1.9.2188537 and
     1.9.2253347 KMs still check the uKernel's DDK build (sgxinit.c:2545 and :2546).

Bridge indices (`_IOWR('g', idx, PVRSRV_BRIDGE_PACKAGE)` on the legacy char device; DRM builds
wrap them in `PVR_DRM_SRVKM_CMD`). They were evaluated by `<session scratch>/gpu/re/tools/bridgeidx2.py` from the headers
with config `__linux__, TRANSFER_QUEUE, SUPPORT_MEMINFO_IDS` and no PDUMP/ION/SID/overlay/2D-HW.
**They depend on the build configuration, so verify before use:**

| command | 1.8.869593 | 1.9.2253347 | 1.17.4948957 |
|---|---|---|---|
| CONNECT_SERVICES | 12 | 12 | 13 |
| ALLOC_DEVICEMEM | 6 | 6 | 7 |
| INITSRV_CONNECT / DISCONNECT | 78 / 79 | 72 / 73 | 69 / 70 |
| SGX_GETMISCINFO | 108 | 102 | 99 |
| SGXINFO_FOR_SRVINIT (`SGX_CMD_BASE+15`) | 109 | 103 | 100 |
| SGX_DEVINITPART2 (`SGX_CMD_BASE+16`) | 110 | 104 | 101 |

*[Verification 2026-10-11]* I recomputed the table independently (`gcc -E` over the headers, run
from scratch, then expression evaluation). It reproduces exactly for the stated config, and
`SUPPORT_MEMINFO_IDS` has no effect on these seven. Two corrections:

| command | **stock 1.8@785978 KM** (Nexus Q `vmlinux`, measured) | letux 1.17 **as its Makefile builds it** (`-DSUPPORT_DMABUF`, eurasia_km/Makefile:243) | +PDUMP (1.8 / 1.9 / 1.17) | +SUPPORT_ION (1.9 / 1.17) |
|---|---|---|---|---|
| CONNECT_SERVICES | 12 | 13 | 12 / 12 / 13 | 12 / 13 |
| ALLOC_DEVICEMEM | 6 | 7 | 6 / 6 / 7 | 6 / 7 |
| INITSRV_CONNECT / DISCONNECT | **69 / 70** | 71 / 72 | 97 / 91 / 88 (+1) | 74 / 71 (+1) |
| SGX_GETMISCINFO | **99** | 101 | 127 / 121 / 118 | 104 / 101 |
| SGXINFO_FOR_SRVINIT | **100** | 102 | 128 / 122 / 119 | 105 / 102 |
| SGX_DEVINITPART2 | **101** | 103 | 129 / 123 / 120 | 106 / 103 |

Stock evidence: `SetSGXDispatchTableEntry` (c0292afc) calls `_SetDispatchTableEntry` (c028d6e0)
with `mov r0,#101` at c0292c60, handler `SGXDevInitPart2BW` (c0292474), name string
"PVRSRV_BRIDGE_SGX_DEVINITPART2" at c068aefc; #100 = "PVRSRV_BRIDGE_SGXINFO_FOR_SRVINIT" at
c068aec0. The core table (`re/stock-dispatch.tsv`) gives 6 = ALLOC_DEVICEMEM, 12 =
CONNECT_SERVICES, 69/70 = INITSRV_CONNECT/DISCONNECT. **So the "1.8" column above is the letux
869593 header set and does not describe the stock 785978 KM.** The 785978 core bridge enum has 9
fewer entries before INITSRV than 869593.

Script limits: `SGX_MAX_INIT_COMMANDS` 64, `SGX_MAX_DEINIT_COMMANDS` 16 in all versions. 1.17
adds `SGX_MAX_PRINT_COMMANDS` 64 and debug-script arrays to `SGX_INIT_SCRIPTS`
(`sgxscript.h:51-97`, 1.17). *[Verification: the array count is not "two" on SGX540.
`asSGXREGDebugCommandsMaster` exists only `#if defined(SGX_FEATURE_MP)`, so a non-MP SGX540 build
adds one array, `asSGXREGDebugCommandsSlave[64]` (+768 B). 1.17 also inserts
`SGX_INIT_OP_READ_HW_REG` and `SGX_INIT_OP_PRINT_HW_REG` into the enum, so `SGX_INIT_OP_HALT` is
2 in 1.8 but 4 in 1.17 (non-PDUMP). A 1.8-format script would be misread by a 1.17 KM.]* The bridge
struct therefore differs between DDKs: an ABI break, in addition to the version checks.

---

## 3. DDK 1.9 and 1.17 userspace: same architecture

| | stock 1.8 | pvr-omap4 1.9.6.0 | TI 1.17 `ti443x` |
|---|---|---|---|
| file | `/vendor/lib/libsrv_init.so` (bionic) | `usr/lib/arm-linux-gnueabihf/libsrv_init.so.1.9.6.0` (glibc, Thumb-2) | `targetfs/ti443x/lib/libsrv_init.so.1.17.4948957` (glibc, Thumb-2) |
| sha256 | c4dee422… | 0865dfe3… | 3a140250… |
| launcher | `pvrsrvinit` | `pvrsrvinit` (src `services4/srvinit/env/linux/pvrsrvinit.c`) | `pvrsrvctl --start [--no-module]` (dlinks `libsrv_init.so.1`) |
| ukernel src/size | 0x2074 / 24 800 | 0x1890 / 20 224 | 0x121e0 / 22 112 |
| TA | 0x8154 / 23 104 | 0x6790 / 18 848 | 0xccf8 / 21 744 |
| SPM | 0xdb94 / 21 408 | 0xb130 / 17 504 | 0x84d0 / 18 480 |
| 3D | 0x12f34 / 31 088 | 0xf590 / 21 984 | 0x2858 / 23 680 (declared size runs 8 B into SPM; UNVERIFIED why) |
| PDS | 44/76/44/880/180 | 44/76/44/880/180 @0x14b70+ | one combined pre-allocation ("Failed to pre-allocate memory for EDM PDS programs"); not traced |
| USE alignment | 0x8000 | 0x8000 | 0x8000, enforced ("invalid alignment" check, `ubfx #0,#15` @0x81a) |
| libc imports | none | `__cxa_finalize@GLIBC_2.4` only | `__cxa_finalize@GLIBC_2.4` + TM-clone stubs |

Image hashes (sha256, first 16 hex): 1.8 — ukernel 5849f25c93c4c841, TA 139aa16fafda483f,
SPM 0575237c317f7a6e, 3D b7fb2cd19ef2a05e. 1.9 — 54d1ebf60cd1da79, df829d02d65345b9,
3cbdcd3813f81c8c, 0921ee0f11161595. 1.17 — bb9b249e7efec048, b4738fae1a64f110,
e9d9b4a3961fae7c, 7c20c68721e68171. All twelve differ, so no image is shared between DDKs.

**Version stamps** (`<session scratch>/gpu/re/tools/stamp.py`). The uKernel fills the MiscInfo features with a fixed
"`limm const` → store slot n" sequence (stores `f02a0000:8000_8081 … 8381`):

| slot | field | 1.8 @ file 0x32f4–0x336c | 1.9 @ 0x2e40–0x2eb8 | 1.17 @ 0x13ae8–0x13b58 |
|---|---|---|---|---|
| 1, 2 | CoreRev, CoreID | read from HW | HW | HW |
| 3 | DDKVersion | 0x10000 \| 8<<8 \| 0x12 → 0x10812 (ALU imm fields 8, 0x12) | 0x10000 \| 9<<8 \| 0x13 → 0x10913 | 0x10000 \| 17<<8 → 0x11100 (no branch op) |
| 4 | DDKBuild | **limm 0x0BFE3A = 785978** (0x3324) | **0x226223 = 2253347** (0x2e70) | **0x4B83DD = 4948957** (0x13b10) |
| 5 | CoreIdSW | limm 0x21C = **540** | 540 | 540 |
| 6 | CoreRevSW | 0x10000 \| 2<<8 → **0x10200** | 0x10200 | 0x10200 |
| 7 | BuildOptions | **0x0036801C** | **0x00068018** | **0x00360018** |

The decoding of the two ALU operands (5-bit immediate in bits [19:15] of word 0, shifted by 8,
and an OR with a 7-bit immediate) is my inference from three samples whose expected values are
known from `pvrversion.h`. **UNVERIFIED** as general ISA semantics. The limm values (slots 4, 5,
7) use the encoding that srvinit's own patch function proves.

Cross-checks:
- 1.9 `PVRVERSION_BRANCH 19` (`pvrversion.h`, both 1.9 branches) matches the 0x93 operand.
- The pvr-omap4 `libsrv_um.so.1.9.6.0` holds 2253347 at 0x8554, `libGLESv2.so.1.9.6.0` at
  0x7a7c and `libglslcompiler.so.1.9.6.0` at 0x5afc.
- pvr-omap4 provenance: `fetch-pvr-omap/log.txt` (2013-02-05) fetched
  `sgx-lib_1.9.0.8.1-2glp1_armhf.deb` (Ubuntu/TI "glp" OMAP4 packages).

**Option-bit decode** (`sgx_options.h`):

- 0x36801c = bits 2, 3, 4, 15, 17, 18, 20, 21 = EDM_STATUS_DEBUG, HW_RECOVERY, PVR_SECURE_HANDLES,
  ACTIVE_POWER_MANAGEMENT, PERCONTEXT_PB, SGX_HWPERF, PRIORITY_SCHEDULING, LOW_LATENCY_SCHEDULING.
  This is consistent with stock srvinit allocating "SGX microkernel trace buffer" (MKTraceProfile)
  and "HW Perf Circular Buffer".
- 0x68018 = bits 3, 4, 15, 17, 18. No EDM status debug, no priority/low-latency scheduling.
- 0x360018 = bits 3, 4, 17, 18, 20, 21. ~~1.17 has no ACTIVE_POWER_MANAGEMENT option bit at all.~~
  *[Verification 2026-10-11: wrong. Upstream 1.17 keeps bit 15. The **letux** branch hard-wires
  it off: `include4/sgx_options.h:151` `#define OPTIONS_BIT15 0x0 /* HACK: missing userspace flag
  */`, while its Makefile still passes `-DSUPPORT_ACTIVE_POWER_MANAGEMENT` (eurasia_km/Makefile:132).
  The ti443x uKernel simply was built without bit 15, and letux patched the KM to match it.]*

**KM pairing:**
- **1.17.4948957 letux** `eurasia_km/Makefile` passes `-DSUPPORT_HW_RECOVERY -DPVR_SECURE_HANDLES
  -DSUPPORT_PERCONTEXT_PB -DSUPPORT_SGX_HWPERF -DSUPPORT_SGX_LOW_LATENCY_SCHEDULING`, and
  `sgxfeaturedefs.h:282-283` then implies PRIORITY_SCHEDULING. EDM_STATUS_DEBUG is in `ccflags-n`
  (disabled). That gives exactly **0x360018** = the ti443x uKernel. `MODULE :=
  pvrsrvkm_$(SOC)_$(SGX)_$(SGX_REV)` and `-DSGX_CORE_REV=$(SGX_REV)` (Makefile:25-40); the omap
  SGX540 config is `SGX_CORE_REV := 120` (`omap_linux/Makefile:76-77`).
  *[Verification 2026-10-11: `SOC`, `SGX` and `SGX_REV` are **not assigned anywhere** in the
  branch tree (`git grep` at 584dd33a; `drivers/gpu/drm/Makefile` does not reference pvrsgx).
  `omap_linux/Makefile` belongs to TI's eurasiacon build, not the letux Kbuild. The name
  `pvrsrvkm_omap4_sgx540_120` is therefore an inference, consistent with
  `SYS_SGX_DEV_NAME = "$(SOC_VENDOR),$(SOC)-$(SGX)-$(SGX_REV)"` and the DT compatible
  `"ti,omap4-sgx540-120"` (env/linux/module.c:293). The `-v2` (8cc51a38) and `-v3` (e5de7556)
  variants of this branch were not examined.]*
- **1.9.2188537 letux** `Makefile` sets HW_RECOVERY, SECURE_HANDLES, PERCONTEXT_PB, SGX_HWPERF,
  `SUPPORT_SGX_LOW_LATENCY_SCHEDULING ?=1` and ACTIVE_PM = 1 when `LDM_PLATFORM`
  (lines 60-61, 100-119, 236-243). The result is ≈0x368018 (UNVERIFIED; derived flags not
  enumerated). *[Verification 2026-10-11: enumerated. With `TI_PLATFORM=omap4` and the defaults
  `LDM_PLATFORM ?= 1` (line 67) and `PVRSRV_USSE_EDM_STATUS_DEBUG` commented out (line 286), the flags are
  HW_RECOVERY (bit 3, line 60 → 370/383), SECURE_HANDLES→PVR_SECURE_HANDLES (bit 4, 237 → 386), ACTIVE_PM = 1 (bit 15, lines 108-116 → 371/384), PERCONTEXT_PB (bit 17, 239 →
  302), HWPERF (bit 18, 401) and LOW_LATENCY (bit 21, 243 → 403). LOW_LATENCY implies PRIORITY
  (bit 20, `sgxfeaturedefs.h:266-267`). Sum = **0x368018 exactly** under these defaults. The
  pvr-omap4 uKernel's 0x68018 therefore says it was built with LOW_LATENCY (and hence PRIORITY)
  scheduling off.]* Against the pvr-omap4 uKernel it **fails twice**: DDK build 2188537 ≠ 2253347,
  and options 0x368018 ≠ 0x68018.
- **1.9.2253347 letux** is the version-correct KM for pvr-omap4. Its README says "version 1.9.11
  of the TI DDK … based on IMG's 1.9 DDK post-beta engineering drop (ED2253347)". The branch at
  d05540a4 contains `include4/`, `services4/` and four `Kbuild.mk` fragments, but **no
  top-level Makefile**, so the build glue and option set (target 0x68018) must be written to
  match.
- **1.8.869593 letux** (`blaze_android_sgx_ogles1_ogles2_GPL`, build 869593) does **not** match
  stock 785978 either. Stock blobs would need a 785978 KM, and no letux branch provides one.
  *[Verification 2026-10-11: but a public GPL 785978 KM **does** exist. AOSP
  `https://android.googlesource.com/kernel/omap`, branch `android-omap-steelhead-3.0-ics-aah`
  (`git ls-remote` HEAD 03a9286bb61a9acd28027206c4937990ac817f1b),
  `drivers/gpu/pvr/pvrversion.h`: MAJ 1, MIN 8, BRANCH 18, BUILD 785978 (WebFetch 2026-10-11).
  It is a 3.0-era Android KM, so a 6.18 port is unexplored. The same userspace is also the Galaxy
  Nexus IML74K/IMM76D imgtec drop, byte for byte, so the `android-omap-tuna-3.0*` branches of the
  same repo are a second candidate (UNVERIFIED: their pvrversion.h was not opened). Note that this
  userspace is **bionic and softfp**: stock `libsrv_init.so` has no `Tag_ABI_VFP_args`, unlike the
  hard-float 1.9/1.17 glibc builds.]*

---

## 4. Is the USSE microkernel disassemblable?

- **No open disassembler or encoding spec for USSE1 (Series5) exists** that I could find. Mesa's
  `imagination` driver covers Rogue only (prior note §1).
- **Garnet/sgx540-reversing** (codeberg.org/Garnet/sgx540-reversing, HEAD c15884751ad8,
  2022-10-16, "Added the first pds binary found"). Its `asm/README.md` says disassembly works by
  `LD_PRELOAD` into Imagination's official `GLSLESCompiler_Series5` (PVRShaderEditor download):
  "while imgtech claims to not provide the disassembler for Series5 gpus they just left out any
  calls to it". The checklist leaves "Reverse the instruction encoding fully", "Reverse engineer
  PDS" and "Reverse engineer the microkernel" open. `info/ISA.md` gives a partial model: register
  banks r/o/pa/sa/c/i/g, pclink, drc; `repeat`; predicates; `br`/`ba` with `.savelink`;
  `stad`/`ldad` with drc and `wdf`. That tool is closed, x86, 32-bit, and has unclear licence
  terms. It is usable for analysis, not redistributable.
  *[Verification 2026-10-11, additions]* HEAD c15884751ad870b3e06abd3d8b5a6ab00e2fb3cd confirmed
  by `git ls-remote` (date not re-checked). The README says the repo targets the SGX540 in the
  **Galaxy Tab 2 7.0 P3110**, and its checklist marks "[x] Implement an assembler (partial)". The
  repo ships an open encoder, `hook-postmarket/asm.c` (182 lines, "initial implementation of an
  assembler library for the SGX 540") and `asm.h`. `asm.h:36-40` defines `LONG_IMM_MASK1
  0x1FFFFF`, `LONG_IMM_SHIFT2_1 17` / `MASK2_1 0x1F0` and `LONG_IMM_SHIFT2_2 14` / `MASK2_2
  0x3F000`. That is exactly the srvinit fn 0x650 split, so the encoding in §1.3 is independently
  confirmed. The opcode field is `OP_SHIFT 27` in word 1 with `OP_EXT 31`, consistent with the
  `0xfc2…` top bits. In IMG's own disassembler output (`hook-postmarket/notes`), this form is
  printed as **`mov rN, #imm`**: `0xFC2030C000003004 mov r0, #0x0D803004`, which decodes with our
  formula to 0x0D803004. "limm" is this report's label, not an IMG mnemonic. The stores
  `0xF02A0000_8000xxxx` are `stad.bpcache`. `ukernel/README` already records the DEADBEEF patch
  points, the register script and the PDS-init program. So: a public open *partial assembler*
  exists; a public open *disassembler* does not.
- **Imagination's internal tool names** (evidence): stock `libusc.so` contains
  `"tools/intern/useasm/useasm.c"` (a string inside the blob) at 0xcec40 (an encoder is linked in), but no mnemonic strings.
  A 2012-09-30 powervr-devel post (Christophe Devine) reports `libuseasm.a` "for both assembly
  and disassembly" and SDK binaries `useasm` and `pdsasm`.
- **sgx535-remesa** (local mirror `re-downloads/sgx535-remesa-acc60f5ff157`; project started
  2026-09-16 per its README; Poulsbo SGX535, first triangle 2026-10-06). Its `SGX535-reMESA:docs/usse.md`
  records "No source for assembler/disassembler USSE, full opcode description … was found". It
  is a hardware-RE effort on SGX535 and does not cover the microkernel.
  *[Verification: the mirror stores the files flattened (`docs_usse.md:21`,
  `docs_phase7_7.5-firmware-microkernel.md`). The quoted sentence ends "… was found **in the two
  TI trees**", so its scope is those two trees only, not a general search.]*
- **What we derived ourselves** (verified by srvinit's own patch code and by 15 placeholder
  hits): instructions are 64-bit; `limm` has word1[31:20] = 0xfc2 (dest-reg fields vary) and
  carries its 32-bit immediate split as `w0[20:0] | w1[8:4]<<21 | w1[17:12]<<26`. Memory stores
  in the MiscInfo writer look like `f02a0000:8000_8x81`. That is enough to find constants,
  patch points and version stamps, but not to read control flow.

Conclusion: we cannot modify or re-target the uKernel; we can only pick a matching closed
userspace. Patching the four version/option immediates to fake a match is technically possible
(the KM checks only the reported values). It would hide genuine SGXMKIF ABI differences between
DDK builds, though, so it is not a fix (UNVERIFIED that any such pair would run).

---

## 5. Is it core-revision specific? Could non-OMAP4 userspace work?

- **Yes, it is rev-specific.** The DDK compiles uKernel and KM per `SGX_CORE_REV`; errata differ
  per rev (SGX540 rev 120 → `FIX_HW_BRN_26620/28011/34028`, `sgxerrata.h:198-201`, 1.8). The
  uKernel self-reports CoreRevSW 0x10200, and the KM rejects a mismatch with the HW revision
  register.
- All three OMAP4 userspaces examined report 540 / 0x10200. The Nexus Q's actual
  `EUR_CR_CORE_REVISION` value is **not yet read from hardware** (UNVERIFIED; the prior note says
  rev 1.2.0).
- A non-OMAP4 SGX540 userspace (Samsung, Ingenic, etc.) needs all of: the same rev 0x10200; a KM
  of the same DDK build with the same `SGX_BUILD_OPTIONS`; the same SGXMKIF struct sizes; and a
  compatible ARM ABI/libc. jz4780 is rev 130 on MIPS. **Practically, only TI OMAP4 userspace
  (1.8 Android, 1.9@2253347, 1.17 ti443x) fits**, each with its own KM branch.
- The uKernel does not depend on the CPU side. srvinit imports no libc (only `__cxa_finalize`),
  so the musl question concerns `libsrv_um`, the GLES libraries and `pvrsrvinit`/`pvrsrvctl`,
  not the microkernel.
  *[Verification 2026-10-11, qualification]* This holds at the symbol level only. `libsrv_init` is
  still an ELF that the dynamic loader must accept:
  - stock: `DT_NEEDED` libc.so, libdl.so, libcutils.so, libsrv_um.so (bionic sonames), softfp
    (no `Tag_ABI_VFP_args`);
  - 1.9: `DT_NEEDED` libsrv_um.so + **libc.so.6**, `Tag_ABI_VFP_args: VFP registers` (hard-float),
    imports `__cxa_finalize@GLIBC_2.4`, `__gmon_start__`, `_Jv_RegisterClasses` (weak);
  - 1.17: `DT_NEEDED` libsrv_um.so.1 + libc.so.6, e_flags 0x5000400 "hard-float ABI".

  So it adds the same soname / float-ABI constraints as the other blobs, but no libc behaviour
  constraint. Whether musl's loader accepts the `GLIBC_2.4` version reference without gcompat is
  UNVERIFIED here. The uKernel *bytes* could also be extracted and loaded by our own srvinit
  replacement, which would remove the ELF entirely (UNVERIFIED feasibility; the unnamed registers
  in §1.4 would have to be reproduced).

---

## 6. Other stock partitions

- `reverse-eng/factory/partitions/` (listing only): `p8-recovery-2026-08-18.img.gz` and
  `p9-boot-2026-08-18.img.gz`.
  - p9 parses (`<session scratch>/gpu/re/tools/bootimg.py`) as **our mainline** boot image: kernel 5 543 872 B, no
    ramdisk, cmdline `… root=/dev/mmcblk0p13 rootwait … video=HDMI-A-1:1280x720@60`.
  - p8 is a stock-style recovery: 38 ramdisk entries, none SGX-related.
- Factory zip `image-tungsten-ian67k.zip`: boot, recovery, system, userdata, android-info.
- `bootloader-phantasm-steelheadb4h0j.img` and `xloader-phantasm-ian67k.img`: 0 strings matching
  sgx/pvr/gpu/ukernel. Not modified, only read.
- Stock `boot.img` ramdisk `init.steelhead.rc`: line 32 `chmod 0666 /dev/pvrsrvkm` (on boot);
  lines 89-92 `service pvrsrvinit /vendor/bin/pvrsrvinit` / `class core` / `user root` /
  `group root`. Running as root satisfies the KM's `CAP_SYS_MODULE` check.
- The KM is built into the stock kernel (`drivers/gpu/pvr/…`, module params
  `pvrsrvkm.sgx_idle_timeout` etc. at vmlinux 0x57a17c).

---

## Open questions

1. Read the real `EUR_CR_CORE_REVISION` (SGX register 0x24) on our hardware once the GPU domain
   is powered under mainline. That confirms 0x10200 against all three uKernels.
2. Names and semantics of the unnamed registers that srvinit writes (0xA58, 0xA68–0xA80, 0xABC,
   0xB30, 0x804, 0xA00, 0x13C, 0x4E8). They are only needed if we ever replace srvinit.
3. Exact `SGX_BRIDGE_INIT_INFO` byte layout per DDK and config (for example, is
   `hKernelSGXPTLAWriteBackMemInfo` present for rev 120?). `libsrv_um!SGXDevInitPart2` was not
   traced.
4. Bridge indices in §2 depend on build flags (PDUMP, SUPPORT_MEMINFO_IDS, ION, DMABUF, SID).
   Confirm against the actual KM config chosen.
5. The 1.17 ti443x 3D image's declared size overlaps SPM by 8 bytes (`0x2858+0x5c80 = 0x84d8 >
   0x84d0`). Is that harmless padding? Also, 1.17 PDS program generation was not traced.
6. ~~Does any Galaxy Nexus or other OMAP4 1.8 build carry uKernel 785978, which would match the
   stock KM? Does a public 785978 KM source exist? Neither was searched.~~ *Answered in
   verification: yes to both. Galaxy Nexus IML74K/IMM76D imgtec drops are byte-identical to
   stock; Panda 2012-04-30 carries the same stamps; AOSP kernel/omap
   `android-omap-steelhead-3.0-ics-aah` has the GPL 1.8@785978 KM. The later drops carry newer
   DDK builds (DDK branch not decoded, so UNVERIFIED whether they are still 1.8): JRO03H and Panda 2013-06-03 are 905891, JDQ39 and JWR66Y are
   2198402, all with options 0x36801c and CoreIdSW 540.*
7. Licence and redistribution status of `GLSLESCompiler_Series5` for a hijacked-disassembler
   workflow (sgx540-reversing approach).
8. Whether the TI 1.9.2253347 KM builds on 6.18 with self-written Kbuild glue and options
   matching 0x68018 (untested).

## Sources

Local (gitignored / scratch, read-only):
- `reverse-eng/factory/tungsten-ian67k/system.raw.img`: `/vendor/bin/pvrsrvinit`,
  `/vendor/lib/libsrv_init.so`, `libsrv_um.so`, `libusc.so`, `libglslcompiler.so`, egl/*, via
  `debugfs -R dump`; `/build.prop` (IAN67K, 4.0.4, 2012-07-13).
- `reverse-eng/vmlinux.bin` (strings @0x678738 `CustomerGoogle_Android_ogles1_ogles2_GPL sgxddk
  18 1.8@785978`) and `reverse-eng/tools/kallsyms.txt` (`SGXDevInitCompatCheck` c0292f1c,
  `SGXRunScript` c0293828, `SGXGetInfoForSrvinitKM` c02939b0, `DevInitSGXPart2KM` c0293a04,
  `SGXInitialise` c0294048).
- `reverse-eng/factory/tungsten-ian67k/boot.img` (`init.steelhead.rc`),
  `image-tungsten-ian67k.zip`, bootloader/xloader images; `reverse-eng/factory/partitions/`.
- `<session scratch>/gpu/re-downloads/pvr-omap4-git/` (maemo-leste pvr-omap4, debian/changelog
  1.9.0.8.1.3-1; repo https://github.com/maemo-leste/pvr-omap4, commit not recorded).
- `<session scratch>/gpu/re-downloads/ti-1.17-next-742cf38/targetfs/ti443x/` (TI 1.17.4948957 OMAP4 UM;
  upstream URL as recorded by the parallel workflow that fetched it, not re-verified here).

Web (fetched 2026-10-11):
- https://github.com/openpvrsgx-devgroup/linux_openpvrsgx — branches `letux/pvrsrvkm-1.8.869593`
  @214f07dd8fe4d9dae7f9e4e42c9472bf08756a1f, `letux/pvrsrvkm-1.9.2188537`
  @e4e332159df1d5ab0509572c78fec075649986e1, `letux/pvrsrvkm-1.9.2253347`
  @d05540a4a44beb55941a07096d6f5643496a90c9, `letux/pvrsrvkm-1.17.4948957`
  @584dd33a1557dde5365d6fce536c107aa6f56d59 (sparse clones in `re-downloads/re05-openpvrsgx-*`).
  Files cited: `services4/include/sgxinfo.h`, `include4/sgxscript.h`, `include4/sgx_options.h`,
  `include4/sgxapi_km.h`, `include4/pvrversion.h`, `services4/srvkm/devices/sgx/sgxinit.c`,
  `services4/srvkm/bridged/bridged_pvr_bridge.c`, `services4/srvkm/env/linux/osfunc.c`,
  `services4/srvkm/hwdefs/{sgx540defs.h,sgxerrata.h,sgxfeaturedefs.h}`,
  `services4/include/{pvr_bridge.h,sgx_bridge.h}`, `eurasia_km/Makefile`,
  `eurasiacon/build/linux2/{omap_linux,jz4780_linux,omap4430_linux}/Makefile`.
- https://codeberg.org/Garnet/sgx540-reversing — HEAD c15884751ad870b3e06abd3d8b5a6ab00e2fb3cd
  (2022-10-16); `README.md`, `asm/README.md`, `info/ISA.md`, `ukernel/README` (local copy
  `re-downloads/sgx540-reversing-c15884751ad8`).
- https://www.mail-archive.com/powervr-devel@listas.gnu.org.ve/msg00021.html — C. Devine,
  2012-09-30 (libuseasm.a, useasm, pdsasm).
- sgx535-remesa: local mirror `re-downloads/sgx535-remesa-acc60f5ff157` (`README.md`,
  `SGX535-reMESA:docs/usse.md`, `SGX535-reMESA:docs/phase7/7.5-firmware-microkernel.md`; upstream URL not recorded).
- `re-downloads/sgx540-reversing-hazematman-c9ce47eef5a8` (LD_PRELOAD ioctl wrapper listing
  `PVRSRV_BRIDGE_SGXINFO_FOR_SRVINIT = SGX_CMD_BASE+15`, `SGX_DEVINITPART2 = +16`; upstream URL
  not found).
- Prior repo note: `docs/2026-06-19-gpu-sgx540-acceleration-research.md` (§4 and §6 statements
  about 1.9.2188537 and the `.fw` file corrected above).

---

## Verification (2026-10-11)

Adversarial re-check by a second agent. Every claim was reproduced from the raw files, not from
the first pass's annotated output. Tools: `debugfs` dumps from `system.raw.img`,
`arm-none-eabi-objdump` (ARM mode, stock libsrv_init and `vmlinux.bin` at VA 0xc0008000), my own
scanners run with `python3 -I` from `<session scratch>/gpu/re/tmp/v05/scripts/`, `gcc -E` over the
openpvrsgx headers (preprocess only, nothing executed), `git ls-remote` and WebFetch. Scratch:
`<session scratch>/gpu/re/tmp/v05/`.

| # | claim | verdict | evidence / correction |
|---|---|---|---|
| 1 | no `.fw`; no `request_firmware` in the 4 KM trees; no SGX file in /vendor/firmware | **confirmed** | sparse checkouts cover all of `drivers/gpu/drm/pvrsgx/` (heads 214f07dd / e4e33215 / d05540a4 / 584dd33a, equal to `git ls-remote`); `grep firmware` over all .c/.h = 0 hits. `/vendor/firmware` also holds a `hdcp.keys` symlink (omitted from the list, not GPU). `/etc/firmware` does not exist in system.raw.img. Prior note line 106 (`sgx540_*.fw`) is wrong. |
| 2 | rodata map 0x2074…0x1ad6c | **confirmed** | srcs resolved from literal pools: 0x17e0→0x2074, 0x17e4→0x8154, 0x17ec→0xdb94, 0x17f4→0x12f34; names 0x1b047/4e/56; sizes `movw` 0x60e0/0x5a40/0x53a0/0x7970 at 0xf8c/0xfd0/0x1010/0x1050; PDS base r9 = sl = 0x1a014 (+0x890/0x8bc/0x908/0x934/0xca4), sizes 0x2c/0x4c/0x2c/0x370/0xb4. Sum 0x1ad6c; rodata 0x1ad6c–0x1b51c has 0 non-printable bytes (strings only). |
| 3 | 15 DEADBEEF sites + encoding | **confirmed** | fn 0x650 decoded; 15 `bl 650` at 0x1518…0x1688 with targets ukernel+0x4d58/0x4d70/0x1430/0x1440/0x1448/0x1480/0x1490/0x14e0/0x14f0, TA+0x46b8/0x46d0, 3D+0x65e8/0x6600, SPM+0x4018/0x4030; scan finds exactly these and no others (also none at 4-mod-8 offsets). Literals 0x3000900/0x1801000/0x1000900 at 0x1834/0x183c/0x1840. Independently confirmed by Garnet `asm.h:36-40`; IMG's disassembler prints the form as `mov rN, #imm`. |
| 4 | KM only gets handles/scripts/constants | **confirmed** | 1.8 sgxinfo.h:70-199, `SGX_MAX_INIT_MEM_HANDLES 18` (:40), `SGX_MAX_DEV_DATA 24` (:39); sgxinit.c:745 message after `InitDevInfo`; sgxscript.h 64/64/16 × 12 B. |
| 5 | 0xA48 DM=3 / 0xAB8 / 0xAC4 writes | **confirmed** (minor fix) | 0x1aa4-0x1ac0 (`lsr #8`, `orr #0x3000000`, `movw 0xa48`), 0x1af0 (0xab8 ← init+0xb8), 0x1b68 (0xac4 ← [init+8]+8), plus 0xb30 ← 0x100 at 0x1b2c. The 1.8 tree **does** define `EUR_CR_USE_CODE_BASE(X)` (sgx540defs.h:538); table header corrected. The unnamed registers have no `EUR_CR_*` define in any downloaded header. |
| 6 | KM checks DDK version/build, rev, 13 sizes, options, "all reported by the uKernel" | **partly refuted** | True for 1.8/1.9 except that the client-options check uses srvinit's constant, not a uKernel report. **1.17's `SGXDevInitCompatCheck` does not check the uKernel DDK version/build at all**; the DDK check is UM↔KM via `PVRSRVCompatCheckKM` (pvrsrv.c:173-188). Stock kallsyms (`SGXDevInitCompatCheck` c0292f1c, `SGXGetMiscInfoUkernel` c0292dd4, etc.) and log strings at vmlinux 0x683474/0x6836f8/0x683b74/0x683e98 confirmed. |
| 7 | stock stamps 785978/540/0x10200/0x36801c | **confirmed** | 0x3324 → 0xbfe3a, 0x3334 → 0x21c, 0x3364 → 0x36801c; vmlinux 0x678738 `…sgxddk 18 1.8@785978`; literal 0x36801c at 0x1774 loaded at 0x9c8. **New:** stock UM = Galaxy Nexus IML74K/IMM76D imgtec drop byte for byte; the GPL 785978 KM is public (AOSP kernel/omap `android-omap-steelhead-3.0-ics-aah`). |
| 8 | pvr-omap4 = 1.9@2253347, opts 0x68018; fails vs 2188537 KM | **confirmed** | 0x2e70 → 0x226223, 0x2eb0 → 0x68018; 2253347 is the only build constant in libsrv_um@0x8554, libGLESv2@0x7a7c, libglslcompiler@0x5afc (no 2188537 anywhere). The 2188537 KM checks the uKernel build (sgxinit.c:2545). |
| 9 | 2253347 branch: 4 Kbuild.mk, no Makefile | **confirmed** | `git ls-tree` at d05540a4: README, INSTALL, licences, include4/, services4/, 4 `Kbuild.mk`; no Makefile/Kconfig; `drivers/gpu/drm/Makefile` does not reference pvrsgx. README "version 1.9.11 … ED2253347" (it also says "OMAP/Jacinto6 platforms"). |
| 10 | 1.17 ti443x 4948957/0x360018; letux flags = 0x360018; module `pvrsrvkm_omap4_sgx540_120` | **confirmed with corrections** | Stamps 0x13b10/0x13b50 reproduced; ccflags at Makefile:107-132 give bits 3, 4, 17, 18, 21 (+20 implied, sgxfeaturedefs.h:282-283) = 0x360018 **only because** letux `sgx_options.h:151` forces bit 15 to 0 ("HACK: missing userspace flag") although `-DSUPPORT_ACTIVE_POWER_MANAGEMENT` is passed (:132). SOC/SGX/SGX_REV are never assigned in the branch, so the module name is inferred from the DT compatible `ti,omap4-sgx540-120`. -v2/-v3 branches unexamined. |
| 11 | 1.9.2188537 KM ≈ 0x368018 | **confirmed** (upgraded from likely) | Enumerated under omap4 defaults: bits 3, 4, 15, 17, 18, 20, 21 = 0x368018 exactly (line refs in §3). |
| 12 | rev-specific; jz4780 rev 130 | **confirmed** (decode of slot 6 remains inference) | Exceptions {0x10100,0x10101} in 1.8 and 1.17 (1.17 sgxinit.c:2686-2689); sgxerrata.h:199-202 rev 120 = BRN 26620/28011/34028; 1.17 `jz4780_linux/Makefile:69-70` 540/130. |
| 13 | srvinit imports no libc beyond `__cxa_finalize`, "adds no musl constraint" | **partly refuted (overreach)** | Symbol-level claim true. But DT_NEEDED and float ABI still constrain: stock = bionic sonames + softfp; 1.9/1.17 = libc.so.6 + hard-float (`Tag_ABI_VFP_args`). Qualified in §5. |
| 14 | init once per load, CAP_SYS_MODULE, init.steelhead.rc | **confirmed** | 1.8 osfunc.c:2260-2262, 1.17 :3343-3345; 1.8 bridged_pvr_bridge.c:4004 (RUNNING/RAN gate); init.steelhead.rc:32 `chmod 0666 /dev/pvrsrvkm`, :89-93 service block. |
| 15 | no other partition carries GPU content | **confirmed** | bootloader/xloader: 0 matching strings. p9 = ANDROID! header, kernel 5 543 872 B, ramdisk 0, cmdline root=/dev/mmcblk0p13 (ours). p8 recovery ramdisk: 38 cpio entries; the only byte match is a compressed-PNG false positive. Factory zip has 5 entries as listed. |
| 16 | bridge indices 110/104/101 | **partly refuted** | Reproduced for the letux headers under the stated config, but **the real stock KM (785978) uses SGX_DEVINITPART2 = 101, SGXINFO_FOR_SRVINIT = 100, GETMISCINFO = 99, INITSRV = 69/70** (vmlinux c0292c3c-c0292c7c). The "1.8" column describes 869593 only. Letux 1.17 as built (`-DSUPPORT_DMABUF`) is 103/102/101 and 71/72, not 101/100/99 and 69/70. The 1.17 debug-script array count for SGX540 is one, not two; the `SGX_INIT_OP_HALT` value changes from 2 (1.8) to 4 (1.17). |

Other spot checks that passed: §1.1 sha256 prefixes of all stock files; 785978 at libsrv_um
0x9fcc, libglslcompiler 0x77d0, libGLESv2 0x9c78; `"tools/intern/useasm/useasm.c"` (a string inside the blob) at libusc
0xcec40; all twelve per-image sha256 prefixes in §3; 1.9 and 1.17 images each hold exactly 15
placeholders (1.9 ukernel +0x1760…0x3ef0, 1.17 ukernel +0x1ab0…0x4620); the 1.17 3D/SPM 8-byte
overlap; the powervr-devel 2012-09-30 post (C. Devine: "libuseasm.a which provides object files
for both assembly and disassembly", "useasm and pdsasm"). The letux branch heads match
`git ls-remote` of openpvrsgx-devgroup/linux_openpvrsgx.

Not re-verified: the PDS address helper fn 0x800 semantics; the 1.9/1.17 PDS layout; the
`SGX_BRIDGE_INIT_INFO` mapping in libsrv_um; and the DDKVersion/CoreRevSW ALU decode (it stays an
inference from three samples).

**Net effect on the pairing conclusions.** The report's "only OMAP4 userspace fits" stands. Its
practical options grow by one: the stock/Galaxy-Nexus **1.8@785978 bionic softfp userspace** now
has a public version-matched GPL KM (AOSP kernel/omap). Anyone writing a shim or KM for it must
use the 785978 bridge numbering (DEVINITPART2 = 101), not the letux 869593 numbering (110).

Additional source: https://android.googlesource.com/kernel/omap/+/refs/heads/android-omap-steelhead-3.0-ics-aah/drivers/gpu/pvr/pvrversion.h
(branch HEAD 03a9286bb61a9acd28027206c4937990ac817f1b, `git ls-remote` 2026-10-11).
