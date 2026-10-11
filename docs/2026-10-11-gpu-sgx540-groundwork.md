# GPU groundwork: PowerVR SGX540 acceleration on mainline 6.18 (2026-10-11)

**Status:** research and planning only. Nothing was built, flashed, committed or
installed. One read-only probe of the Prague unit was made (`hostname` =
`steelhead`, kernel 6.18.48-r20; see
[gpu-sgx540/power-clocks-pm.md](gpu-sgx540/power-clocks-pm.md) §1.3). Everything
else came from the stock firmware in `reverse-eng/`, the existing capture
`nq-captures/20261010-185940/snapshot.txt`, source trees at precise tags, and
upstream repositories read on 2026-10-11.

**What this note is:** the summary, the decision and the plan. It supersedes the
recommendations of [2026-06-19-gpu-sgx540-acceleration-research.md](2026-06-19-gpu-sgx540-acceleration-research.md)
(written on 6.12.12; see "What changed" below). The evidence lives in seven detail
notes in [gpu-sgx540/](gpu-sgx540/README.md), each of which was re-checked by an
independent adversarial pass the same day; where a verifier corrected something,
the correction is what this note uses. Untested starting drafts (DTS block, kernel
aport fragment, blob package, read-only probe, measurement checklist) are in
[gpu-sgx540/drafts/](gpu-sgx540/drafts/README.md).

**Evidence convention.** Every claim carries a pointer: a detail note and section
(`[kdp §8]` = [kernel-driver-port.md](gpu-sgx540/kernel-driver-port.md) §8), a repo
`file:line`, a stock address (`vmlinux.bin @0x…`), a commit or URL, or the label
**UNVERIFIED** with the reasoning. Short names for the detail notes:

| Tag | Detail note | Subject |
|---|---|---|
| `stk` | [stock-ground-truth.md](gpu-sgx540/stock-ground-truth.md) | what stock Android 3.0.8 did |
| `ml` | [mainline-6.18.md](gpu-sgx540/mainline-6.18.md) | mainline DT, clocks, PRM, omapdrm, upstream state |
| `kdp` | [kernel-driver-port.md](gpu-sgx540/kernel-driver-port.md) | the pvrsrvkm port to our kernel |
| `ub` | [userspace-blobs.md](gpu-sgx540/userspace-blobs.md) | closed userspace, Mesa glue, musl/glibc, licence |
| `cd` | [compositor-display.md](gpu-sgx540/compositor-display.md) | compositors, DSS planes, HDMI modes, video |
| `pm` | [power-clocks-pm.md](gpu-sgx540/power-clocks-pm.md) | power domain, clocks, idle, thermal, measurement |
| `ur` | [usecases-roadmap.md](gpu-sgx540/usecases-roadmap.md) | use cases, precedent, roadmap |
| `re` | [reverse-engineering.md](gpu-sgx540/reverse-engineering.md) | the RE master note: verdicts of the seven RE notes, licence limits on RE, RE work list, inconsistencies with this note (§12.1) |
| `abi`, `hyb`, `br`, `sys`, `fw`, `odf`, `vis` | [gpu-sgx540/re/](gpu-sgx540/README.md#reverse-engineering-notes) | the seven RE notes, tags as `re` defines them |

*Corrected 2026-10-11:* the RE set was synthesised after this note was written;
its 20 disagreements with this note ([re §12.1](gpu-sgx540/reverse-engineering.md#121-between-the-re-notes-and-the-groundwork-note))
are applied below in place, each marked *Corrected 2026-10-11 [re §12.1 row N]*,
and listed in the addendum at the end.

---

## TL;DR

1. **Buildable, and the kernel side is closer than in June.** Mainline 6.18.48
   already describes the GPU completely (`sgx_module: target-module@56000000`,
   `gpu@0` "ti,omap4430-gpu","img,powervr-sgx540", `prm_gfx`, clkctrl) and probes
   its bus glue on our board; the module is runtime-suspended and the GFX domain is
   OFF today [ml §1, pm §1.3]. What is missing is a driver: mainline
   `drivers/gpu/drm/imagination` is Rogue-only and ARM64/RISCV64-only, and no
   Series5 work is heading upstream (likely, not verified: lore was unreachable)
   [ml §5].
2. **One DDK end to end: 1.17.4948957.** It is the only DDK with both a kernel
   driver that builds an OMAP4 SGX540 module (openpvrsgx
   `pvrsrvkm_omap4_sgx540_120.ko`) and a maintained non-Android userspace for
   SGX540 rev 1.2.0 (TI `ti443x_linux`, commit `84a396a4`, 2024-10-16) [kdp §4,
   ub §2.1]. Stock ran DDK **1.8@785978** (Android, bionic, soft-float); those blobs
   are reference data only [stk §2.3, §9]. 1.9 (`pvr-omap4`) is obsolete [ub §2.4].
3. **A shipped precedent on our kernel line exists.** Maemo Leste *excalibur*
   ships `linux-image-omap 6.18.51.1` containing
   `pvrsrvkm_omap4_sgx540_120.ko`, built from `maemo-leste/droid4-linux` tag
   `maemo-kernel-6.18.51.1` (`db432aff895b`), with the TI 2024 blobs
   (byte-identical in Maemo's git tree; its debs strip `.comment`, ub Addendum B.4)
   and an SGX Mesa 24.0.9 [ur §2.2, ub §2.2]. Co-shipping is verified. That
   it renders on Maemo's 6.18 kernels rests on developer statements on IRC
   (Droid 4, 2026-06-03 and 2026-08-04). No log, no kmscube or glmark2 figure, and
   nothing specific to the 6.18.51.1 build backs them [kdp Addendum A.5]. Its
   `pvrsgx/` is `pvrsrvkm-6.18-rc6` plus one runtime-PM commit [kdp Addendum A.1]. Every Maemo
   SGX540 device is an OMAP4**430**.
4. **New hard prerequisite: the kernel must become preemptible.** Every OMAP build
   of the 1.17 KM defines `PVR_LINUX_USING_WORKQUEUES`, and `osfunc.c:126-135`
   stops the build with `#error "A preemptible Linux kernel is required when using
   workqueues"`. Our defconfig is `PREEMPT_NONE` (`kernel/configs/steelhead_defconfig:99-102`).
   Upstream picks `PREEMPT_VOLUNTARY` (`0affbb5a7b95`); stock and the working
   Kindle Fire run used `PREEMPT` [kdp TL;DR 8, §8 k]. This is a kernel-wide
   scheduling change and gets its own phase and audio regression run.
5. **The clock is a stock-parity bug-to-be, and it is already measured.** On our
   4460 the SGX mux sits on `dpll_core_m7x2_ck` = **266.67 MHz**
   (`snapshot.txt:467-470`). Stock reparents `gpu_fck` to `dpll_per_m7x2_ck`
   (`vmlinux.bin @0xc0075f40`); mainline does the same only in `omap443x.dtsi`.
   Fix: one `&sgx_module` `assigned-clocks` block at **307.2 MHz** (stock OPP100,
   needs VDD_CORE ≥ 1.127 V). **Never 384 MHz** (stock OPP-OV, needs VDD_CORE
   1.25 V) while mainline cannot scale VDD_CORE [stk §4, pm §2]. The live VDD_CORE
   is expected at **1.139 V**: the stock x-loader programs VCORE1 vsel 0x23, and
   nothing on mainline rewrites it. ~~One read (`nexusq-gpu-probe.sh --pmic`)
   confirms it first~~ *Corrected 2026-10-11 after the live read: the TWL6030
   control interface does not show that setpoint (VCORE1 0x55/0x56 read 0x00 on
   the Prague unit with the rail on). VDD_CORE is not readable from Linux; the
   307.2 MHz gate needs a multimeter on VCORE1, until then 153.6 MHz*
   [pm §4, pm Addendum "Live VDD_CORE without a device" §6].
6. **The openpvrsgx glue would pin the GFX domain ON.** `pvr_probe()` takes a
   `pm_runtime_get_sync()` reference that is only dropped on error and in
   `pvr_remove()` (pvr-drv.c:440-441, 465, 476, 488 at `d2f1e031`). Code inference,
   with one piece of counter-evidence (`84db121f1016` reports clock gating on the
   Droid 4) [pm TL;DR 8, kdp §8 d]. It must be fixed and measured before the
   module may autoload, or it undoes the deep-idle work.
7. **Modern wlroots cannot run on these blobs as published.** wlroots 0.20.2
   (labwc) hard-requires `GL_EXT_unpack_subimage` (B1) and
   `EGL_EXT_image_dma_buf_import` (B2); no SGX540 GLES library has B1, and TI
   removed dma-buf import from mesa-sgx because "DDK 1.17's implementation … was
   never fully functional under Linux" (`a698020`) [cd §3]. Weston 16 needs only B1
   and renders through `gbm_surface`. The June note's "wlroots compositors work"
   dates from wlroots 0.12 [cd §3.6].
8. **The value is the HDMI music visualizer, as a direct KMS/GBM client.** It
   needs no compositor, sidesteps B1/B2, reuses the stock GLSL ES 1.00 shaders (31
   sources in `Visualizer.apk`) and the scene logic nexusqd already runs on the LED
   ring [ur §3.2, cd §4.3]. The idle particle screensaver and a now-playing screen
   do **not** need the GPU: CPU+NEON at 640×360 with DSS-plane upscaling, and DSS
   planes with alpha and zpos [cd §4, ur §3.4].
   *Corrected 2026-10-11 [re §12.1 row 16]:* stock draws the screensaver at the
   HDMI size with fixed 60 px point sprites (40 of them, additive); at 1080p with
   damage-rect clearing it is ≲ 10 % of one core in software, so full-size
   rendering on the CPU is also workable and keeps the stock look; 640×360 with
   upscaling is the cheaper option, its visual impact UNVERIFIED [vis §3.2, §6.2].
9. **Userspace route: glibc sandbox first, native musl second.** The 2024 blobs
   are hard-float glibc (≤ `GLIBC_2.34`); our `/opt/glibc-rt` (bookworm, glibc
   2.36) runs Maemo's *daedalus* debs unmodified for first light. The product is
   native musl + gcompat + a small shim, with two known ABI hazards (32-bit-offset
   `mmap@GLIBC_2.4` in `libsrv_um`, the `strerror_r` GNU/XSI clash) to be measured
   by strace, not patched [ub §4, §6].
   *Corrected 2026-10-11 [re §12.1 rows 2-4]:* the RE set rates both hazards lower.
   The 32-bit-offset `mmap` is not reached from drop B's own caller and probably
   not from drop C's; the blob tests `strerror_r`'s return and prints its own
   buffer, so no crash is expected under musl's XSI version [abi §4, V5]. Both stay
   UNVERIFIED until the Phase 2 strace and error-path probe, and `mesa-sgx` was not
   searched for a direct `PVRSRVMapDmaBuf` call [re §3.4, §10 item 4, abi open 1].
   "gcompat + shim" is one of two licence-clean designs, decided in Phase 2: our own
   `ld-linux-armhf.so.3`-named DSO with the 9 `__*_chk` and **no** gcompat
   [abi §7.1], or a private `ld-linux-armhf.so.3 → ld-musl` link plus gcompat
   loaded explicitly [ub §4.4.2]; the third (`patchelf`) modifies a blob and is
   out; never `LD_PRELOAD` gcompat [abi §6.4, re §3.3].
10. **Licence:** TI's TSPA allows redistributing the **unmodified** binaries with
    the licence text, for TI devices only, and forbids reverse engineering. Any
    route that needs binary patching is out; public images either ship the
    unmodified blobs or fetch them at install [ub §8].
11. **Plan:** Phase 0 (prep, baselines, DT clock, VDD_CORE, SW reference) → 1a
    (preemption model) → 1 (KM loads, GFX idles) → 2 (offscreen GLES2, go/no-go) →
    3 (KMS/GBM on omapdrm) → 4 (visualizer) → 6 (packaging, OTA, licence) with 5
    (accelerated desktop) and 7 (VDD_CORE DVFS) optional. About **9-15
    engineer-weeks** to an OTA-shipped visualizer; UNVERIFIED estimate [ur §6].

---

## 1. What changed since the June note

The June note was written on 6.12.12 with an X11-to-Wayland switch just made. Since
then:

| Area | June 2026 | Now (2026-10-11) | Evidence |
|---|---|---|---|
| Kernel | 6.12.12; "backport 6.15 shims down to 6.12" | **6.18.48 LTS since v1.15.0 (2026-08-31)**, r20 today. openpvrsgx has an integration branch **`pvrsrvkm-6.18-rc6`** (`d2f1e031d58a`, 2025-11-21, first parent "Linux 6.18-rc6") and per-kernel merges up to `pvrsrvkm-7.2` (`2342ce92fdde`, 2026-08-26). Header delta 6.18-rc6 → 6.18.48 touches nothing the driver uses | CHANGELOG.md v1.15.0; kdp §3.1, §7 |
| KM branch | `letux/pvrsrvkm-1.17.4948957` "rebased onto 6.15-rc5" | that branch head is stale since 2025-05-04 (`584dd33a1557`); the active topic is **`-v3`** (`e5de75568819`, 2026-08-21); `-v4` (`3f5f503efcc6`) is `-v3` rebased unchanged onto 7.3-rc6 plus three warning fixes, and `letux-6.18.y` (`c118c403ccb8`, 6.18.55) carries the rc6 1.17 tree byte for byte; both read from the GitHub mirror `goldelico/letux-kernel` (*corrected 2026-10-11*) | kdp §3.1, Addendum C |
| SoC glue | "add `omap-pvr-soc-glue-v10`" | mainline 6.18 already contains all OMAP4 glue; the glue branch adds nothing OMAP4 needs | ml §7.1, kdp §5 |
| DT | "add the gpu node to the steelhead DTS" | the node is inherited from `omap4.dtsi:484-509`; only an `&sgx_module` clock block is missing (`omap4460.dtsi` lacks what `omap443x.dtsi:78-86` has) | ml §1.2, §3.4 |
| Clock | "4460 clocks the SGX higher, likely a DT rate tweak" | the **parent** must change (DPLL_CORE → DPLL_PER), and the 4460-only 384 MHz OPP needs VDD_CORE 1.25 V | stk §4, pm §2 |
| Firmware | "`sgx540_*.fw` must ship with the module" | no separate firmware in 1.8, 1.9 or 1.17: the microkernel is in `libsrv_init.so` `.rodata` (0x15b94 B in 1.17) and uploaded by `SrvInit()`; the KM has no `request_firmware` (strings, section sizes and grep; not disassembled) | ub §3.6, stk §8 |
| Userspace | `maemo-leste/pvr-omap4` (DDK 1.9.x), "1.9.2188537 is canonical for OMAP4" | `pvr-omap4` superseded by `maemo-leste/sgx-ddk-um` (1.17) since 2021-11; 1.9.2188537 is labelled "OMAP3530, AM3517" in openpvrsgx Kconfig and builds no OMAP4 module | ub §2, kdp §4 |
| GBM | "`mobiaqua/libgbm` needed" | not needed: since 2019 TI's 1.17 UM uses Mesa as frontend, GBM comes from Mesa | ub §3.2 |
| Compositor | "wlroots compositors work" (pmOS !1868) | wlroots ≥ 0.13 renders into dma-buf EGLImages and needs `GL_EXT_unpack_subimage`; neither is available | cd §3.1, §3.6 |
| Desktop | X11/XFCE replaced by weston (pixman) | **LXQt-Wayland on labwc 0.20.2 / wlroots 0.20.2, `WLR_RENDERER=pixman`**, on demand only; default target `multi-user.target`; weston kept as a fallback session | cd §1.1 (`pmos/device-google-steelhead/nexusq-wayland.sh:8-9`, APKBUILD:204-216) |
| HDMI without desktop | console | the in-kernel fbdev client held lit at 720p60 by `nq-hdmi hold` for HDMI audio, deliberately not DRM master; a black screen | cd §1.1, §4.4; `docs/2026-09-20-hdmi-audio-the-output-that-was-never-offered.md` |
| HDMI modes | not discussed | patch 0010 caps the pixel clock at 75 MHz: 720p60 and 1080p24/25/30 survive; stock allowed 165 MHz, so the cap masks an omapdrm bug | cd §6 |
| Cores | "single core" | **two cores since v1.2.0** | PLAN.md:2355 |
| Idle | not a constraint | deep idle is now a tuned product property: C3 86-93 % of idle (patches 0054-0058, v1.19.0), `prm_gfx` deliberately kept as a genpd (0057), CORE never leaves ON because USB/L3INIT pins it (Petr's 2026-09-23 decision) | pm §5, §6.1 |
| Boot image | "≤ 6.5 MB ceiling, ship a .ko on the rootfs" | ~92-94 KB headroom; and kernel OTA carries `/lib/modules/<rel>` **only from the kernel apk**, so the module must be built in-tree (`=m`) inside `linux-google-steelhead`, not as a separate aport | kdp §6, ur §5.3 |
| glibc | none | `/opt/glibc-rt` (Debian bookworm armhf, glibc 2.36, for Roon) exists; flash-only, not in OTA | ub §6, ur §5.8 |
| Ecosystem | pmOS as the musl recipe | pmOS removed its SGX packages on 2022-05-27 (policy, and bit-rot); TI's 6.18 BSP has no SGX (SGX ends at TI's 6.12 BSP); TI Mesa 25.2.8 dropped the `sgx` driver | ub §5, ml §5.5 |

---

## 2. The stack, as it would run on the Q

```
 ┌─ GPU client ─────────────────────────────────────────────────────────────────────┐
 │ nexusq-visualizer (KMS/GBM, gbm_surface, DRM master only while shown)   OURS     │
 │   later, optional: weston 16 (gl-renderer) or labwc/wlroots 0.20 (needs B1+B2)    │
 ├─ EGL / GBM / GL dispatch ──────────────────────────────────────────────────────────┤
 │ mesa-sgx (Maemo powervr-24.0.9 = TI 24.0.1 frontend), private prefix              │
 │   /usr/lib/sgx-mesa, -Dllvm=disabled, gallium "sgx" frontend, alias omapdrm        │
 │   + our GL_EXT_unpack_subimage emulation (only when a compositor needs it)  MIT   │
 │ system Mesa 26.2.4 (llvmpipe) stays untouched for everything else                 │
 ├─ closed DDK 1.17@4948957, target ti443x_linux (TI 84a396a4), UNMODIFIED   TSPA    │
 │ libpvr_dri_support · libGLESv2_PVR_MESA · libGLESv1_PVR_MESA · libglslcompiler ·  │
 │ libusc · libsrv_um · libsrv_init (embeds the SGX microkernel) · libpvr2d          │
 │   glibc ≤ 2.34, hard-float: route B = /opt/glibc-rt sandbox; route A = musl +     │
 │   gcompat + nq shim                                                               │
 ├─ open replacements (Maemo sgx-ddk-um leste15) ─────────────────────────────────────┤
 │ libdbm (LGPL, REed; omapdrm primary node, PRIME) · pvrsrvinit (MobiAqua, MIT)     │
 │ /etc/powervr.ini (start with DisableHWTQTextureUpload=1, as Maemo)                │
 ╞═ kernel 6.18.48-rN (linux-google-steelhead) ═══════════════════════════════════════╡
 │ pvrsrvkm_omap4_sgx540_120.ko  =m, in-tree from openpvrsgx 1.17 + our 7 patches     │
 │   DRM render driver "pvr": /dev/dri/card1 + renderD129    GPL/MIT, OURS to carry   │
 │   needs CONFIG_PREEMPT_VOLUNTARY or CONFIG_PREEMPT                                 │
 │ omapdrm (card0/renderD128): KMS, 4 planes, DMM/TILER, PRIME, implicit fences      │
 │ ti-sysc target-module@56000000 → prm_gfx genpd (ON/OFF) → l3_gfx clkctrl          │
 │   gpu_fck mux bit 24: dpll_core_m7x2 266.67 MHz today → dpll_per_m7x2 307.2 MHz   │
 ├─ hardware ─────────────────────────────────────────────────────────────────────────┤
 │ SGX540 rev 1.2.0 @0x56000000, GIC SPI 21, L3_2 initiator, VDD_CORE (TWL6030 VCORE1)│
 └────────────────────────────────────────────────────────────────────────────────────┘
```

Two facts the diagram hides: `libsrv_um` opens the **pvr** render node for
services and the **omapdrm** device for display (strings, ub §3.4); and the
microkernel travels with, and must exactly match, the userspace blobs, so the KM
and UM must be the same DDK build with the same build-options mask
(`SGXInit: Mismatch in client-side and KM driver build options`) [ub §3.7, kdp §4].
*Corrected 2026-10-11 [re §12.1 row 7], a precision:* the 1.17 KM compares its
options against the **UM's** build (ioctl 0), not the microkernel's, and never
checks the SGXMKIF layouts against its own `sizeof` [br §4, fw §2.6]; with 1.17 on
both sides that is low risk, and it is why a 1.17 KM must never be paired with
another uKernel by faking version words [re §4.4].

Stock numbers that the port reproduces or deliberately does not [stk §4-§5, pm §3]:

| Parameter | Stock (vmlinux.bin) | Port, phase 1 |
|---|---|---|
| fck parent | `dpll_per_m7x2_ck` (`@0xc0075f40`) | same (DT block) |
| GPU rate | DVFS 153.6 ↔ 384 MHz (`sgx_idle_mode=2`, 1-3 ms idle timer) | fixed 307.2 MHz |
| VDD_CORE | 962 / 1127 / 1250 mV by OPP | whatever the bootloader left (measure); ≥ 1127 mV required |
| APM latency | `sgx_apm_latency` = 100 ms | 100 ms (openpvrsgx default for OMAP4 is 2 ms via `sysconfig-am4.h`) |
| HW recovery / µKernel timer | 100 Hz / 1000 Hz | same (openpvrsgx OMAP4 default: 50 Hz) |
| `SYS_SGX_CLOCK_SPEED` | dynamic from the OPP list | 307 200 000 (openpvrsgx OMAP4 default: 200 000 000, which miscalibrates the µKernel timer by 0.65×) |
| GFX power states | OFF / INACTIVE / ON | OFF / ON (mainline genpd) |

*Corrected 2026-10-11 [re §12.1 row 6]:* the APM row above is an assumption. The
`ti443x` microkernel was built without the APM option bit (bit 15), the letux KM
compiles APM in but reports bit 15 as 0 (`sgx_options.h:151`, "HACK: missing
userspace flag", `84db121f1016`), and TI's own `ti443x` KM sets
`SUPPORT_ACTIVE_POWER_MANAGEMENT := 0` [fw §3, kdp claim 20, ub §3.7]. Whether the
uKernel sends the active-power events that drive the idle path is **UNVERIFIED**;
risks P3 and P9 and the Phase 4 exit depend on it. It is observed in Phase 1
[re §4.4, §10 item 5]. (The GFX power-state row is confirmed: stock `pwrsts` 0x0d
= OFF | INACTIVE | ON [pm §1.2; re §12.1 row 10].)

---

## 3. The decision matrix

Four axes: **KM DDK** (and where it comes from), **UM source**, **libc strategy**,
**EGL/window platform**. Status: **KW** known working somewhere (named), **P**
plausible, **B** blocked or rejected. Merged from ub §9 and cd §3.5.

| # | KM DDK (source) | UM source | libc | EGL platform / consumer | Status | Why |
|---|---|---|---|---|---|---|
| 1 | **1.17.4948957** openpvrsgx (`pvrsrvkm-6.18-rc6`, cross-diffed with Maemo 6.18.51.1), in-tree `=m` | **TI 84a396a4 ti443x**, unmodified + Maemo open `libdbm`/`pvrsrvinit` | **glibc sandbox** (`/opt/glibc-rt` + Maemo daedalus debs, Mesa 22.3.6+sgx2) | **GBM/KMS** `gbm_surface` (kmscube, visualizer) | **P — first light** | fewest unknowns: any failure is KM/DT/clock, not ABI. Daedalus needs glibc ≥ 2.34, bookworm has 2.36; excalibur's Mesa 24.0.9 needs 2.38 (too new) |
| 2 | same | same | **musl + gcompat + nq shim**, mesa-sgx built for musl | **GBM/KMS** | **P — product** | whole system stays musl; OTA-able; ~1 MB of blobs. First of its kind for the 2024 blobs; `mmap@GLIBC_2.4` and `strerror_r` hazards to measure |
| 3 | same | same | either | **Weston 16** `renderer=gl` + `GL_EXT_unpack_subimage` emulated in mesa-sgx (or TI's 23/-5 line revert patch) | P | weston renders through `gbm_surface`; needs only B1 |
| 4 | same | same | either | **labwc / wlroots 0.20** | **B** until both B1 and B2 are solved | B2 needs working DDK dma-buf import (TI says half-baked); probe once, in Phase 5 |
| 5 | same (Maemo 6.18.51) | same | glibc (Devuan excalibur) | Mesa 24.0.9-sgx1, X11 hildon | shipped by Maemo; renders **UNVERIFIED** | the reference integration to diff against |
| 6 | TI KM `omapdrm_pvr_ti443x` (mobiaqua `sgx-pvr5-module`) | TI 2024 | glibc | Mesa-sgx 22.3.7, GBM | KW per recipes (PandaBoard, kernels ≤ 6.8) | out-of-tree build system; reference for the TI option set only |
| 7 | openpvrsgx 1.17 | TI **2020** `551665b` | musl + `libc6-compat` | classic `pvr` DRI (Mesa 20.3/21.2) | KW 2021 (pmOS espresso3g), dead since 2022 | classic DRI gone from Mesa; 2020 blobs lack the versioned-callback interface every current mesa-sgx needs |
| 8 | openpvrsgx 1.9.2253347 | `pvr-omap4` 1.9@2253347 | glibc | 2013 WSEGL plugins (X11 DRI2, KMS, Wayland-1.0) | **B** on mainline (*corrected 2026-10-11 [re §12.1 row 8]*; was "P but obsolete") | the UM finds the PVR ioctl base through the TI omapdrm plugin ioctl `DRM_OMAP_GET_BASE`, absent in 6.18 `omap_drm.h`; the letux 1.9.2253347 tree has no Makefile [br TL;DR 4, §7]; also 2013 GBM-backend and libwayland ABIs |
| 9 | openpvrsgx 1.8.869593 | stock **1.8@785978** (bionic, soft-float) | libhybris | Android EGL/gralloc | **B** | build-number mismatch against the letux 1.8.869593 KM (exact check, `vmlinux.bin @0xc0293028`); *corrected 2026-10-11 [re §12.1 row 9]:* a version-matched GPL KM source exists (AOSP `kernel/omap` `03a9286b`) [hyb TL;DR 3, br TL;DR 2], so the rejection rests on bionic, soft-float, libhybris on musl, the dead Android display path and the licence; hybris rejected by pmOS for the same reasons |
| 10 | any | TI Mesa `powervr/25.2.8` | any | any | **B** | no `sgx` driver in 25.2.8 |
| 11 | any | any | any | X11 + glamor | **B** | glamor ES2 bugs (pmOS !1868, Maemo bug #524) |
| 12 | mainline `drm/imagination` | Mesa `imagination` | — | — | **B** | Rogue only, ARM64/RISCV64 only, Vulkan only |

### Primary path

- **KM:** openpvrsgx **DDK 1.17.4948957**, flavour `omap4_sgx540_120`, built
  **in-tree `=m` inside `linux-google-steelhead`** from a pinned upstream archive
  (base `pvrsrvkm-6.18-rc6` @ `d2f1e031d58a`; before Phase 1, diff its
  `drivers/gpu/drm/pvrsgx/` against Maemo `maemo-kernel-6.18.51.1` @ `db432aff895b`
  and against `-v3` @ `e5de75568819`, and adopt the fixes that matter, e.g.
  `ff422e4ab0bb` uninitialised fence count). Our patch set [kdp §8]:
  (a) `-DPVR_LINUX_MEM_AREA_USE_VMAP` (openpvrsgx #3, kc1 #26, TI `eda7780bfd52`);
  (b) drop the need for `EXPORT_SYMBOL(__vmalloc_node_range_noprof)` by using
  `__vmalloc()` for the only `PAGE_KERNEL` caller; (c) an OMAP4 sysconfig header
  (307.2 MHz, 100 Hz HW recovery, 1000 Hz PDS, 100 ms APM); (d) balanced runtime PM
  in `pvr_probe()` with autosuspend, and the `pvr_remove()` order fix (*corrected
  2026-10-11 [pm Addendum APM]:* Maemo `2cd8d74ec61a` already is (d), with a 2000 ms
  delay; adopt it at 100 ms; and if the Phase 1 observation shows no microkernel APM
  events, (h) a host-side idle power-down in our system layer); (e)
  `dma_buf_map_attachment_unlocked()`; (f) build only the SGX540-120 variant; (g)
  drop `select DRM_LEGACY`. Plus the kernel config change to
  `CONFIG_PREEMPT_VOLUNTARY=y` or `CONFIG_PREEMPT=y` (decided in Phase 1a) and the
  DT clock block.
  *Corrected 2026-10-11 [re §12.1 row 15]:* letux `pvr_runtime_resume()` also writes
  OCP `DEBUG_CONFIG` = BIT(31) (THALIA_INT_BYPASS), which stock never writes
  [sys §5, row 18, rec. 5]. Not in the list above; a candidate patch only on
  evidence from a running KM.
- **UM:** TI `omap5-sgx-ddk-um-linux` `1.17.4948957/mesa/glibc-2.35` @
  `84a396a4fb379f10931421e489ac8a199d6a9f2c`, `ti443x_linux`, the 9 runtime
  libraries **unmodified** (no `libdbm` blob, no `pvrsrvctl`, no Scope), in
  `/usr/lib/sgx-ddk/` with their `.so`/`.so.1` links (the unversioned names are
  `dlopen`ed at runtime). Open pieces from Maemo `sgx-ddk-um` tag
  `1.17.4948957+leste15` (`a9dbdc7`): `libdbm`, `pvrsrvinit` [ub §2.2, §3].
  *Corrected 2026-10-11 [re §12.1 row 5]:* the bridge match behind this choice is
  complete only for transport, ids, version and options; the per-call struct sizes
  (check S) were measured on the 2020 build (drop B) only. Drop C's sizes are
  UNVERIFIED and it loads an unexplained constant `0x360b14` [abi synthesis,
  br open 4]; KM-side bridge logging in Phase 1-2 closes it [re §10 item 3].
- **Mesa:** one mesa-sgx in a private prefix, never replacing Alpine Mesa
  (no glvnd in Alpine, soname collision otherwise) [cd §3.5 B4, ur §5.9].
  *Decided 2026-10-11 [ub Addendum §A.5]:* Maemo `git.maemo.org/leste-upstream-forks/mesa`
  tag `powervr-24.0.9` @ `72c93be7aa29` — TI `powervr/24.0.1`'s sgx frontend
  (render-node fix included) plus Maemo's `__DRI2_CONFIG_QUERY` fix on Mesa 24.0.9,
  the build Maemo ships for the Droid 4; fallback TI `powervr/24.0.1` @
  `7c82c1eebc67` + Maemo `30bfcd3`. mobiaqua `mesa-22.3-sgx` is rejected (none of
  TI's 2024-10/2025-01 fixes; `distutils` breaks configure on Python 3.14); its
  yocto pin `9d86c744` (still advertises dma-buf import) stays for the B2 probe
  only. `-Dllvm=disabled -Dgallium-drivers=sgx,softpipe -Dgallium-sgx-alias=omapdrm
  -Dgbm-backends-path=/usr/lib/sgx-mesa/gbm` [ub §3.1, Addendum].
- **Platform:** GBM/KMS `gbm_surface`, a dedicated DRM-master client, current mode
  only (no modeset, HDMI audio stays up), master only while the desktop is off
  [cd §4.4].
- **libc:** route B (glibc sandbox) for the first pixel and the go/no-go gate;
  route A (musl) as the product, decided at the Phase 2 gate on measured evidence
  [ub §6]. Route A's loader design is open (TL;DR 9, corrected) [re §3.3].

### Fallbacks

- **F1, if the closed path fails at the Phase 2 gate** (blob/ABI not solvable in
  about a week): ship the Phase 0 CPU+NEON reference renderer for the visualizer at
  reduced internal resolution (blur FBO at 320×180 or 640×360, DSS VID-plane 2×
  upscale) plus the DSS-plane now-playing screen. No GPU, no blobs, no glibc
  [cd §4.3, ur §4].
- **F2, KM base:** if `pvrsrvkm-6.18-rc6` does not build cleanly, take the 7.2-based
  `-v3` with a small compat layer (`kmalloc_obj` family from v7.0,
  `drm_atomic_commit` from v7.2) [ml §7.4]. Maemo's `pvrsgx/` from
  `maemo-kernel-6.18.51.1` is no separate fallback: it is the same tree plus one
  `pvr-drv.c` commit. It is, however, proof that this tree builds against 6.18.51
  with GCC 14.2 [kdp Addendum A.1]. Letux `letux-6.18.y` (6.18.55) is no separate
  fallback either: same 1.17 tree byte for byte [kdp Addendum C].
- **F3, compositor:** if the unpack_subimage emulation in mesa-sgx is not workable,
  an `LD_PRELOAD` shim next to upstream (wlroots 0.20.2 links `libGLESv2` directly,
  so `glPixelStorei`/`glTexSubImage2D`/`glGetString` interpose) [ur §5.10], or
  TI's Weston revert as a separately named, tracked package with Petr's approval
  [cd §3.7].

### Rejected, with the reason

Stock 1.8 blobs via libhybris (wrong KM build, bionic, soft-float, Android window
system; *corrected 2026-10-11 [re §12.1 row 9]:* "wrong KM build" holds only for
letux 1.8.869593, since AOSP `03a9286b` is a version-matched GPL KM source; the
other reasons and the licence carry the rejection [hyb TL;DR 3, re §5]); DDK 1.9 (`pvr-omap4`, obsolete ABIs, no OMAP4 KM); a separate out-of-tree
module aport (breaks kernel OTA, MODVERSIONS lockstep, no kernel `-dev` package);
built-in `=y` (≈66 KB of LZMA text alone against ~92 KB headroom); patching
wlroots or Weston in place (frozen fork); replacing Alpine Mesa; 384 MHz before a
VDD_CORE regulator exists [kdp §6, ub §6, cd §3.7, pm §2.3].

---

## 4. Roadmap

Every phase obeys the project rules: `hostname` first on the unit; device loads in
`timeout` + `nice` and frame-capped; `pactl list sink-inputs` before anything near
audio, no test tones, Petr drives listening; every working change goes into its
APKBUILD with a `pkgrel` bump in the same session; the full nexusq-diag sweep
including CPU frequency and VDD_MPU against the OPP after every flash or OTA; a
test counts only after it was seen failing. Effort is focused engineer-days,
UNVERIFIED, scaled from the Maemo and kc1 precedents [ur §6, kdp §12].

### Phase 0 — preparation, baselines, the no-GPU wins (4-7 days)

- **Entry:** none.
- **Work:**
  1. Decisions from Petr (§9 step 1).
  2. Read-only probe of a unit with [drafts/nexusq-gpu-probe.sh](gpu-sgx540/drafts/nexusq-gpu-probe.sh) (state of
     `56000000.gpu`, `prm_gfx`, mux parent and rate, runtime-PM counters).
  3. **Measure VDD_CORE** (TWL6030 VCORE1) with a multimeter on the VCORE1
     output. *(Corrected 2026-10-11: the `--pmic` read of 0x48 0x55/0x56 returned
     0x00/0x00 on the Prague unit with the rail on; it does not show the
     SR-programmed setpoint, and no other read-only path exists)* [pm Addendum "Live VDD_CORE without a device" §6]. The PRM VP_CORE registers are expected to
     be uninformative because mainline leaves INITVOLTAGE 0 [pm §4].
  4. DT clock block (draft `0062-…patch.draft`), shipped as an ordinary kernel
     revision: inert in power terms (the gate stays off), visible in `clk_summary`.
  5. healthd append-only fields `gpu_active_ms`, `gpu_rpm`, `gpu_irqs`,
     `dss_active_ms`; `nq-diag-snapshot` section `POWER_DOMAINS_GPU` [pm §6.2, §8].
  6. Baseline arms A0 (HDMI off) and A0h (static pixman desktop) [pm §9]; labwc/pixman
     CPU at 720p and 640×480, idle and animated, with and without
     `PIXMAN_DISABLE=arm-neon`; XRUN counters per the 2026-07-08 procedure [ur §6 P0].
  7. CPU reference renderer for `particle_screensaver_*` and the `blur_*` chain,
     host-tested, measured on the unit at 320×180 / 640×360 / 1280×720. It is the
     baseline, the golden-image oracle and fallback F1.
  8. Pin list: KM base, Maemo diff, UM commit with per-file sha256 (in the drafts),
     Mesa choice (made: Maemo `powervr-24.0.9` @ `72c93be7aa29` [ub Addendum §A.5]).
  9. In parallel, GPU-independent: the DSS-plane now-playing screen; root-causing
     the 75 MHz HDMI cap (task #13) [cd §6.2]; trying labwc
     `<reuseOutputMode>yes</reuseOutputMode>` against the desktop-toggle modeset
     [cd Verification "Added"].
- **Exit:** VDD_CORE recorded; `clk_summary` shows the SGX mux under
  `dpll_per_m7x2_ck` at 307 200 000; baselines in a dated `docs/` note; SW
  renderer cost table; pin list.
- **Test seen failing first:** the probe's `gpu_driver` check reports FAIL on
  today's image; the clock check reports `dpll_core_m7x2_ck` 266 666 667 on r20
  (already in `snapshot.txt:467-470`) and flips after the DT block.

### Phase 1a — the preemption model (2-4 days, kernel-wide)

- **Entry:** Phase 0 baselines exist (the comparison needs them).
- **Work:** one kernel revision changing only `PREEMPT_NONE` → `PREEMPT_VOLUNTARY`
  (upstream's choice) or `PREEMPT` (stock parity, kc1); A/B against the baseline:
  XRUNs with music playing, C3 share, 350 MHz residency, idle exits/s, VDD_MPU
  against the OPP, boot log [kdp §8 k].
  *Added 2026-10-11 [kdp Addendum B.5, B.6, B.8]:* step 0 is a host build of each
  candidate: the boot image must fit the ~92 KB headroom (2005 x86 data put PREEMPT
  at up to ~198 KB more on our 5 664 032 B `vmlinuz`, UNVERIFIED on ARM); take
  `PREEMPT` if it fits, else `PREEMPT_VOLUNTARY`. Diff against the built r19 config,
  not `steelhead_defconfig` (it still says `TINY_RCU`, r19 builds `TREE_RCU`).
  Before the A/B, trial-boot `DEBUG_ATOMIC_SLEEP` on today's NONE kernel (D0), then
  on the candidate with `DEBUG_PREEMPT` (D1), to separate existing bugs from what
  preemption exposes (watch 0014, 0015, 0048, the deep-idle set, 0053, 0059).
- **Exit:** the boot image fits; no audio or idle regression beyond noise; D0 and
  D1 free of new splats; choice recorded in a dated note.
- **Test seen failing first:** the compile gate (Phase 1 step 1) fails with the
  `#error` on the old config and passes on the new.

### Phase 1 — the KM loads and the GFX domain idles (5-10 days)

- **Entry:** Phase 0 exit, Phase 1a decided, stock-parity-auditor review of clock,
  power domain and sysconfig constants.
- **Work:**
  1. Compile gate on the host: pristine 6.18.48 + our series + the pvrsgx tree +
     the patch set; `modpost` must list no undefined symbols (proves patch b),
     `modinfo` alias `of:N*T*Cti,omap4430-gpu*`; then the Alpine GCC 15.2 build
     [kdp §12 step 1].
  2. Aport integration (draft [linux-google-steelhead.APKBUILD.fragment.draft](gpu-sgx540/drafts/linux-google-steelhead.APKBUILD.fragment.draft)):
     pinned archive in `source=`, copy-before-patch in `prepare()`, our patches as
     ordinary `kernel/patches/00NN-drm-pvrsgx-*.patch`, a bump script as the
     update path (Petr's no-frozen-copy rule).
  3. `/etc/modprobe.d/nexusq-gpu.conf` blacklists `pvrsrvkm_omap4_sgx540_120` until
     the runtime-PM fix is proven [kdp §11, ur §6 P1].
  4. Kernel OTA to the **trial slot** only; `modprobe`; `pvrsrvinit` from the glibc
     sandbox; `SGXInit: … match. [ OK ]`; `rmmod` clean.
- **Exit:** 10 load/start/unload cycles clean; after `pvrsrvinit` completed and with
  no client (*corrected 2026-10-11 [pm Addendum APM]:* before `pvrsrvinit` the
  device is OFF by default, so that reading proves only (d); after it, OFF needs a
  microkernel APM event or (h)), `prm_gfx` reaches `off-0` and the gpu device
  `runtime_usage` is 0 within 1 s (arm A1 passes [pm §9.5]); the fck reads 307 200 000; 0 new dmesg errors;
  XRUN baseline held; full diag sweep clean.
- **Test seen failing first:** load the module **without** patch (d) and watch
  `prm_gfx` stay ON (that is the expected failure [pm §8.3 step 3]); with (d) it
  goes OFF. Revert the DT block and watch the rate drop to 266.67 MHz. Load against
  a mismatched UM build options mask once and watch `SGXInit` refuse.
  *Corrected 2026-10-11 [re §12.1 row 20]:* the mismatch is made on the **KM**
  side, never by editing a blob (TSPA): build the KM once with an extra define
  whose bit is not masked, e.g. `PVRSRV_USSE_EDM_STATUS_DEBUG` (bit 2). On the
  `pvrsrvkm-6.18-rc6` base any bit is refused; on the `pvrsrvkm-7.2` base
  (fallback F2) bits 0, 3, 4, 5, 6, 8, 9, 17, 19, and 20/21 on non-5XT cores are
  masked in the KM's compare (the UM's own exact `SGXConnectionCheck` still sees
  them), so pick an unmasked bit and expect the KM's `SGXInit` to refuse
  [br §5, re §4.4].
  *Added 2026-10-11 [re §12.1 row 6]:* with a client open but idle, log the KM's
  active-power events and watch genpd `prm_gfx`, to learn whether APM works with
  the `ti443x` uKernel [re §10 item 5].

### Phase 2 — offscreen GLES2, and the go/no-go gate (4-8 days)

- **Entry:** Phase 1 exit.
- **Work:** route B fast path: Maemo daedalus `sgx-ddk-um-ti443x`,
  `sgx-ddk-um-tools`, `libegl-mesa0`/`libgbm1`/`libgl1-mesa-dri` 22.3.6+sgx2 in a
  **copy** of the glibc base (the Debian closure includes `libllvm15`, > 100 MB, so
  never in OTA). `eglinfo`/`es2_info`: dump the full EGL/GL extension strings into
  the repo (settles B1, `GL_OES_EGL_image`, BGRA8888). Golden test: clear + one
  textured quad (`particle.png`) + one `blur_distort_plain_f` pass into a 256×256
  FBO, `glReadPixels`, compare with the Phase 0 CPU reference. `strace -e
  trace=mmap,mmap2,openat,ioctl` to see which DRM nodes open and what offset
  `PVRSRVMapDmaBuf` passes [ub §10]. Then start the route A packaging.
- **Exit:** `GL_RENDERER` names the SGX 540; golden test 100/100; client
  load/unload leaves no leaked contexts; XRUN baseline held during a 60 s,
  30 fps-capped loop.
- **Gate:** if it fails on blob/libc ABI and is not solvable in about a week, stop
  and take fallback F1.
- **Test seen failing first:** run the golden test with the KM unloaded or under
  `LIBGL_ALWAYS_SOFTWARE=1` (renderer assertion fails); corrupt one reference
  pixel (comparison fails).

### Phase 3 — on screen via GBM/KMS on omapdrm (5-8 days)

- **Entry:** Phase 2 go.
- **Work:** kmscube (or mobiaqua's fork) smooth mode, passing the **current** mode
  (legacy `drmModeSetCrtc` with its own mode would modeset and drop HDMI audio)
  [cd §3.3]; buffer sharing pvrsrvkm ↔ omapdrm through DMM/TILER; DRM-master
  handover with `nq-hdmi hold` (this reverses the HDMI-audio note's "no second DRM
  master" decision, so that note gets updated) [ur §6 P3]; CPU, temperature, XRUN,
  fps at 1280×720 and 640×480.
- **Exit:** 30 min at 720p30 with flips, no corruption (the Maemo low-clock
  artifact check), XRUN baseline held with music, 20 exit/restart cycles without
  leaking master or GEM memory, HDMI audio unbroken across handover.
- **Test seen failing first:** client-side checksum of a known frame (`gbm_bo_map`
  readback; omapdrm exposes no CRC or writeback); a build that clears to the wrong
  colour must fail it. Optionally run at the old 266.67 MHz parent once to see
  whether Maemo-type artifacts appear.

### Phase 4 — the stock visualizer on GLES2, the product (10-15 days)

- **Entry:** Phase 3 exit.
- **Work:** `nexusq-visualizer` (a nexusqd sibling or scene inside one DRM-master
  process shared with the now-playing screen); GL draw side per scene: particle
  field, the six `blur_distort_*` programs plus `blur_output_f`, point-morph,
  track-info overlay; blur FBO at half resolution if EMIF demands it; lifecycle
  (start on HDMI audio or app toggle, desktop off; idle the GPU when the screensaver
  blanks so GFX power-gates); `companion/PROTOCOL.md` section and app toggle; SW
  fallback when the KM is absent; re-authored shaders for public images (stock
  shaders have no redistribution grant) [ur §6 P4].
  *Corrected 2026-10-11 [re §12.1 rows 17, 18]:* the scene list above is
  incomplete. Stock has **five** music scenes, `Waveform`, `WaveformSolid`,
  `Circles`, `PointMorph`, `StarField`, rotating every 10 s from a
  `java.util.Random(0)` sequence with 5 s cross-fades, all drawn additively into a
  960×540 RGBA8 FBO (pool of 3) through the feedback pass; plus the track-info
  overlay, the 40-sprite screensaver and the mute quad (`muted.png`) [vis §2.2,
  §2.3, §3, §4]. The LED ring dims to ×0.2 on mute in stock; `nexusqd` lacks it
  [vis Verif. 16]. The feedback decay is **per frame**, so the trail length depends
  on the frame rate and stock's rate is unknown [vis §4.1, open 1]: a 30 fps cap
  must either match stock's rate (measure it, [re §10 item 7]) or rescale the decay
  per `dt`.
- **Exit:** all scenes and the screensaver match stock behaviour; CPU at 720p30
  at least 2× lower than the SW reference **and** more 350 MHz residency than the
  SW arm at the same fps (arm A3 vs A4 [pm §9.5]); 1 h with music, XRUN baseline
  held; die < 85 °C at 30 fps; GFX off within `sgx_apm_latency` + ε after stop
  (*corrected 2026-10-11 [re §12.1 row 6]:* this assumes APM works with the
  `ti443x` uKernel, UNVERIFIED until Phase 1 observes it; ~~without APM the bound is
  presumably the runtime-PM autosuspend after the client closes~~ *corrected again
  2026-10-11 [pm Addendum APM]:* wrong, because the client's clean-up kicks power the
  device ON and the DDK's own runtime-PM reference then blocks autosuspend; without
  APM the bound is (h)'s latency, and without (h) GFX never goes off).
  *Added 2026-10-11 [kdp Addendum A.5]:* GFX power transitions **under load** pass
  too: a Droid 3 (same SGX540-120, 5.15/6.1) renders but resets with GPU runtime PM
  `auto`, and Maemo's workaround (`power/control=on`) would be masking here. Run the
  1 h test with scene changes and pauses longer than the APM/(h) latency, so GFX
  power-cycles mid-session, and require zero SGX resets or HW recoveries in dmesg.
- **Test seen failing first:** per-scene golden frames against the SW reference
  (break one shader constant, watch it go red); a power test asserting GFX OFF
  after stop, run once with a build that skips `eglTerminate`.

### Phase 5 (optional) — accelerated weston or labwc (10-20 days)

- **Entry:** Phase 4 shipped; the Phase 2 extension dump known; real desktop use.
- **Work:** `GL_EXT_unpack_subimage` emulation in mesa-sgx (B1-a) with a unit test
  of sub-rectangle uploads; weston 16 `renderer=gl`; the B2 probe (GBM BO from
  omapdrm → EGLImage dma-buf → FBO → scanout, one hour) decides whether labwc can
  ever use the GPU; session script keeps pixman as automatic fallback [cd §3.7,
  §7].
- **Exit:** ≥ 30 % less compositor CPU on the animated baseline; no artifacts;
  fallback proven by unloading the KM.
- **Test seen failing first:** start the compositor without the emulation and
  watch it fail with "GL_EXT_unpack_subimage not available/supported".

### Phase 6 — packaging, OTA, A/B, public release (5-8 days)

- **Packages:** KM inside `linux-google-steelhead` (rides the kernel slot);
  `sgx-ddk-um-ti443x` (unmodified blobs + TSPA text, `!strip`), the open
  `libdbm`/`pvrsrvinit`/shim/`powervr.ini`/unit/udev rule, `nexusq-sgx-mesa`
  (private prefix), `nexusq-visualizer`; all in `pmos/ota-packages.list` if route A
  (≈ 1 MB of blobs) [ur §6 P6, ub §8].
- **Boot guard:** a oneshot loads the KM only if the previous boot's GPU-attempt
  marker cleared; a crash during GPU bring-up makes the next boot skip the GPU and
  report it through healthd/MQTT.
- **A/B:** the KM↔UM pair is fixed at 1.17.4948957, so any kernel slot pairs with
  any rootfs slot as long as both stay on 1.17; a diag check asserts it.
- **Public release:** see §6.
- **Test seen failing first:** remove the licence file → the new preflight fails;
  leave the GPU-attempt marker set → the guard skips the KM.

### Phase 7 (optional, beyond parity) — VDD_CORE scaling and GPU DVFS

A `vc-core` regulator modelled on patch 0015's VC bridge (VP force-update on the
`core` voltdm), an OPP-v2 table {153.6 MHz @ 962 mV, 307.2 MHz @ 1127 mV, opt-in
384 MHz @ 1250 mV}, devfreq `simple_ondemand` with `devfreq_cooling`; it must
also enforce stock's MPU→CORE dependency (MPU ≥ 700 MHz ⇒ CORE ≥ 1127 mV). The
same regulator opens the bigger, GPU-independent idle win (CORE OPP50 at idle),
which needs its own stock-parity audit [pm §10 phase 3].

### Totals

| Phase | Days | Cumulative | Device risk |
|---|---|---|---|
| 0 prep, baselines, DT clock, SW reference | 4-7 | 4-7 | none (reads, bounded loads) |
| 1a preemption model | 2-4 | 6-11 | low-medium (kernel-wide; trial slot) |
| 1 KM loads, GFX idles | 5-10 | 11-21 | medium (possible hang; trial slot) |
| 2 offscreen GLES2 + gate | 4-8 | 15-29 | low |
| 3 KMS/GBM | 5-8 | 20-37 | medium (EMIF, thermal) |
| 4 visualizer | 10-15 | 30-52 | medium |
| 6 packaging, OTA, licence | 5-8 | 35-60 (≈ 9-15 weeks at ~4 effective days/week) | low |
| 5 desktop (optional) | 10-20 | +2.5-5 weeks | medium-high |
| 7 VDD_CORE DVFS (optional) | not estimated | — | high |

The kernel half alone (Phase 1 steps 1-4 and PM hardening) was sized at
16-35 h plus a 4-16 h SGXInit debug budget [kdp §12].

---

## 5. Power and idle risk register

Likelihood and impact are judgements (H/M/L). Detection names the measurement that
sees it; the arms are defined in [pm §9](gpu-sgx540/power-clocks-pm.md).

| # | Risk | L | I | Detection | Mitigation | Phase |
|---|---|---|---|---|---|---|
| P1 | `pvr_probe()` keeps a runtime-PM reference: GFX ON whenever the module is bound | H | H | `prm_gfx` not `off-0`, gpu `runtime_usage` > 0 at idle (arm A1) | patch (d) = Maemo `2cd8d74ec61a` at 100 ms: put after `drm_dev_register()`, autosuspend; blacklist autoload until proven. *Corrected 2026-10-11 [pm Addendum APM]:* necessary, not sufficient: after `SGXInit` the DDK holds its own reference until a microkernel APM event, so OFF also needs APM or (h) | 1 |
| P2 | Preemption model change costs idle or audio | M | H | Phase 1a A/B: C3 share, exits/s, XRUNs | choose VOLUNTARY vs PREEMPT on data; own kernel revision | 1a |
| P3 | DDK host timer at 20 Hz while SGX is powered | M (if APM fails; *corrected 2026-10-11 [re §12.1 row 6]:* APM with the `ti443x` uKernel is UNVERIFIED, so treat as M-H until Phase 1 observes it) | M | exits/s +6 % against 353/s | APM on with 100 ms latency; the timer stops on any non-ON transition; without APM, ~~close the client when not visible so runtime PM powers GFX off~~ (*corrected 2026-10-11 [pm Addendum APM]:* closing the client powers GFX ON for clean-up and nothing turns it off) (h), the host-side idle power-down | 1 |
| P4 | GPU IRQs (SPI 21, CPU0) break coupled-C3 rendezvous while animating | H while rendering | L-M | `gpu_irqs`, coupled-idle IPI counts | frame cap; idle the GPU when not visible; IRQ affinity experiments | 3-4 |
| P5 | CPU-side driver overhead pulls the `conservative` governor up the ladder | M | M | 350 MHz residency, arm A3 vs A4 | frame cap, damage-limited scenes; the GPU must beat the SW arm or it does not ship | 4 |
| P6 | EMIF contention starves McBSP2 audio DMA (the 2026-07 crackle class) | M | H | XRUN/underflow counters per `docs/2026-07-08-audio-crackle-dma-contention.md` | half-resolution blur FBO; 30 fps cap; test with music, Petr listening | 3-4 |
| P7 | Thermal: GPU heat on the same die; the passive trip throttles the **CPU**, not the GPU | M | M-H | `thermal_zone0`, TMP101; 102.8 °C already seen under CPU load | frame cap at > 85 °C; client thermal stop at 95 °C; devfreq cooling only with Phase 7 | 3-4 |
| P8 | VDD_CORE below 1.127 V → 307.2 MHz out of spec | L (x-loader sets 1.139 V, 12.4 mV margin; *2026-10-11: not readable from Linux, multimeter pending*) [pm Addendum "Live VDD_CORE without a device" §6] | H | Phase 0 measurement | gate: run 153.6 MHz (962 mV point) until proven | 0 |
| P9 | APM churn: gaps > latency power-cycle GFX mid-animation | M (~~moot if APM does not work~~ *corrected 2026-10-11 [pm Addendum APM]:* not moot: with (h) the same churn applies at (h)'s latency) | L | `gpu_active_ms` pattern, PRM transitions | 100 ms latency (stock), not openpvrsgx's 2 ms, for APM and (h) alike | 1 |
| P10 | `SYS_SGX_CLOCK_SPEED` 200 MHz vs real 307.2 MHz miscalibrates µKernel timing (PDS tick 0.65 ms) | H (as shipped) | M | code; HW-recovery timing | patch (c) OMAP4 sysconfig | 1 |
| P11 | udev autoloads the module from `MODULE_DEVICE_TABLE(of)` before P1 is fixed | H | H | `lsmod` after boot | modprobe.d blacklist; later the Phase 6 boot guard | 1 |
| P12 | `pm_debug` samples `gfx_pwrdm` only at MPUSS deep-idle transitions; biased while rendering; ~245 s timebase drift vs runtime PM | H | M (misleads) | — | use `runtime_active_time` and genpd `prm_gfx` as the authority; never mix sources in one ratio | 0 |
| P13 | Smart-standby SGX vetoes CORE idle | L | L today | `CM_L3_2_CLKSTCTRL` activity bits | moot while USB pins CORE ON; revisit if Ethernet power-down happens | — |
| P14 | Reading SGX registers while GFX is OFF: L3 error, imprecise abort | M (operator error) | H | — | never devmem `0x56000000-0x57ffffff` unless `PM_GFX_PWRSTST` = ON; probes use sysfs | all |
| P15 | CMA: 16 MiB, low `CmaFree` | L | M | `cma_alloc` failures; `CONFIG_CMA_DEBUGFS` | the low free count is borrowed movable pages (HighMem), not pinned use; omapdrm scanout is shmem+TILER on OMAP4; the KM uses CMA only with a `memory-region` | 1-3 |
| P16 | GCC 15.2 armv7 miscompile in 2012-era DDK C | M | H | SGXInit misbehaviour not explained by config | compare once against arm-gnu-13.3; read every warning | 1 |
| P17 | Wall power changes below the 1 W meter step | H | M (no data) | — | a ≥ 0.1 W meter or DC shunt (Petr's call); otherwise report residency and IRQ deltas only | 0 |

---

## 6. Licensing and public-release plan

| Component | Licence | Plan | Evidence |
|---|---|---|---|
| KM (openpvrsgx 1.17) | GPLv2 / dual MIT-GPL | carried as in-tree source in our kernel package; our patches offered upstream (ask Petr before posting) | kdp §8, §12 step 10 |
| mesa-sgx frontend | MIT (IMG/TI): all 17 files under `frontends/sgx` and `drivers/sgx{,_alias}` carry the MIT grant at both candidate commits; the package as a whole `MIT AND SGI-B-2.0 AND BSL-1.0` like Alpine's Mesa | our package, private prefix | ub §3.1, Addendum B.2 |
| `libdbm` (Maemo) | *corrected 2026-10-11:* LGPL with no version named → `LGPL-2.0-or-later` (the LGPL's own no-version rule); no COPYING in Maemo's tree | built from source for musl | ub §2.2, §8, Addendum B.1 |
| `pvrsrvinit` | *corrected 2026-10-11:* Maemo's copy has **no licence** (an unattributed copy of pmOS's 2020 file in GPL-3.0 pmaports) → build **MobiAqua's** `pvrsrvinit.c` instead, MIT by its author's header | built from source for musl | ub Addendum B.1 |
| TI DDK 1.17 blobs | TI TSPA ("Text File License"; the 84a396a4 text is TI's Text File License, labelled `LicenseRef-TI-TSPA` by meta-ti) | redistribution and use **in binary form without modification**, licence reproduced, **for TI devices only** (OMAP4460 is one), **no reverse engineering**. Ship unmodified (`options="!strip"`), the licence in `/usr/share/licenses/`; never patchelf, weaken or `dd`-patch; prefer routes that need no modification. On-device patching is *not clearly permitted* either, because the grant ties "use" to "without modification" (legal reading, not advice) | ub §8 |
| Stock 1.8 blobs (Google/IMG) | no redistribution grant (factory image); *corrected 2026-10-11 [re §12.1 row 19]:* the imgtec package licence of the byte-identical Galaxy Nexus blobs also forbids disassembly, decompilation and reverse engineering (§3.b(i)); the Q's own factory-image terms were not read | never shipped; reference only; no further RE of them | ub §8, hyb §1.1, re §11 |
| Stock Visualizer shaders and PNGs | "Copyright 2011 Google Inc.", stock APK content | redistribution **UNVERIFIED**: re-author functionally equivalent shaders for public images; originals only as the matching reference | ur §6 P4 |

Two options for public images, Petr to choose:

1. **Redistribute** the unmodified blobs in the gh-pages OTA repo, with the TSPA
   text (precedents: Maemo `main` — whose debs are `.comment`-stripped and carry
   no licence, so a distribution precedent only [ub Addendum B.4] — pmOS `non-free`
   2021-22; our OTA repo already carries proprietary Broadcom firmware). ≈ 1 MB.
2. **Fetch at install** for `PUBLIC_RELEASE=1`: an open package downloads the pinned
   TI tree (*corrected 2026-10-11:* not Maemo's deb, whose blobs fail the per-file
   sha256), verifies per-file sha256, installs into
   the persist store, writes the licence; loud diag finding and an app hint when
   absent. Draft in [gpu-sgx540/drafts/sgx-ddk-um.APKBUILD.draft](gpu-sgx540/drafts/sgx-ddk-um.APKBUILD.draft).
   git.ti.com's cgit snapshot still returned 503 on 2026-10-11 (git clone works).
   *Second origin found 2026-10-11:* the `rcn-ee/ti-omap5-sgx-ddk-um-linux` GitHub
   mirror carries `84a396a4` with TI's LICENSE and the pinned blob hashes; Maemo's
   GitHub archive is the third; Software Heritage archives the commit. None is
   TI-operated: meta-ti's `git.ti.com → github.com/TexasInstruments` MIRRORS rule
   has no repository to point at for the SGX UM [ub Addendum B.3].

Either way `scripts/release-preflight-no-secrets.sh` gains two checks: the TSPA
text is present whenever `/usr/lib/sgx-ddk` is, and the shipped blob hashes equal
the pinned TI hashes (proves "without modification") [ub §8]. The full list (pin
list complete incl. `libpvr2d`, no TI `libdbm`/`pvrsrvctl`/Scope, open-package
licence metadata) is in [ub Addendum B.5].

**One compliance note for the record:** during this research two call sites of a TI
binary were disassembled to characterise the `mmap` hazard [ub §4.4 item 4]. The
TSPA forbids disassembly. That finding is to be treated as a hypothesis confirmed
or refuted by strace on the device; no further disassembly of TI blobs.

*Corrected 2026-10-11 [re §12.1 row 1]:* "two call sites" understates it. The RE
set disassembled TI and stock IMG binaries much more widely: `libsrv_um` and
`libpvr_dri_support` of drops B and C and drop A's `libsrv_um` [abi §4, V5, V8];
1.17 (2020 and 2024) and 1.9 `libsrv_um` functions and 1.14 constant scans
[br §1-§5, Verif. 8-17]; the USE immediates of the 1.9 and 1.17 `libsrv_init`
[fw §3]. Those passages stay in the notes as written and count as hypotheses to
confirm by observation. Whether they stay in the repo, and in any public copy of
it, is **Petr's decision** [re §10 item 1, §11]; until then nothing extends them.

---

## 7. Device-safety notes

- **Never write `bootloader` or `xloader`.** GPU work touches only the kernel (via
  the kernel-OTA trial slot) and the rootfs.
- **`hostname` first** on any remote host; a reachable IP proves nothing.
- **No `devmem` inside `0x56000000-0x57ffffff`** (SGX registers, including the
  `0x5600fe00/fe10` OCP wrapper) unless `PM_GFX_PWRSTST` reads ON and the clkctrl
  is functional. The DSS investigation hit exactly this external abort [pm §8.1,
  ur §5.6]. The core revision (`0x00010200` expected at `0x56000024`) is read by
  the KM, or once by the procedure in [ml §4](gpu-sgx540/mainline-6.18.md) with
  runtime PM forced on first.
- **Module blacklisted at boot** until the runtime-PM fix is proven, then a boot
  guard; **trial slot first**, never slot A; hardware watchdog armed during
  bring-up as `nq-deep-idle-ladder.sh` does; a hard hang means a power cycle, so
  keep the unit within reach.
- **Bounded loads:** `timeout` + `nice` on everything, a 30 fps cap, a client
  thermal stop (95 °C), no unbounded loops (two busy loops have locked out sshd
  before).
- **Audio:** `pactl list sink-inputs` before anything that may touch the audio
  path; never generate audio; the visualizer only observes. Avoid modesets while
  HDMI audio is the output (pass the current mode).
- **Measurement hygiene:** no ssh session open during a measurement window (it
  heats the die to 74-79 °C and moves the OPP); settle ≥ 15 min; counters, not
  samples [pm §9.1].
- **One image build at a time** (`docker ps` first); every build prunes old images.
- **Never conclude dead hardware:** an SGX that does not answer is our bring-up
  bug (power, clock, reset, sysconfig, preemption, VMAP), not a broken GPU.
- **Compiler suspicion:** if SGXInit misbehaves without a config explanation,
  compare an arm-gnu-13.3 build before blaming the DDK.

---

## 8. Open questions (consolidated)

Device measurements (read-only, Phase 0):

1. Live VDD_CORE (TWL6030 VCORE1) under mainline. ~~The register is derived without
   the TRM: 0x48 regs 0x55/0x56 … Expected `0x23` = 1.139 V.~~ *2026-10-11: read live,
   0x55/0x56 = 0x00/0x00 with VCORE1 on; the control interface does not expose the
   setpoint. Open until a multimeter reading* [pm §4, pm Addendum "Live VDD_CORE without a device" §6].
2. Is `56000000.gpu` created and unbound? Does `0x56000024` read `0x00010200` and
   `0x5600fe00` read `0x40000000` with runtime PM forced on [ml §4]?
3. Which HDMI mode does labwc pick on the Samsung soundbar or a TV, and does the
   desktop toggle glitch HDMI audio; does `reuseOutputMode` avoid it [cd §6.1]?
4. Wall-power instrument (≥ 0.1 W meter or DC shunt) [pm §9.4].

Kernel:

5. `PREEMPT_VOLUNTARY` or `PREEMPT`: which is enough for the DDK's
   spin-wait-on-workqueue paths, and what each costs in XRUNs and idle [kdp §8 k].
   *Partly answered 2026-10-11 [kdp Addendum B]:* by code, VOLUNTARY behaves like
   NONE for every DDK wait, and no wait was found that needs more. PREEMPT stays the
   recommendation, but only if the host build shows it fits the ~92 KB boot-image
   headroom (2005 data: +3.5 % text, which is up to ~198 KB here). XRUN and idle cost
   are still unmeasured.
6. Does Maemo's `maemo-kernel-6.18.51.1` config enable PREEMPT and CMA 32 MiB, and
   does its `pvrsgx/` differ from `pvrsrvkm-6.18-rc6` in OMAP-relevant ways [ur §2.2]?
   *Answered 2026-10-11 [kdp Addendum A.1-A.2]:* `CONFIG_PREEMPT=y`,
   `CONFIG_CMA_SIZE_MBYTES=32`, `CONFIG_PVRSGX_1_17_4948957=y` in the shipped
   `/boot/config-6.18.51`. `pvrsgx/` differs only in `pvr-drv.c`, by
   runtime-PM autosuspend `2cd8d74ec61a`.
7. Do `letux/pvrsrvkm-1.17.4948957-v4` and `letux-6.18.y` (git.goldelico.com only)
   carry OMAP fixes [kdp §3.1]? *Answered 2026-10-11 [kdp Addendum C]:* no. Both
   are on the GitHub mirror `goldelico/letux-kernel`. `-v4` adds three warning fixes
   to `-v3` (one, `3f5f503efcc6` `MODULE_DESCRIPTION`, is worth cherry-picking);
   `letux-6.18.y` has the rc6 `pvrsgx/1.17.4948957/` tree byte for byte. The KM pin
   and patches (a)-(k) stand.
8. Does `pvrsrvkm-6.18-rc6` compile unchanged against 6.18.48 under Alpine GCC 15.2
   [ml §7.4, kdp §7]? *Partly answered:* the same tree (plus one `pvr-drv.c`
   commit) builds against 6.18.51 with Debian GCC 14.2 (Maemo's shipped module).
   GCC 15.2 is still open [kdp Addendum A.1].
9. Which match table is live: `pvr-drv.c` (`ti,omap4430-gpu`) or the DDK's
   `PVR_USE_DEVICE_TREE` (`ti,omap4-sgx540-120`)? The plan assumes `pvr-drv.c`
   [ml §7.3].
10. Does the KM attach dma-fences to exported buffers' dma-resv, so omapdrm's
    `prepare_fb` implicit sync works [ml §6.1]?
11. Does a TILER-pinned omapdrm scanout buffer import cleanly into pvr, which uses
    `sg_phys()` while omapdrm puts the TILER address in the sg entries [kdp open 8]?
12. Do mobiaqua's omapdrm patches (`OMAP_BO` flags revert, dma-buf kmap restore,
    kmap flush hack) matter on 6.18 for the `gbm_surface` path [cd §8]?
13. Does `PVRMMap()` ever fall through to the stubbed `drm_mmap()` (`-EINVAL` since
    6.8) [kdp §8 j]?
14. Do the M7 HSDIVIDER outputs autoidle once the mux moves, and does
    `dpll_per_m7x2_ck` feed anything besides the SGX mux [ml §3.4, stk open 6]?
15. Is the unpublished stock commit `ad584da` identical to branch tip
    `03a9286bb61a` in `drivers/gpu/pvr` [stk open 2]?

Userspace:

16. Under musl, does `PVRSRVMapDmaBuf`'s 32-bit-offset `mmap` misbehave, and which
    `strerror_r` does `libsrv_um` get in the final load order [ub §4.4]?
17. Is gcompat's locale/ctype behaviour safe for `libglslcompiler`'s parser
    [ub open 8]?
18. Do the runtime extension strings match the `strings` output; does any current
    UM + Mesa expose `GL_EXT_unpack_subimage` (expected: no) [cd open 3, ur open 1]?
19. ~~Where is the source of Maemo's Mesa `24.0.9-sgx1+5m7` [ub §2.2]?~~ Answered
    2026-10-11: Forgejo `git.maemo.org/leste-upstream-forks/mesa` tag `powervr-24.0.9`
    @ `72c93be7aa29` [ub Addendum §A.1].
20. Is Mesa 24.0's libgbm ABI-compatible with Alpine's wlroots 0.20.2 / weston 16
    built against Mesa 26.2.4 headers [ub §6]? Symbol level: **yes** — every
    `gbm_*`/`egl*`/`gl*` import of Alpine's armv7 kmscube, weston 16 and wlroots
    0.20.2 is exported by both candidates; the whole Mesa set must come from the
    prefix [ub Addendum §A.2]. Run-time behaviour still open (Phase 3).
21. Does DDK 1.17 dma-buf import work for omapdrm GBM linear XRGB8888 BOs (B2) [cd §3.7]?
22. Does the DDK twiddle `glTexSubImage2D` uploads on the CPU (decides whether a GPU
    compositor helps wl_shm-heavy LXQt) [cd open 5]?
23. TMU count and real fill rate at 307.2 MHz [cd §6.3].

Visualizer:

24. ~~Render-target size and particle blend mode of the stock Visualizer (decompile
    `Visualizer.odex` with baksmali/jadx) [cd open 6]; the
    `setEGLContextClientVersion` argument (inferred 2) [stk open 8].~~
    *Answered 2026-10-11 [re §12.1 row 14]:* three fixed 960×540 RGBA8 FBOs
    (independent of the HDMI mode); the screensaver blends `(SRC_ALPHA, ONE)`
    straight into the screen framebuffer; the scenes draw additively into the FBO;
    `setEGLContextClientVersion(2)` confirmed [vis §2.3, §3.2, Verif. 1, 3, 6].
    What stays open on the visualizer is in `re` open question 9 (frame rate, HDMI
    mode, FFT scaling, texture premultiplication, EGL config, point and line
    limits).
25. Run automatically whenever HDMI audio is the output, or on demand [ur open 12]?

Power:

26. Does stock reach CORE OPP50 at idle, and did it ever run 384 MHz in practice
    (stock RAM boot with `/system`, `sgx_idle_logging=1`) [pm open 6, 10]?
27. Cost of a GFX OFF→ON cycle and how often the visualizer triggers it [pm open 7].

Policy (Petr):

28. Redistribute the unmodified TI blobs in the public OTA repo, or fetch at install?
29. Pin an upstream openpvrsgx archive in the kernel aport with a bump script as
    the update path, and later offer our patches upstream?
30. A mesa-sgx package in a private prefix (the only Mesa this plan adds); and, only
    if B1 emulation fails, a tracked Weston exception?
31. Stock-derived shaders in private images only, re-authored for public ones?

### Decisions (Petr, 2026-10-11)

- **28 → fetch at install.** The public OTA repo carries only the aport; it fetches
  the pinned TI blobs and checks their sha256. No TI binary lands on gh-pages.
- **29 → pin an archive plus a bump script.** `linux-google-steelhead` pins the
  openpvrsgx archive (`d2f1e031d58a`) with our patches on top. A bump script is the
  update path. Patches may go upstream later, after asking Petr before posting.
- **31 → ship the stock shaders as they are**, in every image. No private-only
  split and no re-authoring.
- **RE passages (re §10 item 1) → keep** as written.
- 30 and 25 stay open; Phase 0 does not depend on them.

---

## 9. The first 10 concrete next steps

1. **Decisions from Petr** (open questions 28-31 and 25), recorded in a dated
   note; nothing is built before them.
2. **Read-only probe** of a unit with [drafts/nexusq-gpu-probe.sh](gpu-sgx540/drafts/nexusq-gpu-probe.sh)
   (after review, copied into `scripts/diag/`): confirm `56000000.gpu` unbound,
   `prm_gfx` off, the mux parent and the runtime-PM counters on today's image.
3. ✅ **VDD_CORE settled 2026-10-11** by construction (pm Addendum §7): 307.2 MHz allowed. Still open: make the kernel send the stock CORE ON voltage itself (0027 never transmits it); a multimeter is a cross-check only.
   ~~Measure VDD_CORE with a multimeter on the VCORE1 output (Petr, hands-on).~~
   *(Corrected 2026-10-11: `nexusq-gpu-probe.sh --pmic` read 0x48 0x55/0x56 =
   0x00/0x00 on the Prague unit with the rail on. The SR-programmed setpoint is not
   visible on the control interface, and there is no other read-only path; the probe
   now reports it as unreadable. A method that writes the PMIC needs Petr's approval
   first.)* [pm Addendum "Live VDD_CORE without a device" §6]. Expected 1.139 V from
   the x-loader. Gate: ≥ 1.127 V → 307.2 MHz; else, or until measured, 153.6 MHz.
4. **DT clock block** ([drafts/0062-…patch.draft](gpu-sgx540/drafts/0062-ARM-dts-omap4-steelhead-run-the-SGX-from-DPLL_PER-like-stock.patch.draft)):
   through the stock-parity-auditor, into `kernel/dts/omap4-steelhead.dts` plus a
   new patch, `pkgrel` bump, trial-slot OTA; `clk_summary` must flip from
   `dpll_core_m7x2_ck` 266 666 667 to `dpll_per_m7x2_ck` 307 200 000.
5. **Instrumentation and baselines**: healthd GPU fields, the
   `POWER_DOMAINS_GPU` snapshot section, arms A0/A0h per
   [drafts/measurement-protocol.md](gpu-sgx540/drafts/measurement-protocol.md).
6. **Preemption model** as its own kernel revision with the audio/idle A/B
   (Phase 1a), after the host boot-image size build and the D0/D1
   `DEBUG_ATOMIC_SLEEP` trial boots [kdp Addendum B.5, B.8].
7. **Compile gate** on the host: 6.18.48 + our series + `pvrsgx` from
   `d2f1e031d58a` + the defconfig fragment; read `modpost`. *Corrected 2026-10-11
   [kdp Addendum A.1, C.2]:* the Maemo and `-v3`/`-v4` diffs are done (Maemo = rc6
   plus `2cd8d74ec61a`; `-v3` not used as a base); cherry-pick Maemo's probe half of
   (d) and `3f5f503efcc6` (`MODULE_DESCRIPTION`) instead.
8. **Driver patches (a)-(g)** and the aport integration with the bump script and
   its seen-failing test; `fleet-safety-reviewer` before any commit under `kernel/`
   or `pmos/`.
9. **Trial-slot bring-up**: blacklist in place, `modprobe`, arm A1 (GFX off within
   1 s, `runtime_usage` 0), full diag sweep, 10 load/unload cycles.
10. **First light, route B**: Maemo daedalus debs in a copy of the glibc base,
    `pvrsrvinit`, extension dump into the repo, strace of the mmap path, kmscube on
    the current mode, golden test; then the go/no-go decision.

In parallel and GPU-independent: the CPU reference renderer (step 7 of Phase 0),
the DSS-plane now-playing screen, and the root cause of the 75 MHz HDMI cap.

---

## 10. Sources

The full source lists, with dates and commit IDs, are at the end of each detail
note. The primary ones:

- Stock firmware (gitignored): `reverse-eng/vmlinux.bin` (3.0.8-gad584da) with
  `reverse-eng/tools/kallsyms.txt` and `nqdis.py`/`dump.py`/`callers.py`;
  `reverse-eng/factory/tungsten-ian67k/system.raw.img` read with `debugfs -R`;
  `private/nexusq-original/Visualizer.apk`.
- Live state: `nq-captures/20261010-185940/snapshot.txt` (6.18.48-r20); the
  2026-10-11 read-only probe [pm §1.3].
- Mainline v6.18.48 (`5bbb9c9f8f80`) and v7.3-rc6 (`a90ee4305c4a`):
  `arch/arm/boot/dts/ti/omap/{omap4,omap443x,omap4460}.dtsi`,
  `drivers/clk/ti/clk-44xx.c`, `drivers/bus/ti-sysc.c`,
  `drivers/pmdomain/ti/omap_prm.c`, `drivers/gpu/drm/omapdrm/`,
  `Documentation/devicetree/bindings/gpu/img,powervr-sgx.yaml`.
- openpvrsgx: https://github.com/openpvrsgx-devgroup/linux_openpvrsgx (branches
  `pvrsrvkm-6.18-rc6` `d2f1e031d58a`, `pvrsrvkm-7.2` `2342ce92fdde`,
  `letux/pvrsrvkm-1.17.4948957-v3` `e5de75568819`; issues #3, #17).
- Maemo Leste: https://github.com/maemo-leste/sgx-ddk-um (tag
  `1.17.4948957+leste15`), https://github.com/maemo-leste/droid4-linux (tag
  `maemo-kernel-6.18.51.1`), apt indexes at https://maedevu.maemo.org/leste/.
- TI: https://git.ti.com/git/graphics/omap5-sgx-ddk-um-linux.git
  (`84a396a4fb379f10931421e489ac8a199d6a9f2c`), https://github.com/TexasInstruments/mesa
  (`powervr/24.0.1`), meta-ti (`ti-bsp.inc`, the weston 16 revert patch).
- mobiaqua: https://github.com/mobiaqua/mesa-sgx, `sgx-pvr5-module`, `yocto`.
- wlroots 0.20.2, weston 16.0.0, labwc 0.20.2, kmscube, Mesa 26.2.4 at the tags
  named in [cd Sources](gpu-sgx540/compositor-display.md).
- postmarketOS pmaports MRs !1868, !2573, !3027, !3162 and issue #1316.
- musl v1.2.6 `ldso/dynlink.c`, gcompat 1.1.0, Alpine edge armv7 packages.
- TI OMAP4460 data manual SWPS046A; Android `kernel/omap`
  `android-omap-steelhead-3.0-ics-aah` (`03a9286bb61a`) and
  `android-omap-tuna-3.0-jb-mr2`.

What could not be reached and is therefore weaker: lore.kernel.org (Anubis),
git.kernel.org cgit (403) and git.ti.com cgit (503) for some pages, git.goldelico.com
branch contents (later read from its GitHub mirror, kdp Addendum C), the postmarketOS wiki (Anubis), archive.org (429).

---

## Addendum (2026-10-11): Repair the doc set: missing gpu-sgx540/README.md, broken master-note links, and the 20 unapplied inconsistencies

**Finding.** `tools/dev/docs-check.py` reported 7 problems: line 13 of each of the
seven detail notes links a `gpu-sgx540/README.md` that did not exist, so
`just check` failed. This note is excluded from docs-check (dated records are), so
its own drift went unreported: Phase 0 step 2 and §9 step 2 named
`drafts/nq-gpu-probe.sh`, Phase 1 step 2 named a
`linux-google-steelhead-pvrsgx.APKBUILD-fragment.draft`, and §6 option 2 pointed at
the drafts folder instead of the blob-package draft. The 20 rows of
[re §12.1](gpu-sgx540/reverse-engineering.md#121-between-the-re-notes-and-the-groundwork-note)
had been listed but applied nowhere.

**Repairs.**

- New [gpu-sgx540/README.md](gpu-sgx540/README.md): index of the two master notes
  (`gw`, `re`), the seven detail notes (tags and workstream numbers as the notes
  use them), the seven RE notes (tags as `re` defines them), the five drafts, a
  reading order, and the licence caveat on the disassembly-derived passages.
- Links in this note now name the real files:
  [nexusq-gpu-probe.sh](gpu-sgx540/drafts/nexusq-gpu-probe.sh),
  [linux-google-steelhead.APKBUILD.fragment.draft](gpu-sgx540/drafts/linux-google-steelhead.APKBUILD.fragment.draft),
  [sgx-ddk-um.APKBUILD.draft](gpu-sgx540/drafts/sgx-ddk-um.APKBUILD.draft).
- Evidence table: `re` (the RE master) and the seven RE-note tags added.
- After the repair `tools/dev/docs-check.py` exits 0 with no findings. The links
  and `#fragment`s of this note (outside docs-check) were checked with a small
  script: all targets and headings exist.

**The 20 rows, where each was applied.** "Here" = this note, marked
*Corrected 2026-10-11 [re §12.1 row N]*.

| Row | Subject | Applied |
|---|---|---|
| 1 | compliance note "two call sites" understates the disassembly | here, §6 compliance note; passages left as written, flagged as Petr's decision [re §10 item 1] |
| 2, 3 | `mmap@GLIBC_2.4` and `strerror_r` hazards rated lower by `abi` | here, TL;DR 9 |
| 4 | route A loader design open (own DSO without gcompat vs `ld-musl` link + gcompat) | here, TL;DR 9 and §3 Primary path libc |
| 5 | drop C per-call sizes (check S) unmeasured, `0x360b14` | here, §3 Primary path UM |
| 6 | APM with the `ti443x` uKernel UNVERIFIED | here, §2 (after the stock table), Phase 1 work, Phase 4 exit, risks P3 and P9 |
| 7 | KM checks the UM's build, not the uKernel's; no SGXMKIF layout check | here, §2 paragraph under the diagram |
| 8 | matrix row 8 is B on mainline (`DRM_OMAP_GET_BASE` absent, no Makefile) | here, §3 matrix row 8 |
| 9 | "wrong KM build" true only of letux; AOSP `03a9286b` is version-matched | here, §3 matrix row 9 and the Rejected list |
| 10 | GFX power states | this note holds; `sys` open question answered in place (`pwrsts` 0x0d) |
| 11 | preemption compile-enforced | this note holds; `sys` §6 row 26 corrected in place |
| 12 | mux on `dpll_core_m7x2_ck` 266.67 MHz | this note holds; `sys` §6 rows 7 and 29 and its "Not re-verified" list corrected in place |
| 13 | `pvr_probe()` pins GFX ON | this note holds; `sys` §6 row 17 corrected in place |
| 14 | open question 24 answered | here, §8 question 24 struck and answered |
| 15 | OCP `DEBUG_CONFIG` BIT(31) not in the patch list | here, §3 Primary path KM |
| 16 | screensaver at full HDMI size is workable on the CPU | here, TL;DR 8 |
| 17 | per-frame decay vs the 30 fps cap | here, Phase 4 work |
| 18 | Phase 4 scene list incomplete; LED ×0.2 on mute | here, Phase 4 work |
| 19 | stock 1.8 blobs: licence also forbids RE | here, §6 table |
| 20 | Phase 1 mismatch test must be made on the KM side | here, Phase 1 "test seen failing first" |

**Corrections to other notes (minimal, in place).**

- [re/stock-sysconfig.md](gpu-sgx540/re/stock-sysconfig.md) §6 row 7: "presumably
  CORE" now cites the measurement; row 17: the MATCH is for the sysconfig layer
  only, the letux glue pins GFX ON; row 26: "nothing enforces it" is wrong, the
  `#error` enforces it; row 29: live value answered; open questions: `pwrsts` 0x0d
  decoded; "Not re-verified": live value noted, TRM reset value still unconsulted.
- [gpu-sgx540/reverse-engineering.md](gpu-sgx540/reverse-engineering.md) §12.1
  intro: marked applied; §12.3: marked resolved.
- [gpu-sgx540/drafts/README.md](gpu-sgx540/drafts/README.md): the old-name table
  is now marked as historical.

**Reproduced from primary sources in this pass.**

- Row 11: `osfunc.c:126-135` at openpvrsgx `d2f1e031d58a`
  (`drivers/gpu/drm/pvrsgx/1.17.4948957/eurasia_km/services4/srvkm/env/linux/osfunc.c`,
  fetched from raw.githubusercontent.com on 2026-10-11) is
  `#if defined(PVR_LINUX_USING_WORKQUEUES) && !defined(CONFIG_PREEMPTION) && !defined(CONFIG_PREEMPT_VOLUNTARY)`
  … `#error "A preemptible Linux kernel is required when using workqueues"`;
  `eurasia_km/Makefile:124` and `:238` define `PVR_LINUX_USING_WORKQUEUES`.
- Row 12: `nq-captures/20261010-185940/snapshot.txt:467-470` shows
  `dpll_core_m7x2_ck` → `l3-gfx-clkctrl:0000:24` → `l3-gfx-clkctrl:0000:0`
  (`5600fe00.target-module` fck), all 266666667.
- Row 13: `pvr-drv.c` at `d2f1e031`: `pm_runtime_get_sync()` at 441, the only puts
  at 443 (`put_noidle` on get failure), 476 (probe error path) and 488
  (`pvr_remove()`). Line 465, which TL;DR 6 also cites, is the end of the success
  path (`gpsPVRLDMDev = pdev;` then `return 0;` at 467) with no put.
- Row 6, KM half: `include4/sgx_options.h:151` at `d2f1e031` is
  `#define OPTIONS_BIT15 0x0 /* HACK: missing userspace flag */`.

**Not reproduced (taken from the RE notes' verification sections).** Rows 1-5, 7-10
and 14-20, and row 6's uKernel half (the `ti443x` options word `0x00360018` without
bit 15 [fw §3]), rest on `abi`, `br`, `fw`, `hyb` and `vis` and their 2026-10-11
verification passes. They were not re-derived: several come from TI or stock IMG
binaries, which this pass did not read (§11 of `re`), and the `vis` facts come from
the stock `Visualizer.odex`, which this pass did not reopen. The `fw §2.6` pointer
in row 7 is item 6 of `fw` §2 (there is no §2.6 heading). The anchor-check script
uses a GitHub-style heading slug; how the repo's own renderer slugs `12.1` is
UNVERIFIED.
