# SGX540 RE 3/7: the kernel↔userspace bridge ABI and the KM×UM compatibility matrix

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

- **The letux build-option word was recomputed by three independent passes**
  (this note's verification, [stock-sysconfig.md](stock-sysconfig.md) and
  [firmware-microkernel.md](firmware-microkernel.md)): letux 1.8.869593 and
  letux 1.17 both build `0x00360018`, because `SUPPORT_SGX_LOW_LATENCY_SCHEDULING`
  makes `sgxfeaturedefs.h` define `SUPPORT_SGX_PRIORITY_SCHEDULING` (bit 20).
  The original `0x00260018` came from evaluating `sgx_options.h` alone.
- **The 1.17 option match rests on a letux hack.** `include4/sgx_options.h:151`
  forces `OPTIONS_BIT15` (`SUPPORT_ACTIVE_POWER_MANAGEMENT`) to 0 ("HACK:
  missing userspace flag") while the Makefile still passes
  `-DSUPPORT_ACTIVE_POWER_MANAGEMENT`. The APM code is therefore compiled in,
  only the reported bit is masked ([firmware-microkernel.md](firmware-microkernel.md) §3);
  [stock-sysconfig.md](stock-sysconfig.md) row 16 shows the resulting 2 ms APM
  latency from the AM437x header.
- **Where the DDK version is checked moved in 1.13+.** The 1.8/1.9 KMs compare
  the *microkernel's* DDK build; the 1.17 KM does not, it compares the *UM's*
  DDK build in `PVRSRVCompatCheckKM` via ioctl 0
  ([firmware-microkernel.md](firmware-microkernel.md) §2.6).
- **Drop B vs drop C** (see [blob-abi.md](blob-abi.md)): the 1.17 rows of the
  tables below cover the 2020 build (= drop B) for sizes, and both builds for ids
  and options.

---

## TL;DR (RE-03 — SGX540 DDK kernel↔userspace bridge ABI, 2026-10-11)

1. **"Versions must match" breaks down into six separate checks.** Each can be measured: (T) transport/device node,
   (P) layout of `PVRSRV_BRIDGE_PACKAGE`, (I) the bridge command index table, (V) the DDK version handshake, (O) the
   `SGX_BUILD_OPTIONS` bitmask, (S) the per-command in/out struct sizes and layouts. The KM checks only V and O, plus the
   "SGXMKIF struct sizes" check, which compares the **client against the microkernel and never against the KM**.
   I, P and S are **never validated**: `BridgedDispatchKM` only bounds-checks `InBufferSize`/`OutBufferSize` against
   `PVRSRV_MAX_BRIDGE_IN/OUT_SIZE` (0x1000). So a wrong pairing is not rejected cleanly: the KM silently
   misinterprets the fields. *(Corrected 2026-10-11: the copies themselves stay inside the KM's 4 KiB in/out buffers,
   so "corrupts memory" is not a given. Whether a misread handle, size or address ends in an error return or in real
   corruption depends on the command. UNVERIFIED per command.)*
2. **Stock UM (Android, 1.8@785978) pairs with exactly one KM: the stock one.** 41/41 anchor ioctls match only the stock
   `g_BridgeDispatchTable` (vmlinux). Against every letux tree they score 0–21/41. Letux `1.8.869593` scores 8/41: it has
   10 extra core commands, ids 31..40 (`REMAP_TO_DEV`..`CORE_CMD_RESERVED_7`), and lacks `GETMMU_PD_DEVPADDR` (68)
   and `SGX_GETMMUPDADDR` (95).
   **The exact GPL source of the stock KM is public.** It is AOSP `kernel/omap` branch
   `android-omap-steelhead-3.0-ics-aah` @ `03a9286bb61a9acd28027206c4937990ac817f1b`, `drivers/gpu/pvr`. That tree
   reports `1.8@785978` / branch 18, its preprocessed id table equals the vmlinux table, and it yields build options
   `0x0036801C`.
3. **TI Linux 1.17@4948957 `ti443x` UM (SGX540/120, glibc) is ABI-consistent with letux 1.17 KM on every bridge
   check.** The results: ioctl ids 35/35 (with `SUPPORT_DMABUF`); package layout (1.17 order) identical; DRM driver
   name `"pvr"`, command 0, render node; UM_KM_COMPAT_CHECK `0x00011100`/4948957 = KM `PVRVERSION`; in/out sizes 102/103.
   The single difference is a benign out-size, see §6.
   Build options: UM `0x00360018`, and the letux 1.17 KM *also* `0x00360018` (corrected 2026-10-11; the original
   `0x00260018` was wrong). The letux Makefile sets `-DSUPPORT_SGX_LOW_LATENCY_SCHEDULING`.
   `sgxfeaturedefs.h:282-284` then defines `SUPPORT_SGX_PRIORITY_SCHEDULING` (bit 20), and `sgxinit.c` includes
   `sgxdefs.h`→`sgxfeaturedefs.h` (line 44) before `sgx_options.h` (line 65). Consequences:
   - The exact compare on b618 passes.
   - The masked compare on b72 (`SGX_BUILD_OPTION_MASK` = `0xffc5fc86` for SGX540) passes.
   - The UM's own exact `SGXConnectionCheck` passes too.
   - **No extra define is needed.**
   This is still derived from source, not observed at runtime.
4. **TI Linux 1.9@2253347 OMAP4 UM (pvr-omap4, glibc) matches letux/TI 1.9.2253347 on ids (41/41) and sizes (149/149,
   with `SUPPORT_MEMINFO_IDS`).** Its transport is dead on mainline, though. It does `drmOpen("omapdrm")` and then
   `drmCommandWriteRead(fd, 2 /*DRM_OMAP_GET_BASE*/, "omapdrm_pvr", 72)` to find the PVR ioctl base. That is the TI
   vendor omapdrm *plugin* API (`omap_drm_register_plugin`), and ioctl 0x02 does not exist in 6.18
   `include/uapi/drm/omap_drm.h`.
   Letux 1.9.2253347 has no Makefile at all.
5. **Build-option words (all verified in code):**

   | Side | Build options |
   |---|---|
   | stock KM and stock UM | `0x0036801C` |
   | Android 1.8@905891 UM | `0x0036801C` |
   | Linux 1.9@2253347 UM | `0x00068018` |
   | TI 1.14@3699939 ti335x UM | `0x00360018` |
   | TI 1.17@4948957 ti443x UM | `0x00360018` |
   | letux 1.8.869593 omap4 KM | `0x00360018` (corrected; was `0x00260018`) |
   | letux 1.17 KM (b618 and b72) | `0x00360018` (corrected; was `0x00260018`) |

   **No letux tree, as configured, satisfies the stock UM.** The stock UM needs `PVRSRV_USSE_EDM_STATUS_DEBUG` (bit 2)
   and `SUPPORT_ACTIVE_POWER_MANAGEMENT` (bit 15). Bit 20 is already set via LOW_LATENCY (corrected). Letux 1.17
   hard-wires bit 15 to 0 ("HACK: missing userspace flag", `sgx_options.h:151`). Bit 2 is a Kconfig option on b72:
   `SGX_USSE_EDM_STATUS_DEBUG`, visible only `if SGX_ABI`.
6. **DDK version handshake differs by generation.**
   - **≤1.12:** the KM compares the **microkernel's** DDK (loaded from `libsrv_init`) with its own
     `MAJ<<16|MIN<<8|BRANCH` and `BUILD`. The UM's `SGXConnectionCheck` then compares the KM's DRIVER_SGXREV reply with
     its own constants. The pairs are stock `0x00010812`/785978 and 1.9 `0x00010913`/2253347.
   - **≥1.13:** the UM sends `PVRSRV_BRIDGE_UM_KM_COMPAT_CHECK` (ioctl index 0, `0xC01C6700`) with `MAJ<<16|MIN<<8`
     (no branch) and `BUILD`; this is checked in `PVRSRVCompatCheckKM`.
   - **Practical rule:** a KM can serve a UM only if it *reports* that UM's exact version numbers. Letux b72 already does
     this ("ABI faking") for 1.7.862890 via `PVR_ABI_COMPAT`.
7. **Package layout:** ≤1.14 is `{ID, Size, pvParamIn, InSize, pvParamOut, OutSize, hKernelServices}` (28 bytes);
   1.17 is `{ID, Size, hParamIn, hParamOut, InSize, OutSize, hKernelServices}` (28 bytes). This is confirmed in the
   1.17 UM's `OpenServices` package literal `{0xC01C670D, 0x1C, &in, &out, 4, 16, h}`. So 1.14 UM against 1.17 KM fails
   even though the ids are identical. Letux b72 makes the order selectable with `PVR_ABI_COMPAT`.
8. **musl / bionic does not enter the bridge ABI.** Every bridge struct is 32-bit `IMG_*` types, and the ioctl number
   depends only on `sizeof(PVRSRV_BRIDGE_PACKAGE)` (28) and the index. The libc question is purely a userspace loader
   question (other workstream).

## Scope

Date: 2026-10-11. Scope: Google Nexus Q (OMAP4460, SGX540 rev 120 = `SGX_CORE_REV=120`), mainline 6.18.48.
Nothing built for the device, flashed or committed. All tools and intermediate data are in
`<session scratch>/gpu/re/` (`<session scratch>/gpu/re/tools/`, `ids/`, `callsizes/`, `sizes/`, `bw/`); downloads in `<session scratch>/gpu/re-downloads/`.
(`<session scratch>` = the session scratch directory.)

## 1. Method and inputs

| Input | Where | Identity |
|---|---|---|
| Stock kernel | `reverse-eng/vmlinux.bin` + `reverse-eng/tools/kallsyms.txt` | sha256 `089f4c90b8a61ca7…`; string `CustomerGoogle_Android_ogles1_ogles2_GPL sgxddk 18 1.8@785978` @ `0xc0680738` |
| Stock UM | `system.raw.img` `/vendor/lib/libsrv_um.so`, `libsrv_init.so`, `/vendor/bin/pvrsrvinit` → `re/stock-blobs-03/` (debugfs dump) | libsrv_um sha256 `f177b896e7b37e6a…` (byte-identical to Galaxy Nexus IML74K `vendor/imgtec/maguro/proprietary/libsrv_um.so`) |
| AOSP steelhead KM source | `https://android.googlesource.com/kernel/omap/+/03a9286bb61a9acd28027206c4937990ac817f1b/drivers/gpu/pvr/` (`pvr_bridge.h`, `sgx_bridge.h`, `pvrversion.h`, `sgx_options.h`, `Makefile`, `Kconfig`, `bridged_pvr_bridge.c`, `sgx/sgxinit.c`) → `re-downloads/re03-aosp-steelhead-03a9286b/` | `git ls-remote` HEAD of `refs/heads/android-omap-steelhead-3.0-ics-aah` = `03a9286b…` |
| letux KM | `openpvrsgx-devgroup/linux_openpvrsgx` branches `pvrsrvkm-6.18-rc6` @ `d2f1e031d58a` (b618, `src/openpvrsgx`) and `pvrsrvkm-7.2` @ `2342ce92fdde` (b72, exported to `re/km-b72/`) | the b72 merge includes `letux/pvrsrvkm-1.17.4948957-v3` (commits b9b0a1cd "Add driver ABI configuration options", bc3a02e4 "Support alternative ioctl numbers", 15b675c6 "Support 1.7.862890 ABI", c3a3ae16 "Relax build option sanity checking"; from `k-branchlogs.txt`) |
| TI KM | `git.ti.com/graphics/omap5-sgx-ddk-linux` tag `TI_LINUX_OMAP_SGX_DDK_1.9_2253347` (`6668f4ea`) and branch `ti-img-sgx/1.17.4948957/k6.1` (`bfd9edef`) → `re-downloads/ti-km-19-2253347/`, `re-downloads/ti-km-117-k61/` | — |
| Linux 1.9 UM | maemo-leste `pvr-omap4` @ `46e98395` (TI "sgx-lib 1.9.0.8.1", SGX540, **with DWARF** in `usr/lib/debug`) → `re-downloads/repos-pvr-omap4/`; TI `omap5-sgx-ddk-um-linux` master `b6801bf8` (SGX544, reference only) | `libGLESv2.so.1.9.6.0` = `1.9@2253347` |
| Linux 1.17 UM `ti443x` | `blobs-ti2020`; maemo-leste `sgx-ddk-um` @ `6fb7fa24` (`repos-sgx-ddk-um`, identical to the TI 2024 `ti443x_linux` build); TI branches `1.17.4948957-next` `742cf38`, `ti-img-sgx/kirkstone-ws/1.17.4948957` `76251c0` (the last three were fetched by sibling workstreams) | `libGLESv2_PVR_MESA.so.1.17.4948957` = `1.17@4948957`; the 2020/next/kirkstone libsrv_um are byte-identical (`c4faa93c…`) |
| Android JB 1.8@905891 UM | `imgtec-panda-20130603-539d1ac3`, `imgtec-maguro-jro03h-827bcb4c` (fetched by a sibling workstream) | GLES string `1.8@905891`; panda and maguro `libsrv_um` are identical (`394f112b…`) |
| TI 1.14 UM | `ti-1.14-bbbd5cb` `targetfs/ti335x` (SGX530, reference only) | `1.14@3699939` |

Tools (all in `re/tools/`, run with `python3 -I` from outside the download dirs; capstone from `gpu/venv`):

| Tool | What it does |
|---|---|
| `regtrack.py` | constant-propagates registers in a stock function and dumps args at every `bl` (dispatch-table registrations) |
| `bridge_ids.py` | keeps only the preprocessor directives of `pvrversion.h` + `pvr_bridge.h` + `sgx_bridge.h`, runs `gcc -E` with `PVRSRV_IOWR(x)=x`, prints NAME→index |
| `um_ioctls.py` | finds every `0xC01C67xx` constant (literal pool or movw/movt) in a UM `.so` and attributes it to the enclosing dynsym function |
| `compare.py` | scores UM against KM on 41–52 anchor functions (`PVRSRVGetMiscInfo`→`GET_MISC_INFO`, …) |
| `callsizes.py` | for every call of the UM's bridge-call helper, recovers (id, `InBufferSize`, `OutBufferSize`) from r1/r3/[sp+4] |
| `bwtypes.py` | maps `SetDispatchTableEntry(NAME, FnBW)` to the IN/OUT struct types of `FnBW` |
| `sizes.py` | compiles the KM headers for armv7hf (`arm-linux-gnueabihf-gcc -c`, not linked, not run) and reads `sizeof` from `st_size` |
| `cmpsizes.py` | compares UM in/out sizes with KM `sizeof` by bridge name |
| `buildopts.py` | evaluates `SGX_BUILD_OPTIONS` / `SGX_BUILD_OPTION_MASK` from `sgx_options.h` with given `-D` flags |

## 2. Ioctl encoding and transport (check T, P)

All versions encode a command as `PVRSRV_IOWR(i) = _IOWR('g', i, PVRSRV_BRIDGE_PACKAGE)` = **`0xC01C6700 + i`** on
32-bit ARM. The size field 0x1C = 28 = `sizeof(PVRSRV_BRIDGE_PACKAGE)` (`pvr_bridge.h`, all trees). Every one of
1,000+ constants found in the UM blobs has the size field 28 (`scan_ioc.py`, `um_ioctls.py`).
On the KM side, `PVRSRV_GET_BRIDGE_ID(X) = _IOC_NR(X)` (`bridged_pvr_bridge.h:37` in 1.8, `:53` in 1.9/1.17).
`PVRSRV_BridgeDispatchKM` compares the *full* value to `PVRSRV_BRIDGE_CONNECT_SERVICES` before stripping it.
In stock this is `movw r3,#0x670c; movt r3,#0xc01c; cmp r4,r3` @ `c02771b8`; in 1.17 it is `pvr_bridge_k.c:292-294`.

| Generation | How the UM reaches the KM | Evidence |
|---|---|---|
| stock 1.8@785978 Android | `open("/dev/pvrsrvkm")` + `ioctl(fd, 0xC01C67xx, &pkg)` (char device, `register_chrdev`) | UM strings `/dev/pvrsrvkm`, `OpenServices: Cannot open device driver /dev/pvrsrvkm.`; UM imports `ioctl`; KM string `PVRCore_Init: major device %d` @ `0xc068050c`; built-in `OMAPLFB` display class (`OMAPLFB_Init` @ `c0025af0`) |
| TI Linux 1.9@2253347 | `drmOpen("omapdrm",NULL)` → `PVRDRMSetFD`: `snprintf(buf,64,"%s_pvr","omapdrm")`; `drmCommandWriteRead(fd, 2, buf, 72)`; base = `*(u32*)(buf+64)` stored in `pvr_ioctl_base`; then `PVRSRVBridgeCall` = `drmCommandWrite(fd, pvr_ioctl_base, &pkg, 28)` | pvr-omap4 `libsrv_um.so.1.9.6.0` `PVRDRMSetFD` @ `0x9658`, `PVRDRMOpen` @ `0x9720`, `PVRSRVBridgeCall` @ `0x9758`; string `PVRDRMSetFD: could not get plugin ioctl base: %d`; TI KM `services4/srvkm/env/linux/pvr_drm.c:516 omap_drm_register_plugin(&plugin)`, `omap4430_linux/Makefile:203 PVRSRV_MODNAME := omapdrm_pvr` |
| TI/letux 1.17@4948957 | `_PVRDRMOpenRender`: `drmOpenRender(128..143)`, accept only if `drmGetVersion()->name == "pvr"`; fallback to `/dev/dri/card%d`. Bridge: `drmCommandWrite(fd, 0, &pkg, 28)`, i.e. DRM nr 0x40 | leste `libsrv_um.so.1.17.4948957` `_PVRDRMOpenRender` @ `0xa690` (the strcmp operand resolves to `"pvr"`); `OpenServices` call @ `0x9d38` with `r1=0`; TI KM `pvr_drm.c:630 .name = "pvr"`; letux `pvr-drv.c:205 .name = "pvr"`, `DRM_PVR_SRVKM 0x0` (`pvr-drv.h`), `DRIVER_RENDER` |

The 1.17 UM uses `drmCommandWrite` (`DRM_IOW`) while the KM declares `DRM_IOWR`. 6.18 `drm_ioctl()` (`drm_ioctl.c:855-861`)
copies in only and does not copy the package back. This is harmless because the outputs travel through `hParamOut`.
The 1.17 UM also probes `drmCommandNone(fd, 3)`, which is `PVR_IS_MASTER`, in `OpenServices` @ `0x9cec`.
Letux b72 can additionally mirror all ioctls at `CONFIG_SGX_IOCTL_ALIAS` (`DRM_PVR_RESERVED1`, `pvr_drm.c:509`). That is
used only on the Intel `pvr_drm.c` path; OMAP builds use `pvr-drv.c`.

`PVRSRV_BRIDGE_PACKAGE` (32-bit, 28 bytes):

| Offset | ≤1.14 (1.7/1.8/1.9/1.10/1.14 headers; 1.9 UM DWARF) | 1.17 (TI and letux b618; b72 when `PVR_ABI_COMPAT ≥ 1.17`) |
|---|---|---|
| 0 | ui32BridgeID | ui32BridgeID |
| 4 | ui32Size | ui32Size |
| 8 | pvParamIn | hParamIn |
| 12 | **ui32InBufferSize** | **hParamOut** |
| 16 | **pvParamOut** | **ui32InBufferSize** |
| 20 | ui32OutBufferSize | ui32OutBufferSize |
| 24 | hKernelServices | hKernelServices |

Evidence: `pvr_bridge.h` of each tree; b72 `1.17.4948957/.../pvr_bridge.h` `#if PVR_ABI_VERSION(PVR_ABI_COMPAT) >= PVR_ABI_VERSION(1,17,4948957)`.
The 1.9 UM stack frame in `PVRSRVBridgeCall` @ `0x9758` is `[sp+12]=id, +16=28, +20=in, +24=insize, +28=out, +32=outsize, +36=h`.
The 1.17 UM `OpenServices` package is literals `0xc01c670d,0x1c` @ `0x9de8` and `0x4,0x10` @ `0x9df0`, with `&in`/`&out`
at `sp+32/36`. These addresses are in the **leste-2024** build (sha256 `6bdfe93a…`). In the 2020 build (`c4faa93c…`)
those offsets are code. The 2020 build shows the same order in its bridge helper @ `0x8f94`.

## 3. Command index tables (check I)

KM tables come from three sources:
- **stock:** register-tracked from `CommonBridgeInit` @ `c028d7dc` and `SetSGXDispatchTableEntry` @ `c0292afc`. 84 core
  plus 22 SGX registrations. The table has 122 slots: `cmp r6,#0x79` in `BridgedDispatchKM` @ `c028e228` and the
  `DummyBW` fill loop over `0x1e8` bytes @ `c028de70`.
- **letux / AOSP / TI:** computed by preprocessing (`ids/km-*.tsv`).
- **UM:** constants attributed to exported functions (`ids/um-*.tsv`).

Anchor score: UM function→expected command, counted as matched when KM index == UM constant (`<session scratch>/gpu/re/tools/compare.py`).

| UM \ KM | stock 1.8@785978 | letux 1.8.869593 | letux 1.9.2188537 | 1.9.2253347 | letux 1.10.2359475 | 1.14.3699939 (no DMABUF) | 1.14 +DMABUF | 1.17 b618 (no DMABUF) | 1.17 +DMABUF (b618/b72 ABI 1.17) | 1.17 b72 ABI 1.7 |
|---|---|---|---|---|---|---|---|---|---|---|
| stock 1.8@785978 (Nexus Q = maguro IML74K; also panda 20120430) | **41/41** | 8/41 | 21/41 | 8/41 | 21/41 | 20/41 | 0/41 | 20/41 | 0/41 | 16/41 |
| Android 1.8@905891 (panda 20130603, maguro JRO03H/JWR66Y) | 21/41 | 8/41 | **41/41** | 8/41 | **41/41** | 1/41 | 0/41 | 1/41 | 0/41 | 16/41 |
| Linux 1.9@2253347 OMAP4 (pvr-omap4) | 8/41 | 8/41 | 8/41 | **41/41** | 8/41 | 0/41 | 0/41 | 0/41 | 0/41 | 8/41 |
| Linux 1.9@2253347 OMAP5 (TI master) | 10/52 | 10/52 | 10/52 | **52/52** | 10/52 | 0 | 0 | 0 | 0 | 10/52 |
| TI 1.14@3699939 ti335x | 0/32 | 0/32 | 0/32 | 1/32 | 0/32 | 7/32 | **34/34** | 7/32 | **34/34** | 0/32 |
| TI 1.17@4948957 ti443x (2020 = next = kirkstone-ws; leste 2024) | 0/33 | 0/33 | 0/33 | 1/33 | 0/33 | 8/33 | **35/35** | 8/33 | **35/35** | 0/33 |

The AOSP steelhead source table scores 41/41 against the stock UM, like the stock vmlinux table. The source *defines*
`UNMAP_MEMINFO_MEM = 67`, but neither the source nor the binary *registers* it. `bridged_pvr_bridge.c:4730`
registers only `MAP_MEMINFO_MEM`, and `stock-dispatch.tsv` jumps 66→68. So the registered dispatch tables are
identical (corrected 2026-10-11).

Key indices (the full 120-row table is in Appendix A):

| cmd | stock 1.8@785978 | letux 1.8.869593 | letux 1.9.2188537 / 1.10 | 1.9.2253347 | 1.14/1.17 +DMABUF | 1.17 b72 ABI 1.7 |
|---|---|---|---|---|---|---|
| UM_KM_COMPAT_CHECK | – | – | – | – | 0 | – |
| CONNECT_SERVICES | 12 (`0xC01C670C`) | 12 | 12 | 12 | 13 (`0xC01C670D`) | 12 |
| MAP_DMABUF | – | – | – | – | 30 | – |
| GET_MISC_INFO | 38 | 48 | 38 | 42 | 39 | 38 |
| ENUM_CLASS | 41 | 51 | 41 | 45 | 44 | 41 |
| GETMMU_PD_DEVPADDR | 68 | – | – | – | – | – |
| INITSRV_CONNECT | 69 | 78 | 68 | 72 | 71 | 67 |
| ALLOC_SYNC_INFO | 82 | 91 | 81 | 85 | 84 | 80 |
| SGX_CMD_BASE / SGX_GETCLIENTINFO | 85 | 94 | 84 | 88 | 87 | 83 |
| SGX_DOKICK | 88 | 97 | 87 | 91 | 90 | 86 |
| SGX_GETMISCINFO | 99 | 108 | 98 | 102 | 101 | 97 |
| SGXINFO_FOR_SRVINIT | 100 | 109 | 99 | 103 | 102 | 98 |
| SGX_DEVINITPART2 | 101 | 110 | 100 | 104 | 103 | 99 |
| SGX_READ_HWPERF_CB | 115 | 123 | 113 | 117 | 116 | 112 |

What moves the indices:
- `SERVICES4_TMP` block (`GETMMU_PD_DEVPADDR`): stock 1.8@785978 only.
- Core 31..40 (`REMAP_TO_DEV`, `UNMAP_FROM_DEV`, `MULTI_MANAGE_DEV_MEM`, `CORE_CMD_RESERVED_1..7`): letux 1.8.869593 only.
- Core 31..33 (`REMAP_TO_DEV` / `UNMAP_FROM_DEV` / GEM import): 1.9.2253347.
- `UM_KM_COMPAT_CHECK` at 0 shifts everything by +1 from 1.13 on.
- Relocation of `MAP/UNMAP_DEVICECLASS_MEMORY` into the DEVCLASS block (1.13+).
- `SUPPORT_ION` (+2) and `SUPPORT_DMABUF` (+2).
- `SUPPORT_OVERLAY_ROTATE_BLIT` and `PDUMP`.
- `SWAP_DISPCLASS_TO_BUFFER2` (absent in 1.7).
- In SGX: `SGX_GETMMUPDADDR` (stock 95), `SGX_FEATURE_2D_HARDWARE` and `PDUMP` blocks.

## 4. Version handshake (check V) — exact code

| Where | Compared values | Stock evidence | Failure |
|---|---|---|---|
| KM `SGXDevInitCompatCheck` (≤1.12), run during `DEVINITPART2` from pvrsrvinit | microkernel `sSGXFeatures.ui32DDKVersion` vs `PVRVERSION_MAJ<<16 \| MIN<<8 \| BRANCH`; `ui32DDKBuild` vs `PVRVERSION_BUILD` | vmlinux `movw r3,#0x812; movt r3,#1` @ `c0292ff4` (0x00010812), `movw #0xfe3a; movt #0xb` @ `c0293028` (785978); string `(FAIL) SGXInit: Incompatible driver DDK revision (%d)/device DDK revision (%d).` @ `0xc068b474` | `PVRSRV_ERROR_DDK_VERSION_MISMATCH`, init fails |
| UM `SGXConnectionCheck` (≤1.12), after connect | client constants vs KM's `SGX_MISC_INFO_REQUEST_DRIVER_SGXREV` reply (filled by KM from `PVRVERSION_*`, `sgxinit.c` `SGX_MISC_INFO_REQUEST_DRIVER_SGXREV` case) | stock libsrv_um @ `0x9e9c..0x9fa8`: eRequest=2; DDKVersion `0x00010812` (lit @ `0x9fc8`), build 785978 (lit @ `0x9fcc`); returns 25 | UM refuses (error 25 = DDK mismatch, 26 = build-option mismatch) |
| Same, Linux 1.9 UM | 1.9 UM `SGXConnectionCheck` @ `0x84aa` (DWARF local symbol): DDK `0x00010913` (lit @ `0x8550`), build `0x226223` = 2253347 (lit @ `0x8554`) | — | — |
| KM `PVRSRVCompatCheckKM` (≥1.13, `common/pvrsrv.c:176`) via ioctl 0 | `ui32DDKVersion == MAJ<<16 \| MIN<<8` (no branch); `ui32DDKBuild == PVRVERSION_BUILD` | 1.17 UM `PVRSRVInitSrvConnect` @ `0x5c40`: `mov.w r2,#0x1100; movt r2,#1` (0x00011100), `movw r3,#0x83dd; movt r3,#0x4b` (4948957), `ioctl 0xC01C6700`, in 8 / out 8; then `INITSRV_CONNECT 0xC01C6747` | `(FAIL) UM-KM DDK Mismatch` |
| KM SGXMKIF struct-size check (all versions, `CHECK_SIZE`) | `psSGXStructSizes` (microkernel) vs `psDevInfo->sSGXStructSizes` = **values passed by libsrv_init**, not the KM's own `sizeof` | 1.8 `sgxinit.c:58-66`, 1.9.2253347 `:92-100`, 1.17 `:96-104`; stock string `Size check failed for SGXMKIF_%s (client) = %d bytes, (ukernel) = %d bytes` | Passes whenever UM and microkernel come from the same blob set, even if the KM's own SGXMKIF layouts differ |
| KM core-revision check | microkernel `ui32CoreRev` vs `ui32CoreRevSW`; exception pair `0x10100/0x10101` | stock `movw #0x101; movt #1` @ `c029309c` | — |

Letux b72 forges the version: with `PVR_ABI_COMPAT=1,7,862890`, `pvrversion.h` sets MIN=7, BRANCH=17, BUILD=862890
(`include4/pvrversion.h:56-80`). The same mechanism would serve the stock UM if it reported 1.8 / 18 / 785978.

## 5. Build options (check O)

Bit map (`include4/sgx_options.h`; identical across trees except the 1.17 bit 15 hack):

| Bit | Option | Bit | Option |
|---|---|---|---|
| 0 | DEBUG | 1 | PDUMP |
| 2 | PVRSRV_USSE_EDM_STATUS_DEBUG | 3 | SUPPORT_HW_RECOVERY |
| 4 | PVR_SECURE_HANDLES | 5 | SGX_BYPASS_SYSTEM_CACHE |
| 6 | SGX_DMS_AGE_ENABLE | 8 | SGX_FAST_DPM_INIT |
| 9 | SGX_FEATURE_WRITEBACK_DCU | 10 | SGX_FEATURE_MP |
| 11 | SGX_FEATURE_MULTITHREADED_UKERNEL (1.7/1.8) | 12 | SGX_FEATURE_OVERLAPPED_SPM (1.7/1.8) |
| 13 | SGX_FEATURE_SYSTEM_CACHE | 14 | SGX_SUPPORT_HWPROFILING |
| **15** | **SUPPORT_ACTIVE_POWER_MANAGEMENT (≤1.14; forced 0 in letux 1.17)** | 16 | SUPPORT_DISPLAYCONTROLLER_TILING |
| 17 | SUPPORT_PERCONTEXT_PB | 18 | SUPPORT_SGX_HWPERF |
| 19 | SUPPORT_SGX_MMU_DUMMY_PAGE | 20 | SUPPORT_SGX_PRIORITY_SCHEDULING |
| 21 | SUPPORT_SGX_LOW_LATENCY_SCHEDULING | 22 | USE_SUPPORT_NO_TA3D_OVERLAP (1.7–1.9) |
| 24/28.. | MP core count (SGX_FEATURE_MP only) | | |

| Side | Value | Bits set | Evidence |
|---|---|---|---|
| stock KM (vmlinux) | `0x0036801C` | 2,3,4,15,17,18,20,21 | `SGXDevInitCompatCheck` `movw #0x801c; movt #0x36` @ `c0292f58` and @ `c0293364` (microkernel compare) |
| stock UM libsrv_um | `0x0036801C` | same | `SGXConnectionCheck` lit @ `0x9fb4`; `SGXDevInitPart2` lit @ `0xb0d0` |
| stock libsrv_init | `0x0036801C` | same | lits @ `0x1774`, `0x3364` |
| AOSP steelhead source + steelhead_defconfig | `0x0036801C` (computed) | Makefile: `HW_RECOVERY`, `SGX_HWPERF`, `PVR_SECURE_HANDLES`; Kconfig defaults `PERCONTEXT_PB=y`, `ACTIVE_POWER_MANAGEMENT=y`, `LOW_LATENCY=y`; defconfig `CONFIG_PVR_USSE_EDM_STATUS_DEBUG=y` | bit 20 comes from `drivers/gpu/pvr/sgxfeaturedefs.h:234-235` @ `03a9286b`: `#if defined(SUPPORT_SGX_LOW_LATENCY_SCHEDULING) && !defined(SUPPORT_SGX_PRIORITY_SCHEDULING)` → `#define SUPPORT_SGX_PRIORITY_SCHEDULING` (fetched 2026-10-11 via `?format=TEXT`) |
| Android 1.8@905891 UM | `0x0036801C` | same as stock | panda-20130603 libsrv_um words around `0x9f4c`: `0x36801c, …, 0x10812, 0xdd2a3` |
| Linux 1.9@2253347 OMAP4 UM | `0x00068018` | 3,4,15,17,18 | `SGXConnectionCheck` lit @ `0x854c`; libsrv_init lit @ `0xd28` |
| TI 1.14 ti335x UM | `0x00360018` | 3,4,17,18,20,21 | `movs r3,#24; movt r3,#0x36` @ `0x7822` |
| TI 1.17 ti443x UM (all builds) | `0x00360018` | 3,4,17,18,20,21 | 2020 build `movs r3,#24; movt #0x36` @ `0x7de8`; leste build `bic r0,r5,#0x360000; bic r0,#0x18` @ `0x88c8` |
| letux 1.8.869593 omap4 KM (computed from its Makefile) | **`0x00360018`** (corrected; `buildopts.py` gave `0x00260018`) | 3,4,17,18,20,21 | Makefile lines 109-122 (`LOW_LATENCY` @ 122); `sgxfeaturedefs.h:241-244` derives bit 20; `sgxinit.c` includes `sgxdefs.h` @ 29 before `sgx_options.h` @ 50. For SGX540, `ACTIVE_POWER_MANAGEMENT` is only set in the sgx544/jz4780 blocks (218, 226), and `EDM_STATUS_DEBUG` is in `ccflags-n` (307) |
| letux 1.17 b618 and b72 omap4 KM (computed) | **`0x00360018`** (corrected; `buildopts.py` gave `0x00260018`) | 3,4,17,18,20,21 (ACTIVE_PM defined but bit 15 forced to 0) | Makefile lines 95-132; `sgxfeaturedefs.h:282-284` derives bit 20; `sgxinit.c` includes `sgxdefs.h` @ 44 before `sgx_options.h` @ 65; b72 mask `~(0xa0379 \| 0x300000)` = `0xffc5fc86` (`sgx_options.h:241-249`) |

Comparison semantics:
- **Exact (`!=`):** stock KM, AOSP source (`sgxinit.c:1960, 2095`), letux b618 1.17 (`sgxinit.c:2714`), and all ≤1.14 trees.
- **Masked:** letux b72 1.17 (`(a ^ b) & SGX_BUILD_OPTION_MASK`, `sgxinit.c:2720, 2847`). Masked bits are
  0,3,4,5,6,8,9,17,19, plus 20,21 on non-5XT cores.
- **UM side:** `SGXConnectionCheck` also does an exact compare (stock @ `0x9ee4`; 1.17 @ `0x7dee`) against the KM's
  `DRIVER_SGXREV` reply. So even with the masked KM, a UM still sees the KM's *unmasked* options.
  *Corrected 2026-10-11:* the letux 1.17 KM reports `0x360018`, which equals the 1.17 ti443x UM. So this UM-side check
  passes on both b618 and b72 as configured. The earlier "returns 26" conclusion was wrong; it came from the
  `0x260018` mis-evaluation. For the *stock* UM, any KM still fails here unless it reports exactly `0x36801C`.

## 6. Struct sizes (check S)

The UM-side numbers are the actual `InBufferSize`/`OutBufferSize` arguments at every bridge call
(`callsizes/um-*.tsv`). They are checked against `sizeof` in the KM headers, compiled for armv7hf
(`sizes/km-*.tsv`, with letux-style flags plus `SUPPORT_MEMINFO_IDS` for 1.8/1.9/1.10).

| UM \ KM (match / compared values) | 1.8.869593 | 1.9.2188537 | 1.9.2253347 | 1.10.2359475 | 1.14 +DMABUF | 1.17 b618 +DMABUF | 1.17 b72 ABI 1.17 | 1.17 b72 ABI 1.7 |
|---|---|---|---|---|---|---|---|---|
| stock 1.8@785978 | 114/132 | 112/132 | 112/132 | 113/132 | 73/93 | 36/93 | 36/93 | 70/93 |
| Android 1.8@905891 | 123/137 | 121/137 | 121/137 | 122/137 | 82/98 | 40/98 | 40/98 | 79/98 |
| Linux 1.9@2253347 OMAP4 | 132/149 | 142/145 | **149/149** | 141/145 | 83/101 | 39/101 | 39/101 | 81/101 |
| TI 1.14 ti335x | 79/96 | 83/96 | 80/96 | 83/96 | **100/100** | 44/100 | 44/100 | 83/100 |
| TI 1.17 ti443x (2020) | 38/99 | 38/99 | 38/99 | 38/99 | 46/103 | **102/103** | **102/103** | 49/103 |

What drives the mismatches:
- **Stock UM vs letux 1.8.869593:** `CLIENT_MEM_INFO`-bearing outputs are 16 bytes larger in the KM
  (`ALLOC_DEVICEMEM` out 96 vs 112, `MAP_DEV_MEMORY` out 96 vs 112, `FREE_DEVICEMEM` in 80 vs 96). Also
  `GET_MISC_INFO` 148 vs 168, `SGX_DEVINITPART2` 2072 vs 2068, `REGISTER_HW_RENDER/TRANSFER_CONTEXT` in 12 vs 24 and
  out 8 vs 12, and `SGX_RELEASECLIENTINFO` 256 vs 276.
- **1.17 UM vs 1.17 KM:** the only miss is one `FREE_DEVICEMEM` call site passing out=8 where the KM's
  `PVRSRV_BRIDGE_OUT_FREEDEVICEMEM` is 4. The other site passes 4. Copy-out of 8 from a 4-byte KM struct leaks 4 stale
  bytes from the bridge buffer, so it is benign for function.
- **Linux 1.9 UM:** built with `SUPPORT_MEMINFO_IDS`. DWARF (`usr/lib/debug/usr/lib/libsrv_um.so.1.9.6.0`) shows
  `_PVRSRV_CLIENT_MEM_INFO_` 56 bytes with `IMG_UINT64 ui64Stamp` @ 40; TI `omap4430_linux/Makefile`:
  `SUPPORT_MEMINFO_IDS ?= 1`.

Key per-call UM sizes (in/out bytes; `?` = not constant at the call site):

| cmd | stock 1.8@785978 | Android 1.8@905891 | Linux 1.9@2253347 | Linux 1.17 ti443x |
|---|---|---|---|---|
| CONNECT_SERVICES | 8/8 | 8/8 | 8/8 | 4/16 |
| UM_KM_COMPAT_CHECK | – | – | – | 8/8 |
| ENUM_DEVICES | ?/328 | ?/328 | 0/328 | ?/200 |
| ACQUIRE_DEVICEINFO | 12/8 | 12/8 | 12/8 | 8/8 |
| CREATE_DEVMEMCONTEXT | 8/780 | 8/780 | 8/780 | 4/780 |
| ALLOC_DEVICEMEM | 32/96 | 32/96 | 48/88 | 44/76 |
| FREE_DEVICEMEM | 80/8 | 80/8 | 72/8 | 8/4 (+ one 8/8) |
| MAP_DEV_MEMORY | 12/96 | 12/96 | 12/88 | 8/76 |
| GET_MISC_INFO | 148/148 | 148/148 | 240/240 | 160/164 |
| SGX_GETCLIENTINFO | 8/? | 8/? | 8/344 | 4/104 |
| SGX_RELEASECLIENTINFO | 256/8 | 256/8 | 348/8 | 4/8 |
| SGX_DOKICK | 564/8 | 564/8 | 660/8 | ? |
| SGX_GETMISCINFO | 12/8 | 12/8 | 12/8 | 8/8 |
| SGXINFO_FOR_SRVINIT | ?/776 | ?/776 | 8/776 | 4/776 |
| SGX_DEVINITPART2 | 2072/8 | 2072/8 | 2068/8 | 2836/8 |
| SGX_REGISTER_HW_RENDER_CONTEXT | 12/8 | 24/12 | 24/12 | 20/12 |

Pattern: every 1.17 IN struct is 4 bytes smaller because `ui32BridgeFlags` was removed
(`#if PVR_ABI_VERSION(PVR_ABI_COMPAT) < PVR_ABI_VERSION(1,17,4948957)` in b72 `pvr_bridge.h`).

1.9@2253347 UM DWARF sizes (pahole):

| Struct | Size |
|---|---|
| `_SGX_BRIDGE_INIT_INFO_` | 2060 (`ui32ClientBuildOptions` @ 1796, `sSGXStructSizes` @ 1800) |
| `_SGX_INIT_SCRIPTS_` | 1728 |
| `_SGX_MISCINFO_STRUCT_SIZES_` | 52 |
| `_PVRSRV_SGX_MISCINFO_FEATURES` | 28 |
| `_SGX_CCB_KICK_` | 652 |
| `_SGXMKIF_CMDTA_SHARED_` | 1128 |
| `_SGXMKIF_TRANSFERCMD_SHARED_` | 292 |
| `_SGXMKIF_3DREGISTERS_` | 152 |
| `_SGXMKIF_HWRENDERCONTEXT_` | 68 |
| `_SGXMKIF_HWTRANSFERCONTEXT_` | 252 |
| `_SGXMKIF_HWRTDATASET_` | 80 |

KM 1.9.2253347 compiled gives `SGX_BRIDGE_INIT_INFO` 2060, `SGX_CCB_KICK` 652, `CMDTA_SHARED` 1128 and
`TRANSFERCMD_SHARED` 292, all equal. KM letux 1.8.869593: `CMDTA_SHARED` 552, `CCB_KICK` 556. KM 1.17: `CMDTA_SHARED`
1128, `TRANSFERCMD_SHARED` 268, `INIT_INFO` 2832.

## 7. Compatibility matrix

Legend: ✔ = passes, ✘ = fails (reason), ~ = passes only with the stated KM build change.
Checks run in the order T → P → I → V → O → S. A ✘ in an earlier check makes the later ones moot, but they are still listed.

| UM ↓ / KM → | stock 1.8@785978 (vmlinux = AOSP steelhead 03a9286b) | letux 1.8.869593 | letux 1.9.2188537 | TI/letux 1.9.2253347 | letux/TI 1.14.3699939 | letux 1.17 b618 | letux 1.17 b72 |
|---|---|---|---|---|---|---|---|
| **stock Android 1.8@785978** (`/dev/pvrsrvkm`, bionic) | **T✔ P✔ I✔ (41/41) V✔ (0x10812/785978) O✔ (0x36801C) S✔** — the only consistent pair; its kernel is 3.0, so the source must be forward-ported to 6.18 | T~ (only if `CONFIG_SGX_DRM` is off, which gives the chardev path) P✔ **I✘** (8/41, +10 core ids) **V✘** (869593≠785978) **O✘** (0x360018 vs 0x36801C: bits 2 and 15 missing; corrected) S✘ (114/132) | T~ P✔ **I✘** (21/41: no `GETMMU_PD_DEVPADDR`, `SGX_GETMMUPDADDR`) **V✘** (1.9.19@2188537) O✘ S✘ | **T✘** (omapdrm plugin) I✘ (8/41) V✘ O✘ | **T✘** (DRM "pvr") **P✔** (1.14 still uses the old order) **I✘** (0/41: COMPAT_CHECK shift) **V✘** (the UM's `SGXConnectionCheck` receives DDK 1.14@3699939 from `DRIVER_SGXREV`) O✘ S✘ | **T✘ P✘ I✘** (0/41) **V✘ O✘ S✘** (36/93) | same as b618 with ABI 1.17. With `PVR_ABI_COMPAT=1,7,862890`: **P✔**, I 16/41 ✘, V reports 1.7.17@862890 ✘ |
| **Android 1.8@905891** (JB; reference) | I✘ (21/41) V✘ | I✘ | I✔ (41/41) V✘ (needs 1.8.18@905891) O✘ (0x36801C) S✘ (121/137) | I✘ | ✘ | ✘ | ✘ |
| **Linux 1.9@2253347 OMAP4** (`drmOpen("omapdrm")`, glibc) | T✘ (no DRM) I✘ (8/41) V✘ | T✘ I✘ V✘ | T✘ I✘ (8/41) V✘ (2188537) | **T✘ on mainline** (needs `DRM_OMAP_GET_BASE` plugin ioctl, absent in 6.18 `omap_drm.h`; letux tree has no Makefile) **P✔ I✔ (41/41) V✔ (0x10913/2253347) O~** (KM must build `HW_RECOVERY`, `SECURE_HANDLES`, `ACTIVE_POWER_MANAGEMENT`, `PERCONTEXT_PB`, `SGX_HWPERF`, and nothing else in 0..22 = 0x68018) **S✔ (149/149 with `SUPPORT_MEMINFO_IDS`)** | ✘ (I, V) | ✘ | ✘ |
| **Linux 1.17@4948957 ti443x** (DRM render "pvr", glibc) | ✘ | ✘ | ✘ | ✘ | T✔ **P✘** (field order) I✔ (34/35: +DMABUF required) **V✘** (COMPAT_CHECK build 3699939≠4948957) | **T✔ P✔ I✔ (35/35, `SUPPORT_DMABUF` is in the letux Makefile) V✔ (0x11100/4948957) O✔ as built** (exact compare 0x360018 = 0x360018: bit 20 is derived from LOW_LATENCY in `sgxfeaturedefs.h`; corrected 2026-10-11, was O✘); **S✔ 102/103** | **T✔ P✔ I✔ V✔ O✔ S✔ 102/103**. **O:** the KM reports `0x360018`, so both the masked KM-side compare and the exact UM-side `SGXConnectionCheck` pass (corrected 2026-10-11; derived from code, UNVERIFIED at runtime) |

**KM build options required per UM** (for an exact pass of both KM-side and UM-side checks):

| UM | `SGX_BUILD_OPTIONS` | Must define | Must NOT define (would set a bit) | Other ABI-shaping KM flags |
|---|---|---|---|---|
| stock 1.8@785978 | `0x0036801C` | `PVRSRV_USSE_EDM_STATUS_DEBUG`, `SUPPORT_HW_RECOVERY`, `PVR_SECURE_HANDLES`, `SUPPORT_ACTIVE_POWER_MANAGEMENT`, `SUPPORT_PERCONTEXT_PB`, `SUPPORT_SGX_HWPERF`, `SUPPORT_SGX_PRIORITY_SCHEDULING`, `SUPPORT_SGX_LOW_LATENCY_SCHEDULING` | `DEBUG`, `PDUMP`, `SGX_FEATURE_MP`, `SGX_FEATURE_SYSTEM_CACHE`, `SGX_SUPPORT_HWPROFILING`, `SUPPORT_DISPLAYCONTROLLER_TILING`, `SUPPORT_SGX_MMU_DUMMY_PAGE`, `SGX_FAST_DPM_INIT`, `USE_SUPPORT_NO_TA3D_OVERLAP` | `SUPPORT_MEMINFO_IDS` (EXPORT out = 16), `TRANSFER_QUEUE`, `SUPPORT_SGX_NEW_STATUS_VALS`, no `SUPPORT_DRI_DRM` (chardev), the `SERVICES4_TMP` block, `DISPLAY_CONTROLLER=omaplfb`, `PVRVERSION` 1.8 / 18 / 785978 — i.e. the AOSP steelhead `Makefile` + `steelhead_defconfig` |
| Linux 1.9@2253347 | `0x00068018` | `SUPPORT_HW_RECOVERY`, `PVR_SECURE_HANDLES`, `SUPPORT_ACTIVE_POWER_MANAGEMENT`, `SUPPORT_PERCONTEXT_PB`, `SUPPORT_SGX_HWPERF` | `PVRSRV_USSE_EDM_STATUS_DEBUG`, `PRIORITY`/`LOW_LATENCY` scheduling, plus the above | `SUPPORT_MEMINFO_IDS`, `SUPPORT_DRI_DRM` + omapdrm plugin transport (`SUPPORT_DRI_DRM_PLUGIN`, `PVRSRV_MODNAME=omapdrm_pvr`) |
| TI 1.17@4948957 ti443x | `0x00360018` | `SUPPORT_HW_RECOVERY`, `PVR_SECURE_HANDLES`, `SUPPORT_PERCONTEXT_PB`, `SUPPORT_SGX_HWPERF`, `SUPPORT_SGX_LOW_LATENCY_SCHEDULING` (which implies `SUPPORT_SGX_PRIORITY_SCHEDULING` via `sgxfeaturedefs.h`; the letux Makefile already has it) | `SUPPORT_ACTIVE_POWER_MANAGEMENT` (TI `omap_linux/Makefile`: `SUPPORT_ACTIVE_POWER_MANAGEMENT := 0`; letux forces bit 15 to 0 instead), `PVRSRV_USSE_EDM_STATUS_DEBUG`, `DEBUG`, `PDUMP` | `SUPPORT_DMABUF` (ids 30/31), `SUPPORT_DRI_DRM`, DRM driver name `"pvr"`, no `SUPPORT_ION`, `PVR_ABI_COMPAT ≥ 1.17` on b72 |

## 8. Implications for the plan

- **Path A, stock UM:** forward-port the exact AOSP `android-omap-steelhead-3.0-ics-aah` `drivers/gpu/pvr` (1.8@785978,
  GPL) to 6.18 with the `steelhead_defconfig` PVR options. Every check then passes by construction. No letux tree is
  ABI-compatible with the stock UM. Patching letux 1.8.869593 instead would mean:
  - renumbering 30+ commands;
  - fixing the `CLIENT_MEM_INFO`/`MISC_INFO`/`DEVINITPART2`/`HW_*_CONTEXT` layouts;
  - faking the version;
  - changing 2 option bits (2 and 15; corrected from 3).
  That is a full ABI port, and the SGXMKIF/microkernel structures (`CMDTA_SHARED` 552 vs ?) are unverified.
  The stock UM is bionic and talks to `/dev/pvrsrvkm` + OMAPLFB display class.
- **Path B, TI 1.17 ti443x UM + letux 1.17 KM:** the bridge ABI is consistent on every check, including build
  options. The KM already reports `0x360018` (corrected 2026-10-11): the "bit 20 gap" was an artefact of
  `buildopts.py`, which evaluated `sgx_options.h` without `sgxfeaturedefs.h`. The transport (DRM render node named
  `pvr`) matches letux `pvr-drv.c`. This is the lowest-risk ABI pairing on paper. The remaining unknowns are
  outside the bridge: the microkernel/libsrv_init options and SGXMKIF layouts against this KM, and the glibc→musl
  loader question. Nothing here is verified at runtime.
- **Path C, Linux 1.9 UM:** the bridge ABI matches 1.9.2253347, but it needs the vendor omapdrm plugin ioctl (or an
  `LD_PRELOAD` shim for `drmOpen`/`drmCommandWriteRead(…,2,…)`), and letux has no buildable 1.9.2253347 tree for OMAP4.

## Appendix A — full bridge index table (computed; stock column from vmlinux registrations)

Configs:
- `1.14/1.17 +DMABUF` = `-DSUPPORT_DMABUF`.
- No PDUMP, no ION, no `OVERLAY_ROTATE_BLIT`.
- `TRANSFER_QUEUE` defined.
- `SGX540` (no 2D hardware).
- PDUMP rows are omitted.

| bridge cmd | stock 1.8@785978 (vmlinux) | AOSP steelhead src | letux 1.8.869593 | letux 1.9.2188537 | 1.9.2253347 | letux 1.10.2359475 | 1.14.3699939 +DMABUF | 1.17 b618 +DMABUF | 1.17 b72 ABI=1.17 | 1.17 b72 ABI=1.7 |
|---|---|---|---|---|---|---|---|---|---|---|
| UM_KM_COMPAT_CHECK | – | – | – | – | – | – | 0 | 0 | 0 | – |
| ENUM_DEVICES | 0 | 0 | 0 | 0 | 0 | 0 | 1 | 1 | 1 | 0 |
| ACQUIRE_DEVICEINFO | 1 | 1 | 1 | 1 | 1 | 1 | 2 | 2 | 2 | 1 |
| RELEASE_DEVICEINFO | 2 | 2 | 2 | 2 | 2 | 2 | 3 | 3 | 3 | 2 |
| CREATE_DEVMEMCONTEXT | 3 | 3 | 3 | 3 | 3 | 3 | 4 | 4 | 4 | 3 |
| DESTROY_DEVMEMCONTEXT | 4 | 4 | 4 | 4 | 4 | 4 | 5 | 5 | 5 | 4 |
| GET_DEVMEM_HEAPINFO | 5 | 5 | 5 | 5 | 5 | 5 | 6 | 6 | 6 | 5 |
| ALLOC_DEVICEMEM | 6 | 6 | 6 | 6 | 6 | 6 | 7 | 7 | 7 | 6 |
| FREE_DEVICEMEM | 7 | 7 | 7 | 7 | 7 | 7 | 8 | 8 | 8 | 7 |
| GETFREE_DEVICEMEM | 8 | 8 | 8 | 8 | 8 | 8 | 9 | 9 | 9 | 8 |
| CREATE_COMMANDQUEUE | 9 | 9 | 9 | 9 | 9 | 9 | 10 | 10 | 10 | 9 |
| DESTROY_COMMANDQUEUE | 10 | 10 | 10 | 10 | 10 | 10 | 11 | 11 | 11 | 10 |
| MHANDLE_TO_MMAP_DATA | 11 | 11 | 11 | 11 | 11 | 11 | 12 | 12 | 12 | 11 |
| CONNECT_SERVICES | 12 | 12 | 12 | 12 | 12 | 12 | 13 | 13 | 13 | 12 |
| DISCONNECT_SERVICES | 13 | 13 | 13 | 13 | 13 | 13 | 14 | 14 | 14 | 13 |
| WRAP_DEVICE_MEM | 14 | 14 | 14 | 14 | 14 | 14 | 15 | 15 | 15 | 14 |
| GET_DEVICEMEMINFO | 15 | 15 | 15 | 15 | 15 | 15 | 16 | 16 | 16 | 15 |
| RESERVE_DEV_VIRTMEM | 16 | 16 | 16 | 16 | 16 | 16 | 17 | 17 | 17 | 16 |
| FREE_DEV_VIRTMEM | 17 | 17 | 17 | 17 | 17 | 17 | 18 | 18 | 18 | 17 |
| MAP_EXT_MEMORY | 18 | 18 | 18 | 18 | 18 | 18 | 19 | 19 | 19 | 18 |
| UNMAP_EXT_MEMORY | 19 | 19 | 19 | 19 | 19 | 19 | 20 | 20 | 20 | 19 |
| MAP_DEV_MEMORY | 20 | 20 | 20 | 20 | 20 | 20 | 21 | 21 | 21 | 20 |
| UNMAP_DEV_MEMORY | 21 | 21 | 21 | 21 | 21 | 21 | 22 | 22 | 22 | 21 |
| MAP_MEM_INFO_TO_USER | 24 | 24 | 24 | 24 | 24 | 24 | 23 | 23 | 23 | 24 |
| UNMAP_MEM_INFO_FROM_USER | 25 | 25 | 25 | 25 | 25 | 25 | 24 | 24 | 24 | 25 |
| EXPORT_DEVICEMEM | 26 | 26 | 26 | 26 | 26 | 26 | 25 | 25 | 25 | 26 |
| RELEASE_MMAP_DATA | 27 | 27 | 27 | 27 | 27 | 27 | 26 | 26 | 26 | 27 |
| CHG_DEV_MEM_ATTRIBS | 28 | 28 | 28 | 28 | 28 | 28 | 27 | 27 | 27 | 28 |
| MAP_DEV_MEMORY_2 | 29 | 29 | 29 | 29 | 29 | 29 | 28 | 28 | 28 | 29 |
| EXPORT_DEVICEMEM_2 | 30 | 30 | 30 | 30 | 30 | 30 | 29 | 29 | 29 | 30 |
| MAP_DMABUF | – | – | – | – | – | – | 30 | 30 | 30 | – |
| REMAP_TO_DEV | – | – | 31 | – | 31 | – | – | – | – | – |
| UNMAP_DMABUF | – | – | – | – | – | – | 31 | 31 | 31 | – |
| PROCESS_SIMISR_EVENT | 31 | 31 | 41 | 31 | 35 | 31 | 32 | 32 | 32 | 31 |
| UNMAP_FROM_DEV | – | – | 32 | – | 32 | – | – | – | – | – |
| REGISTER_SIM_PROCESS | 32 | 32 | 42 | 32 | 36 | 32 | 33 | 33 | 33 | 32 |
| MULTI_MANAGE_DEV_MEM | – | – | 33 | – | – | – | – | – | – | – |
| UNREGISTER_SIM_PROCESS | 33 | 33 | 43 | 33 | 37 | 33 | 34 | 34 | 34 | 33 |
| CORE_CMD_RESERVED_1 | – | – | 34 | – | – | – | – | – | – | – |
| MAPPHYSTOUSERSPACE | 34 | 34 | 44 | 34 | 38 | 34 | 35 | 35 | 35 | 34 |
| CORE_CMD_RESERVED_2 | – | – | 35 | – | – | – | – | – | – | – |
| UNMAPPHYSTOUSERSPACE | 35 | 35 | 45 | 35 | 39 | 35 | 36 | 36 | 36 | 35 |
| CORE_CMD_RESERVED_3 | – | – | 36 | – | – | – | – | – | – | – |
| GETPHYSTOUSERSPACEMAP | 36 | 36 | 46 | 36 | 40 | 36 | 37 | 37 | 37 | 36 |
| CORE_CMD_RESERVED_4 | – | – | 37 | – | – | – | – | – | – | – |
| GET_FB_STATS | 37 | 37 | 47 | 37 | 41 | 37 | 38 | 38 | 38 | 37 |
| CORE_CMD_RESERVED_5 | – | – | 38 | – | – | – | – | – | – | – |
| GET_MISC_INFO | 38 | 38 | 48 | 38 | 42 | 38 | 39 | 39 | 39 | 38 |
| CORE_CMD_RESERVED_6 | – | – | 39 | – | – | – | – | – | – | – |
| RELEASE_MISC_INFO | 39 | 39 | 49 | 39 | 43 | 39 | 40 | 40 | 40 | 39 |
| CORE_CMD_RESERVED_7 | – | – | 40 | – | – | – | – | – | – | – |
| GET_OEMJTABLE | 40 | 40 | 50 | 40 | 44 | 40 | 41 | 41 | 41 | 40 |
| MAP_DEVICECLASS_MEMORY | 22 | 22 | 22 | 22 | 22 | 22 | 42 | 42 | 42 | 22 |
| UNMAP_DEVICECLASS_MEMORY | 23 | 23 | 23 | 23 | 23 | 23 | 43 | 43 | 43 | 23 |
| ENUM_CLASS | 41 | 41 | 51 | 41 | 45 | 41 | 44 | 44 | 44 | 41 |
| OPEN_DISPCLASS_DEVICE | 42 | 42 | 52 | 42 | 46 | 42 | 45 | 45 | 45 | 42 |
| CLOSE_DISPCLASS_DEVICE | 43 | 43 | 53 | 43 | 47 | 43 | 46 | 46 | 46 | 43 |
| ENUM_DISPCLASS_FORMATS | 44 | 44 | 54 | 44 | 48 | 44 | 47 | 47 | 47 | 44 |
| ENUM_DISPCLASS_DIMS | 45 | 45 | 55 | 45 | 49 | 45 | 48 | 48 | 48 | 45 |
| GET_DISPCLASS_SYSBUFFER | 46 | 46 | 56 | 46 | 50 | 46 | 49 | 49 | 49 | 46 |
| GET_DISPCLASS_INFO | 47 | 47 | 57 | 47 | 51 | 47 | 50 | 50 | 50 | 47 |
| CREATE_DISPCLASS_SWAPCHAIN | 48 | 48 | 58 | 48 | 52 | 48 | 51 | 51 | 51 | 48 |
| DESTROY_DISPCLASS_SWAPCHAIN | 49 | 49 | 59 | 49 | 53 | 49 | 52 | 52 | 52 | 49 |
| SET_DISPCLASS_DSTRECT | 50 | 50 | 60 | 50 | 54 | 50 | 53 | 53 | 53 | 50 |
| SET_DISPCLASS_SRCRECT | 51 | 51 | 61 | 51 | 55 | 51 | 54 | 54 | 54 | 51 |
| SET_DISPCLASS_DSTCOLOURKEY | 52 | 52 | 62 | 52 | 56 | 52 | 55 | 55 | 55 | 52 |
| SET_DISPCLASS_SRCCOLOURKEY | 53 | 53 | 63 | 53 | 57 | 53 | 56 | 56 | 56 | 53 |
| GET_DISPCLASS_BUFFERS | 54 | 54 | 64 | 54 | 58 | 54 | 57 | 57 | 57 | 54 |
| SWAP_DISPCLASS_TO_BUFFER | 55 | 55 | 65 | 55 | 59 | 55 | 58 | 58 | 58 | 55 |
| SWAP_DISPCLASS_TO_BUFFER2 | 56 | 56 | 66 | 56 | 60 | 56 | 59 | 59 | 59 | – |
| SWAP_DISPCLASS_TO_SYSTEM | 57 | 57 | 67 | 57 | 61 | 57 | 60 | 60 | 60 | 56 |
| OPEN_BUFFERCLASS_DEVICE | 58 | 58 | 68 | 58 | 62 | 58 | 61 | 61 | 61 | 57 |
| CLOSE_BUFFERCLASS_DEVICE | 59 | 59 | 69 | 59 | 63 | 59 | 62 | 62 | 62 | 58 |
| GET_BUFFERCLASS_INFO | 60 | 60 | 70 | 60 | 64 | 60 | 63 | 63 | 63 | 59 |
| GET_BUFFERCLASS_BUFFER | 61 | 61 | 71 | 61 | 65 | 61 | 64 | 64 | 64 | 60 |
| WRAP_EXT_MEMORY | 62 | 62 | 72 | 62 | 66 | 62 | 65 | 65 | 65 | 61 |
| UNWRAP_EXT_MEMORY | 63 | 63 | 73 | 63 | 67 | 63 | 66 | 66 | 66 | 62 |
| ALLOC_SHARED_SYS_MEM | 64 | 64 | 74 | 64 | 68 | 64 | 67 | 67 | 67 | 63 |
| FREE_SHARED_SYS_MEM | 65 | 65 | 75 | 65 | 69 | 65 | 68 | 68 | 68 | 64 |
| MAP_MEMINFO_MEM | 66 | 66 | 76 | 66 | 70 | 66 | 69 | 69 | 69 | 65 |
| UNMAP_MEMINFO_MEM | – | 67 | 77 | 67 | 71 | 67 | 70 | 70 | 70 | 66 |
| INITSRV_CONNECT | 69 | 69 | 78 | 68 | 72 | 68 | 71 | 71 | 71 | 67 |
| INITSRV_DISCONNECT | 70 | 70 | 79 | 69 | 73 | 69 | 72 | 72 | 72 | 68 |
| EVENT_OBJECT_WAIT | 71 | 71 | 80 | 70 | 74 | 70 | 73 | 73 | 73 | 69 |
| EVENT_OBJECT_OPEN | 72 | 72 | 81 | 71 | 75 | 71 | 74 | 74 | 74 | 70 |
| EVENT_OBJECT_CLOSE | 73 | 73 | 82 | 72 | 76 | 72 | 75 | 75 | 75 | 71 |
| CREATE_SYNC_INFO_MOD_OBJ | 74 | 74 | 83 | 73 | 77 | 73 | 76 | 76 | 76 | 72 |
| DESTROY_SYNC_INFO_MOD_OBJ | 75 | 75 | 84 | 74 | 78 | 74 | 77 | 77 | 77 | 73 |
| MODIFY_PENDING_SYNC_OPS | 76 | 76 | 85 | 75 | 79 | 75 | 78 | 78 | 78 | 74 |
| MODIFY_COMPLETE_SYNC_OPS | 77 | 77 | 86 | 76 | 80 | 76 | 79 | 79 | 79 | 75 |
| SYNC_OPS_TAKE_TOKEN | 78 | 78 | 87 | 77 | 81 | 77 | 80 | 80 | 80 | 76 |
| SYNC_OPS_FLUSH_TO_TOKEN | 79 | 79 | 88 | 78 | 82 | 78 | 81 | 81 | 81 | 77 |
| SYNC_OPS_FLUSH_TO_MOD_OBJ | 80 | 80 | 89 | 79 | 83 | 79 | 82 | 82 | 82 | 78 |
| SYNC_OPS_FLUSH_TO_DELTA | 81 | 81 | 90 | 80 | 84 | 80 | 83 | 83 | 83 | 79 |
| ALLOC_SYNC_INFO | 82 | 82 | 91 | 81 | 85 | 81 | 84 | 84 | 84 | 80 |
| FREE_SYNC_INFO | 83 | 83 | 92 | 82 | 86 | 82 | 85 | 85 | 85 | 81 |
| SGX_GETCLIENTINFO | 85 | 85 | 94 | 84 | 88 | 84 | 87 | 87 | 87 | 83 |
| SGX_RELEASECLIENTINFO | 86 | 86 | 95 | 85 | 89 | 85 | 88 | 88 | 88 | 84 |
| SGX_GETINTERNALDEVINFO | 87 | 87 | 96 | 86 | 90 | 86 | 89 | 89 | 89 | 85 |
| SGX_DOKICK | 88 | 88 | 97 | 87 | 91 | 87 | 90 | 90 | 90 | 86 |
| SGX_GETPHYSPAGEADDR | 89 | 89 | 98 | 88 | 92 | 88 | 91 | 91 | 91 | 87 |
| SGX_READREGISTRYDWORD | 90 | 90 | 99 | 89 | 93 | 89 | 92 | 92 | 92 | 88 |
| SGX_2DQUERYBLTSCOMPLETE | 94 | 94 | 103 | 93 | 97 | 93 | 96 | 96 | 96 | 92 |
| SGX_SUBMITTRANSFER | 98 | 98 | 107 | 97 | 101 | 97 | 100 | 100 | 100 | 96 |
| SGX_GETMISCINFO | 99 | 99 | 108 | 98 | 102 | 98 | 101 | 101 | 101 | 97 |
| SGXINFO_FOR_SRVINIT | 100 | 100 | 109 | 99 | 103 | 99 | 102 | 102 | 102 | 98 |
| SGX_DEVINITPART2 | 101 | 101 | 110 | 100 | 104 | 100 | 103 | 103 | 103 | 99 |
| SGX_FINDSHAREDPBDESC | 102 | 102 | 111 | 101 | 105 | 101 | 104 | 104 | 104 | 100 |
| SGX_UNREFSHAREDPBDESC | 103 | 103 | 112 | 102 | 106 | 102 | 105 | 105 | 105 | 101 |
| SGX_ADDSHAREDPBDESC | 104 | 104 | 113 | 103 | 107 | 103 | 106 | 106 | 106 | 102 |
| SGX_REGISTER_HW_RENDER_CONTEXT | 105 | 105 | 114 | 104 | 108 | 104 | 107 | 107 | 107 | 103 |
| SGX_FLUSH_HW_RENDER_TARGET | 106 | 106 | 115 | 105 | 109 | 105 | 108 | 108 | 108 | 104 |
| SGX_UNREGISTER_HW_RENDER_CONTEXT | 107 | 107 | 116 | 106 | 110 | 106 | 109 | 109 | 109 | 105 |
| SGX_REGISTER_HW_TRANSFER_CONTEXT | 111 | 111 | 120 | 110 | 114 | 110 | 113 | 113 | 113 | 109 |
| SGX_UNREGISTER_HW_TRANSFER_CONTEXT | 112 | 112 | 121 | 111 | 115 | 111 | 114 | 114 | 114 | 110 |
| SGX_SCHEDULE_PROCESS_QUEUES | 113 | 113 | 122 | 112 | 116 | 112 | 115 | 115 | 115 | 111 |
| SGX_READ_HWPERF_CB | 115 | 115 | 123 | 113 | 117 | 113 | 116 | 116 | 116 | 112 |
| SGX_SET_RENDER_CONTEXT_PRIORITY | – | – | 124 | 114 | 118 | 114 | 117 | 117 | 117 | 113 |
| SGX_SET_TRANSFER_CONTEXT_PRIORITY | – | – | 125 | 115 | 119 | 115 | 118 | 118 | 118 | 114 |
| GETMMU_PD_DEVPADDR | 68 | 68 | – | – | – | – | – | – | – | – |
| IMPORT_GEM | – | – | – | – | 33 | – | – | – | – | – |
| SGX_GETMMUPDADDR | 95 | 95 | – | – | – | – | – | – | – | – |
| SGX_CMD_BASE | 85 | 85 | 94 | 84 | 88 | 84 | 87 | 87 | 87 | 83 |

## Open questions

1. **RESOLVED 2026-10-11:** `drivers/gpu/pvr/sgxfeaturedefs.h:234-235` @ `03a9286b` derives it from
   `SUPPORT_SGX_LOW_LATENCY_SCHEDULING`; the letux trees do the same. Original question: where the steelhead build
   gets `SUPPORT_SGX_PRIORITY_SCHEDULING` (bit 20). It is not in the fetched
   `Makefile`/`Kconfig`/defconfig lines, yet it is present in vmlinux `0x36801C`. The answer decides the exact flag list
   for a port; grep the full steelhead tree (`sgxapi_km.h`, `config_kernel.h`, `omap4/` sysconfig).
2. Whether the TI 1.17 UM's exact `SGXConnectionCheck` really runs against KM-reported `DRIVER_SGXREV` options in every
   client (eRequest 3 in the 2020 build @ `0x7dd4`). That is, does b72's mask alone suffice, or must the KM report
   `0x360018`? Needs a runtime trace (`PVR_K` log) on hardware. *(Largely moot after the 2026-10-11 correction: the
   letux 1.17 KM is computed to report exactly `0x360018`. Still confirm on hardware.)*
3. Microkernel/SGXMKIF layouts: the KM's own `sizeof(SGXMKIF_*)` is never checked against the microkernel. Stock
   libsrv_init writes a size table @ `0x9c4..0xa30` (552, 552, 552, 152, 60, 68, 60, 68, 92, 252, 68…). The field
   mapping is not yet resolved; resolve it against the AOSP `sgxinfo.h` order and compare with any candidate KM.
4. The 0x360b14 movw/movt constant in leste-2024 `SGXDevInitPart2` @ `0x8430` is unexplained. Its own
   `SGXConnectionCheck` uses `0x360018`.
5. Which UM pairs with letux `1.8.869593` (Kconfig says "OMAP4430, 4460, 4470, OMAP5")? None of the 13 UM builds
   examined matches its id table. Find its TI source package.
6. Android 1.8@905891 has the 1.9.2188537 id layout but a 1.8.18 version word. Its KM source (AOSP tuna/panda JB) was not
   fetched; it is a reference only.
7. The `GETCLIENTINFO` out size in 1.8 UMs is not a constant at the call site; read it from the AOSP `sgx_bridge.h`.

## Sources

- Stock: `reverse-eng/vmlinux.bin` (sha256 prefix `089f4c90b8a61ca7`).
  - Symbols: `CommonBridgeInit` `c028d7dc`, `SetSGXDispatchTableEntry` `c0292afc`, `_SetDispatchTableEntry` `c028d6e0`,
    `g_BridgeDispatchTable` `c07840e4`, `BridgedDispatchKM` `c028e1c8`, `PVRSRV_BridgeDispatchKM` `c0277158`,
    `SGXDevInitCompatCheck` `c0292f1c`.
  - Disassembly in `re/stock-*.dis`, tables in `re/stock-dispatch*.tsv`.
- Stock UM: `reverse-eng/factory/tungsten-ian67k/system.raw.img` via `debugfs dump` → `re/stock-blobs-03/`.
- AOSP: `https://android.googlesource.com/kernel/omap/+/03a9286bb61a9acd28027206c4937990ac817f1b/drivers/gpu/pvr/`
  (`pvr_bridge.h`, `sgx_bridge.h`, `pvrversion.h`, `sgx_options.h`, `Makefile`, `Kconfig`, `bridged_pvr_bridge.c`,
  `sgx/sgxinit.c`) and `…/arch/arm/configs/steelhead_defconfig`; branch head from
  `git ls-remote https://android.googlesource.com/kernel/omap` (`refs/heads/android-omap-steelhead-3.0-ics-aah`).
- letux: `https://github.com/openpvrsgx-devgroup/linux_openpvrsgx` branches `pvrsrvkm-6.18-rc6` @ `d2f1e031d58a`
  and `pvrsrvkm-7.2` @ `2342ce92fdde`, `drivers/gpu/drm/pvrsgx/{Kconfig,Makefile,pvr-drv.c,pvr-drv.h,<ver>/…}`.
- TI KM: `https://git.ti.com/git/graphics/omap5-sgx-ddk-linux.git` tag `TI_LINUX_OMAP_SGX_DDK_1.9_2253347`
  (`6668f4ea0bbf`) and branch `ti-img-sgx/1.17.4948957/k6.1` (`bfd9edef3f97`).
- TI UM: `https://git.ti.com/git/graphics/omap5-sgx-ddk-um-linux.git`:
  - `master` (`b6801bf89e00`);
  - `1.17.4948957-next` (`742cf38aba13`);
  - `ti-img-sgx/kirkstone-ws/1.17.4948957` (`76251c0a88c1`);
  - `ti-img-sgx/1.14.3699939` (`bbbd5cb557ff`).
- maemo-leste: `https://github.com/maemo-leste/pvr-omap4` @ `46e9839510a3` and
  `https://github.com/maemo-leste/sgx-ddk-um` @ `6fb7fa24d8aa`.
- Android JB/ICS vendor blobs (imgtec maguro/panda tarballs in `re-downloads/imgtec-*`, fetched by a sibling
  workstream; identified here only by content hashes and GLES version strings).
- Linux 6.18.48: `include/uapi/drm/omap_drm.h:107-113` (no `DRM_OMAP_GET_BASE`) and `drivers/gpu/drm/drm_ioctl.c:855-861`.


## Verification (2026-10-11)

This is an adversarial re-check by a separate reviewer. Everything was re-derived from the raw files, not from this
report's own tables. Methods:
- Stock KM: `arm-none-eabi-objdump -D -b binary -marm --adjust-vma=0xc0008000` on `reverse-eng/vmlinux.bin`.
  Symbol addresses come from `reverse-eng/tools/kallsyms.txt`.
- UM ioctl constants: an independent scanner, `re/verify03/ioscan.py`, which looks for literal words plus ARM and
  Thumb-2 movw/movt pairs inside dynsym FUNC ranges. It does not reuse `um_ioctls.py`.
- Build options: re-preprocessed with the real include order (`re/verify03/bo.c`).
- AOSP files were re-fetched into `re-downloads/verify03-aosp/`, and Linux v6.18.48 headers into
  `re-downloads/verify03-linux/`.
- Nothing was executed from the download dirs.

| # | Claim | Verdict | Evidence from this pass |
|---|---|---|---|
| 1 | `_IOWR('g',i,pkg)` = `0xC01C6700+i`; KM takes `_IOC_NR` after a full compare with CONNECT_SERVICES | **confirmed** | vmlinux `c02771b8: movw r3,#0x670c` / `c02771bc: movt r3,#0xc01c` / `cmp r4,r3`. `c02771f8: ldrb r1,[fp,#-56]` keeps the low byte (= `_IOC_NR`). Full compares against `0xC01C671D`/`0xC01C671E` follow @ `c02771fc`/`c0277210`. Literal `0xC0xx67xx` words in stock libsrv_um have size field 28 (87 hits); the other values are non-ioctl noise. |
| 2 | `BridgedDispatchKM` checks only In/Out size ≤ 0x1000 and id ≤ 121 | **confirmed, with the consequence softened** | `c028e208 cmp r2,#0x1000` (`[r4,#12]` = InBufferSize), `c028e218 cmp r3,#0x1000` (`[r4,#20]` = OutBufferSize), `c028e228 cmp r6,#0x79`. Table base `0xc0784064+0x80` = `g_BridgeDispatchTable` `c07840e4`; the fill loop @ `c028de70` covers `0x1e8`/4 = 122 slots. The AOSP preprocessed `SGX_CMD_LAST` = 121 agrees. "Corrupts memory silently" was overreach and is reworded in TL;DR 1: copies stay inside the 4 KiB buffers, and the outcome depends on the command. The `[r4,#12]`/`[r4,#20]` offsets independently confirm the ≤1.14 package order on the KM side. |
| 3 | stock UM 41/41 only vs stock KM; letux 1.9.2188537/1.10 21/41; 1.8.869593 8/41 | **confirmed** | Own scanner + scoring (`verify03/score.py`) gives the same numbers: stock 41/41, AOSP 41/41, 1.9.2188537 21, 1.10 21, 1.8.869593 8, 1.9.2253347 8. Spot anchors: GetMiscInfo 38, EnumerateDeviceClass 41, InitSrvConnect 69, AllocSyncInfo 82, SGXGetClientInfo 85, SGXGetMiscInfo 99, SGXGetInfoForSrvInit 100, SGXDevInitPart2 101, SGXReadHWPerfCB 115 — all equal the vmlinux registrations in `stock-dispatch*.tsv`. |
| 4 | AOSP `android-omap-steelhead-3.0-ics-aah` @ `03a9286b…` is the stock KM source | **confirmed (version match), one detail corrected** | `git ls-remote` (re-run) → `03a9286bb61a9acd28027206c4937990ac817f1b refs/heads/android-omap-steelhead-3.0-ics-aah`. The re-fetched `pvrversion.h` is byte-identical to the stored copy: MAJ 1, MIN 8, BRANCH 18, BUILD 785978. The vmlinux string @ `0xc0680738` = `CustomerGoogle_Android_ogles1_ogles2_GPL sgxddk 18 1.8@785978`. **Correction:** `UNMAP_MEMINFO_MEM` is unregistered in the source too (`bridged_pvr_bridge.c:4730` registers only MAP), so the registered tables are identical — this is not a difference. Caveat: the head commit is not proven to be the exact commit IAN67K was built from (UNVERIFIED). The DDK version and dispatch table match. |
| 5 | letux 1.8.869593 has core ids 31-40 extra and lacks GETMMU_PD_DEVPADDR / SGX_GETMMUPDADDR; SGX base 94 vs 85 | **confirmed** | `km-b72/.../1.8.869593/eurasia_km/services4/include/pvr_bridge.h:91-101` (REMAP_TO_DEV +31 … CORE_CMD_RESERVED_7 +40, CORE_CMD_LAST +40); line 202→204 has no SERVICES4_TMP block; `ids/km-1.8.869593.tsv` SGX_GETCLIENTINFO 94. |
| 6 | stock KM and UM: options `0x0036801C`, DDK `0x00010812`/785978 | **confirmed** | vmlinux `c0292f58/5c movw #0x801c; movt #0x36`, again @ `c0293364`. `c0292ff4/8` = `0x10812`; `c0293028/2c` = `0xfe3a`/`0xb` = 785978, then `cmp ip,r3`; `c029309c` = `0x10101`. libsrv_um words: `0x9fb4`=`0x36801c`, `0x9fc8`=`0x10812`, `0x9fcc`=`0xbfe3a`, `0xb0d0`=`0x36801c`. libsrv_init: `0x1774` and `0x3364` = `0x36801c`. The bit decomposition agrees with AOSP `sgx_options.h:45-209`. |
| 7 | letux KMs produce `0x00260018`; none satisfies the stock UM, which needs bits 2, 15 and 20 | **REFUTED (value); conclusion partly stands** | `buildopts.py` preprocessed `sgx_options.h` alone. The real TUs include `sgxdefs.h`→`sgxfeaturedefs.h` first: 1.17 `sgxinit.c:44` then `:65`; 1.8.869593 `:29` then `:50`. `sgxfeaturedefs.h` (1.17 `:282-284`, 1.8.869593 `:241-244`, AOSP `:234-235`) defines `SUPPORT_SGX_PRIORITY_SCHEDULING` whenever `SUPPORT_SGX_LOW_LATENCY_SCHEDULING` is set, and every letux Makefile sets it (line 122). Re-preprocessed: 1.17 → **`0x00360018`** (mask `0xffc5fc86`); 1.8.869593 → **`0x00360018`**; `sgx_options.h` alone reproduces the wrong `0x260018`. The stock UM therefore lacks only **bits 2 and 15** from any letux KM. "None satisfies the stock UM" remains true. |
| 8 | TI 1.17 ti443x UM options `0x00360018`, exact compare | **confirmed** | 2020 build `7dde bl SGXGetMiscInfo` (eRequest 3 @ `7dda`), `7de8 movs r3,#24; 7dea movt r3,#0x36; 7dee cmp r5,r3`. Any mismatch → `r4=26` (`7e0e`/`7e20`). The leste build `88c8 bic.w r0,r5,#0x360000; 88cc bic.w r0,r0,#0x18`. Both builds are hard-float (`Tag_ABI_VFP_args: VFP registers`). |
| 9 | b72 mask `0xffc5fc86`; b618 exact compare fails on bit 20 unless PRIORITY_SCHEDULING is defined | **mask and compare code confirmed; failure conclusion REFUTED** | b618 `sgxinit.c:2713-2714` `if (ui32BuildOptions != psDevInfo->ui32ClientBuildOptions)`; b72 `:2720`, `:2847` masked; mask re-preprocessed = `0xffc5fc86`. PRIORITY_SCHEDULING *is* defined, implicitly, so the KM reports `0x360018` = UM, and b618 passes as configured (see 7). TL;DR 3, §5, §7 and §8 Path B are corrected. |
| 10 | 1.17 package swaps offsets 12/16; 1.17 IN structs drop `ui32BridgeFlags` | **confirmed** (evidence attribution fixed) | leste `libsrv_um` (`6bdfe93a…`): words @ `0x9de8..0x9df4` = `0xc01c670d, 0x1c, 0x4, 0x10`, stored @ `sp+24/+40`; `&in` @ `sp+32`, `&out` @ `sp+36`; `9d38 blx drmCommandWrite` with `r1=0`, `r3=28`. In the 2020 build those offsets are code. Its helper @ `0x8f94` lays out `[sp+12]=pIn, [sp+16]=pOut, [sp+20]=inSize` → the same 1.17 order. The 1.9 UM `PVRSRVBridgeCall` @ `0x9759` (DWARF) uses `r5=28` @ `0x9762`. |
| 11 | 1.17 UM opens render node 128-143, name "pvr", `drmCommandWrite` cmd 0 | **confirmed** | `_PVRDRMOpenRender` @ `0xa690`: `movs r6,#128`, `movs r7,#143`, `drmOpenRender`, `drmGetVersion`, `ldr r0,[r0,#16]` (version→name), `strcmp` with a PC-relative string resolving to file offset `0x1ca3c` = `"pvr\0"`; fallback `"/dev/dri"` @ `0x1ca1c`. letux `pvr-drv.h:28 DRM_PVR_SRVKM 0x0`, `:31 DRM_PVR_IS_MASTER 0x3`; `pvr-drv.c:199 DRIVER_RENDER`, `:205 .name = "pvr"`; TI k6.1 `pvr_drm.c:630 .name = "pvr"`. |
| 12 | 1.17 UM ids 35/35 vs letux 1.17+DMABUF; 102/103 sizes; one FREE_DEVICEMEM out 8 vs 4 | **confirmed** | Own scanner: 35/35 vs `km-1.17-b618-dmabuf`, 8/35 without DMABUF. Call sites in the 2020 build: `0x68f0` (`PVRSRVFreeDeviceMem`) `id 0xC01C6708`, in=8, out=`r2=4` (set @ `0x68d4`); `0x4c8e` id 8, in=8, out=8. KM `sizes/km-1.17-b618-dmabuf.tsv` `PVRSRV_BRIDGE_OUT_FREEDEVICEMEM 4`. The 102/103 total was not re-derived site by site. |
| 13 | ≥1.13 UM_KM_COMPAT_CHECK carries `0x00011100`/4948957 | **confirmed** | 2020 build `PVRSRVInitSrvConnect` @ `0x5c40`: `5c54 mov.w r2,#0x1100; 5c5c movt r2,#1; 5c60 movw r3,#0x83dd; 5c64 movt r3,#0x4b` (=4948957); `5c72/78` id `0xC01C6700`, size 8. KM `common/pvrsrv.c` `PVRSRVCompatCheckKM` compares `MAJ<<16 \| MIN<<8` and `PVRVERSION_BUILD`. These addresses belong to the 2020 build; the leste build has `PVRSRVInitSrvConnect` @ `0x5f48`. |
| 14 | ≤1.12 KM checks microkernel DDK; UM checks DRIVER_SGXREV; 1.9 UM expects `0x10913`/2253347 | **confirmed** | letux 1.8.869593 `sgxinit.c:2042-2050`; stock vmlinux as in 6. Stock UM @ `0x9e9c`: eRequest 2, compares `[sp+28]` with `0x10812` and `[sp+32]` with 785978, returns 25; an options mismatch returns 26. The 1.9 UM (`pvr-omap4`, armhf) words `0x854c`=`0x68018`, `0x8550`=`0x10913`, `0x8554`=`0x226223`; the debug symbol `SGXConnectionCheck` = `0x84ab` (Thumb). TI 1.9 `pvrversion.h:55-61` = 1 / 9 / 19 / 2253347. |
| 15 | SGXMKIF CHECK_SIZE compares client (libsrv_init) against microkernel, never against KM `sizeof` | **confirmed** | `CHECK_SIZE` @ 1.8.869593 `sgxinit.c:58-66`, 1.9.2253347 `:92-100`, 1.17 `:96-104`, AOSP `:59`; `psDevInfo->sSGXStructSizes = psInitInfo->sSGXStructSizes` @ 1.8 `:178`, 1.9 `:265`, 1.17 `:255`, AOSP `:182`. |
| 16 | TI 1.9 OMAP4 UM matches 1.9.2253347 (41/41 ids, 149 sizes); options `0x68018` | **confirmed (my anchor count is 38/38)** | My scanner attributes 38 anchors, all matching `km-1.9.2253347` (zero mismatches); 7/38 vs 1.9.2188537. The difference from 41 is attribution coverage, not a mismatch. `pahole -C _PVRSRV_CLIENT_MEM_INFO_` on the debug file → size 56. TI `omap4430_linux/Makefile:189,193 SUPPORT_MEMINFO_IDS ?= 1`. The 149/149 total was not re-derived. |
| 17 | 1.9 UM needs the TI omapdrm plugin (`drmOpen("omapdrm")`, `drmCommandWriteRead(fd,2,…,72)`); 6.18 lacks ioctl 0x02; letux 1.9.2253347 has no Makefile | **confirmed** | `PVRDRMSetFD` @ `0x9659`: `__snprintf_chk(…,64,…)` with `"%s_pvr"`, then `96b6 movs r1,#2; 96ba movs r3,#72; blx drmCommandWriteRead`; `PVRDRMOpen` @ `0x9721` → `drmOpen`. Strings `omapdrm`, `PVRDRMSetFD: could not get plugin ioctl base: %d`. v6.18.48 `include/uapi/drm/omap_drm.h:107-113` (0x00, 0x01, 0x03..0x06, NUM 0x07; no 0x02). TI KM `pvr_drm.c:516 omap_drm_register_plugin`, `Makefile:203 PVRSRV_MODNAME := omapdrm_pvr`. `km-b72/.../1.9.2253347/` contains only `include4 services4` + docs (no Makefile/Kbuild). `drm_ioctl.c:855-861` re-checked: in/out size logic as described. |
| 18 | stock UM uses `/dev/pvrsrvkm` + `ioctl`; KM has chrdev + built-in OMAPLFB | **confirmed** | libsrv_um strings `/dev/pvrsrvkm`, `OpenServices: Cannot open device driver /dev/pvrsrvkm.`; UND `ioctl`, `open`; NEEDED `libc.so`, `libdl.so`, `libcutils.so`, `libhardware.so` (bionic; no `Tag_ABI_VFP_args` → softfp, as expected for ICS). vmlinux `0xc068050c` = `PVRCore_Init: major device %d`; kallsyms `c0025920 t PVRCore_Init`, `c0025af0 t OMAPLFB_Init`, `c011c258 T __register_chrdev`. |
| 19 | Android 1.8@905891 UM: 1.9.2188537/1.10 layout (41/41), DDK `0x10812`/905891, options `0x36801C` | **confirmed** | panda-20130603 libsrv_um (`394f112b…`): own scanner 41/41 vs 1.9.2188537 and 1.10, 21/41 vs stock; words `0x9f34`=`0x36801c`, `0x9f48`=`0x10812`, `0x9f4c`=`0xdd2a3` (=905891). |

**Net effect on the conclusions:**
- **Path B** (TI 1.17 ti443x UM + letux 1.17 KM) loses its one "known gap". On paper, every bridge-level check now
  passes as configured.
- **Path A** (stock UM) still needs the exact AOSP steelhead KM. Every letux KM misses option bits 2 and 15 (not
  3 bits) on top of the id, version and size mismatches.
- Nothing in this report is verified at runtime.
- No softfp/hard-float mix-up was found:
  - stock Android blobs are softfp/bionic;
  - the Linux 1.9 `pvr-omap4` and TI 1.17 builds are armhf/glibc;
  - the bridge structs are ABI-neutral 32-bit types, as TL;DR 8 says.
