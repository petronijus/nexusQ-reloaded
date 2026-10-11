# SGX540 groundwork 1/7: Stock ground truth: what Android (IAN67K, kernel 3.0.8) did for the SGX540

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

*Original working title: 01 — Stock ground truth: what Android (Nexus Q, IAN67K, kernel 3.0.8) did for the SGX540*

Date: 2026-10-11. Workstream 1 of the GPU groundwork. Research only: nothing was built,
flashed, committed or written into the repo. No Nexus Q unit was touched.

Evidence tags used throughout:
- `VA 0x…` / `sym+off`: address in `reverse-eng/vmlinux.bin` (raw ARM, load VA `0xC0008000`,
  symbols from `reverse-eng/tools/kallsyms.txt`), disassembled with `reverse-eng/tools/nqdis.py`
  and dumped with `reverse-eng/tools/dump.py` (capstone 5.0.7, scratch venv).
- `sys:/path`: a file read out of `reverse-eng/factory/tungsten-ian67k/system.raw.img` with
  `debugfs -R` (no mount). Copies are in `<session scratch>/stock-extract/fs/` (gitignored scratch,
  not in the repo).
- `rd:/path`: the stock boot.img ramdisk (unpacked to `<session scratch>/stock-extract/ramdisk/`).
- `xl:0x…` / `ub:0x…`: file offset in `xloader-phantasm-ian67k.img` / `bootloader-phantasm-steelheadb4h0j.img`.
- `src:` a file at `android.googlesource.com/kernel/omap`, branch
  `android-omap-steelhead-3.0-ics-aah` (tip `03a9286bb61a`, committed 2012-06-11), fetched 2026-10-11.
- `ml:` mainline file at stable tag `v6.18.48` on git.kernel.org, fetched 2026-10-11.
- **FACT** = read directly from an artifact; **INFERENCE** = reasoned from facts, stated as such;
  **UNVERIFIED** = could not be established, with the reason.

---

## TL;DR

1. **The stock kernel has the PowerVR driver built in, not as a module**: `PVRCore_Init` is an
   initcall at level 6 (`__initcall_PVRCore_Init6`, VA `0xc003cf54`), `OMAPLFB_Init` at level 7
   (`0xc003d3d8`); `/lib/modules` does not exist in `/system`. Stock defconfig: `CONFIG_PVR_SGX=y`,
   `CONFIG_SGX_DVFS_MODE_OPTIMIZED=y`, `CONFIG_PVR_USSE_EDM_STATUS_DEBUG=y`, `CONFIG_ION_OMAP=y`.
2. **DDK = Imagination SGX DDK 1.8, branch 18, build 785978**
   (`CustomerGoogle_Android_ogles1_ogles2_GPL sgxddk 18 1.8@785978`, VA `0xc0680738`).
   The kernel's compat check hard-codes DDK version `0x00010812` (1.8.18) and build `0xBFE3A`
   (= 785978) (`SGXDevInitCompatCheck`, VA `0xc0292ff4`/`0xc0293028`). Every userspace blob that
   prints a version says `1.8@785978` (libIMGegl "1.4 build 1.8@785978", libGLESv2
   "OpenGL ES 2.0 build 1.8@785978"). **Build-options mask `0x0036801c`** is shared by the KM and
   by `libsrv_um.so`/`libsrv_init.so`.
3. **Core = SGX540, SGX_CORE_REV 120 (= rev 1.2.0)**: the blob names
   (`libGLESv2_POWERVR_SGX540_120.so`, egl.cfg `0 1 POWERVR_SGX540_120`), `src:drivers/gpu/pvr/Makefile`
   (`-DSGX540 -DSUPPORT_SGX540 -DSGX_CORE_REV=120`). *(Corrected 2026-10-11: an earlier draft also
   cited "`0x00010200` constants in `libsrv_um.so`" — not reproducible: no aligned word or Thumb-2/ARM
   `movw #0x200`+`movt #1` pair holds that value in `libsrv_um.so` or `libsrv_init.so`; the only byte
   matches are unaligned, at file offsets `0x25327`/`0x2536f`/`0x253b7` inside what looks like USSE
   program data. So the numeric encoding 1.2.0 → `0x00010200` is INFERENCE from the
   `SysFinalise` format below, not a blob constant.)*
   The live HW revision register (`EUR_CR_CORE_REVISION`, SGX base + `0x24`, read in
   `SysFinalise` VA `0xc028fb0c`) was **not** read — no device access in this workstream.
4. **Platform glue (all FACT, all match the public source)**: hwmod `gpu`, regs
   `0x56000000–0x5600FFFF`, IRQ **53** (= GIC SPI 21), sysc rev/sysc at `+0xFE00`/`+0xFE10`,
   type2 fields, SIDLE+MIDLE with all four modes, main clock `gpu_fck` in `l3_gfx_clkdm` /
   `gfx_pwrdm` (PRM offset `0x1200`, pwrsts OFF|INACTIVE|ON), CLKCTRL `CM_GFX_GFX_CLKCTRL`
   (`0x4A009220`), OCP master/slave via `l3_main_2` on `l3_div_ck`, `dev_attr =
   smartreflex_core_dev_attr` (i.e. the GPU lives on **VDD_CORE**). Mainline 6.18 `omap4.dtsi`
   already carries the equivalent `sgx_module: target-module@56000000` + `gpu@0`
   (`"ti,omap4430-gpu", "img,powervr-sgx540"`, SPI 21, `power-domains = <&prm_gfx>`).
5. **Clock tree — the item that mainline does not reproduce**: `gpu_fck` is a mux on
   `CM_GFX_GFX_CLKCTRL[24]` (0 = `dpll_core_m7x2_ck`, 1 = `dpll_per_m7x2_ck`). The reset/bootloader
   parent is DPLL_CORE M7 = **266.67 MHz** (bootloader tables, `xl:0xaa3c`, 38.4 MHz row `xl:0xaa9c`;
   on mainline 6.18.48 this is now confirmed live: `nq-captures/20261010-185940/snapshot.txt:467-470`
   shows `l3-gfx-clkctrl:0000:24` under `dpll_core_m7x2_ck` at 266 666 667 Hz). **Stock's board file
   reparents `gpu_fck` to `dpll_per_m7x2_ck`** (`omap4_steelhead_display_init`, VA `0xc0075f08`–`0xc0075f48`)
   because the OPP table scales `dpll_per_m7x2_ck`. DPLL_PER boots at DCO×2 = 1536 MHz with
   M7 = 5 → **307.2 MHz**. Neither bootloader touches any GFX register.
6. **GPU OPPs on OMAP4460 (FACT, `omap446x_opp_def_list` VA `0xc0043e94`)**: 153.6 MHz @ VDD_CORE
   962 mV, 307.2 MHz @ 1127 mV, **384 MHz @ 1250 mV (core OPP100-OV)**; all three available;
   OMAP4430 has only the first two. 384 MHz therefore **requires VDD_CORE = 1.25 V** in stock.
7. **DVFS policy = Google's "sgx_idle_mode=2" (OPTIMIZED)**: SGX runs at the **highest** OPP
   (384 MHz) whenever busy and drops to the **lowest** (153.6 MHz) after an hrtimer of 1 ms (or
   3 ms − busy-time if the busy burst was < 2 ms) of idle, driven by microkernel active-power events
   (`SGXTestActivePowerEvent` → `SysSGXIdleTransition`). 307.2 MHz is never requested by this policy.
   Knobs (all `0644` under `/sys/module/pvrsrvkm/parameters/`): `sgx_idle_mode=2`,
   `sgx_idle_timeout=1000000` (ns), `sgx_apm_latency=100` (ms), `sgx_idle_logging=0`,
   `gPVRDebugLevel=7`. Plus debugfs `sgx_idle` (0444) and `/proc/pvr/{version,nodes,queue,debug_level,power_control}`.
8. **Userspace inventory (FACT, 13 PVR/IMG files in `sys:/vendor`)**: `pvrsrvinit`, `libsrv_um`,
   `libsrv_init` (**contains the SGX microkernel — there is no separate `.fw`**; the KM never calls
   `request_firmware`), `libIMGegl`, `libglslcompiler`, `libusc`, `libpvr2d`, `libpvrANDROID_WSEGL`,
   `libPVRScopeServices`, `egl/lib{EGL,GLESv1_CM,GLESv2}_POWERVR_SGX540_120.so`,
   `hw/gralloc.omap4.so` (+ TI `hw/hwcomposer.omap4.so`). sha256s in §9. No `powervr.ini` is shipped
   (libsrv_um looks for `/etc/powervr.ini`). Started by `rd:/init.steelhead.rc`
   `service pvrsrvinit /vendor/bin/pvrsrvinit` (class core, root, oneshot) after `chmod 0666 /dev/pvrsrvkm`.
9. **The stock blobs are not directly usable on our rootfs**: they link Bionic (`libc.so`,
   `libdl.so`, `libcutils.so`, `libhardware.so`, `/system/bin/linker`), use the **soft-float
   (base AAPCS) calling convention** (no `Tag_ABI_VFP_args`; they import `__aeabi_fadd` etc.) while
   postmarketOS armv7 is musl **armhf**, and their window-system layer is Android-only
   (`libpvrANDROID_WSEGL`, gralloc, OMAPLFB/fbdev + dsscomp). What *is* reusable: the version/ABI
   facts, the core revision, the clock/OPP/DVFS/power parameters, the shaders and the GPL KM source.
10. **The exact stock KM source is public and GPLv2**: Google's `kernel/omap` branch
    `android-omap-steelhead-3.0-ics-aah` contains `drivers/gpu/pvr` with `pvrversion.h` =
    1.8 / 18 / 785978 and the same `omap4/sysconfig.c` idle logic, Kconfig defaults and board file.
    The exact stock commit `ad584da` is **not** on that public branch (gitiles 404; stock built
    2012-06-29, branch tip 2012-06-11), but every GPU function compared is functionally identical.
11. **Version-matching consequence**: the only userspace that matches DDK 1.8@785978 is this
    Android set. The openpvrsgx tree has a 1.8 KM, but it is **`letux/pvrsrvkm-1.8.869593`**
    (a different build; the KM↔microkernel DDK-build check is exact), so stock blobs do not pair
    with any maintained KM out of the box. A Linux/Wayland path will use a *different* DDK
    (most likely 1.9.2188537, whose KM branch `letux/pvrsrvkm-1.9.2188537` was updated 2026-08-16).
    Caveat (verified 2026-10-11 on github.com commit lists): *every* top commit on both
    `letux/pvrsrvkm-1.8.869593` and `letux/pvrsrvkm-1.9.2188537` carries the date 2026-08-16, directly
    on top of "Linux 7.2" — i.e. a bulk rebase, not evidence of active per-DDK work; the 1.8.869593
    port's own history is "initial checkin" → "add initial Makefile (untested)" → Makefile fix.
    The same `1.8.869593/eurasia_km` directory is also present in the kernel-tracking branch
    `pvrsrvkm-7.2` (`drivers/gpu/drm/pvrsgx/`), alongside 1.5.15.3226 … 1.17.4948957 — still no 785978.
12. **Visualizer (FACT)**: OpenGL ES **2.0** via `android.opengl.GLES20` + `GLSurfaceView`
    (`setEGLContextClientVersion`, `detectOpenGLES20`), **31** GLSL ES 1.00 shader sources
    (20 fragment + 11 vertex, 9 776 B, among 42 `res/raw` files — the rest are 3 PNGs and 8
    `pointmorph_model_*` data files; corrected from "40" on 2026-10-11), every fragment shader
    `precision mediump float`, 40 *particles* (count per `docs/2026-06-19-particle-screensaver-RE.md:12`) drawn as **point sprites** (`gl_PointSize = 60.0`,
    `gl_PointCoord`). No `setEGLConfigChooser` call anywhere in the odex → it gets ICS's default
    chooser = **RGB565, depth ≥ 16, no stencil** (AOSP 4.0.4 `GLSurfaceView.java:967`).
    `ro.opengles.version=131072` (0x20000 = GLES 2.0).

---

## 1. Artifacts and method

| Artifact | sha256 | Notes |
|---|---|---|
| `reverse-eng/vmlinux.bin` | `089f4c90b8a61ca74161af1cab65f67922361bc364aa674a015f3f8d64aa8f4b` | `Linux version 3.0.8-gad584da (android-build@vpbs1.mtv.corp.google.com) (gcc version 4.6.x-google 20120106 (prerelease)) #1 SMP PREEMPT Fri Jun 29 15:12:1…` |
| `factory/tungsten-ian67k/boot.img` | `9e9756c94af9556a4c2121e0babce11262ec0c279b4d605123a80306adf0b505` | page 2048, kernel 3 726 816 B, ramdisk 166 303 B |
| `factory/tungsten-ian67k/system.raw.img` | `5f527217af00111ba0899beb4f2af30a5c526cec27baa58071f8b01a30365643` | ext4; `ro.build.fingerprint=google/tungsten/phantasm:4.0.4/IAN67K/403218:user/release-keys` |
| `factory/tungsten-ian67k/xloader-phantasm-ian67k.img` | `a21e45b1f303b6e5003c5dfaf36b5d18af71ad869f8e80fe889300e07777204a` | load base derived statistically: file off `0x200` ↔ VA `0x40300000` (base `0x402ffe00`) |
| `factory/tungsten-ian67k/bootloader-phantasm-steelheadb4h0j.img` | `2ec65855a7574358c3dbea5f0a2226ce08f6469c62bcba62685b823fb54a185a` | base `0x800fffc0` (header 0x40 → load `0x80100000`, matches `reverse-eng/README.md`) |

Tooling note: `capstone` was not installed for the system python; a scratch venv
(`<session scratch>/venv`) was used to run the repo's `nqdis.py`/`dump.py`/`callers.py` unchanged.

---

## 2. How the SGX driver is built into the stock kernel

### 2.1 Built-in, with init order
- FACT: `PVRCore_Init` `0xc0025920` with `__initcall_PVRCore_Init6` `0xc003cf54` (device_initcall);
  `OMAPLFB_Init` `0xc0025af0` with `__initcall_OMAPLFB_Init7` `0xc003d3d8` (late_initcall);
  `omap_init_gpu` `0xc0556ac0` is called from `omap2_init_devices+0x218` (`0xc000f91c`),
  itself `__initcall_omap2_init_devices3` (arch_initcall) `0xc003cc30`;
  `omap4_opp_init` is `__initcall_omap4_opp_init6` `0xc003cd80`.
- FACT: `sys:/lib/modules` does not exist; no `pvrsrvkm.ko` anywhere in `/system`.
- FACT (`src:arch/arm/configs/steelhead_defconfig`, lines 291–305): `CONFIG_PVR_SGX=y`,
  `CONFIG_PVR_NEED_PVR_DPF=y`, `CONFIG_PVR_NEED_PVR_ASSERT=y`, `CONFIG_PVR_USSE_EDM_STATUS_DEBUG=y`,
  `CONFIG_SGX_DVFS_MODE_OPTIMIZED=y`, `CONFIG_ION=y`, `CONFIG_ION_OMAP=y`, `CONFIG_OMAP2_DSS=y`,
  `CONFIG_OMAP2_VRAM_SIZE=16`, `CONFIG_FB_OMAP2=y`, `# CONFIG_FB_OMAP_BOOTLOADER_INIT is not set`,
  `CONFIG_OMAP2_HDMI_DEFAULT_DISPLAY=y` (line 466). Kconfig defaults that therefore apply
  (`src:drivers/gpu/pvr/Kconfig`): `PVR_SGXCORE_540`, `PVR_BUILD_RELEASE`, `PVR_PERCONTEXT_PB=y`,
  `PVR_ACTIVE_POWER_MANAGEMENT=y`, `PVR_ACTIVE_POWER_LATENCY_MS=100`,
  `PVR_SGX_LOW_LATENCY_SCHEDULING=y`, `PVR_DUMP_MK_TRACE=y`, `SGX_DVFS_IDLE_TIMEOUT=1000` (µs).

### 2.2 Compile flags (`src:drivers/gpu/pvr/Makefile`)
`-DLINUX -DANDROID -DPVR_BUILD_DIR="omap4430_android" -DSUPPORT_SGX -DTRANSFER_QUEUE
-DSGX_DYNAMIC_TIMING_INFO -DSUPPORT_HW_RECOVERY -DLDM_PLATFORM -DSUPPORT_SGX_NEW_STATUS_VALS
-DSUPPORT_SGX_HWPERF -DSYS_USING_INTERRUPTS -DPVR_SECURE_HANDLES -DPVR_LINUX_USING_WORKQUEUES
-DPVR_LINUX_MISR_USING_PRIVATE_WORKQUEUE -DPVR_LINUX_TIMERS_USING_WORKQUEUES
-DSYS_CUSTOM_POWERLOCK_WRAP -DSUPPORT_MEMINFO_IDS -DDISPLAY_CONTROLLER=omaplfb
-DPVRSRV_MODNAME="pvrsrvkm" -DSUPPORT_DC_CMDCOMPLETE_WHEN_NO_LONGER_DISPLAYED
-DSUPPORT_LARGE_GENERAL_HEAP -DPVR_NO_OMAP_TIMER -DSYS_SUPPORTS_SGX_IDLE_CALLBACK
-DPVRSRV_REFCOUNT_DEBUG` plus `-DSGX540 -DSUPPORT_SGX540 -DSGX_CORE_REV=120`.
FACT: the binary carries `omap4430_android` at VA `0xc0680778` (the `PVR_BUILD_DIR` string).

### 2.3 DDK version identity (FACT)
| Where | Value |
|---|---|
| VA `0xc0680738` (used by `ProcSeqShowVersion+0x84` and `SGXDumpDebugInfo+0x288`) | `CustomerGoogle_Android_ogles1_ogles2_GPL sgxddk 18 1.8@785978` |
| `SGXDevInitCompatCheck` `0xc0292ff4` | DDK version must equal `0x00010812` (MAJ 1, MIN 8, BRANCH 0x12 = 18) |
| `SGXDevInitCompatCheck` `0xc0293028` | DDK build must equal `0x000BFE3A` = **785978** |
| `src:drivers/gpu/pvr/pvrversion.h` | `PVRVERSION_MAJ 1`, `MIN 8`, `BRANCH 18`, `BUILD 785978`, `BSCONTROL "CustomerGoogle_Android_ogles1_ogles2_GPL"` |
| `/proc/pvr/version` format (VA `0xc0680724`, `0xc068078c`) | `Version %s (%s) %s` + `System Version String: %s` → would print `Version CustomerGoogle_Android_ogles1_ogles2_GPL sgxddk 18 1.8@785978 (release) omap4430_android` then `System Version String: SGX revision = <maj>.<min>.<maint>` (INFERENCE from format strings + source; never observed live) |

### 2.4 KM build-options mask and its meaning (FACT + decode from source)
`SGXDevInitCompatCheck` compares the client's options against **`0x0036801c`**
(`movw/movt` at `0xc0292f58`/`0xc0292f5c`). Decoded with `src:drivers/gpu/pvr/sgx_options.h`:

| bit | option |
|---|---|
| 2 | `PVRSRV_USSE_EDM_STATUS_DEBUG` |
| 3 | `SUPPORT_HW_RECOVERY` |
| 4 | `PVR_SECURE_HANDLES` |
| 15 | `SUPPORT_ACTIVE_POWER_MANAGEMENT` |
| 17 | `SUPPORT_PERCONTEXT_PB` |
| 18 | `SUPPORT_SGX_HWPERF` |
| 20 | `SUPPORT_SGX_PRIORITY_SCHEDULING` |
| 21 | `SUPPORT_SGX_LOW_LATENCY_SCHEDULING` |

The same 32-bit constant appears in `sys:/vendor/lib/libsrv_um.so` (file offsets `0x9fb4`, `0xb0d0`,
next to `0x10812` at `0x9fc8` and 785978 at `0x9fcc`) and in `libsrv_init.so` (`0x1774`, `0x3364`).
INFERENCE: any KM we build to run *these* blobs must reproduce exactly this option set (plus
matching SGXMKIF structure sizes — the check at `0xc02930b8`… compares HOST_CTL, COMMAND, CMDTA,
CMDTA_SHARED, TRANSFERCMD, TRANSFERCMD_SHARED, 3DREGISTERS, HWPBDESC, HWRENDERCONTEXT,
HWRENDERDETAILS, HWRTDATA, …).

Core-revision check (`0xc0293054`…`0xc02930b4`): if the microkernel-reported SW core rev is 0 the
check is skipped; the only exception pair compiled in is HW `0x10100` / SW `0x10101` (generic IMG
code, not OMAP4-specific); otherwise HW rev must equal SW rev or init fails with
"(FAIL) SGXInit: Incompatible HW core rev". INFERENCE: since stock graphics worked on shipped units
with `_120` blobs, the SGX540 in this OMAP4460 reports `0x00010200` (1.2.0). UNVERIFIED on our unit.

---

## 3. Platform device, hwmod and power/clock domains (FACT unless marked)

### 3.1 `omap_init_gpu` (VA `0xc0556ac0`, `src:arch/arm/mach-omap2/devices.c:898`)
- `snprintf(oh_name, 16, "gpu")` → `omap_hwmod_lookup("gpu")`.
- `pdata = kzalloc(sizeof(struct gpu_platform_data) = 0x18)`; fields
  (`src:arch/arm/plat-omap/include/plat/gpu.h`): `ovfreqs` (+0), `set_min_bus_tput` (+4, left NULL),
  `device_scale = omap_device_scale` (+8), `device_enable = omap_device_enable` (+0xc),
  `device_shutdown = omap_device_shutdown` (+0x10), `device_idle = omap_device_idle` (+0x14).
- `ovfreqs = 1` iff `omap_rev() >> 20 == 0x446` (`0xc0556b7c`–`0xc0556b9c`). `ovfreqs` is not
  read anywhere in the PVR sys layer (grep of the source tree); the OV OPP is reached via the OPP
  table instead (§4.3).
- `omap_device_build("pvrsrvkm", 0, oh, pdata, 0x18, omap_gpu_latency, 1, 0)` → platform device
  **`pvrsrvkm.0`**; `omap_gpu_latency` (VA `0xc0705500`) = `{deactivate=omap_device_idle_hwmods,
  activate=omap_device_enable_hwmods, latencies 0, flags=2 (OMAP_DEVICE_LATENCY_AUTO_ADJUST)}`.
- then `platform_device_register(&omap_omaplfb_device)` (VA `0xc0705520`, name `"omaplfb"`, id −1).

### 3.2 `omap44xx_gpu_hwmod` (VA `0xc0715264`; `src:omap_hwmod_44xx_data.c:2927`)
| Field | Value | Evidence |
|---|---|---|
| name / class | `"gpu"` / `omap44xx_gpu_hwmod_class` | `0xc0715264`, `0xc071726c` |
| IRQ | `{ .irq = 53 }` (= 32 + SPI 21) | `omap44xx_gpu_irqs` `0xc0717280` |
| CLKCTRL | `0xfc009220` = `CM_GFX_GFX_CLKCTRL` (PA `0x4A009220`) | hwmod +0x1c |
| main_clk | `"gpu_fck"` | `0xc0715290` |
| slave port | `l3_main_2 → gpu`, clk `l3_div_ck`, addr `0x56000000–0x5600FFFF` flags 2 (`ADDR_TYPE_RT`), user MPU\|SDMA | `0xc07181fc`, `0xc0718d30` |
| master port | `gpu → l3_main_2`, clk `l3_div_ck` | `0xc0717c60` |
| dev_attr | `smartreflex_core_dev_attr` (sensor voltdm `"core"`) | `0xc07152a4` → `0xc0717290` |
| sysc | rev `0xFE00`, sysc `0xFE10`, flags `0x60` (SIDLEMODE\|MIDLEMODE), idlemodes `0xFF` (SIDLE force/no/smart/smart-wkup + MSTANDBY force/no/smart/smart-wkup), fields `omap_hwmod_sysc_type2` | `omap44xx_gpu_sysc` `0xc07181ec` |

### 3.3 Power and clock domain
- `gfx_44xx_pwrdm` (VA `0xc070abc8`): name `gfx_pwrdm`, voltdm `"core"`, `prcm_offs 0x1200`
  (PRM GFX instance = `0x4A307200`), pwrsts byte `0x0d` = OFF\|INACTIVE\|ON, flags
  `PWRDM_HAS_LOWPOWERSTATECHANGE`, 1 bank, mem_ret OFF, mem_on ON;
  source adds `wakeup_lat[OFF] = 1000` (`src:powerdomains44xx_data.c:82`, struct starts at :67).
- `l3_gfx_44xx_clkdm` (VA `0xc070bf9c`): `l3_gfx_clkdm` in `gfx_pwrdm`, CM2 GFX instance,
  `CLKDM_CAN_HWSUP_SWSUP`, wake/sleep deps on `ivahd_clkdm`, `l3_1_clkdm`, `l3_emif_clkdm`
  (`src:clockdomains44xx_data.c:219`, `:417`).
- TI prcm-debug tables `pd_sgx`/`cd_sgx`/`mod_sgx` (VA `0xc0707150`/`0xc0707bc8`/`0xc0708658`)
  confirm the same offsets (`PD_SGX` at PRM `0x1200`, `mod_sgx` at `0xfc009220`).
- Mainline comparison (ml): `powerdomains44xx_data.c` `gfx_44xx_pwrdm.pwrsts = PWRSTS_OFF_ON`
  (no INACTIVE), otherwise identical; `omap4.dtsi` `prm_gfx: prm@1200`.

### 3.4 Register window, IRQ, SoC constants (`src:drivers/gpu/pvr/omap4/sysconfig.h`)
`SYS_OMAP4430_SGX_REGS_SYS_PHYS_BASE 0x56000000`, `SYS_OMAP4430_SGX_REGS_SIZE 0xFFFF`,
`SYS_OMAP4430_SGX_IRQ 53`, `SYS_SGX_CLOCK_SPEED 307200000` (for `SGX540 && SGX_CORE_REV==120`;
only a fallback — dynamic timing info overrides it, §5.3), `SYS_SGX_HWRECOVERY_TIMEOUT_FREQ 100`,
`SYS_SGX_PDS_TIMER_FREQ 1000`. In the binary, `SysInitialise` takes base/size/IRQ from the
platform device (`platform_get_resource(IORESOURCE_MEM)` `0xc028ffd0`, `platform_get_irq`
`0xc028ffe8`) and traces "SGX register base/size/IRQ".

---

## 4. Clock tree and OPPs

### 4.1 `gpu_fck` (VA `0xc07115a4`)
`struct clk`: ops `clkops_omap4_dflt_wait`, name `gpu_fck`, static parent `dpll_core_m7x2_ck`,
`enable_reg 0xfc009220`, `enable_bit 1` (→ writes MODULEMODE = 2, SW-explicit enable),
`clksel_reg 0xfc009220`, `clksel_mask 0x01000000` (bit 24), `clksel = sgx_clk_mux_sel`
(VA `0xc05636b8`: index 0 → `dpll_core_m7x2_ck`, index 1 → `dpll_per_m7x2_ck`), init
`omap2_init_clksel_parent` (reads the HW mux at boot), clkdm `l3_gfx_clkdm`.

### 4.2 Board-file reparent (FACT)
`omap4_steelhead_display_init` (VA `0xc0075ef8`, called from `steelhead_init+0x4d0`):
`clk_get(NULL,"dpll_per_m7x2_ck")` → `clk_get(NULL,"gpu_fck")` → `clk_set_parent(gpu_fck,
dpll_per_m7x2_ck)` (`0xc0075f40`), errors printed with "failed to set gpu_fck to dpll_per_m7x2_ck".
Source comment (`src:board-steelhead.c:1156`): *"set the clock source for gfx to DPLL_PER, not sure
why it's not already that way because the OPP definition for gpu_fck says to use DPLL_PER, but the
default source is DPLL_CORE and nothing else appears to set the source."*
The same function then does `omap_vram_set_sdram_vram(16 MiB, 0)`, `omapfb_set_platform_data`,
HDMI pad mux (`hdmi_cec`, `hdmi_ddc_scl/sda`, gpio 63 `hdmi_hpd` IN, gpio 60 `hdmi_ct_cp_hpd` OUT
high, gpio 41 `hdmi_gpio_ls_oe` OUT high) and `omap_display_init`.

### 4.3 OPP table (FACT, binary == source)
`omap446x_opp_def_list` (VA `0xc0043d5c`, `src:opp4xxx_data.c:265`) — entries
`{hwmod, voltdm, clk, rate, µV, available}`:

| OPP | clock | rate | VDD_CORE | available | VA |
|---|---|---|---|---|---|
| SGX OPP50 | `dpll_per_m7x2_ck` | 153 600 000 | 962 000 µV | 1 | `0xc0043e94` |
| SGX OPP100 | `dpll_per_m7x2_ck` | 307 200 000 | 1 127 000 µV | 1 | `0xc0043eac` |
| SGX OPP-OV | `dpll_per_m7x2_ck` | 384 000 000 | 1 250 000 µV | 1 | `0xc0043ec4` |

For context, the same table on the same voltdm: `l3_main_1` 100 MHz @ 962 mV, 200 MHz @ 1127 mV,
200 MHz @ 1250 mV; `fdif` 32/64/128 MHz. OMAP4430 list (`omap443x_opp_def_list`, VA `0xc0043c9c`)
has only 153.6 and 307.2 MHz for `gpu`. `omap4_opp_init` (VA `0xc0012a9c`) only enables MPU
1.2 GHz when fused; `opp_disable` is called only from `omap_init_opp_table` for entries with
`available = 0`; so all three GPU OPPs are live on stock 4460.

### 4.4 Bootloader state (FACT; lesson of 2026-07-12 applied)
- **DPLL_PER** params, identical in both x-loader (table base `xl:0xa9cc`, VA `0x4030a7cc`) and u-boot
  (`ub:0x21ec8`, VA `0x80121e88`), used via `CM_CLKMODE_DPLL_PER 0x4A008140` (`xl:0x5be8`,
  `ub:0x1d7c`). The table has 7 rows of 16 B (`u32 M, u32 N, u8 M2..M7`), one per sysclk
  12/13/16.8/19.2/26/27/38.4 MHz; the base row is the 12 MHz one (`M=64 N=0`), the 38.4 MHz row is
  `xl:0xaa2c` (`M=20 N=0`). Every row gives DCO×2 = **1536 MHz**, `M2=8 M3=6 M4=12 M5=9 M6=4
  M7=5` → `dpll_per_m7x2_ck` = **307.2 MHz** at kernel entry whatever the sysclk.
- **DPLL_CORE** params for the 4460 branch (table base `xl:0xaa3c`, VA `0x4030a83c`; 38.4 MHz row
  `xl:0xaa9c`; selected at `xl:0x54d8`–`0x5500`: rev `0x44300100` → 1524 MHz table `xl:0xa8ec`,
  rev `0x44300200` or `-1` → 1600 MHz/M2=2 table `xl:0xa95c`, anything else → `xl:0xaa3c`;
  identical 38.4 MHz row at `ub:0x21dd4`, table base `ub:0x21d74`): `M=125 N=5`,
  DCO×2 = 1600 MHz, `M2=1`, `M7=6` → `dpll_core_m7x2_ck` = **266.67 MHz**. *(Corrected 2026-10-11:
  an earlier draft gave the file offset as `xl:0xa8fc`, which is the 13 MHz row of the 4430-ES1.0
  1524 MHz table; the VA `0x4030a83c` was right. All three core tables have `M7=6`.)*
- Cross-check on mainline (on-device capture `nq-captures/20261010-185940/snapshot.txt`, kernel
  6.18.48-r20, 2026-10-10): `dpll_per_ck` 768 MHz, `dpll_per_m7x2_ck` 307 200 000 Hz,
  `dpll_core_x2_ck` 1 600 000 000 Hz, `dpll_core_m7x2_ck` 266 666 667 Hz (lines 324, 333, 465, 467) —
  consistent with these bootloader values.
- **No GFX register is written by either bootloader**: no literal in
  `0x4A0091xx–0x4A0092xx` / `0x4A3072xx` in either image; every load/store with offsets
  `0x200/0x204/0x208/0x220` resolves to the control module `0x4A002000` (ID_CODE/die-ID) or to
  RAM structures (`xl:0x51a0`, `ub:0x14b4`, `ub:0x306c`, `ub:0x20f70`, …). The GFX mux therefore
  starts at its reset value (INFERENCE from the board-file comment: 0 = DPLL_CORE) and the GFX
  power/clock domains at their reset state.

### 4.5 Rates over the boot (INFERENCE from 4.1–4.4 + §5)
reset/bootloader: SGX fck = DPLL_CORE M7 = 266.67 MHz (module not enabled) → board init: mux →
DPLL_PER M7 = 307.2 MHz → first `RequestSGXFreq` after a busy event: `omap_device_scale(gpu,
384 MHz)` → DPLL_PER M7 divider 4 (1536/4) and VDD_CORE raised to OPP100-OV 1.25 V (via the
core voltdm DVFS) → idle: 153.6 MHz (M7 = 10) at 962 mV (if no other core user holds it higher).
The divider arithmetic (1536/4/5/10) is exact; that the omap_device_scale path programs M7 is
INFERENCE (the OPP clock name is `dpll_per_m7x2_ck`; the omap DVFS code was not disassembled).

---

## 5. Runtime behaviour: power management and DVFS

### 5.1 Init path (binary, `drivers/gpu/pvr/omap4/sysconfig.c`)
`PVRSRVDriverProbe` (`0xc0276114`, creates an ION client) → `SysInitialise` (`0xc028fef4`…):
`PVRSRVInit` → `platform_get_resource/irq` → `OSMapPhysToLin(base, size)` →
`SysPMRuntimeRegister` (`pm_runtime_enable`) → **`SysDvfsInitialize`** → `PVRSRVRegisterDevice
(SGXRegisterDevice)` → `EnableSystemClocks` (only inits a mutex) → `EnableSGXClocks` →
`PVRSRVInitialiseDevice` → `DisableSGXClocks` → `debugfs_create_file("sgx_idle", 0444)` →
`hrtimer_init(sgx_idle_timer)` → `alloc_workqueue("sgx_idle")`.
Later, when `pvrsrvinit` disconnects: `SysFinalise` (`0xc028fa80`): `EnableSGXClocks` →
`OSInstallMISR` → `OSInstallDeviceLISR("SGX ISR")` → map regs, **read SGX reg `0x24`**
(`EUR_CR_CORE_REVISION`) → `"SGX revision = %u.%u.%u"` from bits [23:16].[15:8].[7:0] →
`DisableSGXClocks`.

### 5.2 Clock enable/disable (`EnableSGXClocks` `0xc0290d18`, `DisableSGXClocks` `0xc0290dec`)
Enable = `pm_runtime_get_sync` (`__pm_runtime_resume(dev, RPM_GET_PUT)`) + `SysEnableSGXInterrupts`;
Disable = `SysDisableSGXInterrupts` + `pm_runtime_put_sync`. Only when `sgx_idle_mode == 0` do they
also call `RequestSGXFreq(max)` / `RequestSGXFreq(min)`. The runtime-PM callbacks reach
`omap_device_enable/idle` → hwmod enable/idle (clkdm wake, `gpu_fck` MODULEMODE, sysc).

### 5.3 Frequency list and request (`SysDvfsInitialize` `0xc0290f80`, `RequestSGXFreq` `0xc0290c28`)
- List = all OPPs of the `pvrsrvkm` device ascending, plus a duplicate of the highest as an
  "unknown" slot: `[153.6, 307.2, 384, 384]`, size 4, start index 3 ("unknown" = assume highest
  so APM/HW-recovery timers err long; source comment).
- `RequestSGXFreq(bMax)`: index = `bMax ? size-2 (=2 → 384 MHz) : 0 (153.6 MHz)`; calls
  `pdata->device_scale(dev, dev, freq)` = `omap_device_scale`; on `-EBUSY` or error the index is
  set to the "unknown" slot so the next request retries.
- `SysGetSGXTimingInformation` (`0xc0290bb0`): `ui32CoreClockSpeed = list[index]`,
  `ui32HWRecoveryFreq = 100`, `bEnableActivePM = 1`, `ui32ActivePowManLatencyms = sgx_apm_latency`
  (100), `ui32uKernelFreq = 1000`.

### 5.4 Google's idle governor (`SysSGXIdleTransition` `0xc029091c`; `src:sysconfig.c:1201`)
Called from `SGXTestActivePowerEvent` (`0xc0295b4c`, `0xc0295bb8`), i.e. on microkernel
active-power events.
- busy (`bSGXIdle = 0`), mode ≠ 0: cancel hrtimer + work; `RequestSGXFreq(max)` → 384 MHz;
  record `sgx_idle_last_busy = ktime_get()`.
- idle, mode 1 ("LINEAR"): arm hrtimer for `sgx_idle_timeout` ns (1 000 000 = 1 ms).
- idle, mode 2 ("OPTIMIZED", **stock default**, `sgx_idle_mode` = 2 at VA `0xc0725ba4`):
  if the busy burst lasted < 2 ms (`0x1e847f` compare at `0xc0290a2c`), timeout = 3 ms − burst
  (`0x2dc6c0` = 3 000 000 ns), else 1 ms.
- timer → `sgx_idle_work_func` (`0xc028fa54`) → `RequestSGXFreq(min)` → 153.6 MHz.
- mode 0 ("NONE"): no governor; frequency follows clock enable/disable (max while powered).
- Logging ring (`sgx_idle_log_*`, debugfs `sgx_idle`) only when `sgx_idle_logging=1`.

### 5.5 Module parameters (FACT; `__param_*` VA `0xc06ec8b4`–`0xc06ec900`, perms `0x1a4` = 0644)
| param | default | meaning |
|---|---|---|
| `pvrsrvkm.sgx_apm_latency` | 100 | ms of idle before SGX active power-down (APM) |
| `pvrsrvkm.sgx_idle_timeout` | 1 000 000 | ns before dropping to min OPP (mode 1/2) |
| `pvrsrvkm.sgx_idle_mode` | 2 | 0 none / 1 linear / 2 optimized |
| `pvrsrvkm.sgx_idle_logging` | false | event log in debugfs `sgx_idle` |
| `pvrsrvkm.gPVRDebugLevel` | 7 | fatal\|error\|warning |

`/proc/pvr/`: `queue`, `version`, `nodes`, `debug_level` (rw), `power_control` (rw)
(`src:drivers/gpu/pvr/proc.c:591–617`).

---

## 6. Memory: ION, TILER, VRAM (FACT)
`steelhead_reserve` (VA `0xc001658c`) removes `0xA0000000+2 MiB`, `0xBFD00000+3 MiB` (SMC),
`0xB3A00000+105 MiB` and the ION carveouts; `omap_ipu_set_static_mempool(0xB3A00000, 0xC300000)`.
`sh_ion_data` (VA `0xc0719710`, `src:board-steelhead.c:163`), device `"ion-omap4"`:

| heap | type | id | base | size |
|---|---|---|---|---|
| `secure_input` | CARVEOUT (2) | 2 | `0xBA300000` | 90 MiB |
| `tiler` | OMAP TILER (4) | 1 | `0xAE900000` | 81 MiB |
| `nonsecure_tiler` | OMAP TILER (4) | 3 | `0xAC900000` | 32 MiB |

FB VRAM 16 MiB SDRAM (`omap_vram_set_sdram_vram`). PVR KM is ION-aware: probe creates an ION
client (`"PVRSRVDriverProbe: Couldn't create ion client"`), `PVRSRVExportFDToIONHandle` is exported,
and `mm.c` can back allocations from the ION TILER heap (`"Failed to allocate via ion_tiler"`).
`gralloc.omap4.so` notes `"SW write usage bits are not supported for allocations going via TILER"`.
INFERENCE: stock scanout/render buffers lived in TILER 2D space; the SGX itself does not need a
carveout (GPU heaps are page-allocated by the KM). For mainline, omapdrm owns DMM/TILER; our
defconfig has `CONFIG_DRM=y`, `CONFIG_DRM_OMAP=y` (`kernel/configs/steelhead_defconfig:2830,2869`)
and `CONFIG_CMA_SIZE_MBYTES=16` (`:5529`).

---

## 7. Display-side kernel pieces in stock (for orientation)
`omaplfb` (PVR display-class driver over `fb0`; strings `drivers/gpu/pvr/omaplfb/omaplfb_displayclass.c`,
"PowerVR OMAP Linux Display Driver"), TI `dsscomp` (`/dev/dsscomp`, used by `hwcomposer.omap4.so`),
`tiler`/`dmm` (`/dev/tiler`, `/dev/dmm`), `ion` (`/dev/ion`); HDMI is the default display
(`omap4_steelhead_dss_data`: 1 device, default = `omap4_steelhead_hdmi_device`, VA `0xc0719800`).
None of these exist in mainline; omapdrm (+ its DMM) replaces all four.

---

## 8. Userspace start-up (FACT)
- `rd:/init.steelhead.rc`: `on boot` → `chmod 0666 /dev/pvrsrvkm`; `on fs` → `chmod 0777 /dev/tiler`,
  `/dev/dmm`, `/dev/ion`; `service pvrsrvinit /vendor/bin/pvrsrvinit` — `class core`, `user root`,
  `group root`, `oneshot`; `setprop persist.hwc.mirroring.region 0:0:1920:1080`.
- `rd:/ueventd.steelhead.rc`: `/dev/dsscomp 0666 system system`, `/dev/tiler 0666 system system`.
- `sys:/lib/egl/egl.cfg`: `0 0 android` / `0 1 POWERVR_SGX540_120` → Android's EGL loader picks
  `sys:/vendor/lib/egl/lib{EGL,GLESv1_CM,GLESv2}_POWERVR_SGX540_120.so`.
- `sys:/build.prop`: `ro.opengles.version=131072` (GLES 2.0), `ro.sf.lcd_density=320`.
- No `powervr.ini` anywhere in `/system` (`libsrv_um.so` reads AppHints from `/etc/powervr.ini`).
- **Microkernel**: `libsrv_init.so` contains `SetupuKernel`, `LoaduKernelPDSInitPrograms`,
  `"SGX ukernel"`, EDM programs — the uKernel is uploaded by `pvrsrvinit` through the bridge.
  `sys:/vendor/firmware` holds only `bcm4330.hcd`, `ducati-m3.bin`, `fw_bcmdhd*.bin`,
  `libpn544_fw.so`, `sledadk_controller.bin`, `smc_pa_wvdrm.ift` (+ `hdcp.keys` symlink); the only
  direct `request_firmware` callers in the kernel are in `wl_cfg80211_request_fw` (callers.py; two
  BL sites `0xc0310c10`, `0xc0310c64`). `request_firmware_nowait` is called from `hdcp_init+0x198`
  and `rproc_get+0x14c` — neither is PVR. (callers.py only finds direct BL/BLX, so an indirect call
  through a function pointer would be missed; none is expected in the PVR KM.)

---

## 9. Userspace inventory (FACT; sizes/sha256 of files extracted with `debugfs rdump`)

| File (`sys:`) | Size | sha256 | Version string / role | DT_NEEDED |
|---|---|---|---|---|
| `/vendor/bin/pvrsrvinit` | 5 432 | `0e22700666cf4021d75cab7bd16cb5e2ad6bc14fe4ddb879f2fed219c430ec80` | services init (oneshot) | libc libdl libcutils libsrv_init libsrv_um |
| `/vendor/lib/libsrv_um.so` | 190 204 | `f177b896e7b37e6afd6e82a1eeef8923035fec15d15af64c32bb127db4b946fa` | user-mode services; opens `/dev/pvrsrvkm`; options `0x36801c`, DDK `0x10812`, build 785978 | libc libdl libcutils libhardware |
| `/vendor/lib/libsrv_init.so` | 115 708 | `c4dee422fb9c3364ff8128958c077da847f2eb18c4b43e2d47b198f849691926` | srvinit + **embedded SGX microkernel** | libc libdl libcutils libsrv_um |
| `/vendor/lib/libIMGegl.so` | 71 532 | `dddc3f7dbc75a83d41d104b9bd4eada59a37889869f0876b2fe9cfbfce424a38` | `1.4 build 1.8@785978` (EGL 1.4) | libc libdl libcutils libsrv_um |
| `/vendor/lib/libglslcompiler.so` | 253 264 | `bd921d395704180e982ec16c2a8fe7418956b2677d468bf3779de29097d6b6b1` | GLSL ES compiler; contains 785978 | … libsrv_um libusc libm |
| `/vendor/lib/libusc.so` | 898 564 | `f94c73b7206ec306e81e4585ae7621cef3eb5a65a20642a16420178d538a1740` | USSE shader compiler backend | libc libdl libcutils |
| `/vendor/lib/libpvr2d.so` | 21 708 | `b8b99b0a9123e4bde6723454b4343cd14373b6ac1e7c753e7efc7034f2b45c23` | PVR2D blitter | … libsrv_um |
| `/vendor/lib/libpvrANDROID_WSEGL.so` | 13 600 | `f14d2555c3078f162a2d954a57fc4a92690cf61bd377af10c61c5e5c7ca03eb2` | Android window system (WSEGL) | … libsrv_um libhardware |
| `/vendor/lib/libPVRScopeServices.so` | 9 192 | `2bb828400047742b47c0eadeb310d7addf9adfd2f6c6488cf3cceea4958580ae` | PVRScope profiling | … libstdc++ |
| `/vendor/lib/egl/libEGL_POWERVR_SGX540_120.so` | 5 140 | `0af93f70d07b1329db1eda29d14d6d4370926148d09f7e424e699ddfe426de75` | EGL shim → libIMGegl | … libIMGegl |
| `/vendor/lib/egl/libGLESv1_CM_POWERVR_SGX540_120.so` | 446 184 | `d61b2565e8b0330f968161e5a7f7480810c5f07c15eee84cc51935d231d1ddda` | `OpenGL ES-CM 1.1` | … libsrv_um libIMGegl libusc libm |
| `/vendor/lib/egl/libGLESv2_POWERVR_SGX540_120.so` | 372 324 | `229988dd811c2b8b12e6d2b785b982c443fcf187f364ab438afd7f3dd0c0bcc8` | `OpenGL ES 2.0 build 1.8@785978`, `OpenGL ES GLSL ES 1.00 build 1.8@785978` | … libsrv_um libIMGegl libm libcrypto |
| `/vendor/lib/hw/gralloc.omap4.so` | 35 300 | `815c2e9ca04527d212730114924214cc578bfd0deed9f5904782a2dec2f3b549` | IMG gralloc (fb0, TILER) | … libsrv_um libpvr2d |
| `/vendor/lib/hw/hwcomposer.omap4.so` | 92 260 | `83774096fad6f627bed2d232954b15f6bbff461d7b96dcbae149b4dc9a9d5007` | TI HWC (`/dev/dsscomp`, fb0/fb1, libpng 1.2.46) | liblog libEGL libutils … |

ABI of the IMG blobs (FACT, `readelf -A`): ARMv7-A, Thumb-2, `Tag_FP_arch: VFPv3`,
`Tag_Advanced_SIMD_arch: NEONv1`, **no `Tag_ABI_VFP_args`** (= base/soft-float argument passing),
ELF flags `0x5000002`; floating-point helpers imported from libc (`__aeabi_fadd`, `__aeabi_fmul`, …).
The decisive evidence for the soft-float calling convention is the missing `Tag_ABI_VFP_args`
(the ELF flags `0x5000002` set neither `EF_ARM_ABI_FLOAT_HARD` 0x400 nor `_SOFT` 0x200, so they are
inconclusive); the `__aeabi_f*` imports are consistent with it but
are not proof on their own (they are RTABI helpers that hard-float code may also call).
Bionic markers: `pvrsrvinit` interpreter `/system/bin/linker`; `__android_log_print`, `__errno`
imports; `libcutils`/`libhardware` dependencies. No PVR file is stripped of its `SGX540` id
(`libPVRScopeServices`, `libusc` contain the string `SGX540`).

---

## 10. The HDMI particle visualizer (FACT unless marked)
- APK: `sys:/app/Visualizer.apk` sha256 `017f3fadb2a996447afea190cb204e47464855555f7be36579aa0ac9c00bb919`
  — byte-identical to `private/nexusq-original/Visualizer.apk`; shaders already copied (LF line
  endings) in `private/nexusq-original/visualizer/`.
- API: `Landroid/opengl/GLES20;`, `GLSurfaceView`, `GLSurfaceView$Renderer`,
  `setEGLContextClientVersion`, `detectOpenGLES20` (+ `getDeviceConfigurationInfo`,
  `reqGlEsVersion`) in `Visualizer.odex`. Renderers: `OutputActivity$FullRenderer` (HDMI),
  `OutputActivity$LedRenderer`, `StressTestActivity$StressTestRenderer`. The literal argument to
  `setEGLContextClientVersion` was not decoded from the dex (no dex tool used); 2 is implied by
  GLES20 + GLSL ES shaders (INFERENCE, high confidence).
- EGL config: neither `setEGLConfigChooser` nor `setFormat` occurs in the odex string table →
  default `SimpleEGLConfigChooser(true)` = `ComponentSizeChooser(5,6,5,0, depth 16, stencil 0)`
  (AOSP `android-4.0.4_r1` `opengl/java/android/opengl/GLSurfaceView.java:338,965–967`).
- Shaders: 31 shader sources in `res/raw` (9 776 bytes; 20 `*_f` fragment + 11 `*_v` vertex). `res/raw`
  holds 42 files in total (61 771 B): the 31 shaders, `muted.png`, `particle.png`, `particle2.png` and 8
  `pointmorph_model_*` point-cloud data files. *(Corrected 2026-10-11 from "40 files".)* GLSL ES 1.00
  (no `#version` line), all 20 fragment shaders
  `precision mediump float`. `particle_screensaver_v`: `gl_Position = uMVPMatrix * aVertices;
  gl_PointSize = 60.0;` `particle_screensaver_f`: `gl_FragColor = texture2D(sTexture, gl_PointCoord)
  * uColor;` (point sprites, textured by `particle.png`); `blur_*` are full-screen texture passes.
- Output geometry: `persist.hwc.mirroring.region 0:0:1920:1080` (init.steelhead.rc). INFERENCE:
  the visualizer renders full-screen at the HDMI mode; the GPU load is tiny (40 point sprites +
  blur passes), so it sets no meaningful performance bar for SGX540.

---

## 11. Stock vs mainline 6.18 — what already lines up (for later workstreams)

| Item | Stock (evidence) | Mainline v6.18.48 / our port | Status |
|---|---|---|---|
| Register window | `0x56000000–0x5600FFFF` (hwmod) | `target-module@56000000`, ranges 32 MiB, `gpu@0 reg <0 0x2000000>` (ml `omap4.dtsi:484–509`) | match (superset) |
| IRQ | 53 = SPI 21 | `GIC_SPI 21 IRQ_TYPE_LEVEL_HIGH` | match |
| sysc | rev `0xFE00`, sysc `0xFE10`, SIDLE/MIDLE all 4 modes | `reg <0x5600fe00>, <0x5600fe10>`, `ti,sysc-midle/-sidle` all 4 | match |
| Power domain | `gfx_pwrdm` PRM `0x1200`, OFF\|INA\|ON | `power-domains = <&prm_gfx>` (`prm@1200`); legacy pwrdm `PWRSTS_OFF_ON` | match (no INACTIVE) |
| Functional clock | `gpu_fck` = CLKCTRL `0x4A009220`, MODULEMODE SW | `clocks = <&l3_gfx_clkctrl OMAP4_GPU_CLKCTRL 0>`, `CLKF_SW_SUP` (ml `clk-44xx.c:339`) | match |
| SGX fck mux parent | **forced to `dpll_per_m7x2_ck`** by board file | mux `l3-gfx-clkctrl:0000:24` registered (ml `clk-44xx.c:327–339`). Mainline **does** reparent it for OMAP4430 — ml `omap443x.dtsi:79–86` (`&sgx_module` `assigned-clocks`/`-parents` → `dpll_per_m7x2_ck`, 307 200 000 Hz, comment "like droid4 stock v3.0.8 Android kernel") — but **not** in `omap4460.dtsi`, which our DTS (patch 0003 line 65) includes; patch 0003 has no GPU references | **gap on 4460** — confirmed live: `l3-gfx-clkctrl:0000:24` = 266 666 667 Hz from `dpll_core_m7x2_ck` (`nq-captures/20261010-185940/snapshot.txt:467–470`) |
| SGX rate / DVFS | 153.6 / 307.2 / 384 MHz, VDD_CORE 962/1127/1250 mV | no GPU OPP table, no core DVFS | **gap** |
| GPU node compatible | n/a (board files) | `"ti,omap4430-gpu", "img,powervr-sgx540"` | present upstream; no in-tree driver binds it |
| GPU driver in our build | built-in pvrsrvkm 1.8@785978 | none (`steelhead_defconfig` has no PVR/SGX symbol) | absent |

INFERENCE on VDD_CORE: our record says stock programs VC ON = 1.2 V on VDD_CORE (TWL6030 VCORE1)
(`docs/2026-07-02-stock-parity-voltage-wifi-idle.md:37`), while stock DVFS moves core between 0.962,
1.127 and 1.25 V by OPP. Without core DVFS in mainline, **384 MHz (OPP-OV, 1.25 V) should not be
used**; 307.2 MHz (needs 1.127 V) is within spec at a fixed ≥ 1.127 V. Our mainline port programs
the VC ON (and ONLP) target for VDD_CORE to 1 200 000 µV on VCORE1
(`kernel/patches/0027-ARM-OMAP4-stock-parity-vc-on-voltages-4460-core-vcore1.patch`, `OMAP4_CORE_ON_VOLTAGE_UV`),
which would satisfy 307.2 MHz *if* that is the voltage actually on the rail; the live rail voltage is
UNVERIFIED (VC ON is a wake target, not a measurement). To be measured live in a later workstream.

---

## 12. What this tells us (implications for the plan)

1. **DDK branch to "match" depends on which userspace we run.**
   - *Stock Android userspace* ⇒ KM must be **1.8 / branch 18 / build 785978** with build options
     `0x0036801c` and identical SGXMKIF sizes. Source exists (GPLv2, `kernel/omap`
     `android-omap-steelhead-3.0-ics-aah`, `drivers/gpu/pvr`), but nobody maintains a port of that
     exact build; openpvrsgx's 1.8 is **869593**, which fails the exact build check against
     785978 blobs (`SGXDevInitCompatCheck` `0xc029300c`: "Incompatible driver DDK revision").
   - *Linux userspace* (GBM/Wayland/EGL from TI's SDK or the maemo-leste set) ⇒ the KM version is
     dictated by those blobs (e.g. 1.9.2188537 per the 2026-06-19 note); nothing from the stock
     1.8 userspace — including its microkernel, which lives in `libsrv_init.so` — can be mixed in.
2. **Core revision to target: SGX540 rev 1.2.0 (`SGX_CORE_REV=120`)**, same as Droid 4 / Galaxy
   Nexus class OMAP4 blobs. Confirm on our unit by reading `/proc/pvr/version` or SGX reg `0x24`
   once a KM is loaded (open question 1).
3. **Stock blobs are reference data, not deliverables**: Bionic + soft-float ABI + Android WSEGL.
   Running them would need a Bionic loader layer (libhybris-style) with soft-float call shims on
   armhf *and* a 1.8@785978 KM forward-ported to 6.18 *and* an Android-style window system
   (gralloc/ANativeWindow) on top of omapdrm — UNVERIFIED feasibility; listed only for completeness.
   The repo already ships a glibc armhf runtime (`/opt/glibc-rt`, Debian bookworm, used by Roon —
   `CHANGELOG.md:6376`), which is relevant to *glibc-linked* Linux SGX blobs, not to these Bionic ones.
4. **Platform parameters a mainline port must reproduce (from stock, verified):** gpu_fck parent =
   `dpll_per_m7x2_ck`; OPP set 153.6/307.2(/384 only with VDD_CORE OV); DPLL_PER DCO×2 = 1536 MHz
   (M7 = 4/5/10); IRQ SPI 21; sysc smart-idle/smart-standby capable; `gfx_pwrdm` OFF when idle;
   APM latency 100 ms; HW-recovery timer 100 Hz; uKernel timer 1000 Hz; idle governor
   "boost-to-max when busy, drop-to-min 1–3 ms after idle". Of these, only the clock parent and OPPs
   are DT/clock-framework matters; the rest live in the KM's sys layer.
5. **Corrections to `docs/2026-06-19-gpu-sgx540-acceleration-research.md`** (to be applied by
   whoever owns that doc):
   - §6 "SGX firmware blob (`sgx540_*.fw`) must ship alongside the module": not true for the stock
     DDK — the microkernel is inside `libsrv_init.so` and uploaded by `pvrsrvinit`
     (verified for 1.8@785978; UNVERIFIED for other SGX DDK branches, though the KM code paths
     there are the same family).
   - §6 "OMAP4460 clocks the SGX higher… likely just a DT clock-rate tweak": the 4460 adds a 384 MHz
     OPP **that needs VDD_CORE 1.25 V**; it is not a pure clock tweak. Also the *parent* must be
     switched from DPLL_CORE to DPLL_PER (stock does this in the board file).
   - §5 step 1 "build out-of-tree against our 6.12.12": we are on 6.18.48 since v1.15.0.
6. **What stock did *not* do**: no GPU-specific regulator (SGX is on VDD_CORE); no GPU pinmux;
   no bootloader GFX setup; no `powervr.ini` tuning; no X11/EGL-on-fbdev Linux path (Android only).

---

## Open questions

1. **Live HW core revision on our unit** — `EUR_CR_CORE_REVISION` (SGX base + 0x24) was not read.
   Options: (a) on mainline, enable the `sgx_module` target via runtime PM and read `0x56000024`
   (devmem on a gated module is unreliable — needs the module enabled first); (b) stock RAM boot
   (`output/stock-adb-boot.img`) does **not** mount `/system`, so `pvrsrvinit` never runs and
   `SysFinalise` never prints the revision; pushing `pvrsrvinit` + `/vendor/lib` bits would also
   need Bionic's `/system/bin/linker`, which the ramdisk lacks. Needs a decision on method.
2. **Exact stock commit `ad584da`** is not on the public `kernel/omap` branch (gitiles NOT_FOUND
   2026-10-11). All compared GPU functions match the branch tip, but a diff of the whole
   `drivers/gpu/pvr` tree against the binary was not done.
3. ~~**Mainline SGX fck at boot**~~ — RESOLVED 2026-10-11 from an existing capture (no new device
   access): `nq-captures/20261010-185940/snapshot.txt:467–470` (6.18.48-r20) shows
   `dpll_core_m7x2_ck` → `l3-gfx-clkctrl:0000:24` → `l3-gfx-clkctrl:0000:0` (consumer
   `5600fe00.target-module` `fck`) at 266 666 667 Hz. Whether the mux value is the HW reset default or
   left by something else is still UNVERIFIED (the bootloaders write no GFX register, §4.4).
4. **VDD_CORE in mainline** — actual live voltage vs the 1.127 V needed for 307.2 MHz and 1.25 V
   for 384 MHz; and whether L3/other core users would tolerate a core OPP-OV request.
5. Whether mainline's `l3-gfx-clkctrl:0000:24` mux propagates `clk_set_rate` to
   `dpll_per_m7x2_ck` (needed for any DVFS) — not checked.
6. Whether `dpll_per_m7x2_ck` has any consumer other than the SGX mux (if not, reprogramming M7 is
   side-effect free) — TRM not consulted; UNVERIFIED.
7. Whether stock ever exercised 384 MHz in practice (it should, per the governor) — no stock
   runtime trace exists; `sgx_idle_logging=1` + debugfs `sgx_idle` on a stock boot with
   `/system` would show it.
8. `setEGLContextClientVersion` argument in the Visualizer (decoded only by inference = 2).

## Sources

Local artifacts (gitignored, not redistributable):
- `reverse-eng/vmlinux.bin` (+ `reverse-eng/tools/kallsyms.txt`, `nqdis.py`, `dump.py`, `callers.py`)
- `reverse-eng/factory/tungsten-ian67k/{boot.img,system.raw.img,xloader-phantasm-ian67k.img,bootloader-phantasm-steelheadb4h0j.img,android-info.txt}`
- `private/nexusq-original/Visualizer.apk`, `private/nexusq-original/visualizer/`
- Scratch extracts: `<session scratch>/stock-extract/{fs,ramdisk,app,src,vmlinux-pvr-strings.txt}`

Repo files:
- `docs/2026-06-19-gpu-sgx540-acceleration-research.md` (prior note, partly superseded — §12.5)
- `docs/2026-06-19-particle-screensaver-RE.md`
- `docs/2026-07-02-stock-parity-voltage-wifi-idle.md:30–48` (VDD_CORE = TWL6030 VCORE1, ON 1.2 V)
- `kernel/configs/steelhead_defconfig:2830,2869,5529`; `kernel/patches/0003-ARM-dts-omap4-add-steelhead.patch` (no GPU references)
- `PLAN.md:2160–2163` (Wayland chosen for the SGX path); `CHANGELOG.md:6376` (glibc-rt base)

Remote (all fetched 2026-10-11):
- `https://android.googlesource.com/kernel/omap/+refs` — branch `android-omap-steelhead-3.0-ics-aah` @ `03a9286bb61a` (2012-06-11, "OMAP4: HDCP: Only do AV_MUTE during reauthentication"); `+/ad584da` → NOT_FOUND.
- Same branch, files: `drivers/gpu/pvr/{pvrversion.h,sgx_options.h,Makefile,Kconfig,module.c,proc.c,omap4/sysconfig.c,omap4/sysconfig.h,omap4/sysutils_linux.c,sgx/sgxinit.c}`, `arch/arm/configs/steelhead_defconfig`, `arch/arm/mach-omap2/{board-steelhead.c,devices.c,opp4xxx_data.c,omap_hwmod_44xx_data.c,powerdomains44xx_data.c,clockdomains44xx_data.c,pm44xx.c}`, `arch/arm/plat-omap/include/plat/{gpu.h,omap_hwmod.h}`.
- `https://android.googlesource.com/platform/frameworks/base/+/refs/tags/android-4.0.4_r1/opengl/java/android/opengl/GLSurfaceView.java` (lines 338, 965–967).
- `https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux.git/plain/arch/arm/boot/dts/ti/omap/omap4.dtsi?h=v6.18.48` (lines 484–509, 812–816); `.../omap44xx-clocks.dtsi?h=v6.18.48` (`dpll_core_m7x2_ck@144`, `dpll_per_m7x2_ck@164`); `.../drivers/clk/ti/clk-44xx.c?h=v6.18.48` (lines 327–339, 763, 797–825); `.../arch/arm/mach-omap2/powerdomains44xx_data.c?h=v6.18.48` (line 57).
- `https://api.github.com/repos/openpvrsgx-devgroup/linux_openpvrsgx/branches` — 92 branches incl. `letux/pvrsrvkm-1.8.869593` @ `214f07dd8fe4` (2026-08-16, "drm: pvrsgx: 1.8.869593: fix Makefile for out-of-tree builds since v6.9-rc1"), `letux/pvrsrvkm-1.9.2188537` @ `e4e332159df1` (2026-08-16, "…fix for 6.16-rc1: convert from_timer() to timer_container_of()"), `letux/pvrsrvkm-1.17.4948957` @ `584dd33a1557` (2025-05-04, "…fix for 6.15-rc1…"), `letux/omap-pvr-soc-glue-v10` @ `57c9a409ba70` (2026-08-16).
- Not reachable in this session: WebSearch/WebFetch tools were unavailable; all remote facts above came from direct `curl` of the listed URLs.

---

## Verification (2026-10-11)

Adversarial re-check of this report by a second agent, done the same day. Every item below was
re-derived independently: vmlinux disassembled/dumped again with the repo's `nqdis.py`/`dump.py`/
`callers.py`, the stock `/system` files re-extracted with `debugfs -R dump` and re-hashed, the boot.img
ramdisk re-unpacked, and the stock and mainline sources re-fetched with `curl` (gitiles `?format=TEXT`,
git.kernel.org `plain/…?h=v6.18.48`). No device was touched; the only on-device data used is the
existing capture `nq-captures/20261010-185940/snapshot.txt` (2026-10-10, 6.18.48-r20).

### Confirmed (reproduced exactly)

- **Built-in KM**: `__initcall_PVRCore_Init6` `0xc003cf54`, `__initcall_OMAPLFB_Init7` `0xc003d3d8`
  (kallsyms); `/lib/modules` → "File not found by ext2_lookup"; stock `steelhead_defconfig` lines
  291–297 are `PVR_SGX`, `PVR_NEED_PVR_DPF`, `PVR_NEED_PVR_ASSERT`, `PVR_USSE_EDM_STATUS_DEBUG`,
  `SGX_DVFS_MODE_OPTIMIZED`, `ION`, `ION_OMAP` (all `=y`); line 466 `OMAP2_HDMI_DEFAULT_DISPLAY=y`.
  Kconfig defaults (`PERCONTEXT_PB`, `ACTIVE_POWER_MANAGEMENT`, latency 100, `LOW_LATENCY_SCHEDULING`,
  `DUMP_MK_TRACE`, `SGX_DVFS_IDLE_TIMEOUT 1000`) as stated; Makefile line 55 passes
  `-DSYS_SGX_ACTIVE_POWER_LATENCY_MS=CONFIG_PVR_ACTIVE_POWER_LATENCY_MS` (overriding the `(2)` default in
  `omap4/sysconfig.h:42`), which is why the binary holds 100.
- **DDK identity**: string at `0xc0680738` exact; `movw/movt 0x812/1` at `0xc0292ff4`, `0xfe3a/0xb` at
  `0xc0293028`; `pvrversion.h` MAJ 1 / MIN 8 / BRANCH 18 / BUILD 785978 / BSCONTROL as stated.
  Precision added: those two compares are **KM vs. the values the microkernel reports** (read back via
  `SGXGetMiscInfoUkernel`, "driver DDK … / device DDK …"), i.e. vs. the uKernel uploaded from
  `libsrv_init.so`; the user-mode client does its own check (`libsrv_um.so` string
  "SGXConnectionCheck: Incompatible client DDK revision …").
- **Options mask** `0x0036801c` at `0xc0292f58/5c` (compared against the client's options at
  `[psSGXInfo+0xa4]`); bit decode against stock `sgx_options.h` correct (bits 2,3,4,15,17,18,20,21).
  `libsrv_um.so` words at `0x9fb4`/`0xb0d0` = `0x36801c`, `0x9fc8` = `0x10812`, `0x9fcc` = `0xbfe3a`;
  `libsrv_init.so` `0x1774`/`0x3364` = `0x36801c`. Core-rev logic (`0xc0293054`–`0xc02930b4`, HW rev
  `[+4]`, SW rev `[+0x18]`, skip if SW = 0, exception HW `0x10100`/SW `0x10101`) as described.
- **Platform glue**: `omap44xx_gpu_addrs` {`0x56000000`,`0x5600ffff`, flags 2}; `omap44xx_gpu_irqs`
  irq 53; `omap44xx_gpu_sysc` rev `0xfe00`/sysc `0xfe10`, flags `0x60`, idlemodes `0xff`,
  `omap_hwmod_sysc_type2`; hwmod +0x1c CLKCTRL `0xfc009220`, main_clk "gpu_fck", +0x40 →
  `smartreflex_core_dev_attr` (voltdm "core"); `gfx_44xx_pwrdm` voltdm "core", `0x000d1200`
  (offs `0x1200`, pwrsts `0x0d` = OFF|INA|ON); stock source `PWRSTS_OFF_INA_ON`. Mainline v6.18.48
  `omap4.dtsi:484–509` and `powerdomains44xx_data.c:57–62` (`PWRSTS_OFF_ON`) exactly as quoted.
- **gpu_fck clock**: static parent `dpll_core_m7x2_ck`, clksel reg `0xfc009220` mask `0x01000000`,
  `sgx_clk_mux_sel` = {core_m7x2, per_m7x2}, clkdm "l3_gfx_clkdm". Board reparent:
  `clk_get("dpll_per_m7x2_ck")` `0xc0075f0c`, `clk_get("gpu_fck")` `0xc0075f28`, `clk_set_parent`
  `0xc0075f40`; stock source `board-steelhead.c:1155–1182`; `omap_vram_set_sdram_vram(0x1000000, 0)`
  at `0xc0075f64`.
- **Bootloaders write no GFX register**: no 32-bit literal in `0x4A009200–0x4A0092FF` or
  `0x4A307200–0x4A3072FF` in either image. The CM2 base literal `0x4A009000` is used with offsets
  `0x400/0x540/0x548/0x550` (L4PER) and `0x328/0x330/0x3e0/0x470` (L3INIT/L4PER); PRM `0x4A307000`
  only with `+0x840` — none in the GFX instance. (`xl:0x5578`, `xl:0x5a00`, `ub:0x1740`, `ub:0x1b5c`.)
- **GPU OPPs**: `0xc0043e94/eac/ec4` = gpu/core/`dpll_per_m7x2_ck` 153.6 MHz @ 962 000 µV,
  307.2 MHz @ 1 127 000 µV, 384 MHz @ 1 250 000 µV, all `available = 1`; the 4430 list
  (`omap443x_opp_def_list` @ `0xc0043bc4`, GPU rows from `0xc0043c9c`) has only 153.6/307.2;
  `omap4_opp_init` picks the list by `omap_rev()` and only calls `opp_enable` for the MPU
  (`0xc0012b48`). Stock source `opp4xxx_data.c:266–270`.
- **DVFS policy** (`SysSGXIdleTransition` re-disassembled): busy & mode≠0 → `hrtimer_cancel` +
  `cancel_work_sync` + `RequestSGXFreq(max)` + record busy time at `[0xc07b7a38+0x2f8]`; idle & mode 2
  → if `now − last_busy ≤ 1 999 999 ns` timeout = `3 000 000 − delta` else `sgx_idle_timeout`;
  `hrtimer_start(…, HRTIMER_MODE_REL)`. `RequestSGXFreq`: max index = `size − 2`, min = 0, calls
  `pdata+8` (= `omap_device_scale`, set at `omap_init_gpu` `0xc0556b58`), on `-EBUSY`/error sets
  index `size − 1`. `SysDvfsInitialize`: list size = count+1, last slot duplicates the highest, start
  index = count. `sgx_idle_work_func` → `RequestSGXFreq(…, 0)`. Hence 307.2 MHz is never *requested*
  (it is only the rate between the board reparent and the first request).
- **Module params**: `__param_*` perms `0x1a4`; defaults `sgx_apm_latency` 100, `sgx_idle_timeout`
  1 000 000, `sgx_idle_mode` 2, `gPVRDebugLevel` 7, `sgx_idle_logging` in BSS (`0xc07822e0`) = false.
  `SysGetSGXTimingInformation` stores HW-recovery 100, uKernel 1000, ActivePM 1, APM latency from
  `sgx_apm_latency`.
- **Userspace inventory**: all 13 PVR/IMG files + hwcomposer re-extracted; sizes and all 14 sha256
  values in §9 match byte-for-byte. A full `rdump` of `/system` grep'd for `pvrsrvkm|PVRSRV|POWERVR|
  libsrv_um` finds no other PVR file. `egl.cfg`, `ro.opengles.version=131072`, no `powervr.ini`,
  `/etc/powervr.ini` string in `libsrv_um.so`, `SetupuKernel…`/"SGX ukernel" strings in
  `libsrv_init.so`, `/vendor/firmware` listing — all as stated.
- **ABI**: `readelf -A` on libsrv_um, libGLESv2, libIMGegl, libusc: v7, Thumb-2, VFPv3, NEONv1, no
  `Tag_ABI_VFP_args`; NEEDED lists Bionic libs; `pvrsrvinit` interpreter `/system/bin/linker`.
- **init.steelhead.rc** (ramdisk re-unpacked from boot.img): `chmod 0666 /dev/pvrsrvkm` at line 32
  (`on boot`), `service pvrsrvinit` lines 89–93 (class core, user/group root, oneshot); `/dev/tiler`,
  `/dev/dmm`, `/dev/ion` chmod 0777 in `on fs`; ueventd `dsscomp`/`tiler` 0666 system.
- **Public KM source**: gitiles JSON for the branch head = `03a9286bb61a9acd28027206c4937990ac817f1b`,
  committer date 2012-06-11 19:23:32 −0700, subject "OMAP4: HDCP: Only do AV_MUTE during
  reauthentication"; it is the only `steelhead` ref among 2041 refs of `kernel/omap`; `+/ad584da`
  → HTTP 404 while abbreviated `+/03a9286` → 200 (so the 404 is meaningful). vmlinux banner
  `3.0.8-gad584da … Fri Jun 29 15:12:17 PDT 2012`.
- **openpvrsgx**: 92 branches (GitHub API); tips `letux/pvrsrvkm-1.8.869593` `214f07dd8fe4`,
  `letux/pvrsrvkm-1.9.2188537` `e4e332159df1`, `letux/pvrsrvkm-1.17.4948957` `584dd33a1557`,
  `letux/omap-pvr-soc-glue-v10` `57c9a409ba70`; commit subjects/dates for the 1.8 and 1.9 tips as
  stated. No branch or `drivers/gpu/drm/pvrsgx/` subdirectory names build 785978.
- **ION/TILER**: `sh_ion_data` nr 3: `secure_input` type 2 id 2 `0xBA300000` 90 MiB; `tiler` type 4
  id 1 `0xAE900000` 81 MiB; `nonsecure_tiler` type 4 id 3 `0xAC900000` 32 MiB. `steelhead_reserve`
  memblock_removes exactly as stated. Strings "PVRSRVDriverProbe: Couldn't create ion client"
  (`0xc06805e7` region) and "%s: Failed to allocate via ion_tiler" present.
- **Visualizer**: APK sha256 `017f3fad…` equal to `private/nexusq-original/Visualizer.apk`;
  `Visualizer.odex` contains `Landroid/opengl/GLES20`, `setEGLContextClientVersion`,
  `detectOpenGLES20`, `reqGlEsVersion`, and **no** `setEGLConfigChooser`/`setFormat`; AOSP
  `android-4.0.4_r1` `GLSurfaceView.java:338` (`new SimpleEGLConfigChooser(true)`) and `:965–967`
  (`super(5, 6, 5, 0, withDepthBuffer ? 16 : 0, 0)`). Particle shaders' text exactly as quoted.
- **Repo refs**: `kernel/configs/steelhead_defconfig:2830/2869/5529`, no PVR/SGX symbol; patch 0003
  includes `omap4460.dtsi` (line 65) and has no GPU references; `docs/2026-07-02-stock-parity-voltage-wifi-idle.md:37`
  = VDD_CORE on TWL6030 VCORE1, ON 1 200 000 µV.

### Corrected in place

1. **"`0x00010200` constants in `libsrv_um.so`"** (TL;DR 3, claim 4) — not reproducible; removed as
   evidence (see TL;DR 3). The SGX540 rev-1.2.0 identification still stands on the `_120` blob names,
   `egl.cfg`, and `-DSGX_CORE_REV=120`; the live register value stays UNVERIFIED.
2. **DPLL_CORE table offset** (TL;DR 5, §4.4, claim 8): `xl:0xa8fc` → `xl:0xaa3c` (38.4 MHz row
   `xl:0xaa9c`); `xl:0xa8fc` is the 13 MHz row of the 4430-ES1.0 1524 MHz table. Values
   (M=125, N=5, 1600 MHz, M7=6 → 266.67 MHz) unchanged. Also clarified that `xl:0xa9cc` is the base
   (12 MHz) row of the DPLL_PER table; the 38.4 MHz `M=20 N=0` row is `xl:0xaa2c`.
3. **Shader count** (TL;DR 12, §10, claim 19): "40 shaders" → 31 shader sources (20 fragment, 11
   vertex, 9 776 B) among 42 `res/raw` files. "All `precision mediump float`" holds for all 20
   fragment shaders.
4. **"Mainline never reparents the SGX mux"** (claim 17, §11): too strong. Mainline v6.18.48
   `omap443x.dtsi:79–86` *does* reparent it to `dpll_per_m7x2_ck` at 307.2 MHz for OMAP4430; only
   `omap4460.dtsi` (ours) lacks it. The 4460 consequence — SGX on DPLL_CORE M7 = 266.67 MHz — is now
   **verified** from the 2026-10-10 on-device capture, upgrading that part from "likely".
5. `src:powerdomains44xx_data.c:67` → `wakeup_lat[OFF] = 1000` is at line 82 (struct begins at 67).
6. `request_firmware` sentence made precise (direct callers only; `request_firmware_nowait` callers
   are hdcp/rproc).
7. ABI sentence: the `__aeabi_f*` imports alone do not prove soft-float; the missing
   `Tag_ABI_VFP_args` does.
8. VDD_CORE paragraph (§11): added that our patch 0027 sets VC ON/ONLP for VDD_CORE to 1.2 V; actual
   rail voltage remains UNVERIFIED.
9. Open question 3 marked resolved; open-question numbering otherwise unchanged.

### Could not reproduce / still UNVERIFIED

- The live `EUR_CR_CORE_REVISION` value (needs a loaded KM or an enabled `sgx_module`).
- That the SW core-rev the 785978 microkernel reports is encoded as `0x00010200` (no constant found
  in the user-mode blobs; the microkernel image inside `libsrv_init.so` was not decoded).
- That `omap_device_scale` → TI 3.0 DVFS actually reprograms DPLL_PER M7 (DVFS code not
  disassembled — remains INFERENCE as the report already says).
- Whether stock ever ran at 384 MHz in practice (no stock runtime trace).
- That 307.2 MHz is "safe" on mainline depends on the live VDD_CORE, not measured.
- The openpvrsgx 2026-08-16 dates reflect a bulk rebase onto Linux 7.2; whether the 1.8.869593 or
  1.9.2188537 KMs actually build/run on 6.18 was not tested here.
- `setEGLContextClientVersion` argument (still inferred = 2).
