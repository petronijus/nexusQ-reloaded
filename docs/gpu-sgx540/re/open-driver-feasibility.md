# SGX540 RE 6/7: feasibility of a fully open SGX540 driver (no closed blobs)

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

- **Open question 3 (the 1.8 uKernel patching scheme) is answered** by
  [firmware-microkernel.md](firmware-microkernel.md): `.rodata` 0x2074–0x1ad6c
  of stock `libsrv_init.so` is exactly four USE programs (ukernel 24 800 B,
  TA 23 104 B, SPM 21 408 B, 3D 31 088 B) plus five PDS programs
  (44/76/44/880/180 B). The `0xDEADBEEF` placeholders are present, encoded as
  split `limm` immediates (15 sites), which is why a raw word scan finds none.
- **Open question 5 (public source of the stock built-in KM) is answered** by
  [stock-android-blobs-libhybris.md](stock-android-blobs-libhybris.md) and
  [km-um-bridge-abi.md](km-um-bridge-abi.md): AOSP `kernel/omap`
  `android-omap-steelhead-3.0-ics-aah` @ `03a9286b`, version-matched
  (1.8@785978), not proven byte-identical to the shipped kernel.
- **The softfp caveat in §7 applies to the stock 1.8 blobs only.** The TI
  1.9/1.14/1.17 Linux blobs of the primary path are hard-float
  (`Tag_ABI_VFP_args: VFP registers`, [blob-abi.md](blob-abi.md) §4).
- **Open question 4 (DOKICK input layout), partly:** the stock 1.8 and JB
  1.8@905891 UMs pass 564 bytes, the 1.9@2253347 UM 660 bytes; the 1.17 size is
  not a constant at the call site ([km-um-bridge-abi.md](km-um-bridge-abi.md) §6).

---

Workstream RE-06, written 2026-10-11 (Europe/Prague). Target: PowerVR SGX540 rev 120 (Series5, USSE1)
in the TI OMAP4460 of the Google Nexus Q (steelhead), mainline Linux 6.18.48 + postmarketOS.
Nothing was built, flashed or committed, and no device was touched. All downloads are in
`<session scratch>/gpu/re-downloads/<name>-<commit>/` and were only read as data.

Evidence conventions: `file:line`, `file @ offset`, symbol + address, a URL with commit or tag,
or a command-output excerpt. Anything without evidence is marked **UNVERIFIED (reasoning)**.

---

## TL;DR

1. **There is still no open 3D driver for any Series5 SGX, and Imagination has repeatedly said it
   has no plans to help.**
   Imagination staff answered on its forum (2021-09-08, 2021-09-15, 2022-03-15, 2023-05-11) that
   it has "no official plans" to open the SGX drivers or release Series5 documentation. Mesa's
   `imagination` driver covers Rogue only. Its docs say "GPUs prior to Series6 do not have the
   hardware capabilities required to support Vulkan and therefore cannot be supported by this
   driver". The FSF effort from 2012 (`powervr.gnu.org.ve`) is gone. A leak of "2011 era PowerVR
   SGX microkernel and user space" source in 2014 makes clean-room work harder: anyone who has
   looked at it cannot contribute.
2. **The public RE state for SGX540 specifically is thin but real.**
   - *Garnet/sgx540-reversing* (Codeberg, 2022-08 to 2022-10, last commit `c15884751ad8`): a
     partial USSE ISA (register banks, repeat, predicates, branches, loads/stores), a working
     disassembler made by hijacking Imagination's own public Series5 offline compiler, a partial
     assembler, shader replacement through `LD_PRELOAD`, and dumps of the uKernel USE code
     (ukernel 22112 B, TA 21744 B, 3D 23680 B, SPM 18480 B, `pds_init` 44 B).
   - *Lucas Fryzek's fork* (2023-04 to 2023-11, `c9ce47eef5a8`): a 940-line bridge-ioctl wrapper
     (`wrap/wrap.c`) and the start of a custom userspace (`drv/drv.c`) on top of the GPL
     `pvrsrvkm`, on a CI20 (SGX540 rev 130).
   - Neither project has rendered anything independently of the blob.
3. **The newest and strongest signal is SGX535, not SGX540.** *gabrieelgama/SGX535-reMESA*
   started on 2026-09-16 (HEAD `acc60f5ff157`, 2026-10-10). On 2026-10-06 the SGX535 rev 121 of a
   Poulsbo/GMA500 rendered a **32×32 triangle with a hand-written 8-byte constant-colour fragment
   instruction**, and then a 16×16 square from two indexed triangles. Its command construction is
   "frozen", reconstructed by static RE of Intel's closed `psb_dri.so`. The Tungsten Graphics
   Poulsbo kernel driver (GPL, 2007–2009) shows that SGX535 **can be driven from the host without
   a USSE microkernel**. The kernel fires both TA and raster by writing register lists
   (`psb_reg_submit(task->ta_cmds…)` and `psb_reg_submit(task->raster_cmds…)`, `psb_schedule.c`
   l.314 and l.386). Those lists are built by the closed userspace (`psb_dri.so`). Scene binding,
   TA out-of-memory, DPM reset and TA-memory load are delegated to a closed X-server helper
   (`psb_xhw_scene_bind_fire`, `psb_xhw_ta_oom`, `psb_xhw_reset_dpm`, `psb_xhw_ta_mem_load`).
   So "no microkernel" there means the closed logic moved to the host, not that it went away.
   Whether the same holds for SGX540 is **UNVERIFIED**.
4. **The kernel half is already open; the closed parts are the uKernel microcode, the command
   formats and the ISAs.**
   - The GPL/MIT `pvrsrvkm` sources give the MMU format, 40 fixed-address control registers plus
     the 16-entry `USE_CODE_BASE` table (41 `/* Register */` blocks in `sgx540defs.h`), the CCB/uKernel host interface (32-byte `SGXMKIF_COMMAND`,
     256-entry kernel CCB, 11 command types), the build-option checks and 998 lines of uKernel
     status codes.
   - Not open: the uKernel microcode itself (USE + PDS programs, which in DDK 1.8 are embedded in
     `libsrv_init.so` `.rodata`, 103 592 B); the client command layouts (TA/3D register blocks,
     the PDS programs that drive vertex and pixel setup); and the USSE1 and PDS instruction
     encodings.
5. **The Nexus Q is an unusually good RE host.** The stock IAN67K firmware ships the complete DDK
   1.8@785978 stack: GLES1/2, EGL, `libsrv_um`, `libsrv_init`, `libusc`, `libglslcompiler` and
   `pvrsrvinit`, with the KM built into the stock kernel with symbols (365 matching names in
   `kallsyms.txt`). The compiler is a separate library with a clean exported API
   (`PVRUniFlexCompileToHw`, `GLSLCompileToUniflex`), which makes it a ready shader oracle. The
   kick path is one bridge ioctl: `SGXKickTA` → local helper → `ioctl(0xC01C6758)` with a
   564-byte input.
6. **Honest estimate** (one experienced GPU RE engineer, full-time; P50–P90):

   | Target | Effort |
   |---|---|
   | Minimal "clear + textured quad + alpha blend" engine, open userspace, closed uKernel reused as firmware | **9–19 person-months** |
   | That engine wired into Mesa so weston/wlroots can use it | **+4–8 PM** |
   | Real NIR→USSE compiler and dEQP-GLES2-grade GLES2 | **+21–42 PM** |
   | Fully open uKernel or host-driven scheduling | **+6–18 PM**, the least certain item |
   | Upstreamable DRM kernel driver | **+6–12 PM** plus review |
   | Fully open, upstream-quality GLES2 in total | **≈ 4–7 person-years** |

   At hobby pace (0.25 FTE) the minimal target alone is 3–6 calendar years.
7. **The minimal compositor target is meaningfully smaller,** at about 25–35 % of the full
   effort, because it skips the GLSL compiler and the GL state tracker. But it keeps all the fixed
   costs (command stream, parameter buffer and DPM, PDS, uKernel interplay, MMU and sync). For the
   Nexus Q a mostly static HDMI UI could get most of the compositor benefit from OMAP4 DSS overlay
   planes through KMS, with no GPU at all (**UNVERIFIED for omapdrm plane support on 6.18**;
   measure first).
8. **Recommendation:** keep the closed-blob path as primary. Treat the open driver as research,
   with these cheap, reusable first steps that also help the primary path:
   - (a) a bridge tracer for `/dev/pvrsrvkm`;
   - (b) a capture hook in our own GPL KM at `SGXDoKickKM`;
   - (c) a UniFlex/USSE shader-dump hook on `libusc`;
   - (d) offline decoding of the uKernel `.rodata` in `libsrv_init.so`.

   Do not start M2+ (see §9) unless someone commits at least one person-year.

---

## 1. Question and scope

The question is whether a **fully open** GPU stack for the SGX540 can be built, meaning no closed
EGL/GLES, `libsrv_um`, `libsrv_init` or uKernel blob, and at what cost. Sub-questions:

- the public RE state as of 2026-10;
- what Imagination's 2022+ Rogue open-sourcing does and does not give us;
- the public documents and patents;
- how other open GPU drivers started;
- what tracing tooling SGX needs and which existing code can seed it;
- an honest estimate, with a separate answer for a minimal "clear + textured quad" compositor path.

This workstream does not cover the closed-blob primary path (KM/UM version pairing,
glibc/bionic-on-musl). Other files under `docs/gpu-sgx540/` cover that.

---

## 2. What a fully open SGX540 stack has to replace

### 2.1 Component inventory and open status

| Layer | What it does | Status today | Evidence |
|---|---|---|---|
| Kernel services (`pvrsrvkm`) | Memory/MMU, bridge ioctls, kernel CCB, power, HW recovery | **Open** (GPL / dual MIT-GPLv2), out of tree; KM 1.5→1.17 branches maintained by openpvrsgx | `openpvrsgx-devgroup/linux_openpvrsgx` branches `letux/pvrsrvkm-1.5.15.3226` … `letux/pvrsrvkm-1.17`; `sgx540defs.h` header: "@License Dual MIT/GPLv2" (branch `letux/pvrsrvkm-1.17` @ `e521fd7b65b0`) |
| SoC glue (OMAP4) | ti-sysc target module, clocks, PRM | Open (openpvrsgx `letux/omap-pvr-soc-glue-v10`); mainline has the DT binding since 6.9 | `Documentation/devicetree/bindings/gpu/img,powervr-sgx.yaml` @ v6.18: `ti,omap4430-gpu # Rev 120` + `img,powervr-sgx540`; `omap4.dtsi` @ v6.18 lines 504–508: `gpu@0 { reg = <0x0 0x2000000>; interrupts = <GIC_SPI 21 …>` under the target module at 0x56000000 |
| **uKernel ("Micro Kernel")** | Runs on the USSE as "EDM" threads; schedules TA/3D/SPM, handles GPU-internal events, power, context switches | **Closed microcode.** In DDK 1.8 it is embedded in `libsrv_init.so` and loaded by `pvrsrvinit` | Stock `libsrv_init.so` strings: `SetupuKernel : Failed to allocate 0x%x bytes for %s USE program`, `LoaduKernelPDSInitPrograms …`, `SGX TA`, `SGX SPM`, `SGX 3D`; `.rodata` size `0x194a8` = 103 592 B with only ≈2.0–2.5 KB of strings (1 975 B with `strings -n 6`, 2 479 B / 137 strings with `strings -n 4`, on the objcopy'd section) |
| uKernel host interface | Kernel CCB, host control, kick addresses, init scripts | **Open** (KM headers) | `sgx_mkif_km.h:70-75` `SGXMKIF_COMMAND {ui32ServiceAddress; ui32CacheControl; ui32Data[6];}` (32 B); `:84` `asCommands[256]`; `sgxinfo.h:63-80` command types TA=0 … FLUSHPDCACHE=10, MAX=11; `sgxinfo.h:94` `aui32HostKickAddr[SGXMKIF_CMD_MAX]`; `include4/sgxscript.h` (108 lines) |
| Client command formats | TA/3D register blocks per kick (`SGXMKIF_CMDTA`), render targets, parameter buffer (PB) / DPM setup, transfer-queue blits | **Closed** (built by `libsrv_um`); only the `_SHARED` sync part is in the KM | `sgx_mkif_km.h:163-192` `SGXMKIF_CMDTA_SHARED`. In `libsrv_um.so` the builders are large: `SGXKickTA` 0xe674 (4396 B), `SGXAddRenderTarget` 0x109c4 (5720 B), `SGXCreateRenderContext` 0xfea0 (1900 B) |
| PDS programs | Data-master programs that allocate USSE resources, DMA attributes/uniforms, kick USSE tasks | **Closed** encoding, generated by the GLES lib and the uKernel loader | SGX535-reMESA `SGX535-reMESA:docs/usse.md`: `PDS_EXEC_BASE` 0x0ab8, "This does not document PDS instructions"; Garnet `ukernel/README` |
| USSE1 shader ISA | 64-bit instructions on 4 USE pipes (SGX540) | **Closed**, partially RE'd | `sgxfeaturedefs.h:89-96`: `SGX_FEATURE_NUM_USE_PIPES (4)`, `ADDRESS_SPACE_SIZE (28)`; Garnet `info/ISA.md` |
| Shader compiler | GLSL ES → UniFlex IR → USSE | Closed (`libglslcompiler.so` + `libusc.so`) | Exported APIs in §5.2 |
| GLES/EGL state tracker | GL state → TA/ISP/TSP/PBE state words | Closed | `libGLESv2_POWERVR_SGX540_120.so` (372 324 B), string `OpenGL ES 2.0 build 1.8@785978` |
| DRI/GBM/Wayland glue | — | Open-ish wrappers around the closed GL (mobiaqua `mesa-sgx`, Ivaylo Dimitrov's PVR DRI driver, which is RE of the DRI shim only, **not** of the GPU) | openpvrsgx list, 2021-10-30, Ivaylo Dimitrov: RE'd the DDK 1.17 Mesa PVR DRI driver "exactly matches" the blob |

### 2.2 The register map we get for free, and where it stops

**Open KM register map.** `sgx540defs.h` (605 lines) defines only the registers the kernel needs:

```
EUR_CR_CLKGATECTL=0x0000 CLKGATECTL2=0x0004 CLKGATESTATUS=0x0008 CLKGATECTLOVR=0x000C POWER=0x001C
CORE_ID=0x0020 CORE_REVISION=0x0024 DESIGNER_REV_FIELD1=0x0028 DESIGNER_REV_FIELD2=0x002C SOFT_RESET=0x0080
EVENT_HOST_ENABLE2=0x0110 EVENT_HOST_CLEAR2=0x0114 EVENT_STATUS2=0x0118 EVENT_STATUS=0x012C
EVENT_HOST_ENABLE=0x0130 EVENT_HOST_CLEAR=0x0134 TIMER=0x0144
USE_CODE_BASE(X)=0x0A0C+4*X (16 entries)  EVENT_KICK1=0x0AB0 PDS_EXEC_BASE=0x0AB8 EVENT_KICK2=0x0AC0
EVENT_KICKER=0x0AC4 EVENT_KICK=0x0AC8 EVENT_TIMER=0x0ACC PDS_INV0=0x0AD0 PDS_INV1=0x0AD4 EVENT_KICK3=0x0AD8
PDS_INV3=0x0ADC PDS_INV_CSC=0x0AE0 PDS_PC_BASE=0x0B2C BIF_CTRL=0x0C00 BIF_INT_STAT=0x0C04 BIF_FAULT=0x0C08
BIF_DIR_LIST_BASE0=0x0C84 BIF_TA_REQ_BASE=0x0C90 BIF_MEM_REQ_STAT=0x0CA8 BIF_3D_REQ_BASE=0x0CAC
BIF_ZLS_REQ_BASE=0x0CB0 2D_BLIT_STATUS=0x0E04 2D_VIRTUAL_FIFO_0=0x0E10 2D_VIRTUAL_FIFO_1=0x0E14
```

These come from `grep '^#define EUR_CR_… 0x…'` on `sgx540defs.h` at openpvrsgx `e521fd7b65b0`.
There are 40 fixed-address registers plus the 16-entry `USE_CODE_BASE` table
(`EUR_CR_USE_CODE_BASE_NUM_ENTRIES 16`, `sgx540defs.h:595-602`), i.e. 41 `/* Register */` blocks.
*(Corrected 2026-10-11 from "41 named registers plus the array": recount with
`grep -E '^#define\s+EUR_CR_\w+\s+0x' | grep -vE '_(MASK|SHIFT|SIGNED)'` gives 40.)*

**What is missing.** No TA, ISP, TSP, DPM or PBE pipeline register is defined. Those units appear
only as clock-gate, soft-reset and event-status *bits* (e.g. `EUR_CR_SOFT_RESET_TA_RESET_MASK`,
`EUR_CR_EVENT_STATUS_DPM_OUT_OF_MEMORY_GBL_MASK`), and as BIF requestor bases
(`BIF_TA_REQ_BASE`, `BIF_3D_REQ_BASE`, `BIF_ZLS_REQ_BASE`). The DDK never
programs those from the KM: the uKernel and the client command blocks do. An open driver must
recover those registers by tracing.

**The MMU is fully open** (`sgxmmu.h`):

| Field | Value |
|---|---|
| Page size | 4 KiB (`SGX_MMU_PAGE_SHIFT 12`) |
| Page-directory shift / size | 10 / 1024 entries (`SGX_MMU_PD_SHIFT 10`) |
| Page-table shift / size | 10 / 1024 entries (`SGX_MMU_PT_SHIFT 10`) |
| PDE page sizes | 4K/16K/64K/256K/1M/4M (`SGX_MMU_PDE_PAGE_SIZE_*`, mask 0xE) |
| PTE flags | VALID 0x1, WRITEONLY 0x2, READONLY 0x4, CACHECONSISTENT 0x8, EDMPROTECT 0x10 |
| Address space (SGX540) | 28 bits = 256 MiB (`sgxfeaturedefs.h:92`) |

---

## 3. Public knowledge survey (as of 2026-10-11)

### 3.1 Projects and statements, chronologically

| Date | Who / what | Scope | Result / status | Evidence |
|---|---|---|---|---|
| 2005 (FSF listing) / 2012-07 (project) | FSF high-priority project "PowerVR drivers", G3D-SGX Gallium driver plan, `powervr.gnu.org.ve` + `powervr-devel` list | Log the kernel-driver traffic, replay it | Only claim: "USSE opcodes have been reverse-engineered and the assembly language decoded". Server gone ("the wayback machine has only archived 302 errors" — Schaller, 2021-11-09). No code repository linked | libreplanet.org/wiki/Group:PowerVR_drivers (oldid 38782); CI20 list thread 2021-11 |
| 2012 | powervr-devel list | Speculation that the SDK ships `useasm`/`pdsasm` | Not confirmed | mail-archive.com powervr-devel msg00021 |
| 2007–2009 | Tungsten Graphics for Intel: Poulsbo `psb` DRM (GPL) | Host-side TA/raster scheduler for SGX535, **no USSE microkernel** | Shipped; TA fired by `psb_reg_submit(dev_priv, task->ta_cmds, task->ta_cmd_size)` (`psb_schedule.c` l.314); raster fired by `psb_reg_submit(dev_priv, task->raster_cmds, …)` (l.386) — both register lists come from closed userspace. Only scene-less raster tasks additionally go through `psb_xhw_fire_raster` (l.328, the `else` branch); scene bind, TA OOM, DPM reset and TA-mem load go to the closed X server via XHW (`PSB_XHW_FIRE_RASTER 0x00`, `PSB_XHW_SCENE_BIND_FIRE 0x02`, `PSB_XHW_OOM 0x05`, `psb_drm.h:350-361`). IRQ dispatch on `_PSB_CE_PIXELBE_END_RENDER`, `_PSB_CE_DPM_3D_MEM_FREE`, `_PSB_CE_TA_FINISHED`, `_PSB_CE_TA_TERMINATE`, DPM OOM bits (`psb_scheduler_handler`) | github.com/lkundrak/psb-kmod @ `ddb526815bb9` (also gregkh/psb-kmp, jameshilliard/hardware_menlow_psb) |
| 2014-11-21 | libv (Luc Verhaegen): "PowerVR SGX code leaked" | "2011 era PowerVR SGX microcode and user space", probably from an LG GPL release | libv: a credible open SGX RE project is now "horribly impractical and very unlikely". He also argues SGX is microcode-heavy and unstable across revisions | libv.livejournal.com/26972.html |
| 2021-09 → 2023-05 | Imagination forum "Open source older gpus" | Requests for SGX source and Series5 docs | 2021-09-08 David.Hamill: "Imagination has no official plans to open-source the sgx drivers". 2021-09-15: "no official plans to release that documentation publicly". 2022-03-15 AlejandroC: "we currently don't have plans for a series 5 open source driver". 2023-05-11 Nagnath: "no recent developments" | forums.imgtec.com/t/open-source-older-gpus/3425 |
| 2021-10-30 | Ivaylo Dimitrov (openpvrsgx list) | RE of the DDK 1.17 **PVR DRI driver** (Mesa shim) | A working DRI/X.org wrapper; GPU still driven by the closed GLES | lists.goldelico.com/pipermail/openpvrsgx-devgroup/2021-October/000472.html |
| 2021-11-09..12 | Lucas Fryzek ↔ H. Nikolaus Schaller (CI20 list) | Who is doing SGX540 RE? | Schaller: OpenPVRSGX "explicitly excludes reverse engineering and focusses on kernel driver". Using the leak "was considered unethical by the community". Fryzek: "I'll need a working userland" | groups.google.com/g/mips-creator-ci20-dev/c/XNBWlAb8DX8 |
| 2022-08-10 → 2022-10-16 | **Garnet, sgx540-reversing** (Codeberg; GitHub mirror `external-mirrors/sgx540-reversing`) | SGX540 (Galaxy Tab 2 P3110, OMAP4430) on Android, later postmarketOS | Disassembler: done. Partial assembler. Shader replacement: done. Unchecked: "Reverse the instruction encoding fully", "MOE", "PDS", "the microkernel", "basic rendering independently of the userspace libgl" | codeberg.org/Garnet/sgx540-reversing, HEAD `c15884751ad8` (2022-10-16); README checklist |
| 2023-04-21 → 2023-11-06 | **Lucas Fryzek, fork** `Hazematman/sgx540-reversing` | CI20 (JZ4780, SGX540 rev 130) + letux KM | Bridge-ioctl wrapper `wrap/wrap.c` (940 lines), `pprint.c` (405), `pvr_ioctl.inc` (239); "Start framework for custom userspace driver" `drv/drv.c` (206, DRM `DRM_IOCTL_PVR_SRVKM`); "Add documentation about tracking CCB"; "Patch live running binary to insert my own constant data" | github.com/Hazematman/sgx540-reversing @ `c9ce47eef5a8` (10 commits ahead of `c15884751ad8`) |
| 2023-12 → 2024-03 | Andrew Davis (TI): SGX DT binding | Binding only; "there is currently no mainline driver for these binding, there is an open source out-of-tree kernel-side driver available" | Merged for 6.9 (ARM SoC DT pull); maintainer Frank Binns (Imagination) | patchew.org/linux/20240108183302.255055-1-afd@ti.com/; v6.18 `img,powervr-sgx.yaml` |
| 2026-09-16 → 2026-10-10 | **gabrieelgama, SGX535-reMESA** (Poulsbo/GMA500, SGX535 rev 121) | Static RE of `xpsb-glx` 0.18 `psb_dri.so` + TG kernel; experiments on a Dell Mini 12 | **2026-10-06 first triangle** (32×32 readback, 120 magenta px, exact pixel-centre match) and a 16×16 square. `CURRENT-STATUS.json`: `demonstrable_3d_established: false`, `mesa_opengl_driver_complete: false`. Heavily process-driven; one developer | github.com/gabrieelgama/SGX535-reMESA @ `acc60f5ff157`; `SGX535-reMESA:docs/phase8/FIRE3-TRIANGLE-REPRODUCTION.md` |

### 3.2 USSE ISA: what is publicly known (Garnet, SGX540)

All of this comes from `info/ISA.md`, `info/compiler-misc.md` and `hook-postmarket/notes` at
`c15884751ad8`. The author calls it "partially inaccurate".

**Instruction format and operands**

- Instructions are 64-bit (`0xFC2030C000003004 mov r0, #0x0D803004`).
- Register banks:

  | Bank | Meaning |
  |---|---|
  | `r#` | temporary |
  | `o#` | output |
  | `pa#` | primary attribute |
  | `sa#` | secondary attribute |
  | `c#` | hard-wired float constants |
  | `i#` | internal |
  | `g#` | global |
  | `pclink` | link register |
  | `drc#` | read-completion barrier |

- There is an index register, written by encoding a constant as the destination.
- `.repeatN` runs the instruction over N consecutive registers. A swizzle form reorders them.
- `!p0`/`p0` are predicates, set by test modifiers (`fadd.skipinv.testpanz.chan0 !c0, p0, …`).

**Control flow**

- `br` (relative) and `ba` (absolute) branches, counted in instructions, with a range of about
  4096 instructions.
- `.savelink` and `lapc` implement call and return. No call stack was observed.

**Memory**

- `stad [r3,+#0], r5` and `ldad.bpcache r4, [r3,#1], drc0`, followed by `wdf drc0` to wait.
- A measured hazard: a load result is not valid for about 10 instructions.

**Vertex shaders**

- Shaders end with `emitvtx.end.freep`.
- There is a fixed 81–82-instruction prelude before user code.
- Uniforms are loaded into `sa#` by `smlsi`.
- `fmad` is used for adds (multiply by `c52` = 1.0, inferred).

**Binary formats**

- `glGetProgramBinaryOES` output starts with magic `0x38B4FA10`, and inner shaders have a `PSU`
  tag.
- This is **not** final GPU code: the driver does "a secondary finalization step".

**The disassembler hack**

- Imagination's public x86 offline compiler `GLSLESCompiler_Series5` (from PVRShaderEditor) still
  contains a disassembler that is just never called.
- `asm/preload_hack.c` calls it at hard-coded address `0x082994cb` with a fake `gpuinfo`
  (`type 5 = SGX540`, `revision 101`, name `"SGX540"`). The comment says the address "may need to
  be adjusted for different versions".
- The **disassembling** Series5 compiler package itself was NDA-only: an Imagination forum answer
  says "Series5 & Series5XT package of disassembly GLSL ES compilers are available under NDA"
  (forums.imgtec.com/t/…/1998).

### 3.3 The uKernel: what is publicly known

- **Garnet's dumps** (`ukernel/`) total 86 016 B of USE code: `ukernel` 22112 B, `TA` 21744,
  `3D` 23680, `SPM` 18480, `pds_init` 44 B. The README says:
  - patch points are marked by `0xDEADBEEF`, which `libsrv_init` overwrites;
  - "the userspace library builds up a 'script' that writes to hardware registers later in
    kernelspace";
  - `pds_init` is patched with the address of the main microkernel binary and is "likely … the
    first piece of code that runs on the GPU".
- **The OMAP5 DDK 1.9.6.0 `libsrv_init.so` keeps its symbols:** `pbuKernelProgram` (60 208 B),
  `pbSlaveuKernelProgram` (11 552 B), `g_pui32PDSUKERNEL_INIT_PRIM1` (24 B), `…_INIT_SEC`
  (56 B), `…_INIT_PRIM2` (24 B), `…_EVENTS` (252 B). Source: SGX535-reMESA `SGX535-reMESA:docs/firmware.md`
  table, at TI UM commit `b6801bf89e00`.
- **Our stock 1.8 `libsrv_init.so`** is stripped (only `SrvInit` 0x1e60 exported). Its `.rodata`
  is 103 592 B, of which only ≈2.0–2.5 KB are printable strings (threshold-dependent; 40 567 B of
  the section are zero bytes). That is ~101 KB of non-string data,
  consistent with embedded uKernel USE + PDS programs. It contains **no** little-endian
  `0xDEADBEEF` word (Python scan), so the 1.8 patching scheme differs or the markers were already
  resolved (**UNVERIFIED**).
- **The KM shows the init protocol:**
  - `SGXInitialise` runs init script part 1, then soft reset, then script part 2;
  - it zeroes `ui32InitStatus`, kicks, and waits for `PVRSRV_USSE_EDM_INIT_COMPLETE`
    (`sgxinit.c` lines ~703–724 at `e521fd7b65b0`);
  - build options, uKernel build and structure sizes are cross-checked
    (`sgxinit.c:2676-2721`, message "Mismatch in client-side and KM driver build options").
- **Imagination's public description** (Series5 Architecture Guide, 2011-11-01, §4.6): "The Micro
  Kernel is specialised software that the hardware runs on the available USSE general purpose
  execution units … enables the GPU to handle internal interrupt events generated by the GPU
  entirely on the GPU."

### 3.4 What SGX535-reMESA proves, and what it does not

**Proves**

- SGX535 rev 121 rendered a triangle from a command set its author can build without running the
  blob GL.
- The fragment program is an **8-byte constant-colour sequence** `001f00ff fca7f1f1`
  (bytes `ff001f00f1f1a7fc`), replacing the original `00000000 f8040140`
  (`FIRE3-TRIANGLE-REPRODUCTION.md`, "Exact experimental delta").
- A single Series5 USSE fragment instruction pair can therefore be hand-assembled and executed.

**Does not prove**

- Geometry/TA/PDS/ISP/PBE are "frozen" copies of what `psb_dri.so` would emit. The evidence ledger
  still has "nine primary data holes" in the PDS read set (`SGX535-reMESA:docs/phase7/psb-dri-re/README.md`).
- `CURRENT-STATUS.json` `unknown_in_this_reconstructed_path` lists interpolation, controlled
  lighting, perspective object, depth testing, frame-to-frame resource reuse, animation and direct
  shared-buffer presentation. Textures are not in that list. Texturing is simply not demonstrated
  either.

**Relevance to SGX540**

- The two cores share the register skeleton. TG's `psb_reg.h` and the SGX540 KM header agree on
  `EVENT_STATUS 0x12C`, `EVENT_HOST_ENABLE 0x130`, `USE_CODE_BASE0 0x0A0C`, `PDS_EXEC_BASE 0x0AB8`,
  `EVENT_KICK 0x0AC8`, `BIF_CTRL 0x0C00` and `BIF_DIR_LIST_BASE0 0x0C84`.
- `CORE_ID` and `CORE_REVISION` differ (0x10/0x14 on Poulsbo versus 0x20/0x24 on SGX540), and so
  do `DESIGNER_REV_FIELD1/2` (0x18/0x1C versus 0x28/0x2C). `SGX_FEATURE_ADDRESS_SPACE_SIZE` is 32
  for SGX535 and 28 for SGX540 (`sgxfeaturedefs.h` SGX535 block versus line 92).
- SGX535 has 2 USE pipes and SGX540 has 4. SGX535-reMESA warns not to import ISA assumptions
  across cores (`SGX535-reMESA:docs/usse.md` citing `sgxfeaturedefs.h:63-118`).
- **UNVERIFIED (reasoning):** SGX540 is a later revision of the same Series5 family, so USSE1
  encodings are probably close but not identical.

---

## 4. Imagination's 2022+ open-sourcing: what transfers to Series5

| Item | Status | Use for SGX540 |
|---|---|---|
| `drm/imagination` (Linux 6.8+) | Rogue only. The v5 series said "our main focus is on the AXE-1-16M GPU" | Template for a clean DRM driver (GEM, drm_sched, firmware loading, MMU). Its uAPI cannot be reused as-is: Rogue firmware runs on a META/MIPS/RISC-V core, not on the shader cores |
| Mesa `src/imagination/` (main @ `bffd91947efc`, 2026-10-10) | Directories: `pco` (PowerVR COmpiler: NIR → USC, 44 files incl. `pco_isa.py`, `pco_ra.c`, `pco_schedule.c`), `pdsc` (PDS compiler), `csbgen` (control-stream XML generator), `drm-shim`, `vulkan`, plus `common`, `ds`, `include`, `ci` (GitLab tree API at that commit) | Best available **structural** template: NIR front end, Python ISA description, XML-generated packet packers, drm-shim for CI. **No Series5 encodings.** Rogue's USC is not USSE1 and Rogue's PDS is not Series5 PDS (**UNVERIFIED**; we found no doc or code relating them) |
| Mesa docs | "GPUs prior to Series6 do not have the hardware capabilities required to support Vulkan and therefore cannot be supported by this driver." | Mesa `imagination` will never cover SGX; a Gallium (GLES2) driver would be a separate project |
| PowerVR Instruction Set Reference (docs.imgtec.com, SDK v3.4, 2014) | "most of the information in this document applies to the PowerVR Series 6XT architecture" | Concepts only (register types, predication, phases). libv called the 2014 RGX release "shader assembly language … wrongly described as the ISA" |
| Imagination 2022-04-25 blog | Promised to "help enable third parties to provide open-source contributions via our PowerVR architecture and register documentation" | Series5 not mentioned; forum answers (§3.1) say no for Series5 |
| `linux-firmware` Rogue firmware | Closed but redistributable firmware | Precedent: an upstream open driver with closed firmware is acceptable (same model as Asahi with Apple firmware) |

**Shared heritage that does transfer conceptually** (from the Series5 Architecture Guide §3–4):

- tile-based deferred rendering with a TA → parameter buffer → ISP/TSP split;
- data masters feeding PDS programs, which reserve USSE resources and DMA data;
- unified multithreaded shader cores;
- firmware running on the GPU.

So the Rogue code base teaches the *shape* of the problem, but none of the encodings.

---

## 5. Public documents, patents and our own stock artifacts

### 5.1 Public developer documents

| Document | Disclosure relevant to an open driver |
|---|---|
| *PowerVR Series5 SGX Architecture Guide for Developers* (issue date 01 Nov 2011, rev 1.0.13). Copy at github.com/anonymousjustice/pvr-pi @ `fbc9b6daaa44`, sha256 `db334c94…6d60`, 27 pages | Unit split TA / ISP / TSP + USSE + PB. USSE: "Each scheduler manages 16 threads, 4 of which can be active at a given time", zero-cycle switch, Coarse Grain Scheduler. PB: "Primitive Blocks and Display Lists", per-tile linked lists with primitive/vertex masks. TA: clips, projects, culls, updates display lists; "many SGX cores use a 16x16 pixel tile size". ISP: per-tile HSR with an on-chip depth buffer and a Tag Buffer. TSP: schedules fragment tasks, iteration and texture pre-fetch. Micro Kernel runs on USSE (§4.6). **No encodings, registers or formats** |
| *PowerVR SGX Series5 IP Core Family* datasheet (silo.tips copy) | Marketing level: USSE "IEEE 754 single precision" |
| *OpenGL ES 2.0 Application Development Recommendations* / *Performance Recommendations* (PowerVR SDK) | Driver behaviour (HSR, texture formats incl. PVRTC 2/4 bpp) only |
| PVRShaderEditor + offline compilers | Public Series5 compilers **without** disassembly; disassembling package under NDA (forum 1998). Garnet exploited the hidden disassembler (§3.2) |

**Patents.** I could not identify a specific Imagination patent on the USSE, PDS or the uKernel in
this session. One search returned only unrelated or unconfirmed-assignee patents
(US8174534B2, US20080094405A1). **UNVERIFIED.** Patents would at best describe architecture,
never bit encodings, so they are a low-value source for a driver.

### 5.2 Our own ground truth: stock IAN67K blobs and kernel (DDK 1.8@785978)

Extracted read-only with `debugfs -R "dump /vendor/lib/… "` from
`reverse-eng/factory/tungsten-ian67k/system.raw.img` into `<session scratch>/gpu/re/stock-libs/`. The
version string comes from `strings`: `OpenGL ES 2.0 build 1.8@785978`,
`OpenGL ES GLSL ES 1.00 build 1.8@785978`.

| File (`/vendor/lib/…`) | Size | SHA-256 | Notes |
|---|---|---|---|
| `libusc.so` | 898 564 | `f94c73b7206ec306e81e4585ae7621cef3eb5a65a20642a16420178d538a1740` | NEEDED `libc.so libdl.so libcutils.so` (bionic) |
| `libglslcompiler.so` | 253 264 | `bd921d395704180e982ec16c2a8fe7418956b2677d468bf3779de29097d6b6b1` | NEEDED … `libsrv_um.so libusc.so libm.so` |
| `libsrv_um.so` | 190 204 | `f177b896e7b37e6afd6e82a1eeef8923035fec15d15af64c32bb127db4b946fa` | 102 exported FUNC/OBJECT; ARMv7, Thumb-2 allowed, VFPv3, NEON (`readelf -A`). **softfp calling convention**: e_flags `0x5000002` (no `EF_ARM_ABI_FLOAT_HARD` 0x400) and no `Tag_ABI_VFP_args`, same for all 12 stock blobs |
| `libsrv_init.so` | 115 708 | `c4dee422fb9c3364ff8128958c077da847f2eb18c4b43e2d47b198f849691926` | Only `SrvInit` exported (0x1e60, 532 B); `.rodata` @0x2074 size 0x194a8 |
| `egl/libGLESv2_POWERVR_SGX540_120.so` | 372 324 | `229988dd811c2b8b12e6d2b785b982c443fcf187f364ab438afd7f3dd0c0bcc8` | — |
| others | — | — | `libIMGegl.so` 71 532, `libpvr2d.so` 21 708, `libpvrANDROID_WSEGL.so` 13 600, `libPVRScopeServices.so` 9 192, `libGLESv1_CM_POWERVR_SGX540_120.so` 446 184, `libEGL_POWERVR_SGX540_120.so` 5 140, `/vendor/bin/pvrsrvinit` 5 432; `hw/gralloc.omap4.so` 35 300, `hw/hwcomposer.omap4.so` 92 260 |

**Compiler API, the shader-dump hook points** (`readelf --dyn-syms`):

| Library | Symbol | Address | Size |
|---|---|---|---|
| libusc.so | `PVRUniFlexCreateContext` | 0x000b02d0 | 96 |
| libusc.so | `PVRUniFlexDestroyContext` | 0x000b017c | 16 |
| libusc.so | `PVRUniFlexCompileToUspBin` | 0x000b6a80 | 308 |
| libusc.so | `PVRUniFlexCompileToHw` | 0x000b6bb4 | 256 |
| libusc.so | `PVRUniFlexInitTextureParameters` | 0x000b6d90 | 100 |
| libusc.so | `PVRUniFlexGetInputInstDesc` | 0x000b6df4 | 36 |
| libusc.so | `PVRUniFlexInitInst` | 0x000b6e18 | 36 |
| libusc.so | `PVRUniFlexDestroyUspBin` | 0x000b03c4 | 4 |
| libusc.so | `PVRCleanupUniflexHw` | 0x000309f0 | 4 |
| libglslcompiler.so | `GLSLInitCompiler` | 0x000081e4 | 284 |
| libglslcompiler.so | `GLSLCompileToUniflex` | 0x000083d4 | 732 |
| libglslcompiler.so | `GLSLFreeCompiledUniflexProgram` | 0x000083a8 | 44 |
| libglslcompiler.so | `GLSLShutDownCompiler` | 0x00008188 | 92 |
| libglslcompiler.so | `GLSLDisplayMetrics` | 0x0000834c | 4 |
| libglslcompiler.so | `SGXBS_CreateBinaryShader` | 0x0000751c | 696 |
| libglslcompiler.so | `SGXBS_CreateBinaryProgram` | 0x000077d4 | 1024 |

`libGLESv2` names only `libglslcompiler.so` (strings `libglslcompiler.so`, ` PSU` at 0x38b7d and
0x3ac39, `InitializeGLSLCompiler: Failed to initialise the GLSL compiler !`). It contains **no**
`libusc.so` string. `libusc.so` arrives as a `NEEDED` dependency of `libglslcompiler.so`
(`readelf -d`). `libGLESv1_CM` is the GLES library that names `libusc.so` directly
(`grep -a -l`). *(Corrected 2026-10-11: the report said libGLESv2 loads both compilers by name.)* Garnet notes the compiler "is
loaded using a function provided by libsrv_um", i.e. `PVRSRVLoadLibrary`/`PVRSRVGetLibFuncAddr`,
both exported by stock `libsrv_um.so`.

**Services API, the command-stream hook points** (selected `libsrv_um.so` exports):

| Symbol | Address | Size |
|---|---|---|
| `PVRSRVAllocDeviceMem` | 0x950c | 44 |
| `PVRSRVConnect` | 0x95e4 | 468 |
| `SGXGetClientInfo` | 0xab80 | 344 |
| `SGXDevInitPart2` | 0xacd8 | 1040 |
| `SGXKickTA` | 0xe674 | 4396 |
| `SGXCreateRenderContext` | 0xfea0 | 1900 |
| `SGXAddRenderTarget` | 0x109c4 | 5720 |
| `SGXQueueTransfer` | 0x1b368 | 152 |

**Bridge ABI of the stock DDK 1.8.** It uses a plain character device `/dev/pvrsrvkm` (strings
`OpenServices: Cannot open device driver /dev/pvrsrvkm.`), not DRM.

- A word scan finds 87 literal words of the form `0xC01C67NN` (81 distinct NN, 0–115). That is
  `_IOWR('g', NN, 28-byte PVRSRV_BRIDGE_PACKAGE)` (`pvr_bridge.h:59-63`, package struct
  `pvr_bridge.h:311-321`, 7×u32).
- **The TA kick path is verified:** `SGXKickTA` (0xe674) calls a local helper at ≈0xa238. That
  helper does `mov r3, #564`, `ldr r1, =0xC01C6758`, then `bl 0xc674` (the bridge-call wrapper);
  see the objdump of 0xa2a0–0xa308. So **kick = bridge index 88 (0x58) with a 564-byte input
  struct** in this DDK. Further detail: the input is 4 B + 4 B + a 556-B `memcpy` of the caller's
  kick struct, and the output is 8 B. The helper loops back while the returned error word equals
  24; what 24 means is **UNVERIFIED** (not mapped to a 1.8 `PVRSRV_ERROR` name). The single call
  site is `SGXKickTA`+0x10bc (`bl a238` at 0xf730). The stock KM confirms index 88 =
  `PVRSRV_BRIDGE_SGX_DOKICK` → `SGXDoKickBW` (`_SetDispatchTableEntry` call at 0xc0292b94,
  `stock-dispatch-sgx.tsv`).

**The stock kernel has `pvrsrvkm` built in, with symbols** (`reverse-eng/tools/kallsyms.txt`;
365 lines matching `grep -ci 'pvrsrv|sgx'`, case-insensitive; only 40 match case-sensitively):

| Symbol | Address |
|---|---|
| `PVRSRV_BridgeDispatchKM` | 0xc0277158 |
| `BridgedDispatchKM` | 0xc028e1c8 |
| `SGXRegisterDevice` | 0xc0294480 |
| `SGXInitialise` | 0xc0294048 |
| `SGX_ISRHandler` | 0xc02938b8 |
| `SGXScheduleCCBCommandKM` | 0xc0295980 |
| `SGXDoKickKM` | 0xc0296338 |
| `SGXSubmitTransferKM` | 0xc0296700 |
| `SGXGetMiscInfoKM` | 0xc0294a08 |
| `MMU_Initialise` | 0xc0297328 |
| `sgx_idle_*` (Google idle logging) | 0xc028f668… |
| `g_BridgeDispatchTable` | 0xc07840e4 (BSS; next symbol at 0xc07842cc → 0x1e8 B, i.e. 122 four-byte slots if the entries are function pointers only — **INFERRED**) |

**Bridge numbers in the openpvrsgx 1.17 KM.** Computed from `pvr_bridge.h`/`sgx_bridge.h` for a
build without ION, DMABUF, overlay-rotate and PDUMP. The numbers depend on the build config;
re-derive them per build.

| Group | Index | Command |
|---|---|---|
| Core | 0 | UM_KM_COMPAT_CHECK |
| Core | 1…29 | core, e.g. ALLOC_DEVICEMEM = 7, CONNECT_SERVICES = 13 |
| Core | 30–32 | SIM |
| Core | 33–35 | MAPPING |
| Core | 36 | STATS |
| Core | 37–38 | MISC |
| Core | 39 | OEM |
| Core | 40–42 | DEVCLASS |
| Core | 43–58 | DISPCLASS |
| Core | 59–62 | BUFCLASS |
| Core | 63–64 | WRAP |
| Core | 65–68 | SHAREDMEM |
| Core | 69–70 | INITSRV |
| Core | 71–73 | EVENT_OBJECT |
| Core | 74–83 | SYNC_OPS |
| SGX (base 85) | 85 | GETCLIENTINFO |
| SGX | 88 | **DOKICK** |
| SGX | 98 | SUBMITTRANSFER |
| SGX | 99 | GETMISCINFO |
| SGX | 101 | DEVINITPART2 |
| SGX | 102–104 | FIND/UNREF/ADD_SHAREDPBDESC |
| SGX | 105–107 | REGISTER_HW_RENDER_CONTEXT / FLUSH_HW_RENDER_**TARGET** / UNREGISTER_HW_RENDER_CONTEXT |
| SGX | 111–112 | REGISTER/UNREGISTER_HW_TRANSFER_CONTEXT |

**Stock DDK 1.8 numbering differs in the core group** (from the stock KM's
`_SetDispatchTableEntry` calls, `<session scratch>/gpu/re/stock-dispatch.tsv`). 1.8 has no
`UM_KM_COMPAT_CHECK`: index 0 is `ENUM_DEVICES`, `ALLOC_DEVICEMEM` is 6 (not 7) and
`CONNECT_SERVICES` is 12 (not 13). The core group still ends at `FREE_SYNC_INFO` = 83, so the SGX
base is 85 in both. The SGX indices checked agree: GETCLIENTINFO 85, DOKICK 88, SUBMITTRANSFER 98,
GETMISCINFO 99, DEVINITPART2 101, PBDESC 102–104, HW render context 105–107, HW transfer context
111–112, SCHEDULE_PROCESS_QUEUES 113, READ_HWPERF_CB 115. A tracer must use per-DDK tables for the
core group.

Under openpvrsgx DRM the same index travels in `PVRSRV_BRIDGE_PACKAGE.ui32BridgeID` inside
`DRM_IOWR(PVR_DRM_SRVKM_CMD, PVRSRV_BRIDGE_PACKAGE)` (Fryzek `drv/drv.c`).

---

## 6. How other open GPU drivers started, and where SGX differs

| Project (GPU) | Start | First triangle / demo | Kernel upstream | Mesa upstream | People | Seed tooling | Docs | Firmware model |
|---|---|---|---|---|---|---|---|---|
| lima (Mali-200/400) | Presented at FOSDEM 2012-02-04 (Verhaegen) | Q3A timedemo 2013-02-02 (limare) | 5.2 (2019-05) after revival in 2017 (`yuq/mesa-lima` created 2017-06-10) | 19.1 (2019) | 1, then hiatus, then ~2–3 | Ioctl wrapping, blob shader compiler as oracle | None | No GPU firmware |
| freedreno (Adreno) | 2012 (Rob Clark, spare time) | Code public 2012-04-15; shader assembler 2012; FOSDEM demo 2013-02-02 | msm DRM accepted 2013-08 → 3.12 | 2013 | 1 → several (later full-time) | `libwrap` → `.rd` command-stream dumps, `cffdump`, `rnndb` XML | None | Small closed microcode (PM4/PFP/ME); open drivers load it as firmware |
| etnaviv (Vivante GC) | `laanwj/etna_viv` created 2012-12-31 | 2013 (**UNVERIFIED** exact date) | 4.5 (2016) | 2017-01 (GLES2 + GL2.1) | 1–3, part-time → Pengutronix | `viv_hook` LD_PRELOAD ioctl dumps, `rnndb`, blob compiler oracle | None | No GPU firmware |
| grate (Tegra 2/3) | `grate-driver/grate` created 2013-03-05 | Yes (grate tests) | host1x/tegra-drm 3.10 (display/2D) | 3D never upstream (**UNVERIFIED**) | 2–3 part-time | cmdstream tracing | None | — |
| vc4 (VideoCore IV) | 2014 (Eric Anholt, full-time at Broadcom) | 2014 | 4.4/4.5 | 10.3 (2014-08-29 commit) | 1 full-time | — | **Full docs released 2014-02-28** | None |
| panfrost (Mali Midgard/Bifrost) | 2017–2018 (Rosenzweig + others) | 2018 | 5.2 (2019-05) | 19.1 (2019) | 2–4, later Collabora | `panwrap` ioctl tracer, blob compiler oracle, pandecode | None | No GPU firmware (CSF later) |
| Asahi (Apple AGX) | `AsahiLinux/gpu` created 2021-01-07 | Triangle within a month, via the macOS kernel driver; first fully open triangle 2022 (m1n1) | Rust driver: >99 % dEQP-GLES2 on 2022-10-21; upstreaming ongoing | Yes; GLES 3.1 conformant (date **UNVERIFIED**) | ~3–5 core experts | m1n1 hypervisor MMIO tracing, macOS ioctl tracing, blob compiler | None | **Closed Apple firmware on a coprocessor**, reused as-is |
| SGX535-reMESA (Poulsbo) | 2026-09-16 | 2026-10-06 (frozen geometry, hand-written fragment) | — | — | 1 | Static RE (Ghidra) of `psb_dri.so`, TG kernel | KM headers only | Bypassed (TG host-driven path) |

**What sets SGX540 apart**

- Harder:
  - **Two closed ISAs, not one.** USSE1 for shaders and the uKernel, plus PDS for data-master
    programs.
  - **A closed microkernel that runs on the shader cores**, not on a separate coprocessor. It
    shares USSE resources, data masters and PB management with rendering. Replacing it means
    writing USSE+PDS firmware. Keeping it means the open driver depends on a blob with unclear
    redistribution terms (§8).
  - The pipeline registers (TA/ISP/TSP/DPM) appear nowhere in open headers.
  - **Hardware recovery and PB out-of-memory handling** (partial renders) live in the uKernel.
  - **Legal hygiene:** the 2014 leak (§3.1) means contributors must attest they never saw it.
  - The hardware is old and the community is small: the last active SGX540 RE project went quiet
    in 2023.
- Easier:
  - The compiler is a separate library with a clean API.
  - The KM is fully open and debuggable, so all memory and kicks are visible from our own kernel
    code.
  - The stock Android firmware runs the complete original stack with symbols in the kernel.
  - Imagination's own offline compiler gives a disassembly oracle.
  - Mesa's Rogue `pco`/`csbgen`/`pdsc` give structure to copy.

---

## 7. Tooling needed for SGX, and what can seed it

| # | Tool | What it captures | Hook point (stock 1.8 or openpvrsgx) | Seed code | Effort |
|---|---|---|---|---|---|
| T1 | **`pvr-trace`**: `LD_PRELOAD` ioctl/mmap tracer | Every bridge call (`0xC01C67NN` / DRM `PVR_SRVKM`), in/out structs, `ALLOC_DEVICEMEM` → device VA/heap map, mmaps; snapshot of all mapped device memory at each `DOKICK` (index 88, 564-B input in 1.8) and `SUBMITTRANSFER` | `ioctl`, `mmap`, `munmap`; also `PVRSRVAllocDeviceMem`/`dlopen` (Garnet `hook-postmarket/ldpreload.c` `HOOK(...)` lines 243, 303) | Fryzek `wrap/wrap.c` (940 lines), `pprint.c`, `pvr_ioctl.inc`, `pvr_heaps.h`; Garnet heap map `addr_to_name()` (General 0x1000+0x87fe000, TAData 0xc800000, KernelCode 0xe400000, KernelData 0xf000000, PixelShaderCode 0xf400000, VertexShaderCode 0xfc00000, PDSPixelCodeData 0xdc00000, PDSVertexCodeData 0xe800000, CacheCoherent 0xd800000, PerContext3DParameters 0xb800000); `Android/.../ioctl-map.h` names. Struct layouts from the GPL KM headers | 1–1.5 PM |
| T2 | **KM-side capture** in our own GPL `pvrsrvkm` | At `SGXDoKickKM`/`SGXScheduleCCBCommandKM`: dump the kernel CCB entry (32 B), walk the SGX MMU page tables (`sgxmmu.h`) and dump all referenced pages; log every `OSWriteHWReg` (init scripts, kicks); IRQ status. Catches what userspace never sees (uKernel loads, script execution) | `SGXDoKickKM`, `SGXScheduleCCBCommandKM`, `SGXInitialise`, `SGX_ISRHandler` (open source) | The KM itself; PDUMP code in the KM (`services4/srvkm/common/pdump_common.c`, `env/linux/pdump.c`). Caveat: PDUMP is build-option bit 1 (`sgx_options.h:67-69`), so a PDUMP KM fails the client/KM option check against a release UM. The check is fatal: `eError = PVRSRV_ERROR_BUILD_MISMATCH; goto chk_exit;` (`sgxinit.c:2713-2731`). PDUMP also inserts 19 bridge indices before OEM (`pvr_bridge.h:176-202`), which shifts every later index. Use a custom capture instead | 1–2 PM |
| T3 | **Shader dumper / oracle** | GLSL → UniFlex IR → USP binary → HW code, per shader; with the blob's hidden disassembler as text | Interpose `PVRSRVLoadLibrary`/`PVRSRVGetLibFuncAddr` (how GLES finds the compiler), then wrap `GLSLCompileToUniflex` (0x83d4), `PVRUniFlexCompileToUspBin` (0xb6a80), `PVRUniFlexCompileToHw` (0xb6bb4) | Garnet `asm/preload_hack.c` (x86 `GLSLESCompiler_Series5` disassembler at 0x082994cb, version-specific); Garnet Android `libdumper` + Frida agent | 1–2 PM |
| T4 | **USSE/PDS ISA tooling** | Encoding tables, assembler, disassembler, fuzzing: encode bit patterns → oracle disassembly → Mesa-style ISA XML | Offline; oracle from T3 | Mesa `src/compiler/isaspec` (used by freedreno/etnaviv), Rogue `pco_isa.py` as a model; Garnet `hook-postmarket/asm.c` (6.6 KB), `asm.h` | 2–4 PM (USSE), +1–3 PM (PDS) |
| T5 | **Replayer** | Re-submit a captured kick (memory image + CCB) from our own code; then mutate fields one by one | Fryzek `drv/drv.c` (custom UM on `DRM_IOCTL_PVR_SRVKM`) or a KM ioctl added to our `pvrsrvkm` | Fryzek `drv/drv.c`, `Hazematman/sgx540-reversing:tests/test.c`; the freedreno/etnaviv replay pattern | 1–2 PM |
| T6 | **uKernel analysis** | Disassemble the USE uKernel and PDS init programs from `libsrv_init.so` `.rodata`; map the host-control/CCB fields they touch | Offline (T4 disassembler) | Garnet `ukernel/*-disasm` (e.g. `3D-disasm` 273 557 B text); `sgx_ukernel_status_codes.h` (998 lines) as a symbol table | 2–4 PM to *understand*; much more to *replace* |
| T7 | **Conformance harness** | dEQP-GLES2, piglit, deqp-runner | — | Mesa CI tooling | 0.5 PM |

**ABI caveat for T1/T3 hooks (added 2026-10-11).** The stock 1.8 blobs use the softfp (base
AAPCS) calling convention (no `Tag_ABI_VFP_args`, e_flags 0x5000002), while our rootfs is armhf.
An `LD_PRELOAD`/interposer built for the hard-float ABI that wraps an exported function taking or
returning `float`/`double` passes those values in the wrong registers. Mark such wrappers
`__attribute__((pcs("aapcs")))`. Hooks on `ioctl`/`mmap` and on pointer-only APIs are unaffected.
Whether the 1.9/1.14/1.17 TI UM blobs used by the primary path are softfp or hard-float was not
checked here.

**Prerequisite (important).** T1–T3 need the closed stack running somewhere. Options:

- **(a)** The primary path on our mainline kernel. Its musl/glibc question is solved elsewhere.
- **(b)** The stock IAN67K Android 4.0 image on a Nexus Q, which has DDK 1.8 with symbols. This is
  how Garnet worked (Android tablet), but the stock kernel's `pvrsrvkm` can only be modified for T2
  by rebuilding the Tungsten kernel (source availability **UNVERIFIED**).
- **(c)** Another SGX540 board (Droid 4, CI20) with an openpvrsgx KM.

---

## 8. Legal and hygiene constraints (not legal advice)

1. **The 2014 leak.** Contributors must never have looked at it (libv 2014-11-21, Schaller
   2021-11-09). Keep a contributor attestation. Do not use downloads named "sgx ddk source".
2. **Blob licences.**
   - TI's UM package manifest (OLE document) carries TI TSPA terms, "binary distribution without
     modification", and a "reverse engineering restriction". Source: SGX535-reMESA
     `SGX535-reMESA:docs/firmware.md`, "Source and reuse". The `xpsb-glx` package says "Redistributable, no
     modification permitted" (`SGX535-reMESA:docs/phase7/psb-dri-re/README.md`).
   - The licence of Google's stock factory-image vendor blobs was **not checked**: open question.
   - EU Directive 2009/24/EC Art. 6 (decompilation for interoperability) is the likely legal
     basis in Czechia. Applicability is an **open question for a lawyer**.
3. **Firmware redistribution.** Option B in §9 (upstream kernel driver + closed uKernel) needs the
   uKernel microcode to be redistributable, like Rogue's in `linux-firmware`. Nobody has a licence
   for SGX5 microcode today (**UNVERIFIED**).
4. **The DRM uAPI rule.** "any addition of DRM uAPI requires corresponding open-sourced userspace
   patches … ready for merging into a suitable and canonical upstream project"
   (`Documentation/gpu/drm-uapi.rst:56-58` @ v6.18).
   - The out-of-tree `pvrsrvkm` with today's closed UM cannot go upstream as a DRM driver.
   - An open userspace "ready for merging into a suitable and canonical upstream project" is
     required. In practice that means Mesa, but the rule does not name Mesa, and an
     Imagination/TI release of the UM source would also satisfy it (unlikely per §3.1).
     *(Softened 2026-10-11 from "never" / "only an open Mesa driver", which overreached the cited
     text.)*

---

## 9. Paths, milestones and an honest estimate

### 9.1 Architectures for an "open" SGX540 driver

| Option | Userspace | Kernel | uKernel | Upstreamable | Comment |
|---|---|---|---|---|---|
| A | Open (Mesa Gallium `sgx`) | openpvrsgx `pvrsrvkm` (bridge ABI, out of tree) | Closed microcode (from `libsrv_init`), loaded by our own init code | No | Fastest to first pixels; ABI is the old bridge |
| B | Open Mesa | New `drm/sgx` (GEM, drm_sched, sgxmmu, ti-sysc/PRM glue) | Closed microcode as firmware | Yes, *if* microcode redistribution is solved | The Rogue/Asahi model |
| C1 | Open Mesa | `drm/sgx` | **Own USSE+PDS microcode** | Yes | Needs the whole uKernel contract RE'd; no SGX precedent |
| C2 | Open Mesa | `drm/sgx` with a **host-driven scheduler** (TA/3D kicks and PB/DPM out-of-memory handling from IRQs, like TG Poulsbo) | None | Yes | Precedent exists only for SGX535, and there the TA/raster register lists came from closed `psb_dri.so` while scene bind, OOM and DPM reset ran in a closed X helper. An open C2 must RE all of that logic. The register skeleton shared with SGX540 covers only host-interface registers (event, kick, PDS/USE base, BIF), not the pipeline. SGX540 behaviour **UNVERIFIED**; no SGX540 experiment exists. Simpler for single-context compositor use, worse latency |

### 9.2 Milestones and effort

Assumes one experienced GPU-RE engineer full-time; person-months (PM), P50–P90. Option A then B.

| M | Milestone | Depends on | PM |
|---|---|---|---|
| M0 | Closed stack running (primary path or stock Android) + T1/T2/T3 tooling | Primary path | 1.5–3 |
| M1 | Replay a blob-captured clear and triangle from our own code (T5), no blob UM | M0 | 1–2 |
| M2 | Decode TA/3D kick structures, render-target/PB/DPM setup, ISP/TSP state words, PDS vertex/pixel programs well enough to **generate** a flat-shaded triangle with hand-written USSE (SGX535-reMESA's stage, done properly) | M1, T4 | 3–6 |
| M3 | USSE + PDS assembler for ~30 ops (mov, fmad/fadd/fmul, frcp/frsq, smlsi, emitvtx/emitpix, texture sample, ld/st, branch, predicate tests; PDS DMA/kick ops) checked against the oracle | T3/T4 | 2–4 (overlaps M2) |
| M4 | Clear + **textured quad** + premultiplied alpha blend + scissor; ARGB8888/XRGB8888/RGB565; linear and twiddled textures (PVRTC not needed) | M2/M3 | 2–4 |
| **Σ** | **Minimal compositor engine** (library API, fixed hand-written programs, closed uKernel) | | **≈ 9–19 PM** |
| M5 | Mesa Gallium driver with renderonly/kmsro on omapdrm, GBM/EGL, dma-buf import, enough for the weston `gl-renderer` / wlroots `gles2` fixed shader set. Needs a tiny NIR→USSE path for straight-line ALU+tex | M4 | 4–8 |
| M6 | Real compiler: NIR→USSE with RA, repeat/vectorisation, hazard scheduling (e.g. the ~10-instruction load latency), control flow/predication, precision | M3 | 9–18 |
| M7 | GLES2 robustness, dEQP-GLES2 ≥ 95 %: partial renders on PB OOM, MSAA, all formats, multiple contexts, HW recovery | M5/M6 | 12–24 |
| M8 | Clean `drm/sgx` kernel driver (option B) + review cycles | M7 (uAPI rule) | 6–12 + review |
| M9 | Remove the uKernel blob (C1 or C2) | M2, T6 | 6–18 (low confidence) |

Totals:

- **Full open GLES2 userspace** with the closed uKernel: M0–M7 ≈ 34–69 PM ≈ **3–6 person-years**.
- **Fully open and upstream:** + M8 + M9 ≈ **4–7 person-years**.
- For comparison, Asahi reached >99 % dEQP-GLES2 about 21 months after starting (2021-01 →
  2022-10-21) with roughly 3–5 exceptional people and a firmware it did not have to replace.

### 9.3 Is "clear + textured quad for a compositor" a meaningfully smaller target?

Yes, at about 25–35 % of the full effort. It avoids the GLSL→USSE compiler (M6), most of the
GLES2 state tracker and robustness work (M7), and arguably the uKernel replacement (M9).

**It cannot avoid the fixed costs**, which are about 70 % of the minimal target:

- the TA → parameter buffer → ISP/TSP → PBE pipeline setup;
- PDS programs, both for vertex fetch and for pixel iteration/texture DMA;
- render-target and PB/DPM allocation;
- uKernel kick and sync semantics;
- MMU and heaps;
- texture state words.

Two ways to make it smaller still:

- **(i)** Target the DDK's own **transfer queue** model (`SGXQueueTransfer`, bridge
  `SUBMITTRANSFER`, CCB command type `SGXMKIF_CMD_TRANSFER = 1`): a 3D-only pixel pass with no TA
  geometry. It may be the smallest blit/fill engine. **UNVERIFIED** that SGX540 transfers bypass
  the TA.
- **(ii)** Expose it to a compositor as a custom `wlr_renderer` (blit/fill/textured-quad) instead
  of full GLES2. wlroots supports out-of-tree renderers through its renderer interface
  (**UNVERIFIED** for the current wlroots API).

**Before investing, measure the alternative that costs nothing.** OMAP4 DSS overlay pipelines
(scaling, colour conversion, alpha) exposed as omapdrm KMS planes could take most compositor work
off the CPU through weston's plane assignment or libliftoff.

- Today the Q runs `renderer=pixman` (`pmos/device-google-steelhead/weston.ini:11`) and
  `WLR_RENDERER=pixman` (`nexusq-wayland.sh:8`).
- Plane count and formats on 6.18 omapdrm are **UNVERIFIED**.

---

## 10. Recommendation

1. **Do not start an open driver as the means to get acceleration on the Nexus Q.** The closed-blob
   primary path is weeks to months. The open path is person-years, and the device is mainly
   headless (prior note §6, "Worth it?").
2. **Do build T1 + T2 + T3 anyway**, about 3–5 PM spread over time. They debug the primary path
   (KM/UM mismatches, kicks, faults) and are exactly the groundwork any later open effort needs. T2
   costs little because we own the GPL KM.
3. **Publish captures and decoded structures** (bridge structs, heap map, kick layouts, the T6
   uKernel map) in `docs/gpu-sgx540/`. Coordinate upstream with Garnet (Codeberg), Fryzek and
   gabrieelgama. Three one-person efforts on three Series5 cores is the real obstacle.
4. **Re-decide on concrete evidence:** go further than tooling only if M1 (a replayed captured
   triangle) works within ~2 PM, and if a second contributor appears.

---

## Open questions

1. Is the SGX540 USSE1 encoding identical to SGX535's for the common ops (`mov`, `fmad`,
   `emitpix`)? This is testable offline: compare SGX535-reMESA's `fca7f1f1 001f00ff` fragment pair
   against Garnet's SGX540 disassembler.
2. Can SGX540 be operated host-driven (option C2), with TA/3D kicked by register lists and no
   uKernel, as TG did on SGX535? What DPM/PB state would the host have to manage?
3. What is the 1.8 uKernel patching scheme in our stock `libsrv_init.so`? There are no
   `0xDEADBEEF` markers in `.rodata`. Where do the USE program and the PDS init programs start
   inside the 103 592-B `.rodata`?
4. What is the exact 564-byte `SGX_CCB_KICK`-equivalent input of bridge 88 in DDK 1.8, and how
   does it differ from the 1.9/1.14/1.17 KM structs? The primary-path workstream needs this too.
5. Is the Tungsten (Nexus Q) kernel source with the built-in DDK 1.8 KM publicly available, so T2
   could run on stock Android?
6. What licence covers Google's IAN67K vendor blobs and TI's Graphics SDK blobs for analysis and
   interoperability (EU 2009/24/EC Art. 6)? Can any uKernel microcode be redistributed as
   firmware?
7. Is there any Imagination patent that discloses USSE/PDS encodings or the uKernel–host contract
   in useful detail? None was identified this session.
8. Does omapdrm on 6.18 expose the OMAP4 DSS VID pipelines as KMS overlay planes with scaling and
   alpha, so a compositor could skip the GPU? This would remove the motivation for the minimal open
   target.
9. Are `lkcl.net/powervr/sgx/` (the archived FSF-era RE material Fryzek mentioned in 2021) and the
   `powervr.gnu.org.ve` wiki recoverable? The fetch failed here on a TLS certificate mismatch.
10. Exact first-triangle dates for etnaviv and the GLES 3.1 conformance date for Asahi. These were
    not needed for the decision, so they are marked UNVERIFIED above.

## Sources

Local evidence (read-only; nothing was written in the repo):

- `reverse-eng/factory/tungsten-ian67k/system.raw.img`: `/vendor/lib/*`, `/vendor/lib/egl/*`,
  `/vendor/bin/pvrsrvinit`, extracted to `<session scratch>/gpu/re/stock-libs/` (SHA-256 in §5.2).
- `reverse-eng/tools/kallsyms.txt`: stock kernel pvrsrvkm symbols (§5.2).
- `docs/2026-06-19-gpu-sgx540-acceleration-research.md` (prior note).
- `pmos/device-google-steelhead/weston.ini`, `pmos/device-google-steelhead/nexusq-wayland.sh`.
- Commands: `readelf -d/--dyn-syms/-S/-A`, `strings -a`, `arm-none-eabi-objdump -d
  --start-address=0xa2a0 --stop-address=0xa30c libsrv_um.so`, Python `-I` word scans (§3.3, §5.2).

Downloaded data (each in its own directory under `<session scratch>/gpu/re-downloads/`):

- gabrieelgama/SGX535-reMESA @ `acc60f5ff157` (2026-10-10) — https://github.com/gabrieelgama/SGX535-reMESA
  (`README.md`, `SGX535-reMESA:docs/CURRENT-STATUS.json`, `SGX535-reMESA:docs/usse.md`, `SGX535-reMESA:docs/firmware.md`,
  `SGX535-reMESA:docs/command-submission.md`, `SGX535-reMESA:docs/phase7/7.5-firmware-microkernel.md`,
  `SGX535-reMESA:docs/phase8/FIRE3-TRIANGLE-REPRODUCTION.md`, `docs/phase7/psb-dri-re/*.md`)
- Garnet/sgx540-reversing @ `c15884751ad8` (2022-10-16) — https://codeberg.org/Garnet/sgx540-reversing
  (mirror https://github.com/external-mirrors/sgx540-reversing)
- Hazematman/sgx540-reversing @ `c9ce47eef5a8` (2023-11-06) — https://github.com/Hazematman/sgx540-reversing
- lkundrak/psb-kmod @ `ddb526815bb9` — https://github.com/lkundrak/psb-kmod (`psb_schedule.c`, `psb_reg.h`,
  `psb_xhw.c`, `psb_drm.h`)
- openpvrsgx-devgroup/linux_openpvrsgx branch `letux/pvrsrvkm-1.17` @ `e521fd7b65b091e7a3e2d59db0fc1a9a474cf67b`
  — `drivers/staging/pvr/1.17/eurasia_km/{services4/srvkm/hwdefs/sgx540defs.h, sgxmmu.h,
  sgxfeaturedefs.h, services4/include/sgx_mkif_km.h, sgxinfo.h, sgx_bridge.h, pvr_bridge.h,
  sgx_ukernel_status_codes.h, include4/sgxscript.h, sgx_options.h, services4/srvkm/devices/sgx/sgxinit.c, sgxkick.c}`
- PowerVR Series 5 SGX Architecture Guide for Developers 1.0.13 (2011-11-01), via
  https://github.com/anonymousjustice/pvr-pi @ `fbc9b6daaa44` (sha256 `db334c948ef0eac9db9c8be26e1713881dd21b61d733c302d08a54d6db714d60`)

Linux mainline (via GitHub API, tag v6.18):

- https://github.com/torvalds/linux/blob/v6.18/Documentation/devicetree/bindings/gpu/img,powervr-sgx.yaml
- https://github.com/torvalds/linux/blob/v6.18/arch/arm/boot/dts/ti/omap/omap4.dtsi (lines 502–508)
- https://github.com/torvalds/linux/blob/v6.18/Documentation/gpu/drm-uapi.rst (lines 49–58)

Web:

- Imagination forum, "Open source older gpus" — https://forums.imgtec.com/t/open-source-older-gpus/3425
- Imagination forum, disassembly compiler under NDA — https://forums.imgtec.com/t/ive-heard-about-a-glsl-es-disassembly-compiler-package-where-can-i-get-it-from/1998
- Imagination blog 2022-04-25 — https://blog.imaginationtech.com/imagination-and-our-commitment-to-open-source
- Mesa PowerVR docs — https://docs.mesa3d.org/drivers/powervr.html ; Mesa tree `src/imagination` @ `bffd91947efc` (2026-10-10) via gitlab.freedesktop.org API
- PowerVR Instruction Set Reference — https://docs.imgtec.com/reference-manuals/powervr-instruction-set-reference/html/topics/general-architecture-information.html ;
  Phoronix "Imagination Releases Full ISA Documentation For PowerVR Rogue GPUs" — https://www.phoronix.com/news/MTgxOTM
- PVRShaderEditor — https://docs.imgtec.com/performance-guides/graphics-recommendations/html/topics/pvrshadereditor.html
- libv, "PowerVR SGX code leaked." (2014-11-21) — https://libv.livejournal.com/26972.html
- LibrePlanet Group:PowerVR drivers — https://libreplanet.org/wiki/Group:PowerVR_drivers
- powervr-devel list (useasm/pdsasm) — https://www.mail-archive.com/powervr-devel@listas.gnu.org.ve/msg00021.html
- Phoronix, "Reverse Engineering PowerVR Is Now A High Priority" — https://www.phoronix.com/news/OTEwMA
- CI20 list thread (Fryzek/Schaller, 2021-11) — https://groups.google.com/g/mips-creator-ci20-dev/c/XNBWlAb8DX8
- openpvrsgx list, Ivaylo Dimitrov 2021-10-30 — https://lists.goldelico.com/pipermail/openpvrsgx-devgroup/2021-October/000472.html
- SGX DT binding series (Andrew Davis, RFC v2) — https://patchew.org/linux/20240108183302.255055-1-afd@ti.com/ ;
  Rob Herring reply — https://www.mail-archive.com/dri-devel@lists.freedesktop.org/msg478004.html ;
  ARM SoC DT for 6.9 — https://lkml.rescloud.iu.edu/2403.1/04017.html
- Drm/imagination v5 cover — https://lkml.rescloud.iu.edu/2308.2/00181.html
- Wikipedia, Free and open-source graphics device driver (lima/freedreno/etnaviv/panfrost/vc4 dates) —
  https://en.wikipedia.org/wiki/Free_and_open-source_graphics_device_driver
- Phoronix etnaviv in 4.5 — https://www.phoronix.com/news/Etnaviv-DRM-Next-4.5
- Asahi: Phoronix first fully open triangle — https://www.phoronix.com/news/Asahi-Linux-First-Triangle ;
  Gigazine (2022-10-24 / 2022-11-30) — https://gigazine.net/gsc_news/en/20221024-asahi-linux-gpu-driver-asahi-lina/ ;
  Rust-for-Linux AGX page — https://rust-for-linux.com/apple-agx-gpu-driver
- GitHub repo metadata (`gh api repos/...`): laanwj/etna_viv (created 2012-12-31), yuq/mesa-lima (2017-06-10),
  grate-driver/grate (2013-03-05), AsahiLinux/gpu (2021-01-07); Codeberg API Garnet/sgx540-reversing (created 2022-08-10)

---

## Verification (2026-10-11)

An adversarial review re-ran every local check and re-opened the key URLs. It did not trust the
original report's outputs. The stock blobs were re-extracted with `debugfs -R "dump …"` from
`system.raw.img` into a separate scratch dir. All six SHA-256 sums and sizes matched the
`stock-libs/` copies; the re-extracted copies were then deleted. No device was touched and nothing
was written to the repo.

### Verdicts on the key claims

| # | Claim | Verdict | Reproduction / correction |
|---|---|---|---|
| 1 | Imagination: no plans to open SGX drivers or Series5 docs | **Confirmed** | Forum thread 3425: David.Hamill 2021-09-08 "no official plans to open-source the sgx drivers", 2021-09-15 "no official plans to release that documentation publicly" (also 2021-09-20); AlejandroC 2022-03-15; Nagnath 2023-05-11 "no recent developments" |
| 2 | Mesa imagination driver is Rogue-only | **Confirmed** | docs.mesa3d.org/drivers/powervr.html quote reproduced; supported: AXE-1-16M, BXM-4-64, BXS-4-64, GX6250 (partial). Mesa `bffd91947efc` exists (2026-10-10, "nvk: Use meta gfx for depth copies"); `src/imagination` = ci, common, csbgen, drm-shim, ds, include, pco, pdsc, vulkan (the claim listed 5 of 9; corrected in §4) |
| 3 | No independent SGX540 rendering; Garnet checklist | **Confirmed**, with one correction | Codeberg API: HEAD `c15884751ad8…` 2022-10-16; README lines 16-26 checklist as stated; ukernel sizes 22112/21744/23680/18480/44 confirmed by Codeberg contents API. Fork `c9ce47eef5a8` 2023-11-06, 10 commits ahead. **Correction:** the fork does not add "wrap.c and drv.c only". `gh api …/compare` shows 18 files: wrap/{wrap.c 940, pprint.c 405, pvr_ioctl.inc 239, pvr_heaps.h 99, sysinfo.h 48, dump_ioctl.c 45, pvr_ioctl.h 20}, drv/drv.c 206, tests/test.c 214, build scripts, plus +10 lines in hook-postmarket/ldpreload.c (the body text in §3.1 was already closer) |
| 4 | SGX535-reMESA first triangle 2026-10-06 | **Confirmed**, with one correction | `acc60f5ff157…` 2026-10-10 (gh API). FIRE3 doc l.3 date, l.62-64 words/bytes, l.188 32×32 / 120 px; README l.15 16×16 square; README l.5 start 2026-09-16; `demonstrable_3d_established=false`. **Correction:** "textures" is not in `unknown_in_this_reconstructed_path` (fixed in §3.4) |
| 5 | TG Poulsbo drove SGX535 without a uKernel; TA by register list, raster by closed X helper | **Partly wrong** | `psb-kmod @ ddb526815bb9` (2011-05-30). TA via `psb_reg_submit(ta_cmds)` l.314 is confirmed. **Raster is also fired by the kernel** via `psb_reg_submit(raster_cmds)` l.386. `psb_xhw_fire_raster` (l.328) is only reached for scene-less tasks. The closed XHW helper does scene bind (l.199), TA OOM (l.608), DPM reset and TA-mem load. `psb_drm.h` XHW opcodes as quoted. Fixed in TL;DR and §3.1 |
| 6 | SGX540 likely host-drivable (C2) | **Unverified; "likely" not supported** | The register overlap is real (`psb_reg.h` vs `sgx540defs.h`: 0x12C, 0x130, 0x0A0C, 0x0AB8, 0x0AC8, 0x0C00, 0x0C84). It covers host-interface registers only; CORE_ID, CORE_REVISION and DESIGNER_REV differ, and so does address-space size (32 vs 28 bits). The Poulsbo host path depended on closed register lists and a closed X helper. §9.1 C2 row reworded |
| 7 | 41 named registers + 16 USE_CODE_BASE | **Wrong count** | 40 fixed-address registers + the 16-entry `USE_CODE_BASE(X)` table = 41 register blocks. 605 lines confirmed. No TA/ISP/TSP/DPM/PBE register confirmed; the units appear only as bits. Fixed in TL;DR and §2.2 |
| 8 | MMU / uKernel host interface fully open (values) | **Confirmed** | `sgxmmu.h:49,54,68-74,77,89-93`; `sgxfeaturedefs.h:89-96` (SGX540: ADDRESS_SPACE 28, USE_PIPES 4; SGX535 block: 32 / 2); `sgx_mkif_km.h:70-84`; `sgxinfo.h:63-80` (TA=0 … FLUSHPDCACHE=10, MAX=11), `:94` `aui32HostKickAddr`. These are **1.17** headers. The stock KM is 1.8 and its struct layouts were not compared |
| 9 | uKernel in libsrv_init `.rodata`, 103 592 B, 1 968 B strings, no DEADBEEF | **Mostly confirmed** | `.rodata` @0x2074 size 0x194a8 ✔; `SrvInit` 0x1e60 size 532 is the only FUNC export ✔. Strings `SetupuKernel … USE program`, `LoaduKernelPDSInitPrograms …`, `SGX TA/SPM/3D` ✔. 0xDEADBEEF: 0 hits LE or BE, aligned or not, in the whole file ✔. **Correction:** the string total depends on the minimum length (1 975 B at `-n 6`, 2 479 B at `-n 4`), so it is now "≈2.0–2.5 KB". 40 567 zero bytes. That the remaining ~101 KB is uKernel code remains an inference |
| 10 | DDK 1.8@785978, compiler exports and addresses, libusc sha256 | **Confirmed**, with one correction | Both version strings reproduced from libGLESv2; all 16 compiler symbols, addresses and sizes in §5.2 reproduced with `readelf -W --dyn-syms`; libusc sha256 `f94c73b7…1740` ✔. **Correction:** libGLESv2 contains no `libusc.so` string; it reaches libusc via libglslcompiler's NEEDED (fixed in §5.2). **Added:** all 12 stock blobs are **softfp** (e_flags 0x5000002, no `Tag_ABI_VFP_args`), which matters for interposers on our armhf rootfs (§7 caveat) |
| 11 | `/dev/pvrsrvkm` bridge, `_IOWR('g',NN,28)`, SGXKickTA → 0xC01C6758 with 564 B | **Confirmed** | `arm-none-eabi-objdump` 0xa238–0xa310: `mov r3,#564` @0xa2ac, `ldr r1,[pc,#72]` → literal `c01c6758` @0xa308, `bl c674` @0xa2bc; single caller `bl a238` @0xf730 inside SGXKickTA (0xe674+4396). Word scan: 87 aligned (87 unaligned too), 81 distinct NN, range 0–115. Package = 7 × u32 (`pvr_bridge.h:311-320`). Stock KM: 88 = `PVRSRV_BRIDGE_SGX_DOKICK` → `SGXDoKickBW`. **Added:** the stock 1.8 core-group numbering differs from the 1.17 table (no COMPAT_CHECK; ALLOC=6, CONNECT=12); fixed in §5.2 |
| 12 | Stock kernel pvrsrvkm symbols | **Confirmed** | All 10 addresses in §5.2 reproduced in `kallsyms.txt`; `g_BridgeDispatchTable` 0xc07840e4 (B), next symbol `psHashTab` 0xc07842cc → 0x1e8 B. "365 lines" holds only case-insensitively (40 case-sensitive); noted |
| 13 | PDUMP KM cannot serve a release UM | **Confirmed** (upgraded from "likely") | `sgx_options.h:67-72`; `sgxinit.c:2713-2731` sets `PVRSRV_ERROR_BUILD_MISMATCH` and jumps to `chk_exit`, so it is fatal. PDUMP also inserts 19 bridge indices (`pvr_bridge.h:176-202`). This is for the 1.17 KM source |
| 14 | Closed-UM pvrsrvkm can never go upstream; only open Mesa | **Overreach; softened** | `drm-uapi.rst:56-58` @ v6.18 quote reproduced exactly. The rule requires open userspace in "a suitable and canonical upstream project"; it does not say Mesa, and it does not rule out a vendor releasing the UM source. Reworded in §8 |
| 15 | Mainline 6.18 DT: omap4 SGX540 rev 120 | **Confirmed** | `img,powervr-sgx.yaml` @ v6.18 l.25 `ti,omap4430-gpu # Rev 120`; absent at v6.8, present at v6.9. `omap4.dtsi` @ v6.18 l.502 `ranges = <0 0x56000000 0x2000000>`, l.504-508 `gpu@0`, 32 MB, `GIC_SPI 21`. `omap4460.dtsi` includes `omap4.dtsi` (l.7) |
| 16 | 2014 leak taints clean-room RE | **Confirmed** | libv 2014-11-21 "2011 era PowerVR SGX microcode and user space"; "horribly impractical and very unlikely" (same sentence); LG blamed for the GPL. Schaller 2021-11-09 "considered unethical by the community to make any use of it"; Fryzek 2021-11-12 "working userland" |
| 17 | NDA disassembler; Garnet hijack at 0x082994cb | **Confirmed** | Forum t/1998, JoeDavis 2014-02-13 "Series5 & Series5XT package of disassembly GLSL ES compilers are available under NDA". `asm_preload_hack.c` l.94-95 address and "may need to be adjusted" comment; gpuinfo `{SGX540 (=5), 101, …}`, name "SGX540" |
| 18 | Effort estimates (9–19 PM … 4–7 PY) | **Unverified (judgement)** | Not reproducible by construction. Calibration point checked: Asahi Lina tweet 2022-10-21 ">99% of the dEQP-GLES2" (Gigazine 2022-10-24); `AsahiLinux/gpu` created 2021-01-07, so ~21 months is right. Note: that userspace had been developed against the macOS kernel since 2021, so it is not a from-zero comparison |
| 19 | Compositor target ≈25–35 % | **Unverified (judgement)** | Reasoning only; no change |
| 20 | Rogue material gives structure, not Series5 encodings | **Confirmed for the ISA reference** | docs.imgtec.com ISA page: "Most of the information in this document applies to the PowerVR Series 6XT architecture"; no Series5/SGX/USSE mention. That no Rogue↔USSE1 encoding relation exists remains unproven (absence of evidence) |

### Not re-checked

These were not re-checked: the lima/freedreno/etnaviv/panfrost/vc4 dates in §6, the Ivaylo
Dimitrov list post, the Andrew Davis patchew series, the Series5 Architecture Guide sha256, the
`b6801bf89e00` TI UM commit (it appears in SGX535-reMESA `SGX535-reMESA:docs/architecture.md` and
`SGX535-reMESA:docs/phase7/7.5-firmware-microkernel.md`, not in `SGX535-reMESA:docs/firmware.md` as §3.3 implies), and the
LibrePlanet/FSF material. The original evidence stands for these, unaudited.

### DDK-version hygiene

Every KM header citation (`sgx540defs.h`, `sgxmmu.h`, `sgx_mkif_km.h`, `sgxinfo.h`,
`sgx_options.h`, `sgxinit.c`, the bridge table) is **1.17** (`e521fd7b65b0`, committed
2019-11-09). Every stock-blob citation is **1.8@785978**. The two must not be mixed. The bridge
core numbering already differs between them (§5.2), so `SGXMKIF_*` and kick-struct layouts
should be assumed to differ too until the stock KM disassembly is compared.
