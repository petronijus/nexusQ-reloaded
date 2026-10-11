# SGX540 groundwork 3/7: The GPL SGX kernel driver (pvrsrvkm) on our 6.18.48 kernel

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

*Original working title: 03 — The GPL SGX kernel driver (pvrsrvkm) on our 6.18.48 kernel*

Workstream: kernel driver port for the PowerVR SGX540 (rev 1.2.0 / "120") in the
OMAP4460 of the Nexus Q (steelhead). Research and planning only: nothing was
built, flashed or committed. Date of research: 2026-10-11 (Europe/Prague).

Evidence convention used below:

- `repo:path:line`: a file in the repository root
- `stock:symbol@addr`: the stock tungsten 3.0.8 kernel `reverse-eng/vmlinux.bin`, decoded
  with `reverse-eng/tools/{nqdis,dump}.py` (capstone installed into a scratch venv)
- `6.18.48:path:line`: pristine linux-6.18.48 from cdn.kernel.org, extracted to scratch
- `6.12.12:path`: the pristine tree already in `repo:build/linux-6.12.12`
- `opsgx:<branch>@<sha>`: openpvrsgx-devgroup/linux_openpvrsgx, read through the
  GitHub API and a sparse partial clone in scratch
- **UNVERIFIED (…)**: my inference, with the reasoning given

---

## TL;DR

1. **Pick DDK 1.17.4948957 for SGX540 rev 120, and build it in-tree as a module (`=m`)
   inside `linux-google-steelhead`.** It is the only DDK for which a kernel driver
   (openpvrsgx and TI) *and* a matching non-Android userspace (TI `ti443x` target)
   exist for this GPU, and which someone has run end to end on an OMAP4. It was
   shown on an OMAP4430 Kindle Fire in 2021: KM/UM "DDK match", kmscube at 60 fps. That
   run needed one extra flag, `-DPVR_LINUX_MEM_AREA_USE_VMAP`. The DDK 1.9.x and 1.8.x
   trees in openpvrsgx do not build an OMAP4 module at all. The stock Nexus Q DDK,
   `1.8@785978` (Android/bionic), is not in openpvrsgx.
2. **openpvrsgx is alive and already tracks 6.18.** It has a merge branch
   `pvrsrvkm-6.18-rc6` (`d2f1e031d58a`, 2025-11-21) built on exactly `Linux 6.18-rc6`.
   It also has newer per-kernel merges up to `pvrsrvkm-7.2` (`2342ce92fdde`,
   2026-08-26, the default branch). The 1.17 topic branch keeps moving: `-v3` was
   updated 2026-08-21 on GitHub, and a `-v4` exists on git.goldelico.com and its GitHub
   mirror `goldelico/letux-kernel` (= `-v3` on 7.3-rc6 plus three warning fixes, Addendum C). A
   static check of headers between 6.18-rc6 and 6.18.48 found no API change that the
   1.17 driver uses. The 1.17 tree keeps `LINUX_VERSION_CODE` guards back to 2.6, so
   the 7.2-based tree should also build on 6.18 (UNVERIFIED by compile).
3. **Mainline 6.18.48 already contains the whole OMAP4 "SoC glue".** That is the
   `ti,sysc-omap4` target module @0x56000000 with a `gpu@0` child
   (`"ti,omap4430-gpu","img,powervr-sgx540"`, SPI 21), the `prm_gfx` power domain,
   the `l3_gfx_clkctrl` GPU clock with its mux, the ti-sysc revision quirk, and the
   official `img,powervr-sgx.yaml` binding. The openpvrsgx glue branches
   (`omap-pvr-soc-glue-v10`, `omap-sysc-prm-gfx`) add nothing that OMAP4460 needs.
   **One DT fix is missing on the 4460:** mainline pins the SGX clock to
   dpll_per_m7x2 = 307.2 MHz only in `omap443x.dtsi`. `omap4460.dtsi` has nothing, so
   our GPU clock is whatever the bootloader left.
4. **The driver as published needs a core-kernel change: `EXPORT_SYMBOL(__vmalloc_node_range_noprof)`.**
   It is the only change the PVR merge makes to `mm/vmalloc.c`, and 6.18.48 does not
   export the symbol. With `PVR_LINUX_MEM_AREA_USE_VMAP` set, the only remaining
   caller asks for a plain cached mapping (`PAGE_KERNEL`). A driver-side switch to
   the exported `__vmalloc()` therefore removes the core patch. Root-cause fix,
   nothing masked.
5. **In-tree `=m` is the only build model that fits our delivery chain.**
   - The zImage does not grow. Staged-image headroom was only **92 KB** at v1.17.0
     (`repo:INSTALL.md:88-89`). Built-in would cost an estimated ≥66 KB of
     LZMA-compressed text alone (stock 1.8 code block, see §6.1), so `=y` would use up
     most or all of that headroom. That is an estimate, not a measurement.
   - `nq-kernel-ota stage-apk` carries `/lib/modules/<rel>` *only from the kernel
     apk* (`repo:userspace/nexusq-kernel-ota/nq-kernel-ota:398-415`). An
     out-of-tree module apk would vanish on every kernel OTA.
   - `CONFIG_MODVERSIONS=y` plus `LOCALVERSION=-r$pkgrel` mean a separate module
     would have to be rebuilt in lockstep with every kernel pkgrel.
   - We ship no kernel `-dev` package to build an out-of-tree module against.
6. **Stock ground truth for clocks:**
   - Stock steelhead builds pvrsrvkm into the kernel, DDK `sgxddk 18 1.8@785978`.
   - It reparents `gpu_fck` to `dpll_per_m7x2_ck`.
   - It runs DVFS over three GPU OPPs: **153.6 MHz @ 962 mV, 307.2 MHz @ 1127 mV,
     384 MHz @ 1250 mV**, all on VDD_CORE (`stock:omap446x_opp_def_list@c0043e94`).
   - Its sysutils builds a 4-entry table (last entry duplicated), drops to index 0
     (153.6 MHz) when idle and jumps to index count-2 = **384 MHz** when busy
     (`stock:SysDvfsInitialize@c0290f80`, `stock:RequestSGXFreq@c0290c28`).

   Mainline cannot scale VDD_CORE, so **run at a fixed 307.2 MHz** (OPP100). That is
   TI's own KM constant for SGX540-120 and the Droid 4 mainline choice.
   384 MHz is off the table until VDD_CORE is measured and can be raised.
7. **Driver changes we must carry, and offer upstream** (Petr is asked before anything
   is posted):
   - (a) VMAP flag
   - (b) no private mm export
   - (c) an OMAP4 sysconfig (307.2 MHz, 100 Hz HW recovery, 100 ms active-power
     latency like stock). Today OMAP4 silently reuses the **AM437x** header: 200 MHz,
     50 Hz, 2 ms.
   - (d) balance the `pm_runtime_get_sync()` in `pvr_probe()`. As written, it pins
     the GFX power domain ON for as long as the module is loaded, which would undo
     our deep-idle work.
   - (e) `dma_buf_map_attachment_unlocked()`
   - (f) build only the SGX540-120 variant, not the OMAP4470 SGX544 one as well
   - (g) drop `select DRM_LEGACY`, a symbol that no longer exists
8. **Kernel-wide prerequisite found in verification (2026-10-11): our kernel must become
   preemptible.** Every OMAP build of the 1.17 KM defines `PVR_LINUX_USING_WORKQUEUES`
   (`opsgx:pvrsrvkm-6.18-rc6@d2f1e031:drivers/gpu/drm/pvrsgx/1.17.4948957/eurasia_km/Makefile:124,238`),
   and `osfunc.c:126-135` then does
   `#error "A preemptible Linux kernel is required when using workqueues"` unless
   `CONFIG_PREEMPTION` or `CONFIG_PREEMPT_VOLUNTARY` is set. Our defconfig has
   `CONFIG_PREEMPT_NONE=y`, `# CONFIG_PREEMPT_VOLUNTARY is not set`,
   `# CONFIG_PREEMPT is not set` (`repo:kernel/configs/steelhead_defconfig:99-102`), and
   nothing in the APKBUILD or patches overrides it (grep). As configured today, **the
   module will not compile.** Upstream's own merge adds `CONFIG_PREEMPT_VOLUNTARY=y` to
   `omap2plus_defconfig` for exactly this reason (`0affbb5a7b95`, 2024-10-26, "PVR/SGX
   build now needs CONFIG_PREEMPT=y or CONFIG_PREEMPT_VOLUNTARY=y";
   `omap2plus_defconfig:511` in the merge), and the kc1 run that worked used
   `CONFIG_PREEMPT=y`. Stock steelhead was `#1 SMP PREEMPT` (banner string in
   `reverse-eng/vmlinux.bin`). This changes scheduling for the whole kernel, audio path
   included, so it needs its own regression pass (see §8 k, §9).
9. **Effort:** about **20-35 engineer-hours** to a probed `/dev/dri/card1` "pvr
   1.17.4948957" device on the unit, with the GFX domain idling. That excludes
   userspace bring-up, which is another workstream and the riskiest part (SGXInit
   option/ABI mismatches). DVFS (153.6/307.2 via devfreq) is an optional later phase
   (+8-16 h).

---

## 1. What was read and checked (method)

- Prior note `repo:docs/2026-06-19-gpu-sgx540-acceleration-research.md` (125 lines,
  written on 6.12). Corrections to it are in §13.
- Kernel aport `repo:pmos/linux-google-steelhead/APKBUILD`:
  - pkgver 6.18.48, pkgrel 20
  - `prepare()` forces `CONFIG_LOCALVERSION="-r$pkgrel"` at :97-113
  - modules installed with `INSTALL_MOD_STRIP=1` at :126-138
- `repo:kernel/configs/steelhead_defconfig`. Its header still says "Linux/arm 6.12.12",
  GCC 13.3. The build runs `olddefconfig`, so the file is stale but functional; see the
  open questions.
- The kernel-OTA and rootfs-A/B design: `repo:docs/2026-08-18-kernel-ota-phase2.md`,
  `nq-kernel-ota`, `nq-rootfs-ab`.
- Boot-image size history:
  - `repo:INSTALL.md:85-91`
  - `repo:docs/2026-08-31-kernel-6.18-test-plan.md:25-27`
  - `repo:scripts/build-kernel-boot.sh:257-259`
- Stock kernel: kallsyms plus disassembly of `omap_init_gpu`, `SysDvfsInitialize`,
  `RequestSGXFreq` and `SysGetSGXTimingInformation`, a dump of
  `omap446x_opp_def_list`, and strings.
- Stock `/system` (`reverse-eng/factory/tungsten-ian67k/system.raw.img`), read with
  `debugfs` without mounting: blob list and version strings.
- openpvrsgx:
  - every branch head with its date (GitHub API)
  - logs of the 1.17 topic branches
  - all issues and PRs
  - a sparse partial clone of `pvrsrvkm-6.18-rc6` and `pvrsrvkm-7.2`, used to read
    the `drivers/gpu/drm/pvrsgx` tree and diff the PVR merge against its first parent
    (`Linux 6.18-rc6`)
- git.goldelico.com letux-kernel: refs listed with `git ls-remote`. It is dumb HTTP
  with no gitweb, so branch contents were *not* readable there (read later from the
  GitHub mirror, Addendum C).
- TI: `git.ti.com/cgit/graphics/omap5-sgx-ddk-linux` and `-um-linux` branch pages,
  plus the meta-ti recipes and BSP include on GitHub (`TexasInstruments/meta-ti`).
- mobiaqua `sgx-pvr5-module`, `mesa-sgx`, `libgbm`; maemo-leste `pvr-omap4`.
- pmaports via the gitlab.postmarketos.org API: MRs !1868, !2573, !3027, !3162 and
  issues #932, #1316.
- Tree comparison **6.12.12 vs 6.18.48** for every API break the driver hits (§7).

**Not done, because the instructions forbid it:** no compile, not even a host compile
test. Every "compiles" statement is an inference from upstream history and header
comparison. Step 1 of the plan (§12) is the compile gate.

---

## 2. Stock ground truth (Nexus Q, tungsten IAN67K, kernel 3.0.8)

| Fact | Evidence |
|---|---|
| Stock KM is **built into vmlinux**, sources `drivers/gpu/pvr/…`, platform glue `drivers/gpu/pvr/omap4/sysconfig.c` + `sysutils_linux.c`, plus `omaplfb` | `strings vmlinux.bin`; `stock:PVRCore_Init@c0025920` with `__initcall_PVRCore_Init6@c003cf54` |
| Stock DDK = **`CustomerGoogle_Android_ogles1_ogles2_GPL sgxddk 18 1.8@785978`** | string in `vmlinux.bin` |
| Stock userspace is DDK **1.8@785978**, Android/bionic. Version strings: `OpenGL ES 2.0 build 1.8@785978` (in `/vendor/lib/egl/libGLESv2_POWERVR_SGX540_120.so`) and the EGL string `1.4 build 1.8@785978` (in `/vendor/lib/libIMGegl.so`, not a GLES library). Other blobs: `/vendor/bin/pvrsrvinit`, `/vendor/lib/libsrv_um.so`, `libsrv_init.so`, and `/vendor/lib/hw/gralloc.omap4.so` | `debugfs -R "ls -l /vendor/lib"`, `/vendor/lib/egl`, `/vendor/lib/hw` on `system.raw.img`; `strings` of the dumped blobs (re-checked 2026-10-11) |
| GPU device built with `omap_device_build("pvrsrvkm", hwmod "gpu", pdata, omap_gpu_latency)`. pdata = {`ovfreqs`=1 when `omap_rev()>>20 == 0x446`, `device_scale=omap_device_scale`, `device_enable/idle/shutdown`}. Then `omap_omaplfb_device` is registered | `stock:omap_init_gpu@c0556ac0` (disassembly) |
| `gpu_fck` is reparented to **dpll_per_m7x2_ck** (error strings `failed to set gpu_fck to dpll_per_m7x2_ck`) | strings |
| **GPU OPPs (4460), all enabled:** 153 600 000 Hz @ 962 000 µV; 307 200 000 Hz @ 1 127 000 µV; 384 000 000 Hz @ 1 250 000 µV. Voltage domain **"core"**, clock **dpll_per_m7x2_ck** | `stock:omap446x_opp_def_list` entries at `c0043e94…c0043ed8` (dump.py) |
| `SysDvfsInitialize`: n = `opp_get_opp_count()` (3); allocates n+1 entries, fills them with `opp_find_freq_ceil` and duplicates the last. Stores count = n+1 (+0x30), table (+0x34), current index = n (+0x38) | `stock:SysDvfsInitialize@c0290f80` (disassembly) |
| `RequestSGXFreq(sys, bMax)`: index = 0 when idle, **count-2 (= 384 MHz)** when busy. If the clock call fails it does not pick a frequency; it records the current index as count-1 (the duplicate entry), so the next request retries. Callers: `EnableSGXClocks` and `SysSGXIdleTransition` pass bMax=1, `sgx_idle_work_func` passes 0. So this is clock-on → 384 MHz, idle work → 153.6 MHz, not load-based scaling | `stock:RequestSGXFreq@c0290c28` (disassembly); call sites from `callers.py` (c0290dd0, c0290a00, c028fa78) |
| Timing: core clock = current table entry (dynamic); HW-recovery 100 Hz; µKernel timer 1000 Hz; active PM on; APM latency = `sgx_apm_latency` = **100 ms**; `sgx_idle_timeout` = 1 000 000 | `stock:SysGetSGXTimingInformation@c0290bb0`; `dump.py c0725b9c` |
| No firmware file: the SGX microkernel is uploaded by userspace (`libsrv_init.so` has `SetupuKernel …` strings) | `strings libsrv_init.so`; the 1.17 KM has no `request_firmware` (grep) |

**Implications:**

- The stock GPU ran a VDD_CORE-coupled DVFS that reached **384 MHz only with VDD_CORE
  at 1.25 V**. Mainline has no VDD_CORE scaling.
- Our patch 0027 sets the VC *ON* voltage for CORE to 1.200 V
  (`repo:kernel/patches/0027-…patch` header), but nobody has measured the live
  VDD_CORE (see open questions).
- So the safe fixed point is **307.2 MHz** (OPP100, needs ≥1.127 V).
- 384 MHz is not allowed until VDD_CORE ≥ 1.25 V is proven, and nothing in mainline
  sets that.

---

## 3. Upstream landscape (state as of 2026-10-11)

### 3.1 openpvrsgx-devgroup/linux_openpvrsgx (GitHub)

- Not a GitHub fork, so it cannot be compared against `torvalds/linux` across repos.
  The default branch is `linux+pvrsgx`. Last push 2026-08-26T05:07Z.
- Description: "shaping existing GPL Linux kernel drivers for the PVR/SGX5 … into
  drivers/gpu/drm … NOT about … user-space".
- Layout of the project (from branch names and merge messages):
  - **Topic branches** `letux/pvrsrvkm-<DDK>` (one per DDK), `letux/pvrsrvkm-vN`
    (common Kconfig/Makefile/pvr-drv), `letux/omap-pvr-soc-glue-vN`,
    `letux/omap-sysc-prm-gfx`, `letux/pvrsrvkm-generic`, `letux/pvrsrvkm-ddk-core`,
    `letux/pvrsrvkm-defconfig`. All are rebased onto each new mainline. The current
    topic heads sit on **Linux 7.2** (committer date 2026-08-16 everywhere).
  - **Per-kernel merge branches** `pvrsrvkm-<kver>` merge every topic branch onto
    that tag.

| Branch | Head | Commit date | What it is |
|---|---|---|---|
| `linux+pvrsgx` (default) = `pvrsrvkm-7.2` | `2342ce92fdde` | 2026-08-26 | merge of all topics incl. `pvrsrvkm-1.17.4948957-v3` + `pvrsrvkm-v3` onto 7.2 |
| `pvrsrvkm-7.2-rc3` / `-rc2` | `004b19f6e283` / `b9d3eef50959` | 2026-07-16 / 07-08 | merges (1.17 **-v2**) |
| `pvrsrvkm-7.1` | `c9c94731b070` | 2026-06-29 | merge (1.17-v2) |
| `pvrsrvkm-7.0` | `d44512677de0` | 2026-07-08 | "Merge pull request #23 … pvrsrvkm-7.0-poulsbo" |
| `pvrsrvkm-6.19-rc6` | `f0f6774c85c3` | 2026-01-20 | merge |
| **`pvrsrvkm-6.18-rc6`** | **`d2f1e031d58a`** | **2025-11-21** | merge whose first parent is `6a23ae0a96a6` "Linux 6.18-rc6" (2025-11-16). Includes `letux/pvrsrvkm-1.17.4948957` (v1) + `pvrsrvkm-v2` |
| `pvrsrvkm-6.17-rc7` / `6.15-rc5` / `6.12` | `60f1612bdc40` / `59c9ebd2c36c` / `d34cd2128523` | 2025-09-27 / 2025-05-06 / 2024-11-19 | merges |
| `letux/pvrsrvkm-1.17.4948957-v3` | `e5de75568819` | 2026-08-21 | 1.17 topic on 7.2 (log in §3.2) |
| `letux/pvrsrvkm-1.17.4948957` (v1, GitHub) | `584dd33a1557` | 2025-05-04 | "fix for 6.15-rc1: convert del_timer_sync() to timer_delete_sync()". **Stale on GitHub**; goldelico has a different head (`af3a1ed28eb5`) |
| `letux/pvrsrvkm-1.9.2188537` | `e4e332159df1` | 2026-08-16 (rebase) | 1.9 topic (OMAP3 only, §4) |
| `letux/omap-pvr-soc-glue-v10` | `57c9a409ba70` | 2026-08-16 (rebase) | DT nodes for jz4780, sun6i/sun8i, s5pv210, **omap4470**, am33xx, atlas7/prima2; bindings |
| `letux/omap-sysc-prm-gfx` | `5c31c028e783` | 2026-08-16 (rebase) | `pdata-quirks` PRM auxdata + omap5 IVA clkctrl |
| `letux/pvrsrvkm-generic` | (2025-09-27 authored) | 2026-08-16 | "SoC integration reconstructed from 1.x" for each DDK: groundwork for one generic driver |

**git.goldelico.com/letux-kernel.git** (`git ls-remote`, 27 621 refs, 2026-10-11):

- Has `letux-6.18`, **`letux-6.18.y`** (`c118c403ccb8`), `letux-6.19(.y)`,
  `letux-7.0(.y)` … `letux-7.2(.y)`.
- Has **`letux/pvrsrvkm-1.17.4948957-v4`** (`3f5f503efcc6`), which is *not* on the
  openpvrsgx GitHub repo, and `letux/pvrsrvkm-1.14.3759903-v2`.
- The contents could not be read from git.goldelico.com itself: the server is dumb HTTP
  (no shallow fetch), and the web front end is a "Mac OS X Server" landing page with no
  gitweb. *Corrected 2026-10-11 [Addendum C]:* the GitHub mirror `goldelico/letux-kernel`
  carries both refs at the same hashes and was read there.
- **UNVERIFIED (inference):** `letux-6.18.y` is the Letux distribution kernel on the
  6.18 stable series and very likely carries the PVR merges. *Answered
  2026-10-11 [Addendum C]:* it does. Its `pvrsgx/1.17.4948957/` tree is byte-identical to
  `pvrsrvkm-6.18-rc6`, and so is `pvr-drv.c`; `letux_defconfig` sets
  `PVRSGX_1_17_4948957=y`, `SGX_OMAP=m`. It adds nothing OMAP4-relevant to rc6.

**Issues and PRs** (all 24, GitHub API):

- **#3** (opened 2021-03-21, closed 2021-03-22 by the reporter; the last comments are
  from 2021-03-24), "The driver crashes when used". On **OMAP4430 SGX540**
  with 1.17 and pmOS `sgx-ddk-um`:
  - `UM DDK-(4948957) and KM DDK-(4948957) match. [ OK ]`
  - then `PollForValueKM: Timeout … SGXInitialise: Wait for uKernel initialisation failed`
  - Fix: add `-DPVR_LINUX_MEM_AREA_USE_VMAP` to the module Makefile. The reporter
    replied "It works!!".
  - The flag is **still not in the 1.17 Makefile** on either the 6.18-rc6 or the 7.2
    branch (grep).
  - Independent confirmation (added in verification): TI's own KM branch
    `ti-img-sgx/1.17.4948957/k5.10` on git.ti.com has head `eda7780bfd52` "Fix driver
    config for 5.10 kernel". That commit adds `PVR_LINUX_MEM_AREA_USE_VMAP = 1` to
    `eurasia_km/eurasiacon/build/linux2/config/core.mk` and cites issue #3. It was
    written by Paul Barker (SanCloud) for AM335x (`git ls-remote` plus the cgit
    commit page, 2026-10-11). So the flag is needed beyond OMAP4 and beyond openpvrsgx.
- **#4** (closed). wlroots plus SGX GLES errors (`GL_EXT_unpack_subimage`, `GL_CLAMP`).
  A userspace concern.
- **#2** (open since 2021). Build fails with `CONFIG_SGX_DEBUG`.
- **#17** (open). "Progress on mainline efforts". Upstreaming is considered far off:
  IMG has no interest in anything older than AXE (comment by StaticRocket of TI,
  2024-11-03).
- **#20** (closed 2026-08-26). jz4780 cache-sync crash on 7.1. Fixed for MIPS only
  (`43caf0880109`, `4044dd9c39c9`). The ARM path is separate (`dma_sync_single_*` on
  physical ranges, `0e4610be9830`).
- PRs #21-#24 (2026-06…09). Intel Poulsbo/Cedarview work on 1.17. This is where the
  `-v2`/`-v3` churn comes from: dumb buffers, fbdev helpers, ABI options. It is
  irrelevant to OMAP4, but it means 1.17 is actively maintained.
- No open issue mentions musl. musl is a userspace concern; the KM does not care.

### 3.2 What the 1.17 topic gained after the 6.18-rc6 merge (`-v3` log, newest first)

Taken from the GitHub commit list of `letux/pvrsrvkm-1.17.4948957-v3`.

**Relevant to us:**
- `ff422e4ab0bb` "fix unitialized variable". It initialises `blocking_fence_count` in
  `pvr_linux_fence.c`. A **real bug** on our path (dma-resv fence code); cherry-pick it.
- `4ec821a3f175` `in_irq()` → `in_hardirq()` (needed for 6.19; harmless on 6.18).
- `faa4b8e1a91e`, `6428124320cf`, `e5de75568819`: `strncpy` → `strscpy`. Hygiene;
  `strncpy` still exists in 6.18.48 (`6.18.48:include/linux/string.h:71`).
- `53e1d02833e5`: a format warning with `PHYS_ADDR_T_64BIT`. Not set for us.

**Intel/x86-only:** Poulsbo/Cedarview enablement, `rdmsrl` → `rdmsrq` (7.2),
Cedarview ABI 1.7.862890 support, ioctl alias, dumb buffers, FBO, swap chains, GTT
resource API.

**Kconfig/Makefile restructure in `-v3`** (`b9b0a1cd50dc` "Add driver ABI configuration options"):
- `SUPPORT_PERCONTEXT_PB`, `SUPPORT_HW_RECOVERY` and `SUPPORT_SGX_HWPERF` move from
  fixed `ccflags` into Kconfig (`SGX_PB_*` choice, `SGX_HW_RECOVERY`, `SGX_HW_PERF`).
- These three are in the **UM↔KM options check** (`include4/sgx_options.h`).
- With `CONFIG_SGX_ABI` off, the parameter-buffer `choice` has a *hidden prompt*
  (`opsgx:pvrsrvkm-7.2@2342ce92:drivers/gpu/drm/pvrsgx/Kconfig:97-110`). The Kconfig side
  of this change is the `letux/pvrsrvkm-v3` commit `7865ecbcc7b5` "pvrsgx: Add driver ABI
  configuration options" (2026-07-19). `b9b0a1cd50dc` is the matching 1.17-tree commit.
- **Mostly resolved by reading the code (2026-10-11), not by running kconfig.** In
  6.18.48 kconfig, a choice member's visibility comes from its own prompt
  (`scripts/kconfig/symbol.c:212-235`), and that prompt carries only the enclosing
  `if SGX && PVRSGX_1_17_4948957` dependency (`menu.c:310-318`). The choice prompt's
  `if SGX_ABI` does not reach the members. With no explicit `default`,
  `sym_choice_default()` returns the first visible member (`symbol.c:288-291`), so the
  choice should resolve to `SGX_PB_PER_CONTEXT` even with `SGX_ABI` off. Pinning the
  symbols explicitly (§9) is still the cheap guard against "Mismatch in client-side and
  KM driver build options". Confirm it once with `make olddefconfig` at the compile gate.

### 3.3 TI's own KM: `git.ti.com/graphics/omap5-sgx-ddk-linux`

- **The SGX540-120 target exists in TI's KM.** Branch `ti-img-sgx/1.17.4948957/k4.19`,
  last commit "km: Add build targets for sgx530-121 and sgx540-120 devices"
  (Andrew F. Davis, about 7 years ago per the cgit page). Branches continue at `k5.4`,
  `k5.10`, `k6.1`, and `1.17.4948957/mesa/k6.1`, whose last commit "compiler.mk: fix
  hardfloat toolchains not using suffix" is "19 months" old by the cgit page.
- **Kernel coverage stops at 6.12.**
  - meta-ti `ti-sgx-ddk-km_1.17.4948957.bb` bumped SRCREV `3005cf81…` → `f555b9e1…`
    "to allow this module to work on kernel 6.12" (Randolph Sapp, 2025-02-13, meta-ti
    list msg05600; GitHub commit `6c69db8d0d68`, 2025-02-14).
  - On meta-ti **wrynose/master** the `ti-6_18` BSP section (`8267e14677d0`,
    2025-12-19; default since `135dfe3f2620`, 2026-02-25) defines **no
    `BSP_SGX_DRIVER_PROVIDER`**, only Rogue. TI does not ship SGX on 6.18.
- **COMPATIBLE_MACHINE** is `ti33x|ti43x|am57xx|am65xx`. meta-ti never builds the OMAP4
  product, even though the KM source has it.
- **Constants.** TI's 1.17 KM (via the mobiaqua mirror) carries the canonical OMAP4
  values: `#elif (SGXCORE == 540) && (SGX_CORE_REV == 120) // OMAP44xx` →
  `SYS_SGX_CLOCK_SPEED 307200000`, `SYS_SGX_HWRECOVERY_TIMEOUT_FREQ (100)`, PDS timer
  1000 Hz (mobiaqua `services4/system/omap/sysconfig.h`).
- **Verdict.** Do not use TI's KM as the base: its build system is out-of-tree, it was
  last ported to 6.12, and nobody packages it for OMAP4. It is the **reference** for
  the option set and constants that TI's ti443x userspace was built against.

### 3.4 mobiaqua/sgx-pvr5-module

- Last push 2025-04-06; commit messages "synced with upstream" (TI) and "fixed
  compilation for kernel >= 6.8" (2024-04-01).
- Carries `eurasiacon/build/linux2/ti443x_linux/Makefile` with SGXCORE 540,
  SGX_CORE_REV 120, `SUPPORT_ACTIVE_POWER_MANAGEMENT := 0`, `PVR_NO_OMAP_TIMER := 1`,
  `SGX_DYNAMIC_TIMING_INFO := 1`, `SUPPORT_DRI_DRM := 1`, `SUPPORT_DMABUF := 1`,
  `PVRSRV_MODNAME := omapdrm_pvr_$(TARGET_PRODUCT)`.
- Its `module.c` matches `ti,omap4-sgx540-120` and `ti,omap4430-gpu`.
- A useful second reference for the TI option set. Not a base: out-of-tree, ≤6.12-era
  fixes, and the README is arm64/TI-SDK oriented.

### 3.5 postmarketOS (pmaports)

- **!1868** "PowerVR SGX Acceleration" (merged 2021-02-23; Jonathan Bakker):
  - `main/mesa-pvr-dri-classic` plus `non-free/sgx-ddk-um` (pkgver `1.17.494857`,
    TI `omap5-sgx-ddk-um-linux` snapshot `551665bf9c32…`)
  - subpackages per SoC, including **`sgx-ddk-um-ti443x`**
  - `depends="libc6-compat"`, so the glibc blobs run on musl through `dlsym`
  - a tiny `pvrsrvinit.c` that `dlopen("libsrv_init.so")` → `SrvInit()`
  - an OpenRC service that retries 6× / 5 s
- **#1316** "Embrace PowerVR or not?" (closed) led to **!3162** (merged 2022-05-27),
  which removed both packages. The quoted decision: "we've decided that we want to
  avoid adding the proprietary userspace components required to support pvr in pmOS".
  **!3027** removed PowerVR from samsung-espresso3g (OMAP4430).
- The espresso3g kernel had used the **whole openpvrsgx tree as its kernel source**:
  `$pkgname-$_commit.tar.gz::https://github.com/tmlind/linux_openpvrsgx/archive/$_commit.tar.gz`,
  pkgver 5.15.2, visible in the !3027 diff. This is a pmOS precedent for pinning an
  openpvrsgx GitHub archive in an APKBUILD.
- **Consequence:** nothing of this is in pmaports any more. We own the packaging
  completely, which our project already does for the kernel.

### 3.6 Field evidence of 1.17 on OMAP4 under mainline

- **hansemro/kc1-linux discussion #26** (Amazon Kindle Fire "otter", OMAP4430 SGX540;
  posts 2021-04-24…07-31):
  - openpvrsgx `letux-pvrsrvkm-5.12-rc2` / `-5.13-rc2`
  - `CONFIG_SGX=y CONFIG_SGX_DRM=y CONFIG_SGX_OMAP=m`
  - module `pvrsrvkm_omap4_sgx540_120`, DDK 1.17.4948957 on both sides
  - userspace `sgx-ddk-um-ti443x` + `mesa-pvr-dri-classic`
  - same SGXInitialise failure as #3, fixed by `-DPVR_LINUX_MEM_AREA_USE_VMAP`
  - then Weston and **kmscube at 59.99 fps**, "PowerVR SGX 540", EGL 1.4 / GLES 2.0
- openpvrsgx `84db121f1016` (2020-12-13, Tony Lindgren): enabled
  `SUPPORT_ACTIVE_POWER_MANAGEMENT` + `SYS_USING_INTERRUPTS` in the 1.17 KM and
  removed APM from the options bitmask, so the UM check passes. Message: "tested on
  droid4 with sway".
- Maemo Leste wiki "Motorola Droid 4/PowerVR" is marked out of date (last edit
  2020-02-17) and points to openpvrsgx.

---

## 4. DDK version decision

| DDK in openpvrsgx | Builds an OMAP4 SGX540 module in the 6.18-rc6 tree? | Matching non-Android SGX540-120 userspace? | Verdict |
|---|---|---|---|
| **1.17.4948957** | **Yes.** `pvr_drv=yes`, `ARCH_OMAP4` → `SOC=omap4 SGX=sgx540 SGX_REV=120 AM_VERSION=4` → `pvrsrvkm_omap4_sgx540_120.ko` (`opsgx:pvrsrvkm-6.18-rc6@d2f1e031:drivers/gpu/drm/pvrsgx/Makefile:92-96`) | **Yes.** TI `omap5-sgx-ddk-um-linux` target `ti443x` (pmaports !1868 `sgx-ddk-um-ti443x`) | **Use this** |
| 1.14.3699939 (omap2plus_defconfig default in the merge) | Yes (`pvr_drv=yes`) | No SGX540 UM known | no |
| 1.9.2188537 / 1.9.2253347 | **No.** `pvr_drv=no` path builds only `TI_PLATFORM=omap3/omap3630/ti335x` (Makefile:119-133). Kconfig help: "OMAP3530, AM3517" | Maemo `pvr-omap4` 1.9.x blobs | needs new OMAP4 enablement work, so no |
| 1.8.869593 | **No** (same `pvr_drv=no` path). Help text claims OMAP4 | — | no |
| stock 1.8@785978 | not in openpvrsgx | Android/bionic only (needs libhybris) | out of scope for a KM port |

The KM and UM DDK revision must be identical (stock string: "(FAIL) SGXInit:
Incompatible driver DDK revision"). Beyond that, the build-option bitmask must
match: in 1.17 `include4/sgx_options.h` that covers `DEBUG`, `PDUMP`,
`PVRSRV_USSE_EDM_STATUS_DEBUG`, `SUPPORT_HW_RECOVERY`, `PVR_SECURE_HANDLES`,
`SGX_BYPASS_SYSTEM_CACHE`, `SGX_DMS_AGE_ENABLE`, `SGX_FAST_DPM_INIT`,
`SGX_FEATURE_WRITEBACK_DCU`, `SGX_FEATURE_MP`, `SGX_FEATURE_SYSTEM_CACHE`,
`SGX_SUPPORT_HWPROFILING`, `SUPPORT_DISPLAYCONTROLLER_TILING`,
`SUPPORT_PERCONTEXT_PB`, `SUPPORT_SGX_HWPERF`, `SUPPORT_SGX_MMU_DUMMY_PAGE`,
`SUPPORT_SGX_PRIORITY_SCHEDULING` and `SUPPORT_SGX_LOW_LATENCY_SCHEDULING`. The
6.18-rc6 1.17 Makefile sets exactly the combination that the kc1 run proved against
the ti443x UM: `HW_RECOVERY`, `SECURE_HANDLES`, `PERCONTEXT_PB`, `SGX_HWPERF`,
`LOW_LATENCY_SCHEDULING`, release build.

---

## 5. SoC glue: stock vs mainline 6.18.48 vs what we must add

| Function | Stock 3.0.8 | Mainline 6.18.48 (all verified in the source) | Needed from us |
|---|---|---|---|
| Interconnect target / OCP sysconfig | hwmod "gpu" + `omap_device` | `sgx_module: target-module@56000000`, `ti,sysc-omap4`, rev @0x5600fe00, sysc @0x5600fe10, midle/sidle force/no/smart/smart-wkup (`6.18.48:arch/arm/boot/dts/ti/omap/omap4.dtsi:484-509`); ti-sysc quirk `SYSC_QUIRK("gpu", 0, 0xfe00, 0xfe10, -ENODEV, 0x40000000, 0xffffffff, 0)` (`6.18.48:drivers/bus/ti-sysc.c:1610`) | nothing |
| GPU device node / binding | platform device "pvrsrvkm" | `gpu@0 { compatible = "ti,omap4430-gpu", "img,powervr-sgx540"; reg = <0x0 0x2000000>; interrupts = <GIC_SPI 21 …>; }` (omap4.dtsi:504-508); binding `6.18.48:Documentation/devicetree/bindings/gpu/img,powervr-sgx.yaml` lists `ti,omap4430-gpu # Rev 120` | nothing. `pvr-drv.c` matches `ti,omap4430-gpu` (`opsgx:…/pvr-drv.c:363-365`) |
| Power domain | pwrdm "gfx" via omap_device | `power-domains = <&prm_gfx>`; `prm_gfx: prm@1200 { compatible = "ti,omap4-prm-inst", "ti,omap-prm-inst"; }` (omap4.dtsi:812-816); `omap4_prm_data` "gfx" @0x4a307200, `omap_prm_onoff_noauto`, **no reset lines** (`6.18.48:drivers/pmdomain/ti/omap_prm.c:196-198`) | nothing. openpvrsgx `omap-sysc-prm-gfx` adds `OF_DEV_AUXDATA("ti,omap4-prm-inst", …)`, but the existing `OF_DEV_AUXDATA("ti,omap-prm-inst", …)` (`6.18.48:arch/arm/mach-omap2/pdata-quirks.c:496`) already matches our node's second compatible |
| Functional clock enable | `omap_device_enable` | `clocks = <&l3_gfx_clkctrl OMAP4_GPU_CLKCTRL 0>` (clkctrl, `CLKF_SW_SUP`) (`6.18.48:drivers/clk/ti/clk-44xx.c:333-340`) | nothing |
| Clock source / rate | `gpu_fck` reparented to `dpll_per_m7x2_ck`; DVFS 153.6/307.2/384 | mux bit 24 parents `dpll_core_m7x2_ck`, `dpll_per_m7x2_ck` (clk-44xx.c:327-331). **Only `omap443x.dtsi:78-86`** assigns parent per_m7x2 @307.2 MHz; **`omap4460.dtsi` has no such block** (grep) | **add the `&sgx_module` assigned-clocks to our DTS** (§10) |
| Reset | — (no rstctrl for gfx on OMAP4) | none (omap_prm gfx entry has no `rstctrl`) | nothing |
| DVFS / VDD_CORE | `omap_device_scale` scales VDD_CORE 962→1127→1250 mV | no VDD_CORE scaling on OMAP4 mainline; `CONFIG_PM_DEVFREQ` is off in our defconfig (`repo:kernel/configs/steelhead_defconfig:4208`) | fixed 307.2 MHz in phase 1; optional devfreq 153.6↔307.2 at fixed voltage later |
| sgxfreq governors (TI Android) | stock has its own Google `sgx_idle` + `RequestSGXFreq` | n/a | not built in openpvrsgx for SGX540 (`CONFIG_OMAP_SGX_FREQ` not in Kconfig; `SYS_OMAP_HAS_DVFS_FRAMEWORK` is `ccflags-n`) |
| PM QoS latency | `omap_gpu_latency` | n/a | not needed |

**Today, without a driver**, ti-sysc idles the module and the GFX domain reaches OFF
under runtime PM. `repo:docs/2026-09-20-sleep-states-design.md:88` reads `gfx` in the
pwrdm mismatch list as "powered off by runtime PM … good news". Any driver we add must
keep this true whenever the GPU is not rendering (§11).

---

## 6. Build model

### 6.1 Options compared

| | **A. In-tree `=m` (recommended)** | B. Out-of-tree module aport | C. Built-in `=y` |
|---|---|---|---|
| zImage size | **unchanged.** The `obj-y += pvrsgx/` directory produces no built-in objects with `SGX_OMAP=m`, and `CONFIG_SGX` is a bool that only gates the subdir | unchanged | grows by the whole KM. Stock 1.8 PVR+OMAPLFB text runs from `AllocPagesAreaToPhys@c0272218` to `OMAPLFBDisableLFBEventNotification@c029b1b0`: 167 832 B raw, about **66 KB with LZMA -9e** (our `CONFIG_KERNEL_LZMA=y`, defconfig:43), or about 86 KB with zlib. That count leaves out rodata, data and init code, and 1.17 is a larger DDK. Headroom is **92 KB** (`repo:INSTALL.md:88-89`), so `=y` would use up most or all of it. **Very likely not viable** (UNVERIFIED until measured; the earlier "impossible" was overstated, because the headroom is compressed bytes and 164 KB is the raw text size) |
| vermagic / MODVERSIONS (`CONFIG_MODVERSIONS=y`, `repo:kernel/configs/steelhead_defconfig:695`) | built in the same tree, so CRCs and vermagic match by construction | must build against that exact kernel build (Module.symvers, generated headers). Our APKBUILD produces **no `-dev`/headers package** (`repo:pmos/linux-google-steelhead/APKBUILD:126-138`) | n/a |
| `LOCALVERSION=-r$pkgrel` (`APKBUILD:97-113`) | module lands in `/lib/modules/<rel>` of every build automatically | module apk must be rebuilt and versioned for **every** kernel pkgrel | n/a |
| Kernel OTA (`nq-kernel-ota stage-apk` copies **only** `$_tmp/lib/modules/$_rel` from the kernel apk, `nq-kernel-ota:398-415`) | GPU module travels with the kernel and rolls back with it | GPU module **missing** on every OTA-staged kernel until a second apk is installed. That breaks the "rollback carries its own modules" invariant from `docs/2026-08-18-kernel-ota-phase2.md` | n/a |
| Rootfs A/B (`nq-rootfs-ab`) | each slot's kernel apk carries its module | extra package to keep in sync per slot | n/a |
| `mm/vmalloc.c` export | needed by upstream code, removable by a driver patch (§8 b) | same; would still force a kernel rebuild anyway | same |
| Build time | +1 sub-build of ~153 k lines (the pvrsgx Makefile always rebuilds: "always rebuilds even if nothing has changed", Makefile:10-11). Cross-native, so small | separate | — |

### 6.2 How to bring the source into the aport (do not make a frozen copy)

Petr's global rule forbids a frozen local copy of an upstream component unless it
comes with an update path. Recommended layout:

1. Add `source=` entry
   `linux_openpvrsgx-<sha>.tar.gz::https://github.com/openpvrsgx-devgroup/linux_openpvrsgx/archive/<sha>.tar.gz`,
   pinned by sha512 in the APKBUILD, same precedent as pmaports' espresso3g (§3.5).
   - **UNVERIFIED:** size ≈ a full kernel tree (~230-260 MB gz). pmbootstrap caches
     distfiles, so the cost is paid once per pin.
   - Alternative: a deterministic, script-generated `pvrsgx-<sha>.tar.xz` holding only
     `drivers/gpu/drm/pvrsgx/{Kconfig,Makefile,pvr-drv.[ch],1.17.4948957/}` (≈6.0 MB
     raw, 358 files), published as a release asset. Smaller, but it adds a mirror we
     must keep honest.
2. `prepare()`: before `default_prepare`, copy only `drivers/gpu/drm/pvrsgx/{Kconfig,
   Makefile, pvr-drv.c, pvr-drv.h, 1.17.4948957/}` from `$srcdir/linux_openpvrsgx-<sha>`
   into `$builddir/drivers/gpu/drm/pvrsgx/`. Ordering matters: our pvrsgx patches
   touch these files, so they must exist before `default_prepare` applies the
   patches.
3. Add our delta as normal flat `kernel/patches/00NN-drm-pvrsgx-*.patch` files.
   - Flat names keep `docker-build.sh:123/289`, `scripts/build-kernel-boot.sh:54` and
     `tests/test_aports.py:40-48` working, because they glob `kernel/patches/*.patch`.
   - They must apply with **GNU `patch`** (project rule, memory
     `patches-must-apply-with-gnu-patch`).
   - Also add the 2-line hook into `drivers/gpu/drm/{Kconfig,Makefile}` (§8 h).
4. **Update path:** a `scripts/pvrsgx-bump.sh <branch|sha>`. It resolves the upstream
   head, rewrites `_pvrsgx_commit`, runs `pmbootstrap checksum`, and re-applies our
   patches with GNU patch on a pristine extract. A conflict fails loudly. The base
   commit stays tracked in git (the APKBUILD variable).

---

## 7. Kernel API breaks between the driver's history and 6.18.48 (verified)

All rows are checked against real trees, not memory. Columns:

- *Fixed in openpvrsgx by*: the upstream commit that already handles the break
  (1.17 or common).
- *Verified how*: the tree comparison done here.

| Kernel | Change | Fixed in openpvrsgx by | Verified how |
|---|---|---|---|
| 5.8 | `__vmalloc()` lost its `pgprot` argument; the module needs a private wrapper over `__vmalloc_node_range` | `47ba2d0e4f43` / `a5559de3ed05` (adds `EXPORT_SYMBOL` in **core** mm) | `6.18.48:mm/vmalloc.c` exports `__vmalloc_noprof` (:4007) and `__vmalloc_node_noprof` (GPL, :3999) but **not** `__vmalloc_node_range_noprof` (:3849); the merge diff adds exactly that export |
| 5.16 / 6.13 | `MODULE_IMPORT_NS(DMA_BUF)` → string literal `MODULE_IMPORT_NS("DMA_BUF")` | `8bc7477adf07`, `3eb4b62bd9ee` | 6.12.12 uses `MODULE_INFO(import_ns, __stringify(ns))`, 6.18.48 `MODULE_INFO(import_ns, ns)` (`include/linux/module.h:307`) |
| 6.0 | `arm_dma_ops` no longer reachable; cache maintenance via `dma_sync_single_*` | `0e4610be9830` | ARM path `pvr_flush_range()` uses `dma_sync_single_for_{device,cpu}` (osfunc.c). Needed ARM exports present: `__cpuc_flush_kern_all`, `cpu_cache` (`6.18.48:arch/arm/mm/proc-syms.c:25,31`), `outer_cache` (`arch/arm/kernel/setup.c:126`) |
| 6.2 | `dma_buf_map_attachment()` requires the resv lock (`dma_resv_assert_held`) | **not fixed** (driver still calls the locked variant without the lock, `dmabuf.c:186`) | `6.18.48:drivers/dma-buf/dma-buf.c:1113` asserts; `dma_buf_map_attachment_unlocked()` exists (`include/linux/dma-buf.h:598`). Silent without lockdep (`CONFIG_PROVE_LOCKING` off), but wrong: **our patch §8 e** |
| 6.3 | `vma->vm_flags` read-only; `vm_flags_set()` | `7e4ef04bcbdd` | `6.18.48:include/linux/mm.h:871` |
| 6.5 | `get_user_pages()` lost `vmas` | `b4d95bec50b3` | `6.18.48:include/linux/mm.h:2715` |
| 6.5/6.6 | `__pte_offset_map_lock` not exported; `follow_pte` | `7324d6be38ae` | (superseded below) |
| 6.6 | `drm_driver.prime_handle_to_fd/fd_to_handle/gem_prime_mmap` removed | `6ab2e006ac95` | — |
| 6.8 | `drm_legacy_mmap` / `<drm/drm_legacy.h>` removed; `DRM_LEGACY` gone | `93cf687fded3` makes `drm_mmap()` return `-EINVAL` ("may need real fix") | `config DRM_LEGACY` absent in both 6.12.12 and 6.18.48. `SGX_DRM` still `select`s it (Kconfig:66-72), see **§8 g** |
| 6.9 | out-of-tree Makefile changes | `015669fcb7bf` | — |
| 6.10 | `_noprof` allocator names | `cc3cc247135b` | 6.18.48 symbol names as above |
| 6.11 / 6.13 | `platform_driver.remove` returns `void` (6.11); the transitional `remove_new` member was dropped later, so it is still present in 6.12.12 (`platform_device.h:246`) | `db0be6bcea49` | 6.18.48 only has `void (*remove)` (`include/linux/platform_device.h:233`) |
| 6.12 | `FMODE_UNSIGNED_OFFSET` → `.fop_flags = FOP_UNSIGNED_OFFSET` | `8ac3728be62d`, `9bb839326c21` | `6.18.48:include/linux/fs.h:2328`; `pvr-drv.c:195` |
| 6.12 | `follow_pfn()` removed → `follow_pfnmap_start/end` | `f64a012f3c93` | `6.18.48:include/linux/mm.h:2611`; osfunc.c:3558-3577 |
| 6.14 | `drm_driver.date` removed | `77ea0f693e97` (1.17), `c05771b38e3b` (pvr-drv; this hash was misprinted as `c05071b38e3b` before verification) | 6.12.12 `drm_drv.h:387 char *date;`; absent in 6.18.48 |
| 6.15 | `del_timer_sync()` → `timer_delete_sync()` | `cd5e751ffd9b` | 6.12.12 has `del_timer_sync`, 6.18.48 only `timer_delete_sync` (`include/linux/timer.h:166`) |
| 6.16 | `from_timer()` → `timer_container_of()` | `399fdecf821e` | 6.12.12 has `from_timer`; 6.18.48 `timer.h:132 timer_container_of` |
| 6.17 | `pfn_t` / `<linux/pfn_t.h>` removed; `vmf_insert_mixed(…, unsigned long pfn)` | `8ac9af1053ab` ("hack to restore compile of pfn_t": local typedef + wrapper, `mmap.h:61-75`) | 6.12.12 has `pfn_t.h` and `vmf_insert_mixed(..., pfn_t)`; 6.18.48 neither (`mm.h:3802`) |
| 6.19 | `in_irq()` removed | `4ec821a3f175` (only on -v3) | `in_irq` still in 6.18.48 (`include/linux/preempt.h:141`), so not needed for us |
| 6.18-rc6 → 6.18.48 | header deltas in `mm.h` (`VM_MAYBE_GUARD`), `vmalloc.h`, `fs.h`, `dma-mapping.h`, `highmem.h` (`tag_clear_highpages`), `uaccess.h` (`…_inatomic_nontemporal`), `platform_device.h` (`driver_override` moved) | — | diffed 23 headers `opsgx:b618` vs 6.18.48; **none of the changed identifiers are used** by `pvrsgx/1.17` or `pvr-drv.c` (grep). `dma-buf.h`, `timer.h`, `drm_drv.h`, `drm_file.h`, `drm_ioctl.h`, `pm_runtime.h`, `dma-resv.h`, `dma-fence.h`: byte-identical |

The kernel's own warning-to-error flags (`6.18.48:scripts/Makefile.extrawarn:13-16,97,100,103`)
are `-Werror=implicit-function-declaration`, `implicit-int`, `return-type`,
`strict-prototypes`, `date-time`, `incompatible-pointer-types` and `designated-init`.
The 1.17 sources contain no `__DATE__`/`__TIME__` and no `()` prototypes in the
services/system/include dirs (grep). `PVR_BUILD_DATE` is a `$(shell date)` macro,
which `-Werror=date-time` does not catch. Our `CONFIG_WERROR` is off
(`steelhead_defconfig:33`).

**Not covered by any upstream compile-test (UNVERIFIED):**

- The **1.17 OMAP** variant under **Alpine GCC 15.2**. The merge branch's
  `omap2plus_defconfig` selects **1.14.3699939**, not 1.17
  (`opsgx:b618:arch/arm/configs/omap2plus_defconfig:507-510`). The maintainer's
  routine OMAP compile therefore exercises 1.14.
- The Cedarview contributors and the kc1 run exercised 1.17 on other compilers and
  kernels.

---

## 8. Driver delta we must carry (each a separate patch, each offered upstream)

**a. `-DPVR_LINUX_MEM_AREA_USE_VMAP` for the OMAP SGX540 build.**
- Evidence: openpvrsgx #3, kc1 #26. Without it the µKernel never came up
  (`PollForValueKM: Timeout`) on the 2021 trees, which lacked the pgprot fix of
  2021-07-30. The as-published tree no longer needs it; it is now the precondition
  for (b), not a fix on its own (Addendum "Maemo 6.18.51.1", A.3). The flag is absent from both the 6.18-rc6 and the 7.2
  1.17 Makefile.
- Scope it to `SOC_FAMILY=omap`, or to `SGX540`, or make it unconditional. Upstream
  DDKs `generic/` and `1.9.2204701-iq451` default it on (`core.mk:596
  PVR_LINUX_MEM_AREA_USE_VMAP ?= 1`, `config_kernel_user.h:15`).

**b. Drop the dependency on `EXPORT_SYMBOL(__vmalloc_node_range_noprof)`.**
- With (a), the only `VMallocWrapper()` caller is `OSAllocMem_Impl()` with
  `PVRSRV_HAP_CACHED` (`osfunc.c:156-161`). `AllocFlagsToPGProt()` maps that to
  `PAGE_KERNEL` (`mm.c:487-490`).
- Change `_VMallocWrapper()`:
  - `PAGE_KERNEL` → `__vmalloc(size, gfp)`, which is exported.
  - Any non-cached request → fail loudly, or route through `VMapWrapper()`
    (alloc_pages + `vmap(…, prot)`; `vmap` is exported, `6.18.48:mm/vmalloc.c:3563`).
- Result: no core-mm patch in our series. This is the root-cause fix: a driver must
  not need a private allocator export.
- **Statically verified 2026-10-11.** `__old_vmalloc_node` has exactly one caller,
  `_VMallocWrapper` (`mm.c:535`). `_VMallocWrapper` is called from `OSAllocMem_Impl`
  (`osfunc.c:158,160`, always `PVRSRV_HAP_CACHED`) and from `NewVMallocLinuxMemArea`
  (`mm.c:1115`). That second call sits in the `#else` branch of
  `PVR_LINUX_MEM_AREA_USE_VMAP` (`mm.c:1105-1125`), which uses `VMapWrapper` instead.
  The wrapper is still *compiled*, though, so `modpost` will report the unexported
  symbol until the wrapper is changed. The compile gate (§12 step 1) shows that.

**c. OMAP4 sysconfig header.**
- Today `AM_VERSION=4` makes OMAP4 include `sysconfig-am4.h` ("TI437x"):
  `SYS_SGX_CLOCK_SPEED 200000000`, `HWRECOVERY 50 Hz`, APM latency 2 ms
  (`opsgx:…/services4/system/omap/sysconfig.h:45-55`, `sysconfig-am4.h:66-75`).
- Add a `sysconfig-omap4.h`, selected for `SGX540 && SGX_CORE_REV==120`, with:
  - `SYS_SGX_CLOCK_SPEED 307200000`: TI KM value (mobiaqua `sysconfig.h` "OMAP44xx"),
    mainline 443x DT, stock OPP100
  - `SYS_SGX_HWRECOVERY_TIMEOUT_FREQ 100`: TI KM and stock `SysGetSGXTimingInformation`
  - `SYS_SGX_PDS_TIMER_FREQ 1000`
  - `SYS_SGX_ACTIVE_POWER_LATENCY_MS 100`: stock `sgx_apm_latency`; TI default 2
- Why it matters: the core clock value calibrates the µKernel timer
  (`sgxpower.c:156-157 ui32uKernelTimerClock = CoreClockSpeed / uKernelFreq`). At
  200 MHz declared and 307.2 MHz actual, the "1 ms" PDS tick is 0.65 ms.
- Stock-parity fix; keep it even if nothing visibly breaks (project rule "keep
  stock-matching fixes").

**d. Balance runtime PM in `pvr_probe()`.**
- `pvr_probe()` calls `pm_runtime_get_sync()` and never puts on success
  (`opsgx:…/pvr-drv.c:439-445` vs `:461-466`). The DDK's own
  `EnableSGXClocks`/`DisableSGXClocks` get/put on top of it
  (`sysutils_linux.c:214,260-261`).
- Net effect: usage count never reaches 0 while the module is loaded, so the GFX
  domain stays ON and the GPU fck stays enabled. **UNVERIFIED on hardware**; it
  follows directly from the code. The only runtime-PM calls in the 1.17 OMAP path are
  `pvr-drv.c:440-443,476-477,488-489` and `sysutils_linux.c:214,260-261` (grep), and
  `pvr-drv.c` has had this probe shape since 2019.
  - **Contradicting evidence:** the message of `84db121f1016` (Tony Lindgren,
    2020-12-13) says the change exists "to gate the sgx clock on screen blank" and was
    "tested on droid4". Either that run had a pvr-drv without the probe-time
    reference, or the gating seen there came from another path. Do not treat this
    item as settled until the `gfx` pwrdm is read on hardware with the module loaded.
    *Resolved 2026-10-11 [pm Addendum APM]:* the 2020 run had the probe-time reference
    (`0ed3c444d68c` pvr-drv.c:322), so it cannot have reached genpd OFF. Lindgren fixed
    the probe later in Maemo `2cd8d74ec61a` (2023-11-14, autosuspend 2000 ms), which
    is this item's fix already written.
- Fix: `pm_runtime_use_autosuspend()` + `pm_runtime_set_autosuspend_delay(100 ms)` +
  `pm_runtime_put_autosuspend()` after `drm_dev_register()`.
- Fix the error and remove paths too: `pvr_remove()` calls `drm_put_dev()` *before*
  `pvr_drm_unload()` and dereferences the freed device afterwards (`pvr-drv.c:483-489`).
  Use `drm_dev_unregister()`, then unload, then `drm_dev_put()`.
- Verification: read the `gfx` pwrdm state and the GPU clkctrl idle state with the
  module loaded and nothing rendering, the same method as
  `docs/2026-09-20-sleep-states-design.md`.

**e. `dma_buf_map_attachment_unlocked()` / `dma_buf_unmap_attachment_unlocked()`** in
`dmabuf.c` (186 and the unmap site). This fixes the locking contract added in 6.2.

**f. Build only the SGX540-120 module.**
- Under `ARCH_OMAP4` the Makefile builds `omap4430/60` *and* `omap4470` (SGX544-112)
  in the same object dir, one after the other (Makefile:92-100). 6.18 has no
  `SOC_OMAP4470` Kconfig symbol.
- Add a Kconfig bool `SGX_OMAP4470` (default n) and gate the second run on it. This
  halves build time and stops shipping a dead `pvrsrvkm_omap4_sgx544_112.ko`.

**g. Remove `select DRM_LEGACY`** from `SGX_DRM` (Kconfig:69). The symbol has not
existed since before 6.12 (verified absent in both trees). **UNVERIFIED** whether
kconfig warns about it. Either way it is dead text.

**h. Hook.** `source "drivers/gpu/drm/pvrsgx/Kconfig"` and `obj-y += pvrsgx/` in
`drivers/gpu/drm/{Kconfig,Makefile}`. That is exactly the merge diff, without the
`DRM_INTEL_CDV` line.

**i. Cherry-picks from `-v3`** when basing on 6.18-rc6: `ff422e4ab0bb` (uninitialised
fence count), optionally the `strscpy` series.

**k. Preemption model (kernel config, not a driver patch; mandatory).**
- `osfunc.c:126-135` stops the build with `#error` unless `CONFIG_PREEMPTION` or
  `CONFIG_PREEMPT_VOLUNTARY` is set, because `PVR_LINUX_USING_WORKQUEUES` is always
  defined for OMAP (`1.17.4948957/eurasia_km/Makefile:124,238`; the same in the 7.2
  tree, Makefile:124,247). Our defconfig is `PREEMPT_NONE`
  (`steelhead_defconfig:99-102`).
- The source comment gives IMG's generic reason: Services spins waiting for events
  that workqueues deliver, so the waiting thread must be preemptible. *Refined
  2026-10-11 (Addendum B.2):* a code read of the OMAP build found no busy-wait that
  waits on a workqueue; every such wait sleeps. The guard is a blanket rule, not a
  traced deadlock. Patching out the `#error` still masks it; do not.
- Choices:
  - `CONFIG_PREEMPT_VOLUNTARY=y` is upstream's choice (`0affbb5a7b95`). It satisfies
    the guard, but whether voluntary preemption actually prevents the described
    spin-wait livelock is **UNVERIFIED**. *Answered 2026-10-11 (Addendum B.2-B.3):*
    it adds no scheduling point to any DDK busy-wait (`udelay`, test-and-set and
    plain loads never reach `might_sleep()`), so for the DDK it behaves exactly
    like `PREEMPT_NONE`.
  - `CONFIG_PREEMPT=y` is stock parity (`3.0.8 … #1 SMP PREEMPT`) and the kc1 config.
    It also adds `preempt` to the module vermagic.
- Either is a kernel-wide change. Run the full diag sweep plus an audio and latency
  regression after it, independently of the GPU work, and record the choice in a dated
  `docs/` note.

**j. Review item, no patch yet.** `drm_mmap()` returns `-EINVAL` since 6.8
(`93cf687fded3`, "may need real fix"). Find out whether `PVRMMap()` ever falls through
to it for our UM. If it does, implement the mapping properly; do not paper over it.

---

## 9. Kconfig / defconfig fragment

Already present and sufficient:

- `CONFIG_DRM=y` (2830), `CONFIG_DRM_OMAP=y` (2869)
- `CONFIG_DMA_SHARED_BUFFER=y` (1425); required, `dmabuf.c` uses `dma_buf_*`
- `CONFIG_SYNC_FILE=y` (4005); not needed by the KM, but harmless
- `CONFIG_CMA=y` / `DMA_CMA=y` with 16 MB (821, 5524-5530). Neither the KM nor omapdrm
  scanout needs CMA here: the KM uses CMA only with a `memory-region`, and omapdrm
  uses DMM/TILER because `dmm@0 { compatible = "ti,omap4-dmm" }` is present
  (`6.18.48:omap4.dtsi:298-302`; `omap_gem.c:1308-1313`)
- `CONFIG_ARCH_OMAP4=y`, OMAP3/OMAP5/AM33/AM43/DRA7 off (317-323)
- `CONFIG_PM=y`, `PM_SLEEP=y`, `CONFIG_SMP=y`, `CONFIG_HIGHMEM=y`,
  `CONFIG_VMSPLIT_3G=y`, `CONFIG_OUTER_CACHE=y`, `CONFIG_CACHE_L2X0=y`
- `CONFIG_MODVERSIONS=y`, `CONFIG_MODULE_SIG` off, `CONFIG_FORTIFY_SOURCE` off,
  `CONFIG_WERROR` off

Add (base = 6.18-rc6 tree):

```
# mandatory, see §8 k; replaces CONFIG_PREEMPT_NONE=y (steelhead_defconfig:99-102)
CONFIG_PREEMPT=y                          # or CONFIG_PREEMPT_VOLUNTARY=y (upstream omap2plus choice)
CONFIG_SGX=y
CONFIG_PVRSGX_1_17_4948957=y
# CONFIG_SGX_DEBUG is not set
CONFIG_SGX_DRM=y
CONFIG_SGX_OMAP=m
# CONFIG_SGX_GENERIC is not set
# CONFIG_SGX_OMAP4470 is not set        # our patch §8 f
```

If the base is the `-v3`/`-v4` tree, pin the ABI-relevant symbols explicitly so the UM
options check cannot drift (§3.2):

```
CONFIG_SGX_ABI=y
CONFIG_PVRSGX_1_17_4948957_ABI=y
CONFIG_SGX_PB_PER_CONTEXT=y
CONFIG_SGX_HW_PERF=y
CONFIG_SGX_HW_RECOVERY=y
# CONFIG_SGX_PDUMP is not set
# CONFIG_SGX_HW_PROFILING is not set
# CONFIG_SGX_USSE_EDM_STATUS_DEBUG is not set
CONFIG_SGX_IOCTL_ALIAS=0                 # only used by pvr_drm.c (Intel path); set so the int has a value
```

Later, phase 2 only: `CONFIG_PM_DEVFREQ=y`, `CONFIG_DEVFREQ_GOV_SIMPLE_ONDEMAND=y`.

---

## 10. Device-tree change (steelhead)

```dts
/*
 * SGX540 from DPLL_PER M7 at 307.2 MHz (OPP100). Stock steelhead 3.0.8 reparents
 * gpu_fck to dpll_per_m7x2_ck and scales 153.6/307.2/384 MHz with VDD_CORE
 * 962/1127/1250 mV (omap446x_opp_def_list); mainline does not scale VDD_CORE, so
 * hold the OPP100 rate. Same block mainline uses for 4430 (omap443x.dtsi).
 */
&sgx_module {
	assigned-clocks = <&l3_gfx_clkctrl OMAP4_GPU_CLKCTRL 24>,
			  <&dpll_per_m7x2_ck>;
	assigned-clock-rates = <0>, <307200000>;
	assigned-clock-parents = <&dpll_per_m7x2_ck>;
};
```

- dpll_per_x2 = 1536 MHz (`repo:docs/2026-06-19-boot-warnings-followup.md:149-150`),
  so M7 /5 = 307.2 MHz.
- `dpll_per_m7x2_ck` is a plain `ti,divider-clock` (`omap44xx-clocks.dtsi:734-744`),
  so `set_rate` works. Our patch 0007 (composite dividers) is not involved.
- The M3 output (ABE/TAS5713 MCLK, patch 0042) is an independent divider.
- History:
  - Tony Lindgren set 4430 to 153.6 MHz in 2020 ("Fix sgx clock rate for 4430":
    droid4/duovero hangs, "thermal issues … memory corruption").
  - Carl Philipp Klemm moved it back to 307.2 MHz in 2021 ("as used on motorola vendor
    kernel"), applied for v5.12 (lkml/lab.nexedi.cn links in Sources).
  - Neither touched 4460.
- Put it in its own patch, as the project already does for DT changes (0040/0042/0043/
  0057), or in `kernel/dts/omap4-steelhead.dts` followed by `scripts/regen-dts-patch.sh`.

---

## 11. Power and PM considerations (Petr cares about these)

- **Requirement:** module loaded but GPU idle ⇒ GFX pwrdm OFF, GPU fck gated, CORE
  deep idle unaffected. §8 d is the precondition. Also add a check to the diag sweep
  (`scripts/diag`): GPU module state, `clk_summary` rate for the GPU fck, `gfx` pwrdm
  state, `PVR_K:(Error)` count in dmesg.
- **APM.** openpvrsgx enables `SUPPORT_ACTIVE_POWER_MANAGEMENT` in the KM but hides it
  from the UM options check (`84db121f1016`). TI's ti443x product sets
  `SUPPORT_ACTIVE_POWER_MANAGEMENT := 0` for its own KM, so with this split the UM
  never learns about it. Expect APM power-down after `SYS_SGX_ACTIVE_POWER_LATENCY_MS`
  of idle. 100 ms matches stock; 2 ms is TI's default. (*Corrected 2026-10-11 [pm
  Addendum APM]:* only if the `ti443x` microkernel raises the active-power request,
  which the KM cannot do itself. That is UNVERIFIED. Otherwise GFX stays ON after
  `SGXInit`, and the fix is (h), a host-side idle power-down.)
- **Autoload.** The `MODULE_DEVICE_TABLE(of)` match means udev loads the module at
  boot. Allow that only after §8 d is proven. Until then, blacklist it and let the GPU
  session service `modprobe` it, so a headless unit pays nothing.
- **DVFS phase 2** (optional): a devfreq driver hooked into `SysSGXIdleTransition` /
  `SGXPreClockSpeedChange`/`SGXPostClockSpeedChange` (both exist in the DDK; stock
  uses them), with OPPs 153.6/307.2 at a fixed VDD_CORE.
  - Gain: only the dynamic-power share, since voltage does not change.
  - 384 MHz stays out until VDD_CORE scaling exists and is proven safe.
- **Thermal.** The 2020 4430 note links SGX at 307.2 MHz to "thermal issues that seem
  to be related to memory corruption" on 4430. Our idle temperature is already
  72-75 °C (`repo:docs/2026-07-15-…md:192`). Add a thermal check to the bring-up
  sweep (bandgap, under a bounded `timeout`+`nice` kmscube run).

---

## 12. Step-by-step port plan with effort

Hours are for the agent+Petr working pattern of this project. "Gate" is the evidence
needed to move on.

| # | Step | Detail | Effort | Gate |
|---|---|---|---|---|
| 0 | Approvals | Petr OKs: (1) DDK 1.17.4948957 + TI ti443x UM (proprietary blobs in the image, so check `PUBLIC_RELEASE=1` and `scripts/release-preflight-no-secrets.sh` implications); (2) pinning an upstream openpvrsgx archive with a bump script (§6.2); (3) offering patches upstream later | 0.5 h | decision recorded in a dated `docs/` note |
| 1 | **Compile gate (host, no device)** | In the kstack tree (`~/nexusq-build/kstack/linux` on the build machine; **not present on host `omarchy`**): apply our 44+ patches on pristine 6.18.48 → copy `pvrsgx/{Kconfig,Makefile,pvr-drv.*,1.17.4948957}` from `pvrsrvkm-6.18-rc6@d2f1e031d58a` → hook (§8 h) → defconfig fragment (§9) **including the preemption change (§8 k), without which `osfunc.c` hits `#error`** → `make modules` with arm-gnu-13.3 (fast filter, ~2 min per project memory), then the real Alpine GCC 15.2 cross-native build | 2-4 h, **+0-8 h** if GCC 15 raises new errors in DDK code | `pvrsrvkm_omap4_sgx540_120.ko` links; `modpost` lists **no** undefined symbols (proves §8 b is needed, then that it fixed it); `modinfo` alias `of:N*T*Cti,omap4430-gpu*` |
| 2 | Driver delta patches §8 a-g, i (plus the §8 k config) | write, GNU-`patch` verify, recompile | 4-8 h | clean compile; `vermagic` = `6.18.48-r<N> SMP mod_unload modversions ARMv7 p2v8` with `PREEMPT_VOLUNTARY`, or `6.18.48-r<N> SMP preempt mod_unload modversions ARMv7 p2v8` with `PREEMPT` (`modversions` because `CONFIG_MODVERSIONS=y`; Maemo's shipped module reads `6.18.51 SMP preempt mod_unload modversions ARMv6 p2v8`, Addendum A.2; the `ARMv7` token is UNVERIFIED, read it from any in-tree `.ko` of the same build) |
| 3 | DTS clock patch §10 | new patch or DTS + regen 0003 | 0.5-1 h | DTB contains the `assigned-clocks` on `target-module@56000000` (`fdtget`) |
| 4 | Aport integration | `source=` archive + sha512; `prepare()` copy-before-patch; `pkgrel` bump; `scripts/pvrsgx-bump.sh`; `tests/test_aports.py` stays green; CHANGELOG entry naming the revision | 3-5 h | `just check` green; a seen-failing test for the bump script (rule "a test must be seen failing") <!-- docs-check: ignore --> |
| 5 | Kernel-only build | via the `nexusq-build` agent (`scripts/build-kernel-boot.sh` in the builder container) | 0.5 h + build | staged image size within the ~6656 KB caution (expected unchanged vs r20; `=m`); `.ko` present under `/lib/modules/<rel>/kernel/drivers/gpu/drm/pvrsgx/…` in the apk |
| 6 | Device probe without userspace | trial-slot OTA (`nq-kernel-ota stage-apk` + `try`), then `hostname` first, then `modprobe pvrsrvkm_omap4_sgx540_120` | 2-3 h | dmesg `pvrsrvkm 56000000.gpu: Enabling quirks 00000001` + `[drm] Initialized pvr 1.17.4948957 for 56000000.gpu on minor 1` (6.18 prints no date: `drivers/gpu/drm/drm_drv.c:1104` is `"Initialized %s %d.%d.%d for %s on minor %d"`. The `20110701` in the 2021 logs comes from pre-6.14 kernels); `/dev/dri/card1` + `renderD129` (omapdrm keeps card0/renderD128: `DRIVER_RENDER` set, `omap_drv.c:637-638`); GPU fck 307 200 000 in `clk_summary`; **gfx pwrdm OFF when idle** (§8 d); full diag sweep incl. CPU freq + VDD_MPU (project rule) clean, **0 new dmesg errors** |
| 7 | Hand-off to the userspace workstream | `pvrsrvinit` (`SrvInit` via `dlopen`) → `UM DDK-(4948957) and KM DDK-(4948957) match` → SGXInit options check → kmscube | kernel-side debug budget **4-16 h** (history: VMAP; options bitmask; HW-recovery triggers) | `SGXInit` OK, no `PVR_K:(Error)`, kmscube steady 60 fps on HDMI 720p, bounded test (`timeout`, `nice`) |
| 8 | PM hardening | autosuspend delay tuning, autoload decision, diag-sweep GPU section, idle power A/B vs a kernel without the module | 3-6 h | idle power and deep-idle counters unchanged vs baseline |
| 9 | (optional) devfreq 153.6/307.2 | OPP table on the GPU node, DDK clock-change hooks | 8-16 h | rate follows load, no SGX lockups over a soak |
| 10 | Upstream | send §8 a-g to openpvrsgx (issue/PR; **ask Petr before posting**) | 2-4 h | PRs linked from the dated doc |

**Core path (steps 0-6, 8): ~16-35 h. Total including the step-7 kernel budget: ~20-50 h.**

Process rules from AGENTS.md / CLAUDE.md that apply:

- `fleet-safety-reviewer` before committing anything under `kernel/` or `pmos/`.
- `nexusq-docs` after success or a notable failure.
- `stock-parity-auditor` for §8 c / §10.
- The fix is "done" only when it is in the APKBUILD with a pkgrel bump and has passed
  a full diag sweep on hardware.

---

## 13. Corrections to `docs/2026-06-19-gpu-sgx540-acceleration-research.md`

| June note says | Correct as of 2026-10-11 |
|---|---|
| "actively rebased onto ~6.15 mainline" | rebased through **7.2** (`pvrsrvkm-7.2@2342ce92fdde`, 2026-08-26); there is a **`pvrsrvkm-6.18-rc6`** merge matching our kernel generation |
| backport shims from 6.15 down to 6.12 | we are on **6.18.48**; the shims point the other way and are already in the tree |
| `omap-pvr-soc-glue-v10` is "the OMAP-specific reset/clock/PRM wiring" | for OMAP4 it adds **nothing**: mainline 6.18.48 already has the target module, gpu node, prm_gfx, clkctrl and binding (§5). Only the 4460 clock assignment is missing |
| "SGX firmware blob (`sgx540_*.fw`) must ship alongside the module" | no firmware file: the µKernel is uploaded by userspace `libsrv_init`/`pvrsrvinit` (no `request_firmware` in the KM; `SetupuKernel` strings in `libsrv_init.so`) |
| milestone "`/dev/pvrsrvkm` appears, `pvrsrvctl` starts" | 1.17 with `pvr-drv.c` is a **DRM render driver**: `/dev/dri/card1` + `renderD129`, name "pvr"; init tool is `pvrsrvinit` (pmOS shim) |
| "OMAP4460 … double-check GFX DPLL … 4460 clocks the SGX higher" | stock 4460 GPU OPPs are 153.6/307.2/**384** MHz, with 384 needing VDD_CORE 1.25 V; mainline 4460 DT sets no SGX clock at all; we pin 307.2 |
| "DDK 1.9.2188537 is the canonical OMAP4 SGX540 userspace" / "pick 1.17 or 1.9" | openpvrsgx 1.9.x and 1.8.x **do not build an OMAP4 module**; the stock Nexus Q DDK is **1.8@785978**; **1.17 is the only practical match** (§4) |
| "≤6.5 MB boot-image kernel ceiling" | ~6656 KB U-Boot caution / 8192 KB partition; staged-image headroom **92 KB** at v1.17.0 (`repo:INSTALL.md:85-91`) |

---

## Open questions

1. **Live VDD_CORE on the unit.** It decides whether 307.2 MHz has margin (needs
   ≥1.127 V) and whether 384 MHz could ever be considered (needs 1.25 V). Read the
   TWL6030 VCORE1 vsel and the VC/VP state read-only. Nothing in `scripts/diag` reads
   it today (grep).
2. **Current GPU clock parent and rate on our 4460** with no `assigned-clocks`.
   Readable from `/sys/kernel/debug/clk/clk_summary` on the unit (read-only).
3. Does the **`-v4`** 1.17 branch, or **`letux-6.18.y`** on git.goldelico.com, contain
   OMAP-relevant fixes newer than `-v3`? Neither is readable (dumb HTTP, no gitweb).
   Ask the maintainer (H. N. Schaller) or fetch the full pack once.
   *Answered 2026-10-11 [Addendum C]:* no. `-v4` is `-v3` unchanged plus three warning
   fixes; `letux-6.18.y` carries the rc6 1.17 tree byte for byte.
4. In `-v3`+, does a `choice` with a hidden prompt still default to
   `SGX_PB_PER_CONTEXT`? *Mostly answered by reading the code (§3.2): yes, by the
   6.18.48 kconfig rules.* Confirm once with `olddefconfig` at the compile gate.
4a. **Preemption model (§8 k):** `PREEMPT_VOLUNTARY` (upstream) or `PREEMPT` (stock
   parity)? Which one is enough for the DDK's spin-wait-on-workqueue paths, and what
   does each do to audio XRUNs and idle power on this 2-core unit?
   *Code half answered 2026-10-11 (Addendum B):* VOLUNTARY behaves like NONE for the
   DDK; no wait was found that needs either. The size, audio and idle halves are
   still open (B.5, B.8).
5. Does `PVRMMap()` ever fall through to the stubbed `drm_mmap()` (`-EINVAL` since 6.8)
   with the TI ti443x UM?
6. GCC 15.2 permerror and warning fallout on 150 k lines of 2012-era DDK C. Unknown
   until step 1.
7. The project's armv7 GCC 15.2 codegen history (memory
   `qemu-passes-hardware-fails-armv7-codegen`): should the module build be compared
   once against arm-gnu-13.3 on hardware, if SGXInit misbehaves?
8. Does the omapdrm dma-buf of a TILER-pinned scanout buffer import cleanly into pvr?
   omapdrm puts the TILER address in both `sg_page` and `sg_dma_address`
   (`omap_gem.c:1022-1027`); pvr uses `sg_phys()` (`dmabuf.c`). This belongs to the
   display-glue workstream, but the kernel side may need a fix.
9. Licensing and distribution: `PUBLIC_RELEASE=1` images and the proprietary ti443x
   UM. The KM is GPL/MIT; the UM is TI's "TSPA" licence (UNVERIFIED wording; check the
   UM repo's LICENSE).
10. Does the stale header of `kernel/configs/steelhead_defconfig` (6.12.12/GCC 13.3)
    matter for adding new symbols? `olddefconfig` should carry them, but regenerate the
    defconfig from the pipeline once to keep diffs readable.
11. Is `SYS_SGX_ACTIVE_POWER_LATENCY_MS` 100 ms (stock) or 2 ms (TI) the better choice
    for a mostly idle appliance with an occasional HDMI UI? Measure after step 8.

---

## Sources

Repo and local (read 2026-10-11):
- `repo:docs/2026-06-19-gpu-sgx540-acceleration-research.md`; `repo:docs/2026-08-18-kernel-ota-phase2.md`; `repo:docs/2026-08-31-kernel-6.18-test-plan.md:25-27`; `repo:docs/2026-09-20-sleep-states-design.md:88`; `repo:docs/2026-06-19-boot-warnings-followup.md:149-150`; `repo:INSTALL.md:85-91,585`
- `repo:pmos/linux-google-steelhead/APKBUILD:5-6,31-93,97-138`; `repo:kernel/configs/steelhead_defconfig` (lines cited inline); `repo:kernel/patches/0007-…`, `0027-…`
- `repo:userspace/nexusq-kernel-ota/nq-kernel-ota:398-415`; `repo:scripts/build-kernel-boot.sh:54,257-259`; `repo:docker-build.sh:123,289`; `repo:tests/test_aports.py:40-48`
- Stock: `reverse-eng/vmlinux.bin` + `reverse-eng/tools/kallsyms.txt`, symbols `omap_init_gpu@c0556ac0`, `SysDvfsInitialize@c0290f80`, `RequestSGXFreq@c0290c28`, `SysGetSGXTimingInformation@c0290bb0`, `omap446x_opp_def_list@c0043d5c` (GPU rows at c0043e94-c0043ed8), `sgx_apm_latency@c0725b9c`; `reverse-eng/factory/tungsten-ian67k/system.raw.img` `/vendor/lib`, `/vendor/lib/egl`, `/vendor/bin/pvrsrvinit`
- Pristine linux-6.18.48 (https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-6.18.48.tar.xz, downloaded 2026-10-11) and `repo:build/linux-6.12.12`

openpvrsgx (GitHub API and sparse clone, 2026-10-11):
- https://github.com/openpvrsgx-devgroup/linux_openpvrsgx: branch list and heads as tabled in §3.1; merge `d2f1e031d58a` (first parent `6a23ae0a96a6` Linux 6.18-rc6); `2342ce92fdde` (7.2)
- 1.17 commits: `e5de75568819`, `ff422e4ab0bb`, `4ec821a3f175`, `8ac9af1053ab`, `399fdecf821e`, `cd5e751ffd9b`, `77ea0f693e97`, `3eb4b62bd9ee`, `015669fcb7bf`, `f64a012f3c93`, `cc3cc247135b`, `93cf687fded3`, `7324d6be38ae`, `6ab2e006ac95`, `b4d95bec50b3`, `7e4ef04bcbdd`, `0e4610be9830`, `84db121f1016`, `43caf0880109`, `b9b0a1cd50dc`; pvrsrvkm-v3: `db0be6bcea49`, `8ac3728be62d`, `c05771b38e3b`, `7865ecbcc7b5`, `a5559de3ed05`, `47ba2d0e4f43`, `86f019dade7e`
- Issues: https://github.com/openpvrsgx-devgroup/linux_openpvrsgx/issues/3, /issues/4, /issues/2, /issues/17, /issues/20; commit https://github.com/openpvrsgx-devgroup/linux_openpvrsgx/commit/4044dd9c39c949
- git.goldelico.com letux-kernel refs (`git ls-remote https://git.goldelico.com/letux-kernel.git`, 2026-10-11): `letux-6.18.y c118c403ccb8…`, `letux/pvrsrvkm-1.17.4948957-v4 3f5f503efcc6…`. Contents not readable.

TI:
- https://git.ti.com/cgit/graphics/omap5-sgx-ddk-linux/: branch page incl. `ti-img-sgx/1.17.4948957/k4.19` "km: Add build targets for sgx530-121 and sgx540-120 devices", `1.17.4948957/mesa/k6.1`
- https://git.ti.com/cgit/graphics/omap5-sgx-ddk-um-linux/: branch page (`1.17.4948957/mesa/glibc-2.35` newest; tree pages returned HTTP 503 at time of research)
- https://raw.githubusercontent.com/TexasInstruments/meta-ti/master/meta-ti-bsp/recipes-bsp/powervr-drivers/ti-sgx-ddk-km_1.17.4948957.bb (COMPATIBLE_MACHINE, TARGET_PRODUCT, BRANCH `${PV}/mesa/k6.1`, SRCREV `9ae0fa49…` on that mirror); GitHub API on `TexasInstruments/meta-ti` branches `scarthgap`/`wrynose`/`master`; commits `6c69db8d0d68` (2025-02-14), `8267e14677d0` (2025-12-19), `135dfe3f2620` (2026-02-25)
- https://www.mail-archive.com/meta-ti@lists.yoctoproject.org/msg05600.html "ti-sgx-ddk-km: bump revision for kernel 6.12" (2025-02-13, SRCREV `3005cf81…` → `f555b9e1…`)
- https://git.yoctoproject.org/meta-ti/commit/?id=b444d36dc5177bee26fb00285f12d6c057c6df57 (search result only: "sgx: bump version for kernel 6.6 / mesa 23.2.1")

mobiaqua / Maemo / others:
- https://github.com/mobiaqua/sgx-pvr5-module: `eurasiacon/build/linux2/ti443x_linux/Makefile`, `services4/system/omap/sysconfig.h` (OMAP44xx block), `services4/srvkm/env/linux/module.c` compatible list; last push 2025-04-06
- https://github.com/mobiaqua/mesa-sgx (pushed 2024-11-22), https://github.com/mobiaqua/libgbm (2023-02-19), https://github.com/maemo-leste/pvr-omap4 (2022-02-01)
- https://leste.maemo.org/Motorola_Droid_4/PowerVR (last edited 2020-02-17, marked outdated)
- https://github.com/hansemro/kc1-linux/discussions/26 (OMAP4430, 1.17, VMAP fix, kmscube 59.99 fps; 2021)

postmarketOS:
- https://gitlab.postmarketos.org/postmarketOS/pmaports/-/merge_requests/1868 (merged 2021-02-23), /merge_requests/3162 (merged 2022-05-27), /merge_requests/3027 (2022-03-26, espresso3g; diff shows the `tmlind/linux_openpvrsgx` archive source), /merge_requests/2573 (closed)
- https://gitlab.postmarketos.org/postmarketOS/pmaports/-/work_items/1316 "Embrace PowerVR or not?" (closed), /work_items/932

Mainline history of the 4430 SGX clock:
- https://lkml.iu.edu/hypermail/linux/kernel/2010.3/02087.html "ARM: dts: omap4: Fix sgx clock rate for 4430" (2020, 153.6 MHz)
- https://lab.nexedi.cn/kirr/linux/-/commit/19d3e9a0bdd57b90175f30390edeb06851f5f9f3 (Lindgren commit page, from search results; not opened)
- The 2021 revert to 307.2 MHz ("Correct sgx clock to 307.2MHz as used on motorola vendor kernel", applied to omap-for-v5.12/dt) is known only from a search-result summary. Its upstream commit hash was **not** verified; the result is visible in `6.18.48:arch/arm/boot/dts/ti/omap/omap443x.dtsi:78-86`.

---

## Verification (2026-10-11)

An adversarial re-check by a second agent. Every check re-opened the source itself:
- the openpvrsgx partial clone at `d2f1e031d58a` / `2342ce92fdde`
- pristine linux-6.18.48 and `repo:build/linux-6.12.12`
- `reverse-eng/vmlinux.bin` through `reverse-eng/tools/{dump,nqdis,callers}.py`
- `debugfs` on `system.raw.img`
- `git ls-remote` against GitHub and git.ti.com
- the GitHub REST API (`gh api`) and the gitlab.postmarketos.org API

Nothing was built, and no device was touched.

### Corrected or added

1. **Missing hard blocker, now TL;DR item 8 and §8 k: the preemption model.**
   - The 1.17 OMAP build always defines `PVR_LINUX_USING_WORKQUEUES` (`Makefile:124,238`).
   - `osfunc.c:126-135` stops with `#error "A preemptible Linux kernel is required when
     using workqueues"` unless `CONFIG_PREEMPTION` or `CONFIG_PREEMPT_VOLUNTARY` is set.
     The same guard is in the 7.2 tree.
   - Our `steelhead_defconfig:99-102` is `PREEMPT_NONE`, so the module as planned
     cannot compile.
   - Supporting evidence: the merge commit carries `0affbb5a7b95` ("PVR/SGX build now
     needs CONFIG_PREEMPT=y or CONFIG_PREEMPT_VOLUNTARY=y"), and `omap2plus_defconfig:511`
     sets `CONFIG_PREEMPT_VOLUNTARY=y`.
   - The working kc1 run used `CONFIG_PREEMPT=y`, and stock was `SMP PREEMPT`.
   - §9 and §12 are updated to match.
2. **Built-in `=y` is "very likely not viable", not "impossible".**
   - The 92 KB headroom counts compressed bytes. The stock PVR+OMAPLFB text
     (`c0272218`-`c029b1b0`) is 167 832 B raw, about 66 KB with LZMA -9e and about 86 KB
     with zlib.
   - That figure excludes rodata, data and init code. 1.17 is larger, so it most likely
     uses up the headroom. Still unmeasured.
3. **Expected dmesg line on 6.18.** `[drm] Initialized pvr 1.17.4948957 for …`, with no
   `20110701` date. `drm_driver.date` was removed in 6.14, and the format string is at
   `drm_drv.c:1104`.
4. **Commit hash typo.** The pvr-drv `drm_driver.date` fix is `c05771b38e3b`, not
   `c05071b38e3b`, which GitHub reports as "No commit found". The Kconfig half of the ABI
   options is `7865ecbcc7b5` on `letux/pvrsrvkm-v3`; `b9b0a1cd50dc` is the 1.17-tree half.
5. **Issue #3 dates.** Opened 2021-03-21 and closed 2021-03-22 by the reporter. The fix
   comment ("It works!!") is from 2021-03-22; the last comments are from 2021-03-24.
6. **Stock blob strings.**
   - `1.4 build 1.8@785978` is the EGL version string in `/vendor/lib/libIMGegl.so`. No
     GLES1 version string was found in `libGLESv1_CM_POWERVR_SGX540_120.so`.
   - `gralloc.omap4.so` lives in `/vendor/lib/hw/`.
7. **`RequestSGXFreq` error path.** It does not "fall back to count-1" as a frequency;
   it marks the current index as count-1 so the next call retries. The bMax arguments
   at the call sites were checked: Enable and IdleTransition pass 1, idle_work passes 0.
8. **`remove_new`.** It was still present in 6.12.12 (`platform_device.h:246`), so its
   removal came later than 6.11. The 6.11 change was the `void` return type.
9. **§8 d gets contradicting evidence.** The message of `84db121f1016` reports sgx clock
   gating on droid4 with the same probe code. The "pinned ON" conclusion stays a code
   inference until it is measured.
10. **§3.2 hidden-prompt question mostly answered by reading the code.** 6.18.48
    `scripts/kconfig/symbol.c:212-235,272-295` and `menu.c:310-318` give the first
    visible member, `SGX_PB_PER_CONTEXT`.
11. **§8 b promoted from UNVERIFIED to statically verified.** There is a single call
    chain, and the non-VMAP `VMallocWrapper` call is under `#else` (`mm.c:1105-1125`).
12. **Added evidence for the VMAP flag.** TI's `ti-img-sgx/1.17.4948957/k5.10` head
    `eda7780bfd52` adds `PVR_LINUX_MEM_AREA_USE_VMAP = 1` and cites openpvrsgx #3.
13. **The merge's non-pvrsgx file list also includes `MAINTAINERS` and
    `omap54xx-clocks.dtsi`** (the OMAP5 IVA clkctrl from `omap-sysc-prm-gfx`).
    `git diff --name-only 6a23ae0a96a6 d2f1e031d58a` shows 19 files outside
    `drivers/gpu/drm/pvrsgx/`, and none of them touch OMAP4 SoC code beyond
    `pdata-quirks.c`.

### Confirmed (reproduced)

- **Claim 1, stock DDK.**
  - The string `CustomerGoogle_Android_ogles1_ogles2_GPL sgxddk 18 1.8@785978` is in
    `vmlinux.bin`.
  - `PVRCore_Init@c0025920` and `__initcall_PVRCore_Init6@c003cf54` are in
    `kallsyms.txt`.
  - `OpenGL ES 2.0 build 1.8@785978` is in `libGLESv2_POWERVR_SGX540_120.so`.
  - `gpu_fck`/`dpll_per_m7x2_ck` error strings are present.
  - `omap_init_gpu` disassembly: `omap_rev()>>20 == 0x446`,
    `omap_device_build("pvrsrvkm", …, omap_gpu_latency)`, then `omap_omaplfb_device`.
- **Claim 2, stock OPP rows.** At `c0043e94`/`eac`/`ec4` (row stride 0x18): {"gpu",
  "core", "dpll_per_m7x2_ck", 153600000/962000, 307200000/1127000, 384000000/1250000,
  available=1}.
- **Claim 3, stock table construction.** `SysDvfsInitialize` allocates n+1 entries,
  duplicates the last, and stores count=n+1 @+0x30, table @+0x34, index=n @+0x38.
  `RequestSGXFreq` uses `bMax ? count-2 : 0`. Upgraded from likely to verified, with the
  nuance in item 7 above.
- **Claim 4, stock timing.** `SysGetSGXTimingInformation` stores 100 (HWR), 1 (APM),
  `sgx_apm_latency`=100 and 1000 (µKernel); the core clock comes from the table. Also
  seen: `sgx_idle_timeout`=1000000 and `sgx_idle_mode`=2 @c0725ba4.
- **Claim 5, branch heads.** `git ls-remote` on GitHub:
  - `pvrsrvkm-6.18-rc6` `d2f1e031d58a…` (2025-11-21; first parent `6a23ae0a96a6`
    "Linux 6.18-rc6", 2025-11-16)
  - `HEAD` = `linux+pvrsgx` = `pvrsrvkm-7.2` = `2342ce92fdde…` (2026-08-26)
  - every other head in the §3.1 table matches character for character
  - `-v3` head `e5de75568819` was committed 2026-08-21
- **Claim 6.** Confirmed with the addition in item 13.
- **Claim 7, exports.** `6.18.48:mm/vmalloc.c` has `__vmalloc_node_range_noprof` at
  :3849 with no export, `EXPORT_SYMBOL_GPL(__vmalloc_node_noprof)` :3999,
  `EXPORT_SYMBOL(__vmalloc_noprof)` :4007 and `EXPORT_SYMBOL(vmap)` :3563.
  `AllocFlagsToPGProt` maps CACHED to `PAGE_KERNEL` (mm.c:490-491).
- **Claim 8, VMAP.** The flag is absent from both 1.17 Makefiles. `core.mk:596` defaults
  it on. kc1 #26 (2021-05-13 failure, 2021-07-31 fix, 59.986 fps) was re-read.
- **Claim 9, which DDKs build for OMAP4.** Makefile:29-59 (`pvr_drv=yes` only for
  1.14.3699939 and 1.17), :92-100 (sgx540_120 *and* sgx544_112 under `ARCH_OMAP4`),
  :119-133 (`TI_PLATFORM=omap3/omap3630/ti335x`).
- **Claim 10, pmaports.**
  - !1868 merged 2021-02-23: `pkgver=1.17.494857`, `_commit=551665bf…`,
    `depends="libc6-compat"`, `$pkgname-ti443x`.
  - !3162 "main/mesa-pvr-dri-classic: remove", merged 2022-05-27, deletes
    `non-free/sgx-ddk-um/*` and quotes #1316.
  - !3027 merged 2022-03-26.
  - #1316 closed 2022-01-25.
- **Claim 11, meta-ti.**
  - `6c69db8d0d68` "ti-sgx-ddk-km: bump revision for kernel 6.12" (authored 2025-02-13,
    committed 02-14).
  - `8267e14677d0` "Add ti-6_18" (committed 2025-12-19).
  - `135dfe3f2620` makes 6_18 the default (2026-02-25).
  - master `ti-bsp.inc` has `BSP_SGX_DRIVER_PROVIDER` only for ti-6_12 and ti-6_6.
  - The git.ti.com KM branches include `ti-img-sgx/1.17.4948957/{k4.14,k4.19,k5.4,k5.10,k6.1}`
    and `1.17.4948957/mesa/k6.1` (`9ae0fa49…`).
- **Claim 12, mainline glue.** Line for line: `omap4.dtsi:484-509` and `:812-816`,
  `omap_prm.c:196-198`, `clk-44xx.c:327-340`, `ti-sysc.c:1610`, binding line 25
  `ti,omap4430-gpu # Rev 120`. `of_dev_lookup()` matches any compatible
  (`drivers/of/platform.c:287`), so the existing `ti,omap-prm-inst` auxdata covers
  `prm_gfx`.
- **Claim 13, 4460 clock block.** `omap443x.dtsi:78-86` has the `&sgx_module` block;
  `omap4460.dtsi` includes only `omap4.dtsi` and `omap446x-clocks.dtsi`, and neither has
  it. Our `0003` patch has no sgx/GPU clock entry. DPLL_PER x2 = 1536 MHz
  (`docs/2026-06-19-boot-warnings-followup.md:149-150`).
- **Claim 14, sysconfig constants.** `sysconfig.h:46-56` selects `sysconfig-am4.h` for
  `AM_VERSION==4`, which sets 200 MHz / 50 Hz / 2 ms. `sysutils_linux.c:173`
  uses `SYS_SGX_CLOCK_SPEED` because the DVFS framework is not built. mobiaqua
  `sysconfig.h:84-90` OMAP44xx block: 307200000, 100 Hz.
- **Claim 15, runtime PM.** Probe takes `pm_runtime_get_sync` (pvr-drv.c:441) with no
  put on success. The remove order bug is at :484-485. Kept at "likely" because of the
  item 9 counter-evidence.
- **Claim 16, dma-buf locking.** `dma-buf.c:1113` is `dma_resv_assert_held`;
  `dma-buf.h:598` declares `_unlocked`; `dmabuf.c:186` and `:101` call the locked
  variants. The 7.2 tree is the same.
- **Claim 17, API breaks.** All 6.18.48 line citations in §7 were spot-checked and
  match. 6.12.12 has `pfn_t.h`, `from_timer`, `remove_new` and `char *date`.
  `dma-buf.h`, `timer.h`, `drm_drv.h`, `drm_file.h`, `drm_ioctl.h`, `pm_runtime.h`,
  `dma-resv.h` and `dma-fence.h` are byte-identical between 6.18-rc6 and 6.18.48.
  `vmalloc.h`, `platform_device.h` and `dma-mapping.h` differ only in identifiers the
  driver does not use. All cited fix commits resolve on GitHub with matching subjects
  (`c05071b38e3b` excepted, see item 4).
- **Claim 18, kernel OTA.** `nq-kernel-ota:398-415` installs `/lib/modules/$_rel` from
  the kernel apk only.
- **Claim 19, firmware.** `request_firmware` appears nowhere under `pvrsgx/` except the
  Intel `1.7.862890/imgv/psb_msvdxinit.c`. `libsrv_init.so` contains the `SetupuKernel`
  strings. Stock `/vendor/firmware` has no SGX file.
- **Claim 20, APM.** The `84db121f1016` diff (2020-12-13, Tony Lindgren) adds
  `SUPPORT_ACTIVE_POWER_MANAGEMENT` and `SYS_USING_INTERRUPTS`, and sets
  `OPTIONS_BIT15 0x0 /* HACK: missing userspace flag */`. Message: "tested on droid4
  with sway".
- **Repo line citations confirmed.** `steelhead_defconfig` lines
  33/317-323/695/821/1425/2830/2869/4005/4208/5524-5530, `APKBUILD` pkgver 6.18.48,
  pkgrel 20, `prepare()` LOCALVERSION.

### Could not reproduce / still UNVERIFIED

- **The real Kconfig result for the hidden choice.** It was inferred from reading the
  kconfig code; `conf` was not run.
- **Whether `PREEMPT_VOLUNTARY` is enough** for the DDK's spin-waits, or `PREEMPT` is
  needed. *Answered from code 2026-10-11, Addendum B.2-B.4; not run on hardware.*
- **Whether the module actually pins the `gfx` power domain on hardware.**
- **The compressed size of a built-in 1.17 KM.**
- **The upstream commit hash of the 2021 "307.2 MHz" OMAP4430 DT revert.** Not looked
  up in this pass; the report already flags it.
- **git.goldelico.com `-v4` / `letux-6.18.y` contents.** Not re-tried. *Read 2026-10-11
  from the GitHub mirror [Addendum C].*
- **The "StaticRocket of TI" affiliation.** The 2024-11-03 comment text was confirmed;
  the affiliation was not checked.

---

## Addendum (2026-10-11): Maemo 6.18.51.1 reference integration: tree diff, .config, and evidence that it renders

Research only. Nothing was built, flashed or installed, and no device was touched.
Downloads went to their own scratch subdirectories and were read with `git`, `diff`,
`readelf` and `python3 -I`; nothing from them was executed.

**Result in one paragraph.** Maemo's `drivers/gpu/drm/pvrsgx/` at
`maemo-kernel-6.18.51.1` equals openpvrsgx `pvrsrvkm-6.18-rc6` (`d2f1e031d58a`) except
for one commit: `2cd8d74ec61a`, Tony Lindgren, 2023-11-14, "gpu: pvr: Enable runtime PM
autosuspend for pvr-drv". The shipped kernel is `CONFIG_PREEMPT=y`, CMA 32 MiB and DDK
1.17. It builds the OMAP4 module **without** the VMAP flag and **with** the core-mm
`__vmalloc_node_range_noprof` export. The VMAP requirement from 2021 has an identified
root cause that was fixed upstream on 2021-07-30, so (a) becomes the means to drop the
core-mm patch rather than a bug fix. Maemo developers state that pvr renders on the
Droid 4 with their 6.18 kernels. Nobody has published a measurement, and a Droid 3
report shows reset problems tied to GPU runtime PM.

### A.1 Tree diff: Maemo vs `pvrsrvkm-6.18-rc6` vs `-v3`

Sources:
- Maemo: a sparse fetch of `maemo-leste/droid4-linux` at
  `db432aff895bb8a500cba67ce2041df5ad3c36ab`. The commit date is 2026-09-22 and the
  subject is "CONFIG_PROC_EVENTS needs CONFIG_CONNECTOR=y". The Makefile reads 6.18.51.
- openpvrsgx: `pvrsrvkm-6.18-rc6` = `d2f1e031d58aca97bc4b62367f0d7bef4a7559c3` and
  `letux/pvrsrvkm-1.17.4948957-v3` = `e5de755688193794ecbbcd6df2bf32fd3dee122a`, both
  fetched by branch name (the heads match §3.1).

**Maemo vs rc6** (`diff -rq` over `drivers/gpu/drm/pvrsgx/`, 4048 vs 4050 files):

| Difference | Classification |
|---|---|
| `pvr-drv.c`: probe adds `pm_runtime_use_autosuspend()` and `pm_runtime_set_autosuspend_delay(…, 2000)` before the `get_sync`, and `pm_runtime_mark_last_busy()` + `pm_runtime_put_autosuspend()` after success. The error path adds `pm_runtime_dont_use_autosuspend()`. `pvr_remove()` adds a guarding `pm_runtime_get_sync()` and a conditional extra put | **(d), probe half: already written** (`2cd8d74ec61a`). The remove half is incomplete and adds a new defect, see below |
| `generic/include4/aw/` (`platform.h`, `sun8i/sun8iw6p1.h`) present only in rc6 | not relevant (Allwinner, `SGX_GENERIC`) |

Everything else is byte-identical, including the whole `1.17.4948957/` tree, `Kconfig`
and `Makefile`.
- The commit message of `2cd8d74ec61a` says it depends on "drm: pvrsgx: Force enable
  limited runtime PM support for ddk 1.17". That is openpvrsgx `84db121f1016`, already
  in rc6: the `SUPPORT_ACTIVE_POWER_MANAGEMENT` and `SYS_USING_INTERRUPTS` flags are at
  `1.17.4948957/eurasia_km/Makefile:131-132,228,262`, and
  `include4/sgx_options.h:151` has `OPTIONS_BIT15 0x0`.
- Neither openpvrsgx `pvrsrvkm-7.2` nor `letux/pvrsrvkm-v3` contains the commit: `pvr-drv.c`
  has 0 matches for "autosuspend", and `pvrsrvkm-7.2:pvr-drv.c:482-490` still has the old
  `pvr_remove()`.
- Maemo's history of the hook files shows the same openpvrsgx commits re-applied
  (committer date 2026-09-13; e.g. `084d34836943` for `drivers/gpu/drm/{Kconfig,Makefile}`,
  `d4b99f71d31b` + `0ed6addd38b1` for the `mm/vmalloc.c` export). It also shows
  `cd0c7327bf76` "ARM: OMAP2+: pdata-quirks: add PRM data for reset support".
- There is no pvr-specific omapdrm change since 2026-04-01. The only Maemo-local omapdrm
  commits are DSI/HDMI/tc358775: `643c9000da33`, `e056f2be7f38`, `7d0e906c987f`.

**What Maemo's `pvr_remove()` does** (Maemo `pvr-drv.c:488-505`):
- **The use-after-free order is still there.** It calls `drm_put_dev()` before
  `pvr_drm_unload()`, as in rc6 `:484-485`. Patch (d)'s remove-order fix is still ours.
- **A new usage-count imbalance.** `active = pm_runtime_get_sync()` returns 1 when the
  device is already `RPM_ACTIVE` (Maemo `drivers/base/power/runtime.c:820-822`). The code
  then calls `pm_runtime_put_sync()` twice for one get, `if (active)` plus the
  unconditional put kept from rc6. 6.18's `rpm_drop_usage_count()` clamps the count and
  logs `Runtime PM usage count underflow!` (runtime.c:1080-1095).
- It is balanced only when the device was runtime-suspended at removal. Inside the
  2000 ms autosuspend window, `rmmod` warns. This is derived from the code and was not
  seen on hardware.
- Our (d) should take `2cd8d74ec61a`'s probe half (credit Lindgren) and write the remove
  path as `drm_dev_unregister()` → unload → `drm_dev_put()` with one balanced
  get/put.

**rc6 vs `-v3`, 1.17 tree only** (41 files differ). The diff to Maemo is the same, since
Maemo's 1.17 tree is rc6's.

| Hunk group | Classification |
|---|---|
| `pvr_linux_fence.c:542` `unsigned blocking_fence_count;` → `= 0` | **(i)** `ff422e4ab0bb`. A real bug on our path: the ≥5.19 branch does `blocking_fence_count++` from an uninitialised value (rc6 `pvr_linux_fence.c:541-596`). **Maemo ships it unfixed** |
| `dc_poulsbo/*`, `pvr_drm.c`/`.h`, `pvr_bridge.h`, `sgx_bridge.h`, `bridged_pvr_bridge.c`, `env_data.h`, `mm.c` (`extern gpsPVRLDMDev` → `env_data.h`, a debug format string), `Makefile` (`SOC_VENDOR=intel` builds `pvr_drm.o` instead of `pvr-drv.o`) | Intel Poulsbo/Cedarview, not relevant |
| `Makefile`: `SUPPORT_PERCONTEXT_PB`, `SUPPORT_HW_RECOVERY`, `SUPPORT_SGX_HWPERF` move from fixed flags to `CONFIG_SGX_*`; adds `PVR_ABI_COMPAT`; drops `PVR_LDM_DEVICE_TREE` and `PVR_DRI_DRM_PLATFORM_DEV`; adds `DRM_PVR_RESERVED1=$(CONFIG_SGX_IOCTL_ALIAS)` | new, ABI-relevant (already in §3.2/§9) |
| `sgx_options.h` adds `SGX_BUILD_OPTION_MASK ~(0xa0379 \| SCHED_MASK)`. `sgxinit.c` masks both UM↔KM and KM↔µKernel build-option comparisons with it. The `SGX_MISC_INFO_REQUEST_SGXREV` reply no longer memsets the misc info or fills `ui32BuildOptions`, and `ui32DDKVersion` now ORs in `PVRVERSION_BRANCH`. `PVR_ABI_VERSION(...)` guards around misc-info cases and debug scripts | **new, and it changes behaviour on the init handshake** that the ti443x UM goes through. Not exercised by any OMAP4 user. This is a reason to stay on rc6 |
| `osfunc.c`, `pvr_debug.c`, `sgxkick.c`, `sgxtransfer.c`, `module.c`, `mutils.c`, `pvrsrv.c`, `devicemem.c`, the 3rd-party display classes, `pvrversion.h` | `strncpy`→`strscpy`, `in_irq`→`in_hardirq`, debug-only edits, ABI-compat guards: hygiene or 6.19+ (already in §3.2) |

None of the `-v3` hunks touches (a), (b), (c), (e), (f) or (g).

### A.2 The effective configuration

- **No source package is published.** The excalibur pool
  `https://maedevu.maemo.org/leste/pool/main/o/omap-linux/` has only binary debs, and
  `excalibur/main/source/Sources.gz` has no `omap-linux` entry.
- **The packaging** is branch `maemo/excalibur` of
  `https://git.maemo.org/leste-upstream-forks/droid4-linux` (head `c5fab0c095e7`,
  2026-09-22, "update debian/changelog").
  - Its `debian/rules` runs `make ARCH=arm omap2plus_defconfig`, then
    `zImage modules dtbs` with `LOCALVERSION=`. There is no config fragment and no patch
    step.
  - `debian/gbp.conf` sets `upstream-tag=maemo-kernel-%(version)s`.
  - `debian/changelog` has `6.18.51.1-1` "enable CONNECTOR=y" (2026-09-22) and
    `6.18.51.0-1` "new upstream release" (2026-09-13).
- **Why 1.17 wins.** Maemo's `omap2plus_defconfig` keeps upstream's `CONFIG_PVRSGX_1_14_3699939=y` (:510) and
  `CONFIG_PREEMPT_VOLUNTARY=y` (:511). A "Leste changes" block then re-assigns
  `CONFIG_PREEMPT=y` (:749) and `CONFIG_PVRSGX_1_17_4948957=y` (:750) and sets
  `CONFIG_CMA_SIZE_MBYTES=32` (:746). In a defconfig the later assignment of a choice
  wins.
- **Confirmed from the shipped binary.** I downloaded
  `linux-image-omap_6.18.51.1-1+5m7_armhf.deb` (sha256 `9eaefae51da9…e5fd` matches
  `excalibur/main/binary-armhf/Packages.gz`) and read its `/boot/config-6.18.51`:

| Symbol | Maemo 6.18.51.1 (shipped) | Ours (`steelhead_defconfig`) |
|---|---|---|
| Compiler | `gcc (Debian 14.2.0-19) 14.2.0` | Alpine GCC 15.2 |
| Preemption | `CONFIG_PREEMPT=y`, `PREEMPT_BUILD`, `PREEMPTION`, `PREEMPT_COUNT`, `PREEMPT_RCU`; `PREEMPT_NONE` and `PREEMPT_VOLUNTARY` not set (:109-114,139) | `PREEMPT_NONE=y` (:99-102) |
| HZ | `CONFIG_HZ_100=y`, `HZ=100`, `NO_HZ_IDLE=y` (:92,520-526) | `HZ=100` (:451) |
| CMA | `CMA=y`, `DMA_CMA=y`, `CMA_SIZE_MBYTES=32`, `CMA_SIZE_SEL_MBYTES=y`, `CMA_AREAS=8` (:926-929,8111-8121) | 16 MiB (:5529) |
| PVRSGX | `SGX=y`, `PVRSGX_1_17_4948957=y` (all other DDKs not set), `SGX_DRM=y`, `SGX_OMAP=m`, `SGX_DEBUG` and `SGX_GENERIC` not set (:5003-5018) | same plan (§9) |
| DRM_OMAP | `DRM_OMAP=m` (:4792) | `=y` |
| Other | `MODVERSIONS=y`, `HIGHMEM=y`, `VMSPLIT_3G=y`, `PROVE_LOCKING` not set, `PM_DEVFREQ` not set, `SYNC_FILE=y` | same |

- No Droid 4 / mapphone DTS gives the GPU a `memory-region` (grep of `omap4.dtsi`,
  `omap4-droid4-xt894.dts` and `motorola-*mapphone*.dtsi`), so the 32 MiB CMA is not an
  SGX reservation. Why Maemo chose 32 MiB is UNVERIFIED; it does not change §9.
- **The shipped module.** `lib/modules/6.18.51/kernel/drivers/gpu/drm/pvrsgx/1.17.4948957/eurasia_km/pvrsrvkm_omap4_sgx540_120.ko`:
  359 116 B, sha256 `e088e0a59749…a378`. `modinfo` via `readelf -p .modinfo`:
  `vermagic=6.18.51 SMP preempt mod_unload modversions ARMv6 p2v8`, `intree=Y`,
  `alias=of:N*T*Cti,omap4430-gpu*`, `import_ns=DMA_BUF`.
  - Undefined symbols include `__vmalloc_node_range_noprof`, `dma_buf_map_attachment`,
    `dma_buf_unmap_attachment` (the locked variants, so (e) is not applied),
    `__pm_runtime_use_autosuspend` and `pm_runtime_set_autosuspend_delay`. That proves
    `2cd8d74ec61a` is built in.
  - `vmap` is **not** imported. So the module was built without
    `PVR_LINUX_MEM_AREA_USE_VMAP`, consistent with the source, and the VMAP path's
    `VMapWrapper` → `vmap()` (`mm.c:616-628`) is absent.
  - The deb also ships the dead `pvrsrvkm_omap4_sgx544_112.ko`, so (f) is not applied.
- **Result for patch (k):** Maemo, the kc1 run and stock all run full `PREEMPT`.
  `PREEMPT_VOLUNTARY` (upstream `omap2plus`) has no known OMAP4 SGX field user. That is
  evidence for picking `CONFIG_PREEMPT=y` in Phase 1a; the audio/idle A/B is still
  required.

### A.3 Why the VMAP flag was needed in 2021, and why Maemo runs without it

- **2020-06-16, `beaeda9077c4`** (H. N. Schaller), "mm.c: __vmalloc has lost its
  PGProtFlags parameter". `_VMallocWrapper()` became `__vmalloc(uiBytes, gfp_mask)` on
  ≥5.8, which silently drops the uncached / write-combined `pgprot`.
  - Every `LINUX_MEM_AREA_VMALLOC` allocation (`NewVMallocLinuxMemArea`, `mm.c:1105-1125`,
    non-VMAP branch) was then mapped cached. That includes the memory shared with the
    µKernel.
- **2021-03 (#3) and 2021-05 to 07 (kc1 #26).** Both reported `PollForValueKM: Timeout …
  Wait for uKernel initialisation failed`.
  - `-DPVR_LINUX_MEM_AREA_USE_VMAP` routes those allocations through `alloc_pages` +
    `vmap(…, PGProtFlags)`, which keeps the `pgprot`.
- **2021-07-30, `7e493c1ab5c5` + `47ba2d0e4f43`** (Schaller). These restored the
  `pgprot` on the non-VMAP path with `__old_vmalloc()` → `__vmalloc_node_range()`, plus
  an `EXPORT_SYMBOL` in core mm. `a5559de3ed05` (2024-06-01) updated it for `_noprof` in
  6.10.
  - With the export present, the non-VMAP path is correct again (rc6 `mm.c:512-575`
    passes `PGProtFlags`). This is the configuration Maemo ships.
- **What this means for us.**
  - The causal chain (cached mapping → µKernel handshake timeout) is UNVERIFIED as a
    *measured* mechanism. Its parts are from commit history: the dates line up, and both
    fixes restore exactly the `pgprot`.
  - TI's `eda7780bfd52` (k5.10, VMAP) is consistent with TI's KM having the same ≥5.8
    `__vmalloc` change. UNVERIFIED: TI's `mm.c` was not read.
  - So (a) and (b) are one design choice, not two fixes. There are two internally
    consistent configurations:

| Configuration | Core-mm patch | Field evidence |
|---|---|---|
| **Maemo**: no VMAP, `EXPORT_SYMBOL(__vmalloc_node_range_noprof)` in `mm/vmalloc.c` | yes (Maemo carries `d4b99f71d31b` + `0ed6addd38b1`) | Maemo 6.18 on Droid 4 (A.5, statements only) |
| **Ours**: (a) VMAP + (b) `__vmalloc()` for the one `PAGE_KERNEL` caller | none | kc1 2021 (5.13, kmscube 59.99 fps), TI k5.10 |

Keep ours: there is no private core-mm export, and the project rule against carrying a
modified core file holds. At first light, if `SGXInitialise` times out, the Maemo
configuration is the diagnostic A/B. It is one `EXPORT_SYMBOL` line plus dropping (a)
and (b), and it isolates the memory path in a single rebuild.

### A.4 Patch list (a)-(k) after the Maemo diff

| Patch | In Maemo 6.18.51.1? | Ours to write? |
|---|---|---|
| (a) VMAP | no (source + `.ko` imports) | **yes**, now as the precondition for (b) (A.3); no longer a bug fix on its own |
| (b) no core-mm export | no; Maemo carries the export | **yes** |
| (c) OMAP4 sysconfig (307.2 MHz, 100 Hz, 100 ms) | no; byte-identical 1.17 tree, so Maemo's Droid 4 runs the AM437x header (200 MHz declared) | **yes** |
| (d) runtime PM | **probe half yes** (`2cd8d74ec61a`, 2000 ms autosuspend); remove half no (order unchanged, new double put, A.1) | **cherry-pick the probe half** (author kept, delay re-chosen: 100 ms stock APM vs Maemo's 2000 ms, measure in step 8); **write the remove half** |
| (e) `dma_buf_*_unlocked` | no (imports the locked variants) | **yes** |
| (f) SGX540-120 only | no (ships `sgx544_112.ko`) | **yes** |
| (g) drop `select DRM_LEGACY` | no (`Kconfig:69`) | **yes** |
| (h) hook | yes (`084d34836943`, same as the merge) | copy |
| (i) `ff422e4ab0bb` | **no**, Maemo ships the uninitialised count | **yes** |
| (j) `drm_mmap` review | unchanged | review |
| (k) preemption | `CONFIG_PREEMPT=y` | config change, now with Maemo as a third PREEMPT precedent |
| new | nothing else OMAP-relevant in Maemo; `-v3` adds the build-option mask/handshake change (A.1) | do not take with a 6.18-rc6 base |

So out of (a)-(g) and (i), only half of (d) is already written. Seven and a half patches
remain ours.

**KM-base recommendation (updates §6.2, §12 step 1 and gw "F2").**
- Pin openpvrsgx `pvrsrvkm-6.18-rc6` @ `d2f1e031d58a`, as before.
- Carry `2cd8d74ec61a` (probe half) as the first patch of (d).
- Do not pin Maemo's tree. It is downstream and equals rc6 plus that one commit. It also
  carries an unrelated 6.18.51 tree with its own Droid 4 patches.
- Do not base on `-v3`. Its handshake changes are untested on OMAP4 and buy nothing on
  6.18.
- Maemo's value is as **field evidence** that exactly this `pvrsgx/` tree builds (GCC
  14.2) and loads on 6.18.51 with PREEMPT. Use it as the A/B reference for the memory
  path (A.3).

### A.5 Evidence that it renders (2025-2026)

| Date | Source | Device / SGX | Kernel | Statement |
|---|---|---|---|---|
| 2026-06-03 | IRC #maemo-leste, https://libera.catirclogs.org/maemo-leste/2026-06-03#40020808 | Droid 4 / SGX540-120 | Maemo 6.18 test builds (6.18.18-.34 era per the same day) | arno11: "does HW accel working on d4 with 6.18 btw ?" — sicelo: "yes" |
| 2026-08-04 | IRC, https://libera.catirclogs.org/maemo-leste/2026-08-04 | Droid 4 | freemangordon's 6.18.y (the maintainer who tagged 6.18.51.1) | Wizzup: "pvr works ok?" — freemangordon: "yes". Same day, Wizzup cannot get pvr to probe with a hand-copied cross-built kernel; freemangordon points at `LOCALVERSION=` (vermagic/module path), the same flag `debian/rules` sets |
| 2026-07-25 | IRC, https://libera.catirclogs.org/maemo-leste/2026-07-25 | Droid 4, new user on the excalibur image | not stated | "you have gpu accel :)"; the user later finds supertuxkart was CPU-rendering (it needs desktop GL). Weak |
| 2026-07-31 | IRC, https://libera.catirclogs.org/maemo-leste/2026-07-31#40257950 | N900 / SGX530 (OMAP3) | "new 6.18" | arno11: "… PM, boost, HW accel, h-s-m, battery, all seem ok" |
| 2026-05-23/24 | IRC, …/2026-05-23#39975476, …/2026-05-24#39979852 | N900 / SGX530 | early 6.18 (6.18.18) | **fails**: `PVR:(Error): OpenServices: PVRDRMOpenRender failed`, `pvrsrvkm_omap3_sgx530_121 failed to probe on boot`; later blamed on off-mode handling, superseded by the 07-31 report |
| 2026-05-03 | GitHub `maemo-leste/bugtracker#667` (comments by norayr), Forgejo `leste/bugtracker#880` (2026-08-29) | **Droid 3 / SGX540-120 (OMAP4430)** | 5.15.2 and 6.1.9 (chimaera) | `[drm] Initialized pvr 1.17.4948957 20110701 for 56000000.gpu`; renders (Maelstrom). With `56000000.gpu/power/control` = `auto` the phone resets, and dmesg shows `SGX Entering state D3 … Soft Reset of SGX` cycling. `echo on > …/power/control` before `pvrsrvinit` makes it stable. Not 6.18 |
| 2026-02-09 | IRC, https://libera.catirclogs.org/maemo-leste/2026-02-09#39478611 | not stated | not stated | freemangordon: "this is a kernel issue, most-probably in sgx driver" (a hang a user reported; asks for SGX recovery lines in dmesg) |

Also: the wiki page https://leste.maemo.org/Motorola_Droid_4 (last edited 2026-09-27)
lists kernel "6.18 LTS" and 3D acceleration "Yes … PowerVR SGX540 (closed driver)". That
is a status table, not a test.

**Conclusion.**
- That the Maemo 6.18 stack renders on SGX540-120 is **supported by two maintainer
  statements** and by excalibur shipping it as the Droid 4 default. Developers also
  discuss Droid 4 GPU acceleration as on by default (dsc_, 2026-08-03).
- It is **not measured**. No log, fps figure or test case was published, and none of the
  statements names 6.18.51.1.
- The Droid 3 report is the only SGX540 report with dmesg. It ties instability to
  runtime-PM cycling on an OMAP4430 (5.15/6.1, so before `2cd8d74ec61a` reached those
  builds: the 6.1.9 kernel is dated 2023-03-20 by `uname`). The mechanism is
  UNVERIFIED.
- It is directly relevant to our §11 / step 8 gate. Expect to test GPU runtime-PM
  transitions under load explicitly (APM D3 cycling plus genpd OFF), not just the idle
  state. `power/control=on` is the field workaround and would be a mask under our rules,
  not a fix.

### A.6 Corrections made in place

1. `kernel-driver-port.md` §8 a: "Without it the µKernel never comes up" is now limited
   to the 2021 trees, and (a) is redefined as the precondition for (b) (A.3).
2. `kernel-driver-port.md` §12 step 2: the expected `vermagic` gains `modversions`
   (`CONFIG_MODVERSIONS=y`, as Maemo's module shows).
3. `2026-10-11-gpu-sgx540-groundwork.md` TL;DR 3: "renders … UNVERIFIED" now reads as
   maintainer statements without measurement, and `pvrsgx/` = rc6 + one commit.
4. `2026-10-11-gpu-sgx540-groundwork.md` F2: Maemo's tree is no separate fallback (it is
   rc6 + one commit). Open questions 6 (answered) and 8 (partly answered: 6.18.51 + GCC
   14.2 builds) are annotated.
5. `userspace-blobs.md` overview item and §2.2: "no 2026 test report found" now names the
   IRC statements and the N900 reports. Open question 3 is answered: 1.17 wins, there
   are no `SGX_ABI` symbols on rc6, and the build is a plain `omap2plus_defconfig`.
6. `usecases-roadmap.md` open question 2: the Kconfig choice is answered.
7. `reverse-engineering.md` open question 7: partly answered.

Already consistent, so not edited: the §8 d resolution added by the power-clocks-pm
addendum, which names the same commit `2cd8d74ec61a`, and the `usecases-roadmap.md`
§2.2 values (`CMA_SIZE_MBYTES=32`, `DRM_OMAP=m`).

### A.7 What could not be reproduced

- **Rendering on 6.18.51.1 specifically.** No log, kmscube or glmark2 result exists for
  that build. The two Droid 4 "yes" statements predate the 6.18.51 rebase
  (2026-09-13), and no post-release (2026-09-22 onward) Droid 4 GPU report was found in
  the IRC search (`sgx`, `powervr`, `6.18`, `accel`, `pvrsrvinit`, `kmscube`, `glmark`)
  or on the Forgejo bugtracker (`sgx`, `pvr`, `powervr`, `excalibur`).
- **That the deb was built from exactly `db432aff895b`.** It is consistent: the
  packaging uses that tag scheme, the changelog matches, `CONNECTOR=y`/`PROC_EVENTS=y`
  are in the config (:1805-1806), and the `.ko` imports match the source. But the build
  was not reproduced, and the Forgejo compare between the packaging branch and the tag
  returned no commits (unrelated histories).
- **The Droid 3 reset mechanism**, and whether it applies to 6.18 with `2cd8d74ec61a`.
- **The VMAP root cause as a measurement** (A.3 is reconstructed from commit history).
- **The `pvr_remove()` underflow on hardware** (it is derived from the code).
- **IRC search coverage.** The search endpoint for "pvr" timed out (120 s), so pvr-only
  mentions without "sgx"/"powervr"/"accel" may be missed. The 2026-06-03 "yes" was read
  in the full day log.
- **The Maemo Mesa 24.0.9-sgx1 source (ub open 2)** was not pursued here. #826 (Forgejo,
  2025-11) shows the 25.x rebase blocked because upstream Mesa removed
  `src/gallium/frontends/sgx/` and the legacy DRI interface.

Sources for this addendum:
- https://github.com/maemo-leste/droid4-linux @ `db432aff895bb8a500cba67ce2041df5ad3c36ab`
  (`drivers/gpu/drm/pvrsgx/`, `arch/arm/configs/omap2plus_defconfig`, `mm/vmalloc.c`,
  `drivers/base/power/runtime.c`, `arch/arm/boot/dts/ti/omap/`); commits `2cd8d74ec61a`,
  `084d34836943`, `d4b99f71d31b`, `0ed6addd38b1`, `cd0c7327bf76` via the GitHub API
- https://git.maemo.org/leste-upstream-forks/droid4-linux branch `maemo/excalibur`
  (`c5fab0c095e7`): `debian/rules`, `debian/changelog`, `debian/gbp.conf`
- https://maedevu.maemo.org/leste/dists/excalibur/ (`Release` dated 2026-09-22,
  `main/binary-armhf/Packages.gz`, `main/source/Sources.gz`) and
  `pool/main/o/omap-linux/linux-image-omap_6.18.51.1-1+5m7_armhf.deb`
- https://github.com/openpvrsgx-devgroup/linux_openpvrsgx: `pvrsrvkm-6.18-rc6`
  (`d2f1e031d58a`), `letux/pvrsrvkm-1.17.4948957-v3` (`e5de75568819`), `pvrsrvkm-7.2`
  and `letux/pvrsrvkm-v3` `pvr-drv.c`; commits `beaeda9077c4`, `7e493c1ab5c5`,
  `47ba2d0e4f43`, `a5559de3ed05`, `84db121f1016`, `ff422e4ab0bb`
- IRC logs https://libera.catirclogs.org/maemo-leste/ (days and anchors as tabled in A.5)
- https://github.com/maemo-leste/bugtracker/issues/667; https://git.maemo.org/leste/bugtracker/issues/880,
  /issues/826, /issues/845, /issues/857, /issues/828
- https://leste.maemo.org/Motorola_Droid_4 (last edited 2026-09-27)

---

## Addendum (2026-10-11): Preemption model desk study: which model the DDK needs, boot-image size, and atomic-context exposure

Desk study only: nothing was built, flashed or run on a unit. It closes the code half
of §8 k and open question 4a and leaves the measurement half to Phase 1a.
Short names:
- `km:` = `drivers/gpu/drm/pvrsgx/1.17.4948957/eurasia_km/` at openpvrsgx `pvrsrvkm-6.18-rc6`
  `d2f1e031d58aca97bc4b62367f0d7bef4a7559c3` (fetched file by file from
  raw.githubusercontent.com).
- `k:` = linux-stable `v6.18.48` (git.kernel.org `plain/…?h=v6.18.48`).
- `r19:` = our own kernel package
  `output/ota-v2test-2026-09-30c/linux-google-steelhead-6.18.48-r19.apk`
  (`boot/config`, `boot/System.map`, `boot/vmlinuz`).

### B.1 Result in five lines

1. **`PREEMPT_VOLUNTARY` is the same as `PREEMPT_NONE` for every DDK wait.**
   VOLUNTARY only turns `might_sleep()` into `__cond_resched()` (`k:include/linux/kernel.h:47-51`).
   The DDK busy-waits on `udelay()`, test-and-set and plain loads, and none of them
   reaches `might_sleep()`. It meets the `#error` on paper and changes nothing in the
   driver's own waits.
2. **No wait in the OMAP build needs a preemptible kernel.** Every wait on work done by
   a workqueue sleeps for real (`msleep`, `schedule_timeout`, `mutex_lock`), so it
   works under any model. The busy-waits poll the SGX microkernel or hardware, which no
   workqueue drives. The `#error` (`km:services4/srvkm/env/linux/osfunc.c:126-135`)
   is IMG's blanket rule, not a deadlock anyone traced. It still stays in.
3. **Where full `PREEMPT` matters is latency, not correctness.** The DDK has busy-waits
   that last up to 1-2 s when they time out, which is exactly what a failing
   bring-up does. Under NONE or VOLUNTARY such a wait owns its CPU for that long.
   PREEMPT lets the audio threads in. In return it adds one new DDK hazard, B.2 (iii).
4. **Size is the open risk.** The only published comparison, from 2005, is +0.2 % text
   for VOLUNTARY and +3.5 % for PREEMPT. Applied to our 5 664 032 B `vmlinuz`, that is
   about +11 KB and about +198 KB, against ~92 KB of headroom. Only a host build
   settles it (B.5).
5. **ARM32 on 6.18.48 offers exactly NONE, VOLUNTARY and PREEMPT.** LAZY, DYNAMIC and
   RT are all unavailable, so each A/B arm is a separate kernel build (B.3).

### B.2 The DDK's wait paths, read from code

The OMAP build defines `PVR_LINUX_USING_WORKQUEUES`, `PVR_LINUX_MISR_USING_PRIVATE_WORKQUEUE`
and `PVR_LINUX_TIMERS_USING_WORKQUEUES` (`km:Makefile:124-126`, again at :238). It does
**not** define `SUPPORT_LISR_MISR_SYNC`, so the wait in `km:…/sgx/sgxpower.c:381-393`
for MISR interrupt-count catch-up is compiled out. `SUPPORT_OMAPLFB` is unset
(`km:Makefile:270`, "this is broken and we do not have it in Kconfig"), so no
display-class driver registers command handlers. The only registrations are in
`km:services4/3rdparty/*` (grep `RegisterCmdProcList`), and the "swap chain
destruction" example in the `#error` comment has no workqueue behind it in this build.

The OS primitives:

| Primitive | Implementation | Scheduling point? |
|---|---|---|
| `OSWaitus` | `udelay()` (`km:…/env/linux/osfunc.c:787-790`). ARM `udelay` is `arm_delay_ops.udelay`, a loop or timer busy-wait (`k:arch/arm/include/asm/delay.h:78-84`) | none, under any model |
| `OSSleepms` | `msleep()` (`osfunc.c:793-796`) | sleeps, under any model |
| `OSReleaseThreadQuanta` | `schedule()` (`osfunc.c:734-737`); reached only from emulator code and pdump | sleeps |
| `OSEventObjectWaitKM` → `LinuxEventObjectWait` | drops `gPVRSRVLock`, then `schedule_timeout(100 ms)` (`osfunc.c:3208-3222`, `km:…/env/linux/event.c:388-410`) | sleeps |
| `LinuxLockMutex*` | `mutex_lock*` (`km:…/env/linux/mutex.c:66-76`) | sleeps |
| `OSLockResource` | bare test-and-set, no `preempt_disable` (`osfunc.c:1576-1590`) | none, and the holder stays preemptible under PREEMPT |
| MISR | `queue_work` on `create_singlethread_workqueue("pvr_workqueue")` (`osfunc.c:1230,1303`). In 6.18 that is an ordered **unbound** queue (`alloc_ordered_workqueue` = `WQ_UNBOUND | __WQ_ORDERED`, `k:include/linux/workqueue.h:569-578`), so the work can run on either CPU | — |
| Timers | `queue_work` on `create_workqueue("pvr_timer")` (`osfunc.c:2869,4923`), which is per-CPU bound (`WQ_PERCPU`, `workqueue.h:572-573`) | — |

Every loop that waits, sorted by what ends the wait:

| Site | Waits for | Body | Limit | NONE / VOLUNTARY | PREEMPT |
|---|---|---|---|---|---|
| `km:…/common/queue.c:647-655` (destroy command queue, the "swap chain" case) | queue drained | `OSSleepms(1)` | `MAX_HW_TIME_US` | sleeps; fine | fine |
| `km:…/sgx/sgxutils.c:242-250` (kernel CCB slot) | µkernel read offset | `OSSleepms(1)` | 1 s | fine | fine |
| `sgxutils.c:1894-1906`, `km:…/bridged/bridged_pvr_bridge.c:4053-4064` | sync ops complete | `OSSleepms(1)` | 1 s | fine | fine |
| `sgxutils.c:881-886` (cleanup request) | µkernel `CleanupStatus` | `PollForValueKM(…, 1000 µs, IMG_TRUE)` → `OSSleepms(1)` (`km:…/common/pvrsrv.c:1054-1063`) | 10 s | fine | fine |
| `km:…/sgx/sgxinit.c:702`, `sgxpower.c:262,350`, `sgxutils.c:359`, `km:…/sgx/sgxreset.c:415` | µkernel init, power and invalidate status; SGX registers | `PollForValueKM(…, MAX_HW_TIME_US/WAIT_TRY_COUNT, IMG_FALSE)` = `udelay(50)` | 1 s (2 s at `sgxutils.c:359`) | busy; owns the CPU until the hardware answers | preemptible |
| `sgxinit.c:2940-2947` (`SGXGetMiscInfoUkernel`), `sgxinit.c:3065-3074` (`SGXGetMiscInfoKM`, breakpoint) | µkernel flag | **empty**: a tight loop on a load | 1 s | busy | preemptible |
| `km:…/common/power.c:175-193` (`PVRSRVPowerLock`) | power test-and-set | `OSWaitus(1)` | 1 000 000 iterations | uncontended: `mutex_lock(sPowerLock)` runs first for KERNEL_ID (`km:services4/system/omap/sysutils_linux.c:89-105`), and ISR_ID callers try-lock and return `RETRY` | same |
| `queue.c:1399-1403` (`PVRSRVProcessQueues`) | `sQProcessResource` test-and-set | `OSWaitus(1)` | **none** | the holder (MISR, timer work, or a bridge thread on the force-swap path) never sleeps while holding it, because there are no command handlers. So it cannot be descheduled, and the spinner waits only for the other CPU to finish | **new**: the holder can be preempted while holding, and a spinner on the same CPU then burns until the tick preempts it (10 ms slices at `HZ=100`) |

`LOOP_UNTIL_TIMEOUT` measures time with `OSClockus()` = `jiffies × 10 000` µs
(`osfunc.c:777-782`, `km:…/include/srvkm.h:249-256`). The tick advances it on any model,
so every bounded loop does end. `MAX_HW_TIME_US` = 1 000 000 and
`WAIT_TRY_COUNT` = 20 000 under workqueues (`km:…/system/omap/sysinfo.h:47-55`).

Conclusions from the table:

- (i) No row needs preemption to finish. What each row waits for is either a real
  sleep or the GPU.
- (ii) Under NONE or VOLUNTARY, the `udelay` and tight-loop rows can hold a CPU for up
  to 1-2 s each on timeout. That is the failure mode of Phase 1 and 2 bring-up
  (µkernel not starting, wrong sysconfig). While it lasts, only IRQs and softirqs run
  on that CPU, and per-CPU work (including `pvr_timer` and the kworkers of
  `docs/2026-09-12-the-staircase-the-ceiling-could-not-reach.md`) waits. On a working
  GPU these waits last µs to ms (UNVERIFIED; not measured anywhere).
- (iii) PREEMPT adds the `queue.c:1402` lock-holder-preemption stall. It is harmless
  while the command queues are empty, as they are without a display-class driver, and
  is a Phase 2+ watch item.

### B.3 What 6.18.48 offers on ARM32

- `k:kernel/Kconfig.preempt:17-87`: the choice is NONE, VOLUNTARY, PREEMPT and LAZY.
  LAZY `depends on ARCH_HAS_PREEMPT_LAZY` (:78). `PREEMPT_DYNAMIC` `depends on
  HAVE_PREEMPT_DYNAMIC` (:128). `PREEMPT_RT` `depends on … ARCH_SUPPORTS_RT` (:91).
- `k:arch/arm/Kconfig` selects none of `ARCH_HAS_PREEMPT_LAZY`, `HAVE_PREEMPT_DYNAMIC*`
  or `ARCH_SUPPORTS_RT` (grep; its only RT mention is `depends on HIGHMEM && !PREEMPT_RT`,
  :1218). So **NONE, VOLUNTARY and PREEMPT are the only choices, and each is a
  separate build.** There is no `preempt=` boot switch.
- PREEMPT on ARM32 is IRQ-return preemption: `__irq_svc` checks `TI_PREEMPT` and
  `_TIF_NEED_RESCHED` and calls `preempt_schedule_irq` (`k:arch/arm/kernel/entry-armv.S:230-252`).
- Side effects PREEMPT brings automatically:
  - `PREEMPT_RCU` (`k:kernel/rcu/Kconfig:19-22`, default y if PREEMPT)
  - out-of-line `spin_unlock_irq`, `read_unlock[_irq]` and `write_unlock[_irq]`
    (`k:kernel/Kconfig.locks:140-216`, `depends on !PREEMPTION`), plus
    `UNINLINE_SPIN_UNLOCK` (`Kconfig.preempt:12`). r19 has them all inlined
    (`r19:boot/config:819-823`; `_raw_spin_unlock` is absent from `System.map`).
  - `preempt` in the vermagic (§8 k).
  - `DEBUG_PREEMPT` stays off; it has no default (`k:lib/Kconfig.debug:1347-1359`).
- The built r19 config is `PREEMPT_NONE_BUILD=y`, `TREE_RCU=y`, `HZ=100`, `SMP=y`, and
  `PREEMPT_COUNT` is absent (`r19:boot/config:112-115,137,469,494`). Side finding:
  `kernel/configs/steelhead_defconfig:120` still says `CONFIG_TINY_RCU=y`, which
  `olddefconfig` overrides because `TINY_RCU` needs `!SMP`
  (`k:kernel/rcu/Kconfig:32-34`). It is harmless, but a Phase 1a config diff should
  start from `r19:boot/config`, not from that file.

### B.4 Recommendation for §8 k

`CONFIG_PREEMPT=y`, **provided the B.5 host build shows that it fits**. The reasons:

- B.2 (ii): it bounds the audio damage of a hung DDK busy-wait.
- It is the only model with SGX field precedent: stock, kc1 and Maemo 6.18.51 (A.2).
- By B.1 point 1, VOLUNTARY buys nothing for the driver.

Fallback if PREEMPT does not fit: VOLUNTARY. It is safe by code (no wait needs
preemption), but it has no OMAP4 SGX field user, and a hung spin then stalls a CPU
for up to 2 s. If that happens, the Phase 2 runbook must treat any stall as "unload
the module", not "wait".

### B.5 Boot-image size

- The baseline: r19 `boot/vmlinuz` is 5 664 032 B (LZMA, `CONFIG_KERNEL_LZMA=y`).
  Headroom is 92 KB below the ~6656 KB U-Boot caution at v1.17.0 (`INSTALL.md:85-89`).
  `output/boot.img` dated 2026-10-10 is 6 723 584 B, about 90 KB below that line,
  if it is a staged image (UNVERIFIED which build produced it).
- Published data: Ingo Molnar's commit introducing VOLUNTARY (`f8cbd99bd3a0`,
  2005-06-25, x86) gives text 3 618 774 → 3 626 406 (+0.2 %) for VOLUNTARY and
  → 3 748 414 (+3.5 %) for PREEMPT. No modern ARM32 bloat-o-meter comparison was found
  (searches: lkml, lore, "bloat-o-meter PREEMPT"). Gleixner's 2020 "preempt: Make
  preempt count unconditional" series argues runtime cost, not size.
- Scaled to our image, assuming growth in compressed bytes tracks growth in text:
  VOLUNTARY ≈ +11 KB, well inside the headroom. PREEMPT ≈ +57 KB at 1 % and ≈ +198 KB
  at 3.5 %.
- The 2005 figure probably overstates 6.18. The unlock un-inlining in B.3 removes
  inline code (it makes it smaller), and much of 2005's growth was inline
  `preempt_disable` in lock fast paths that ARM now keeps out of line. Against that,
  every `preempt_enable()` grows a decrement, test and call, and `PREEMPT_COUNT`
  switches on everywhere. **Net: UNVERIFIED. PREEMPT may exceed the 92 KB.**
  It would still be under the 8192 KB partition, but over the U-Boot caution.
- **The definitive measurement:** on the build machine, build the r19 config three
  times (NONE, VOLUNTARY, PREEMPT), changing nothing else. Then compare
  `scripts/bloat-o-meter vmlinux.none vmlinux.{vol,preempt}`, the `vmlinuz` sizes and
  the *staged* boot-image size (`INSTALL.md` rule). It was not done here.

### B.6 Our patch series under preemption: trial-boot candidates

`grep` of the added lines in `kernel/patches/*.patch` (59 files) for spinlocks,
per-CPU and `smp_processor_id`, IRQ masking, delays, sleeps and runtime PM. What
PREEMPT newly exposes is process-context code that relies on not migrating or not
being interrupted between two statements. No such code was found. The candidates
worth watching in a `CONFIG_DEBUG_ATOMIC_SLEEP=y` (+ `CONFIG_DEBUG_PREEMPT=y` on the
PREEMPT arm) trial boot:

| Patch | Code | Context | Risk under PREEMPT |
|---|---|---|---|
| 0014 tps62361 retask | `omap_vc_bypass_scale`-style busy loop, `udelay(10)` retries (patch :287-301); delayed work that polls TWL i2c | kworker | the loop counts iterations, not time, so preemption only delays it. The hand-over already sleeps in i2c under NONE. Low |
| 0015 VC MPU bridge regulator | `omap_voltage_scale_voltage()` from `regulator_set_voltage` (patch :77-94) | cpufreq, under the regulator mutex | VP force-update polls with an iteration timeout. Low; watch `vdd_mismatch` |
| 0048 cpuidle knobs | `keep_core_on_set()` → `omap_set_pwrdm_state(core_pd)` from a sysfs write (patch :100-122) | process context, parameter lock | can now be preempted mid-update while CPU0 idles. Powerdomain state has its own lock (UNVERIFIED). Low |
| 0047/0052/0054-0058 deep idle | `dev->cpu` checks, `udelay(1)` wait for CPU1 (0052 :52) | cpuidle, IRQs off | none from preemption. DEBUG_ATOMIC_SLEEP still checks them for sleeping calls |
| 0053 gpio-omap idle veto | `smp_processor_id()` in the `CPU_PM_ENTER` notifier (patch :93) | idle, IRQs off | none (DEBUG_PREEMPT would flag it if not) |
| 0059 u_audio doze | `local_irq_save` + `spin_lock` pairs (patch :148-189) and `spin_lock_irqsave` | URB completion / process | none; spinlocks disable preemption |
| 0005/0011/0029 AVR LED, 0006 EHCI, 0020 pn544, 0028 pwrseq, 0051 hci_bcm | `mutex_lock`, `msleep`/`usleep_range`, `udelay(2000)` (0006 :144), runtime PM | process / threaded IRQ | none new; 0006's 2 ms `udelay` becomes preemptible |

`DEBUG_ATOMIC_SLEEP` `select`s `PREEMPT_COUNT` and works on NONE as well
(`k:lib/Kconfig.debug:1568-1572`). So run it on today's NONE kernel first (arm D0
below). That separates sleeping-in-atomic bugs we already have from anything
PREEMPT exposes.

### B.7 Audio and preemption: what the repo knows

No earlier note measures preemption against audio. The task framing names
McBSP/PipeWire, but the shipping path is PulseAudio:
- **The audio threads are not real-time.** All six PulseAudio IO threads are
  `SCHED_OTHER`, nice 0, and musl stubs `alsaloop`'s `sched_setscheduler`
  (`docs/2026-09-12-the-staircase-the-ceiling-could-not-reach.md:100-111`). That note
  attributes late wake-ups of 16-76 ms to "nothing runs real-time" plus a kworker
  eating a quarter of cpu0.
- **The audio data path is not scheduled.** The McBSP/sDMA refill is hardware and
  hardirq timed (`docs/2026-07-08-audio-crackle-dma-contention.md:30-45`), so no
  preemption model reaches it.
- **Expectation (UNVERIFIED reasoning):** PREEMPT can only shorten how long a woken
  `SCHED_OTHER` audio thread waits behind kernel code on its CPU. It should not raise
  XRUNs. It may change context-switch counts, and through them the C-state mix, which
  is why the idle arm matters.

### B.8 Phase 1a in measurement-protocol terms

Order:

| Step | Arm | Kernel | What it decides |
|---|---|---|---|
| 0 | host only | r19 config × {NONE, VOLUNTARY, PREEMPT}, nothing else changed | size (B.5); vermagic; `olddefconfig` diff = only the B.3 side effects. **Stop PREEMPT here if the staged image misses the caution** |
| 1 | **D0** (new, trial slot, not shipped) | NONE + `DEBUG_ATOMIC_SLEEP` | existing sleeping-in-atomic bugs: boot plus one A0m window. Expect zero splats |
| 2 | **D1** (new, trial slot, not shipped) | PREEMPT + `DEBUG_ATOMIC_SLEEP` + `DEBUG_PREEMPT` | anything PREEMPT exposes in B.6: boot, an A0m window, a deep-idle window, one cpufreq sweep |
| 3 | **P1a** (as in `drafts/measurement-protocol.md` §2) | clean PREEMPT (or VOLUNTARY if step 0 rules PREEMPT out) | idle (against A0) and music (against A0m); every arm twice, A0 again last |

P1a metrics (protocol §3 instruments, plus four additions):

- C3 share, idle exits/s, 350 MHz residency, VDD_MPU against the OPP with no
  `vdd_mismatch`, die °C. Thresholds as protocol §5 *proposed*.
- With music: kernel audio errors Δ0, PulseAudio underruns Δ0, ALSA `RUNNING`
  throughout.
- *Added:*
  - `/proc/stat` `ctxt` delta per second (the cost of preemption itself)
  - the dmesg strings `BUG: sleeping function called from invalid context`,
    `using smp_processor_id() in preemptible`, `scheduling while atomic`,
    `rcu_preempt detected stalls` (all must be zero)
  - boot-to-`multi-user.target` time
  - the vermagic string
- The staircase note's late-wake-up measure, if its instrumentation is reusable
  (UNVERIFIED that it is scripted).

The compile gate's "test seen failing first" is unchanged: the `#error` on the r19
config.

### B.9 Corrections made in place

1. `kernel-driver-port.md` §8 k: "That is a real correctness requirement, not a build
   quirk" is now refined to "a blanket rule, not a traced deadlock" (B.2). "Do not
   patch out the `#error`" stands.
2. `kernel-driver-port.md` §8 k: the VOLUNTARY UNVERIFIED is annotated as answered
   from code (B.2-B.3).
3. `kernel-driver-port.md` open question 4a and the "Could not reproduce" item:
   annotated (code half answered, measurement half open).
4. `2026-10-11-gpu-sgx540-groundwork.md` §8 open question 5: annotated with B's answer
   and the size caveat.
5. `re/stock-sysconfig.md` row 26: "The DDK's locking assumes preemption points" is
   annotated as not borne out by the code. Its recommendation 4
   (`PREEMPT_VOLUNTARY=y`) is annotated as superseded by B.4.

Not edited: groundwork TL;DR 4 and Phase 1a, `reverse-engineering.md` row 26, and §9.
They say "VOLUNTARY or PREEMPT, decided in Phase 1a", which still holds. B.8 refines
the order without contradicting them.

### B.10 What could not be reproduced

- **The zImage growth.** It is an extrapolation from 2005 x86 data. No ARM32 6.x
  number was found, and no host build was run (B.5).
- **That a DDK busy-wait ever runs long on a working GPU.** That is inferred from the
  timeout constants, not observed.
- **Whether the TI ti443x UM ever drives the `queue.c` command-queue path** without a
  display-class driver. B.2 (iii) assumes the queues stay empty.
- **Powerdomain locking in `omap_set_pwrdm_state` (0048 row).** Not re-read in 6.18.48.
- **The DDK sources were read file by file at `d2f1e031`** (167 `.c`/`.h` under
  `services4/srvkm`, `services4/system/omap` and `services4/3rdparty`), not from a
  clone. `km:Makefile` and `pvrsgx/Kconfig` were read whole.

Sources for this addendum:
- https://github.com/openpvrsgx-devgroup/linux_openpvrsgx @ `d2f1e031d58aca97bc4b62367f0d7bef4a7559c3`
  (`drivers/gpu/drm/pvrsgx/Kconfig`, `1.17.4948957/eurasia_km/Makefile`, `services4/srvkm/**`,
  `services4/system/omap/**`, `services4/3rdparty/**`)
- https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux.git `v6.18.48` (the `k:` prefix): `k:kernel/Kconfig.preempt`,
  `k:kernel/Kconfig.locks`, `k:kernel/rcu/Kconfig`, `k:lib/Kconfig.debug`, `k:arch/arm/Kconfig`,
  `k:arch/arm/include/asm/delay.h`, `k:arch/arm/kernel/entry-armv.S`, `k:include/linux/kernel.h`,
  `k:include/linux/smp.h`
- https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git/patch/?id=f8cbd99bd3a023db8d6356d19a5f6f539d367327
  ("sched: voluntary kernel preemption", size table)
- https://lkml.iu.edu/hypermail/linux/kernel/2010.3/08892.html ("preempt: Make preempt count unconditional")
- repo: `kernel/patches/*.patch`, `kernel/configs/steelhead_defconfig:99-102,120`, `INSTALL.md:85-89`,
  `output/ota-v2test-2026-09-30c/linux-google-steelhead-6.18.48-r19.apk`, the two audio notes named in B.7

## Addendum (2026-10-11): Read the goldelico letux-pvrsrvkm-1.17.4948957-v4 and letux-6.18.y branches

Research only. Nothing was built, flashed or installed, and no device was touched.
The fetches went into an empty scratch repo (`git fetch --filter=blob:none`, shallow)
and were read with `git log`, `git range-diff`, `git diff-tree` and `git show`. Nothing
from them was executed.

**Result.** Neither branch changes the KM base or the patch list.
- `-v4` is `-v3` rebased unchanged onto Linux 7.3-rc6, plus three warning fixes.
- `letux-6.18.y` carries the rc6 1.17 tree byte for byte.
- The pin (`pvrsrvkm-6.18-rc6` @ `d2f1e031d58a`), patches (a)-(k) and fallback F2 stand.
- One hygiene commit is worth taking: `3f5f503efcc6` (`MODULE_DESCRIPTION`), which
  silences a modpost warning that 6.18 prints for every module without one.

### C.1 How it was read

1. **`git ls-remote https://git.goldelico.com/letux-kernel.git`** (27 621 refs). It gives
   the full heads:

| Ref | Head (full, from ls-remote) |
|---|---|
| `letux/pvrsrvkm-1.17.4948957-v4` | `3f5f503efcc6dc01126af2541c19af17c1e6605f` |
| `letux/pvrsrvkm-1.17.4948957-v3` | `e5de755688193794ecbbcd6df2bf32fd3dee122a` |
| `letux/pvrsrvkm-1.17.4948957` | `af3a1ed28eb5b447e62164d79cd49394e50d5d71` |
| `letux-6.18.y` (= tag `letux-6.18.55`) | `c118c403ccb8f3a02753f5bf7bef9076510be775` |
| `pvrsrvkm-6.18-rc6` | `d2f1e031d58aca97bc4b62367f0d7bef4a7559c3` |
| `letux/pvrsrvkm-v3` | `1f46f84a7055361156bfbf269219dd47d1d92c2d` |
| `letux/omap-sysc-prm-gfx` | `9c2210e6516215cef32bbcaa2f1dd5929f63e275` |
| `letux/omap-pvr-soc-glue-v10` | `6ad3df74661828ff673134730e6c17621c5048da` |

   The last three heads differ from the openpvrsgx GitHub heads in §3.1 (`5c31c028e783`,
   `57c9a409ba70`). They are the 2026-10-04 rebase onto 7.3-rc6 (committer dates read
   from the mirror). They do not matter for a 6.18 base.
2. **Dumb HTTP is impractical.** `objects/info/packs` lists 8 packs. Every wanted commit
   sits in one 3 379 641 633-byte pack (`pack-0b2f4e35…`, repacked 2026-10-06), and that
   pack's `.idx` alone is 708 444 148 bytes. The 7 small packs (`git show-index` on their
   `.idx`) contain none of the heads above. An alternates store cannot help, because the
   dumb walker downloads whole packs. It was not attempted.
3. **GitHub mirror `goldelico/letux-kernel`** (not a fork, last push
   2026-10-07T22:22:58Z per the search API). All eight heads above match `ls-remote`
   exactly (`gh api repos/goldelico/letux-kernel/branches/<ref>`). Everything below
   comes from this mirror: `-v3`/`-v4` shallow since 2026-06-01, and `letux-6.18.y` and
   `pvrsrvkm-6.18-rc6` at depth 1, all blobless with blobs fetched lazily.

### C.2 `-v4` against `-v3`

- **Bases** (first commit on the first-parent chain committed by Linus Torvalds):
  - `-v3`: `8d3ae59288f1` "Linux 7.2", 152 topic commits.
  - `-v4`: `a90ee4305c4a` "Linux 7.3-rc6" (2026-10-04), 155 topic commits.
- **`git range-diff 8d3ae59288f1..v3 a90ee4305c4a..v4`**: 152 pairs `=` (identical
  patches) and 3 new commits. Nothing was dropped or reworded. All three new commits are
  by H. N. Schaller, authored 2026-08-31 and committed 2026-10-04:

| Commit | Change | Effect on an OMAP4 SGX540-120 build on 6.18.48 |
|---|---|---|
| `c0c242a1b6007303cc796d2aed4d87c92bc015bc` "fix warnings in sgxinit.c" | `static IMG_BOOL bFirstTime` and its reset in `SGXInitialise()` wrapped in `#if !defined(SGX_FEATURE_MP)` | none: SGX540 is not MP, so the code is unchanged for us |
| `f16e87da5b099313fbce1cbf7a8d3fa720263ccb` "fix warnings in sgxinfokm.h" | the `#if defined(SGX_DYNAMIC_TIMING_INFO)` guard around the `SysGetSGXTimingInformation()` prototype commented out (`// #if`) | none: the in-tree build defines `SGX_DYNAMIC_TIMING_INFO` (rc6 `eurasia_km/Makefile:290`; stock does too, stock-ground-truth.md:176) |
| `3f5f503efcc6dc01126af2541c19af17c1e6605f` "fix warnings in pvrmodule.h" | adds `MODULE_DESCRIPTION("DRM driver for PVR SGX")` to `include4/pvrmodule.h` | silences `missing MODULE_DESCRIPTION()`. In v6.18 `scripts/mod/modpost.c:1610-1611` warns unconditionally (read at tag `v6.18`; not re-read at `v6.18.48`) |

- **OMAP paths.** `git log a90ee4305c4a..v4 -- …/services4/system/omap pvr-drv.c` lists
  30 commits, all with `=` partners in `-v3`. So `-v4` brings no new runtime-PM, APM,
  sysconfig or 6.18-API change. What §3.2 and Addendum A.1 say about `-v3` applies to
  `-v4` unchanged.

### C.3 `letux-6.18.y`

- Head `c118c403ccb8` "auto-update letux_defconfigs for 6.18.55", committed
  2026-10-03 13:45 +0200. Its Makefile reads 6.18.55.
- **It merges the pvrsgx tree.** `drivers/gpu/drm/pvrsgx/` holds all 16 DDK
  directories plus `generic`. The GitHub compare `d2f1e031…c118c403` says `diverged`,
  with merge base `6a23ae0a96a6` (Linux 6.18-rc6). So letux-6.18.y does not contain the
  rc6 merge commit itself. It re-merges the topics onto the stable series (UNVERIFIED
  which topic heads, because the fetch was depth 1).
- **Tree identity against `pvrsrvkm-6.18-rc6`** (`git rev-parse <ref>:<path>`):
  - `pvrsgx/1.17.4948957`: `006844ec1ebc…` on both
  - `pvrsgx/generic`: `4ff84586bcd1…` on both
  - `Kconfig`, `Makefile`, `pvr-drv.c`: identical
  - the only differences under `pvrsgx/` are six files in `1.14.3759903/` (not our DDK)
  
  So letux-6.18.y does **not** carry Maemo's `2cd8d74ec61a` (runtime-PM autosuspend),
  `ff422e4ab0bb` (fence count) or the 1.17 VMAP flag in `eurasia_km/Makefile`.
- **OMAP4 SoC files.** `omap4.dtsi`, `omap4460.dtsi`, `omap443x.dtsi` and
  `omap4-l4.dtsi` are blob-identical to rc6. So Letux does not set the 4460 SGX clock
  either, and draft 0062 is still ours to carry.
  - The changes in `ti-sysc.c`, `mach-omap2/control.c`, `pm44xx.c`, `cpuidle44xx.c` and
    `pdata-quirks.c` were all read. They are `of_node_put` leak fixes, an AM33 timer
    quirk, dra7 cpuidle, and the removal of a Pandora GPIO table. None touches the GPU,
    `prm_gfx` or OMAP4 idle.
- **`letux_defconfig`** (lines 110-115, 5158-5172): `CONFIG_PREEMPT=y`, `CONFIG_SGX=y`,
  `CONFIG_PVRSGX_1_17_4948957=y`, `CONFIG_SGX_DRM=y`, `CONFIG_SGX_OMAP=m`.
  - That is one more full-PREEMPT precedent for §8 k, after stock, kc1 and Maemo
    6.18.51 (B.4).
  - It is a configuration, not a published build log. That it compiles on 6.18.55 is
    UNVERIFIED (the defconfig auto-update suggests a `make` ran, but no artifact was
    read).

### C.4 Effect on the plan

| Item | Change |
|---|---|
| KM pin `pvrsrvkm-6.18-rc6` @ `d2f1e031d58a` | none. letux-6.18.y confirms the same 1.17 tree is what Letux carries on 6.18 stable |
| (a)-(k) | none. `-v4` adds no OMAP4 fix; letux-6.18.y adds none of (a)-(i) |
| hygiene | optional cherry-pick `3f5f503efcc6` (one line, removes a modpost warning, in keeping with "every build warning is ours"). The other two `-v4` commits are no-ops for SGX540 |
| F2 | unchanged. A 7.x-based fallback is now `-v3` (7.2) or `-v4` (7.3-rc6), which have the same content |
| VMAP flag | `PVR_LINUX_MEM_AREA_USE_VMAP ?= 1` exists in `eurasiacon/build/linux2/config/core.mk:596` (rc6 and letux-6.18.y). That is the DDK's own out-of-tree build system. The in-tree Kbuild `eurasia_km/Makefile` neither includes `core.mk` nor sets the flag (grep), so §3.1's "still not in the 1.17 Makefile" holds |

### C.5 Corrections made in place

1. §1 item 2: "a `-v4` exists only on git.goldelico.com" now names the GitHub mirror
   and what `-v4` is.
2. §2 sources (git.goldelico.com bullet) and §3.1 goldelico list: "not on GitHub" is
   narrowed to the openpvrsgx repo. The letux-6.18.y inference is annotated as answered.
3. Open question 3 and the "Could not reproduce" bullet: annotated as answered.
4. `2026-10-11-gpu-sgx540-groundwork.md`, the KM-branch row of the corrections table:
   "exist only on git.goldelico.com and could not be read" is replaced by the finding.
5. Same note, open question 7: annotated as answered. F2: letux-6.18.y is noted as no
   separate fallback. The "could not be reached" sources line points to the mirror.

Not edited: `reverse-engineering.md` makes no statement about `-v4` or letux-6.18.y.
`re/stock-sysconfig.md:798` only names the remote. `userspace-blobs.md` §2.6 concerns
the Letux userspace repo, which was not part of this task.

### C.6 What could not be reproduced

- **Dumb-HTTP read from git.goldelico.com itself.** Not done, because of the 3.4 GB pack
  (C.1). The mirror is trusted only because all eight heads match the server's
  `ls-remote` byte for byte. A force-push between the two reads would show as a
  mismatch, and none was seen.
- **Which topic heads letux-6.18.y merged.** The depth-1 fetch has no history. Only the
  tree identity of `pvrsgx/` is established.
- **What the six `1.14.3759903/` differences are.** They were listed, not read: that DDK
  does not build OMAP4.
- **That `letux-6.18.y` builds or renders on any OMAP4.** No build log, artifact or
  report was found or looked for in this pass.
- **The modpost warning on 6.18.48.** The guard was read at `v6.18`, not at the stable
  point release.

Sources for this addendum:
- `git ls-remote https://git.goldelico.com/letux-kernel.git` (2026-10-11);
  `https://git.goldelico.com/letux-kernel.git/objects/info/packs` and `HEAD` on each
  `.pack`/`.idx` (sizes, Last-Modified)
- https://github.com/goldelico/letux-kernel: refs
  `letux/pvrsrvkm-1.17.4948957-v3`, `-v4`, `letux-6.18.y`, `pvrsrvkm-6.18-rc6` (hashes
  in C.1). The compare API `d2f1e031d58a...c118c403ccb8` gave `diverged`, ahead 23 159,
  behind 568, merge base `6a23ae0a96a600d1d12557add110e0bb6e32730c`
- https://github.com/torvalds/linux `v6.18`: `scripts/mod/modpost.c:1610-1611`
