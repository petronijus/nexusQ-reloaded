# SGX540 groundwork 7/7: Use cases, value, precedent and the phased roadmap

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

*Original working title: Nexus Q SGX540: use cases, value, precedent and a phased roadmap*

Workstream 07 of the GPU groundwork. Written 2026-10-11 (Europe/Prague). This is research
and planning only. Nothing here was built, flashed, committed or run on a device.

Evidence conventions used below:

- `repo:path:line` is a file in `the repository root` at the
  clean `main` tip `dc988b9`.
- `stock:` is the stock Nexus Q firmware under `reverse-eng/` (gitignored), read with
  `strings`, `kallsyms.txt` and `debugfs -R` against `system.raw.img`. Nothing was mounted.
- `web:` is a URL I opened on 2026-10-10/11, with what I saw there. Commit hashes and dates
  come from the GitHub or GitLab APIs, or from a `git clone --filter=tree:0` of pmaports
  made today.
- **UNVERIFIED** marks inference or estimates, with the reasoning given.

---

## TL;DR

1. **The strongest precedent is now an exact match for our kernel line.** Maemo Leste
   *excalibur* ships `linux-image-omap 6.18.51.1-1+5m7`, which contains
   `pvrsrvkm_omap4_sgx540_120.ko` (DDK 1.17.4948957). It is paired with
   `sgx-ddk-um-ti443x 1.17.4948957+leste15` and an SGX-patched Mesa `24.0.9-sgx1`
   (web: maedevu.maemo.org excalibur `Packages.gz` and `Contents-armhf.gz`). The Droid 4
   wiki page says "Kernel 6.18 LTS, 3D acceleration: Yes (closed)" (last edited
   2026-09-27). The kernel source is `maemo-leste/droid4-linux` branch
   `leste/maemo-6.18.y` (Makefile 6.18.51, tip `db432aff895b`, 2026-09-22), which is
   exactly the tag `maemo-kernel-6.18.51.1` (the shipped 6.18.51.1). It carries
   `drivers/gpu/drm/pvrsgx/` for every DDK version. *(Corrected 2026-10-11: an earlier
   draft named the sibling branch `leste/maemo-6.18.y-glm`, which is 6.18.39, tip
   `858f1778b7b0`, 2026-07-29, and is not what excalibur ships.)* The June note named a 6.15-rc backport
   as the main kernel risk. That risk has mostly gone: a working 6.18 integration exists
   to diff against.
2. **The June note's userspace choice is outdated.** `maemo-leste/pvr-omap4` (DDK 1.9.x)
   has been superseded on OMAP4 since 2021-11 (`sgx-ddk-um` initial import 2021-11-15,
   `pvr-omap4-utils` conflict added 2021-11-23) by `maemo-leste/sgx-ddk-um`
   (`sgx-ddk-um-ti443x`, DDK **1.17.4948957**). That package `Conflicts`/`Replaces`
   `pvr-omap4` and requires a droid4 kernel ≥ 5.15. **Recommendation: DDK 1.17.4948957
   end to end. Do not use 1.9.**
3. **postmarketOS (rename to Nura announced around 2026-09-27) is not a precedent we can
   reuse packages from.**
   - pmOS shipped SGX540 acceleration exactly once: on the Galaxy Tab 2 7.0
     (`samsung-espresso3g`, OMAP4430; renamed `samsung-espresso7` on 2022-11-22), from
     2021-11-22 to 2022-03-24 (commit dates; MR 3027 merged 2022-03-26). It used the
     `tmlind/linux_openpvrsgx` 5.15.2 kernel, `CONFIG_PVRSGX_1_17_4948957=y`,
     `sgx-ddk-um-ti443x`, `mesa-pvr-dri-classic`, and a **patched wlroots** for phosh and
     sway (not in pmaports). X-based desktops did not work (MR !1868 description; not
     re-checked specifically for espresso3g).
   - pmOS then decided against shipping PowerVR userspace (issue #1316, closed
     2022-01-25). It removed `mesa-pvr-dri-classic` and `sgx-ddk-um` on 2022-05-27
     (MR 3162).
   - The Galaxy Nexus (maguro) and Droid 4 (maserati) ports are archived and ran
     *downstream* 3.0.x kernels. Neither ever had mainline SGX in pmOS. (The archived
     maserati kernel APKBUILD does build the downstream Android `pvr-source/eurasiacon`
     KM from LineageOS `android_hardware_ti_omap4`, but the device package pulls in no
     SGX userspace.)
4. **Modern Wayland compositors will not start on the SGX blobs unmodified.**
   - wlroots 0.19.0 and 0.20.2 (Alpine's labwc 0.20.2 links wlroots 0.20) hard-fail
     without `GL_EXT_unpack_subimage`.
   - Weston 16.0.0 also hard-fails without it on GLES < 3.0.
   - The SGX blobs did not expose that extension, which is why pmOS needed a wlroots
     patch (MR 2573, 2021). This is likely, not proven: the MR 1868 text and the patch
     imply it, but nobody has dumped the leste15 + Mesa 24 extension string.
   - wlroots 0.20.2 also hard-requires `EGL_EXT_image_dma_buf_import`,
     `GL_EXT_texture_format_BGRA8888`, `EGL_KHR_no_config_context` (or
     `EGL_MESA_configless_context`) and `EGL_KHR_surfaceless_context`
     (`render/gles2/renderer.c`, `render/egl.c` at tag 0.20.2).
   - Patching wlroots would be a frozen fork, which the user's rules forbid. The roadmap
     instead puts a small **`LD_PRELOAD` GL shim** next to upstream (a proposal, not
     verified). It also puts a **direct KMS/GBM client (no compositor)** ahead of any
     compositor work.
5. **The best value is the stock HDMI music visualizer, and its shaders survive.**
   - The stock `Visualizer.apk` contains **31 GLSL ES 1.0 shader source files** in
     `res/raw/` (11 vertex `*_v`, 20 fragment `*_f`), plus `particle.png`,
     `particle2.png` (64×64), `muted.png` (100×100) and the point-morph models (stock:
     `/app/Visualizer.apk`). *(Corrected 2026-10-11: an earlier draft said 25.)*
   - Today the Q renders those effects only on the 32-LED ring. Over HDMI it shows a
     **black screen**, even while HDMI is held lit for audio (`nq-hdmi hold`,
     `docs/2026-09-20-...`).
   - Users with HDMI receivers and TVs exist (GitHub issue #5). A visualizer on a screen
     that is already lit is a user-visible feature, not a demo.
6. **What GPU work does *not* buy.**
   - A now-playing/album-art screen is static. It needs no GPU: omapdrm already exposes
     4 DSS planes with zpos, alpha, premultiplied blend and VID scaling, so it can be
     done today.
   - A browser is not a realistic target.
   - Desktop acceleration means compositing only. Qt widget rendering stays in software.
7. **There are device-specific risks the June note did not have.**
   - The boot image has about 94 KB of headroom, so the module must live on the rootfs.
   - Kernel OTA keeps per-release module trees, so the GPU module must be built *with*
     the kernel package.
   - Audio crackle on this board was **EMIF/L3 DMA contention** (closed with patch 0041),
     so every GPU phase must measure McBSP underflows and XRUNs.
   - Thermal: 102.8 °C was measured under sustained load.
   - Reading registers of an unclocked IP takes an external abort (seen on the DSS), so
     there is no `/dev/mem` probing of GFX.
   - Alpine Mesa 26.2.4 has no glvnd, so the SGX Mesa must live in a **private prefix**.
     It must not replace the system Mesa.
   - **SGX clock: mainline sets it for the 4430 but not for the 4460.** Mainline
     `omap443x.dtsi` (v6.18.48, lines 78-86) assigns the SGX mux to `dpll_per_m7x2_ck`
     at 307.2 MHz ("like droid4 stock v3.0.8 Android kernel"); Maemo's 6.18.51.1 tree has
     the same block. `omap4460.dtsi` (which steelhead includes) has no such block, and our
     patch 0003 adds none. So the Q inherits whatever mux the boot chain left, which is
     exactly the Droid 4 "too low clock → artifacts" situation Maemo fixed. Every Maemo
     SGX540 device (Droid 4, Bionic) is a 4430, so the 4460 clock setup is untested by
     anyone we know of.
8. **The roadmap runs Phase 0 to Phase 6** (section 6), with a go/no-go gate after Phase 2.
   Rough total is 8–14 engineer-weeks to an OTA-shipped GLES2 visualizer. An accelerated
   desktop (Phase 5) is a separate, optional and high-risk 2–4 weeks.

---

## 1. Corrections to `docs/2026-06-19-gpu-sgx540-acceleration-research.md`

The June note was written on 6.12.12. These are the points that are now wrong or stale.

| June note says | Now (2026-10-11) | Evidence |
|---|---|---|
| Kernel delta 6.12 vs 6.15 is the main kernel risk; letux branch `pvrsrvkm-1.17.4948957` "actively rebased onto 6.15-rc5" | That branch's tip is **2025-05-04** (`584dd33a1557`, "fix for 6.15-rc1") and is effectively stale. The active branch is **`letux/pvrsrvkm-1.17.4948957-v3`** (tip `e5de75568819`, 2026-08-21). The integration branch `linux+pvrsgx` is a merge of all DDK branches into **7.2.0** (`2342ce92fdde`, 2026-08-26). Maemo's `droid4-linux` has two 6.18 branches: `leste/maemo-6.18.y` = **6.18.51** (`db432aff895b`, 2026-09-22, = tag `maemo-kernel-6.18.51.1`, the shipped build) and `leste/maemo-6.18.y-glm` = 6.18.39 (`858f1778b7b0`, 2026-07-29). Both carry `pvrsgx/`. Maemo excalibur ships a built **6.18.51** with the OMAP4 SGX540 module. | web: GitHub API `openpvrsgx-devgroup/linux_openpvrsgx` branches; `maemo-leste/droid4-linux` branches, tags and Makefile; maedevu excalibur `Contents-armhf.gz` |
| Userspace = `maemo-leste/pvr-omap4` DDK 1.9.x | `pvr-omap4` was last pushed 2022-02-01 (`1.9.0.8.1.3-1`, 2020-05-27). It is **replaced by `maemo-leste/sgx-ddk-um`** (`sgx-ddk-um-ti443x 1.17.4948957+leste15`, 2025-01-08), which `Conflicts/Replaces: pvr-omap4`. | web: `maemo-leste/sgx-ddk-um` `debian/control`, `debian/changelog` |
| Mesa path = `mobiaqua/mesa-sgx` 22.3 | Three options now exist: mobiaqua `mesa-22.3-sgx` (last push 2024-11-22); Maemo's fork `maemo-leste-upstream-forks/mesa` (gallium `pvr` and `sgx` frontends; daedalus 22.3.6, excalibur branch tip 2025-12-05 on the GitHub mirror); and Maemo's built **`24.0.9-sgx1+5m7`** packages in excalibur, whose source is Forgejo tag `powervr-24.0.9` (`72c93be7aa29`, 2025-12-27) — the recommended one [ub Addendum §A.5]. | web: GitHub API; maedevu `Packages.gz` |
| "Single core … EGL/driver overhead still runs on the one A9" | **Two cores since v1.2.0** (2026-06-22). | repo:PLAN.md:2355 |
| Recommends "1.17 preferred, or 1.9" | Stock ran **DDK 1.8@785978** (Android, bionic). The modern pairs are 1.17 KM ↔ 1.17 UM. 1.9 has no maintained OMAP4 UM for musl or glibc. | stock: `strings vmlinux.bin` → `CustomerGoogle_Android_ogles1_ogles2_GPL sgxddk 18 1.8@785978` |
| pmOS MR !1868 is "the musl recipe" | It was merged (2021-02-23 per API `merged_at`; packages added 2020-12-09 and 2021-01-03) and **removed 2022-05-27** (MR 3162) after a policy decision. It is still useful as a *recipe* (gcompat/`libc6-compat`, `dlsym` loading) but not as a package source. | pmaports history: `cecfb418`, `023f8cc1`; issue #1316 |
| *(The June note states no resolution; this row is an addition, not a correction. An earlier draft said the note implied 1080p, which it does not.)* | HDMI is **capped at a 75 MHz pixel clock** (patch 0010: `mode->clock > 75000` is rejected). That leaves 74.25 MHz modes: 1280×720@60, and also 1920×1080@24/25/30 if the sink offers them (CEA 1080p30 is 74.25 MHz, so it passes the filter). 1080p30 has 2.25× the pixels of 720p and is untested on the Q. For a GPU or SW visualizer, 1280×720@60 is the sensible ceiling, not a hard one. | repo:kernel/patches/0010-drm-omapdrm-hdmi4-cap-pixel-clock-steelhead.patch:43; grep of the June note for 1080/1920/resolution finds nothing |
| Firmware: "`sgx540_*.fw` microkernel must ship alongside the module" | The excalibur `sgx-ddk-um-ti443x` file list contains **no separate firmware file**: only `pvrsrvctl`, the `lib*_PVR_MESA`, `libdbm`, `libglslcompiler`, `libpvr2d`, `libpvr_dri_support`, `libsrv_init`, `libsrv_um`, `libusc`, `libPVRScopeServices` `.so` files and the changelog. In DDK 1.x the microkernel is loaded by the UM init path; which library embeds it is UNVERIFIED. | web: maedevu excalibur `Contents-armhf.gz` |
| pmOS MR !1868 used "the PVR fork of Mesa" = mobiaqua `mesa-sgx` | MR 1868's `mesa-pvr-dri-classic` was Mesa **20.3.2** from `freemangordon/mesa` (commit `5bd40a453e14`), url `xc-racer99/mesa-pvr`, not mobiaqua. | pmaports `023f8cc1^:main/mesa-pvr-dri-classic/APKBUILD` |

---

## 2. Precedent survey: SGX540 (and close relatives) on mainline or near-mainline kernels

### 2.1 Summary table

| Device (SoC) | Project | Kernel | DDK KM ↔ UM | What ran accelerated | Status 2026 | Evidence |
|---|---|---|---|---|---|---|
| Motorola Droid 4 (OMAP4430, SGX540 rev 1.2.0) | **Maemo Leste** | mainline + patches; **6.18 LTS** in excalibur (`linux-image-omap 6.18.51.1-1+5m7`) | 1.17.4948957 ↔ `sgx-ddk-um-ti443x 1.17.4948957+leste15` | hildon-desktop on **X11** with Glamor (GLES2), **2D EXA** in X via the PVR drivers (2022-04), GLES1 re-enabled in Mesa (2023-01), clutter with the buffer-age extension | **Active, shipping**. Wiki page edited 2026-09-27 | web: leste.maemo.org/Motorola_Droid_4 (kernel "6.18 LTS", 3D "Yes … closed driver"); maedevu excalibur `Contents-armhf.gz` lists `lib/modules/6.18.51/.../pvrsrvkm_omap4_sgx540_120.ko`; blog posts 2020-12-27, 2022-04-16, 2023-01-12 |
| Droid 3 / Droid Bionic / Nokia N900 (OMAP3 SGX530) | Maemo Leste | same kernel | 1.17 ↔ `sgx-ddk-um-ti343x` | same X11 stack | Active | blog 2022-04-16 ("available immediately for the Nokia N900, Motorola Droid 3, Motorola Droid 4 and Droid Bionic") |
| Samsung Galaxy Tab 2 7.0 (`samsung-espresso3g`, OMAP4430) | **postmarketOS** | `tmlind/linux_openpvrsgx` **5.15.2** (commit `6ba3430a6fad`), `CONFIG_PVRSGX_1_17_4948957=y` | 1.17 ↔ `sgx-ddk-um-ti443x` (TI `omap5-sgx-ddk-um-linux` commit `551665bf9c32`) | phosh / sway with **patched wlroots**; X11 broken | **Removed 2022-03-24** (commit date; MR 3027 merged 2022-03-26, "remove GPU support and hacks"; kernel moved to mainline 5.17). Renamed `samsung-espresso7` on 2022-11-22 (`c45c27008`); today depends on `linux-postmarketos-omap` (7.1.5) with software rendering | pmaports commits `b2d88000`, `1c1dbf23`, `865ff8dc`, `ed90e5da` |
| Galaxy Nexus (`samsung-maguro`, OMAP4460, same SoC as the Q) | postmarketOS | **downstream** LineageOS tuna **3.0.31** | Android (bionic) only | weston on framebuffer (2017) | **Archived** in pmaports (`device/archived/device-samsung-maguro`). A 2019 mainline attempt (drebrez) first panicked on clock setup; with that code commented out it reached initramfs, and further work brought up USB, storage, battery/charging, buttons, sensors, display and earphone audio. No GPU. *(Corrected 2026-10-11: an earlier draft said it "only reached initramfs".)* | pmaports tree today; nura.eco/blog/2019/06/23/two-years |
| Galaxy Nexus toro / tuna | postmarketOS | — | — | — | No `samsung-toro` or `tuna` device package exists in pmaports (checked the tree at `862c5af2`, 2026-10-09). No mainline DTS exists for tuna in 6.12 | pmaports `git ls-tree`; `build/linux-6.12.12/arch/arm/boot/dts/ti/omap/` |
| Motorola Droid 4 (`motorola-maserati`) | postmarketOS | **downstream 3.0.8** | downstream Android KM built from LineageOS `android_hardware_ti_omap4` `pvr-source` (`omap4430_android`); no UM packaged | — | **Archived** | pmaports `device/archived/linux-motorola-maserati/APKBUILD` (`pkgver=3.0.8`, `_pvr_builddir`) |
| Pandaboard / Pandaboard ES (OMAP4430 / **OMAP4460**) | TI/Linaro Ubuntu era; Maemo used Panda ES as a test platform | downstream TI kernels (2012–2013); mainline DTS `omap4-panda-es.dts` exists | TI Graphics SDK 4.x | X11/EGL demos (TI era) | **No 2024–2026 SGX-on-mainline report found** for Panda. No `ti-pandaboard` package exists in pmaports | leste.maemo.org/Motorola_Droid_4/PowerVR (2020-02-17 stub: "Pandaboard ES … close match"); pmaports tree. UNVERIFIED that anyone currently runs SGX on a mainline Panda |
| Epson Moverio BT-200 (`omap4-epson-embt2ws`, **OMAP4460**) | Andreas Kemnade (mainline) | mainline DTS (lore 2023-03) | — | — | No SGX report found | lore.kernel.org thread 20230327125713.49537a26@aktux. UNVERIFIED for GPU |
| Kindle Fire 1st gen (`omap4-kc1`, OMAP4430) | mainline DTS | — | — | — | No SGX report found | mainline DTS present in 6.12 tree. UNVERIFIED for GPU |
| Pyra (OMAP5, SGX544) | Letux / OpenPandora | Letux kernel | 1.14/1.17 | "works on Pyra/OMAP5 (if TILER framebuffer rotation and X11 are disabled)" | Letux is the upstream of `openpvrsgx` | `drivers/gpu/drm/pvrsgx/TODO` on `linux+pvrsgx` |
| **Nexus Q stock** (OMAP4460) | Google ICS IAN67K | Android 3.0.8 | **1.8@785978** (built-in KM) ↔ bionic `libEGL/GLESv2_POWERVR_SGX540_120.so`, `pvrsrvinit`, `gralloc.omap4.so`, `hwcomposer.omap4.so` | the HDMI visualizer (GLES2 `GLSurfaceView`) | Reference only | stock: `vmlinux.bin` strings; `debugfs ls /vendor/lib/egl`, `/vendor/bin` |

### 2.2 Maemo Leste on the Droid 4: the template to follow

- **History.**
  - 2020-04-03: first accelerated build (tuxphones article).
  - 2020-12-27: `freemangordon`, `uvos` and `tmlind` get **DDK 1.17** running on the N900
    and the Droid 4. Fixing Xorg Glamor/modesetting required forking X11 (blog
    2020-12-27, lines 722–757 of the source `.rst`).
  - Same post: the "Corruption" section reports that the **Droid 4 SGX ran at too low a
    clock**, which caused rendering artifacts. Fixing the frequency removed them. This is
    directly relevant to us (section 5.7).
  - 2022-04-16: "latest PowerVR drivers … both in kernel and userspace", **2D EXA** in X,
    and the ChromeOS PowerVR Mesa driver integrated into Mesa 21.2.5.
  - 2023-01-12: "performance and stability improvements for PowerVR devices like the
    Droid 4, N900, Bionic".
- **Current packages (excalibur, armhf):**
  - `linux-image-omap 6.18.51.1-1+5m7` (source package `omap-linux`, built from
    `droid4-linux` tag `maemo-kernel-6.18.51.1`), which contains
    `pvrsrvkm_omap4_sgx540_120.ko` and the 1.17 modules for am3352, am3517, am4, omap3,
    omap3630, omap4 sgx544, omap5 and dra7. Its `omap2plus_defconfig` has
    `CONFIG_DRM_OMAP=m` (ours is `=y`), `CONFIG_SGX=y`, `CONFIG_SGX_OMAP=m`,
    `CONFIG_SGX_DRM=y`, `CONFIG_CMA_SIZE_MBYTES=32`.
  - `sgx-ddk-um-ti443x 1.17.4948957+leste15-1+5m7`, which `Depends: libc6 (>= 2.34),
    libdrm2, libstdc++6`.
  - `libegl-mesa0 / libgbm1 / libgl1-mesa-dri 24.0.9-sgx1+5m7` (`libc6 (>= 2.38)`).
  - Daedalus (the previous release) has `linux-image-omap 6.6.58.4` and Mesa
    `22.3.6+sgx2-1+4m7` (`libc6 (>= 2.34)`).
- **UM blob set (ti443x).** `libGLESv1_PVR_MESA`, `libGLESv2_PVR_MESA`, `libglslcompiler`,
  `libpvr2d`, `libpvr_dri_support`, `libsrv_init`, `libsrv_um`, `libusc`,
  `libPVRScopeServices` and `pvrsrvctl`. **There is no `libEGL` blob.** EGL comes from
  Mesa's PVR frontend. `libdbm` is a reverse-engineered open replacement in the same repo
  (commit `cfd8e0f9a4`, 2022-02-18, "dbm: use REed library"), and it carries a fix for
  wlroots render-node usage (`ce20a6afdd`).
- **Display stack.** Maemo is X11 (hildon). The wiki's HDMI section uses `xrandr`. Maemo
  therefore proves the **KM, UM and Mesa PVR frontend on 6.18**. It does **not** prove
  wlroots or Weston on SGX540.

### 2.3 postmarketOS: what was tried, and why it stopped

- **Issue #262 (2019-05-19 → 2021-01-24), "Get PowerVR working".** It started from
  libhybris and noted that mainline was "impossible for now".
- **MR !1868 "PowerVR SGX Acceleration"** (author `xc-racer99`, merged 2021-02-23).
  - Added `non-free/sgx-ddk-um` (pkgver `1.17.494857`, from
    `git.ti.com/cgit/graphics/omap5-sgx-ddk-um-linux` snapshot `551665bf9c32`) with
    subpackages per SoC, `ti443x` among them.
  - Added `main/mesa-pvr-dri-classic` (Mesa 20.3.2, from `freemangordon/mesa`).
  - The MR text says: the blobs are "built against GLIBC and only include wayland
    support … can be loaded [with] dlsym and work properly under musl"; known to work
    with "wlroots-based compositors (when there's a patch for the unpack subimage
    extension included) as well as Plasma mobile. X-based DEs do not currently work".
  - The package `depends="libc6-compat"`.
- **MR 2573 "temp/p-wlroots"** (opened 2021-10-05, closed unmerged 2021-11-01). wlroots 0.12 with
  `0002-render-Don-t-use-GL_EXT_unpack_subimage-when-not-ava.patch` (Jonathan Bakker,
  2021-01-02). It does a software row-by-row upload fallback and forces
  `GL_CLAMP_TO_EDGE` for PowerVR. Together with the MR 1868 text ("when there's a patch
  for the unpack subimage extension included") this is strong, indirect evidence that
  **the 2021 SGX GLES2 blob lacked `GL_EXT_unpack_subimage`**. It is not a dump of the
  extension string, and it predates the 2025 leste15 blobs.
- **espresso3g with GPU**, 2021-11-22 (MR 2651). The APKBUILD comment reads "Patched
  wlroots is also necessary for accelerated phosh and sway … Unfortunately, such
  workarounds are not accepted in pmOS."
- **Issue #1316 "Embrace PowerVR or not?"** (2021-11-27 → 2022-01-25). The team decided
  against it, quoted in commit `023f8cc1`: "supporting pvr in pmaports/pmOS has many of
  the same problems that we saw when trying to support hallium/libhybris … we want to
  avoid adding the proprietary userspace components required to support pvr in pmOS."
- **2022-03-24**: espresso3g drops its GPU support. **2022-05-27**: both packages are
  removed.
- **What this means for us.** Our own aports (`pmos/`) and OTA repo are the only place
  these packages can live. Upstream pmOS (now Nura, renamed 2026-09-27, see itsfoss
  2026-09-28) will not take them. We are already outside pmaports for our device
  packages, so that is a packaging fact, not a blocker.

### 2.4 Upstream (mainline kernel and Mesa) outlook

- Mainline's `drivers/gpu/drm/imagination` is **Rogue only**. In 6.12 the only compatible
  is `img,img-axe` (`build/linux-6.12.12/drivers/gpu/drm/imagination/pvr_drv.c:1477`).
  In v6.18.48 it is `thead,th1520-gpu`, `img,img-rogue` and `img,img-axe`
  (`pvr_drv.c:1492-1506`), still no SGX.
- The SGX DT binding exists (`Documentation/devicetree/bindings/gpu/img,powervr-sgx.yaml`
  lists `ti,omap4430-gpu # Rev 120` with `img,powervr-sgx540`). Our SoC DT already has
  the node (see section 5.1). **No driver binds it in mainline.**
- openpvrsgx issue #17 "Progress on mainline efforts" (2024-11):
  - `goldelico`: "quite a long distance … multiple DDK versions".
  - `StaticRocket` (TI): "IMG has stopped all development on SGX … no interest in adding
    anything older than AXE … these things have a hard expiration date".
  - Upstreaming is **not** a realistic path. We will carry an out-of-mainline driver
    indefinitely, as Maemo does.
- **Lima, etnaviv, Panfrost and the Mesa PowerVR (Rogue) driver are not applicable.**
  - Lima drives ARM Mali-4xx (Utgard).
  - etnaviv drives Vivante GCxxx.
  - Panfrost/Panthor drive Mali Midgard, Bifrost and Valhall.
  - Mesa's `imagination` driver targets Rogue (Series6+).
  - SGX5 (USSE1) is a different ISA and MMU with no open shader compiler. No open
    reverse-engineered SGX5 driver is known. UNVERIFIED as an absolute claim, but neither
    openpvrsgx nor Maemo mentions one, and openpvrsgx's own description says it is "NOT
    about reverse engineering or user-space components".

### 2.5 What the stock Nexus Q itself tells us

- **KM.** The `pvrsrvkm` code is built into stock `vmlinux`, with 279 `PVR` symbols in
  kallsyms, e.g. `PVRSRVDriverProbe` at `0xc0276114` and `EnableSGXClocks` at
  `0xc0290d18`. Version string: `sgxddk 18 1.8@785978`.
- **Clock.** Stock reparents the GPU functional clock: `"failed to set gpu_fck to
  dpll_per_m7x2_ck"`, `"Unable to scale SGX frequency"`, plus `RequestSGXFreq` and the
  module parameters `pvrsrvkm.sgx_idle_mode / sgx_idle_timeout / sgx_apm_latency`.
  Mainline's `omap4_sgx_clk_mux_parents` = {`dpll_core_m7x2_ck`, `dpll_per_m7x2_ck`}
  (`build/linux-6.12.12/drivers/clk/ti/clk-44xx.c:327`; identical at v6.18.48 and in
  Maemo's 6.18.51.1). Index 0 (bit 24 = 0) is core_m7x2. Mainline sets the parent and
  rate only for the 4430, in `omap443x.dtsi` (`assigned-clock-parents =
  <&dpll_per_m7x2_ck>`, 307.2 MHz); `omap4460.dtsi` has no such block (v6.18.48). So
  on the Q nothing in our DT selects the stock parent. **UNVERIFIED** which parent and
  rate the Q actually runs with after U-Boot; Phase 0's clk_summary read answers it.
  This is a stock-parity item for the kernel workstream.
- **UM** (`/vendor/lib/egl/*_POWERVR_SGX540_120.so`, `/vendor/lib/libsrv_um.so`,
  `/vendor/bin/pvrsrvinit`). These are **bionic Android** binaries for DDK 1.8.
  - Using them would need libhybris (rejected by pmOS for the same reasons) plus a
    **1.8.785978** KM.
  - openpvrsgx has `letux/pvrsrvkm-1.8.869593` (tip 2026-08-16), a different 1.8 build.
    Mixing builds breaks the KM↔UM ABI check (`PVRSRV_ERROR_CORE_REVISION_MISMATCH`,
    `SGXInit: … check`).
  - **Do not pursue the stock blobs.** Use them only as ground truth for clocks, idle
    and power behaviour.
- **Visualizer.** Stock `/app/Visualizer.apk` (zip entries dated 2012-01-26; the file in
  `system.raw.img` is dated 2012-07-13) holds 31 shader source files in `res/raw/`
  (11 vertex, 20 fragment):
  - `particle_screensaver_{v,f}`, `particle_screensaver_mute_{v,f}`
  - `blur_v`, `blur_output_f`, and six `blur_distort_*_f`
    (`cells`, `concave`, `hstrips`, `plain`, `splurge`, `vstrips`)
  - `{circles,starfield,pointmorph,waveform,waveformsolid,trackinfooverlay,stresstest,debugoverlay}_{v,f}`
  - `icebox_{reflect,steps,threshold}_f`
  - point-morph models `pointmorph_model_{cube,sphere,spiral,stackedcircles}` (plus
    `*_led` variants), `particle.png` / `particle2.png` (64×64) and `muted.png` (100×100)

  The odex references `GLSurfaceView`, `setEGLContextClientVersion`, FBO calls
  (`glGenFramebuffers`, `glFramebufferTexture2D`), `BlurEffect$BlurDistortProgram`,
  `StressTestActivity` and `DiagnosticsHelper`. The shaders are short GLSL ES 1.0, and
  every one fits the SGX540's GLES2 profile by construction, since it ran on this GPU.

---

## 3. Value for the Nexus Q

### 3.1 Inventory: what exists today

| Thing | State | Evidence |
|---|---|---|
| LED-ring idle screensaver (breathing #0099CC) | Ported, pixel-exact, CPU-trivial (one `cos` per frame) | repo:userspace/nexusqd/src/screensaver.c:36-62 |
| 5 music scenes on the LED ring | Ported (`fx_waveform*`, `fx_circles`, `fx_pointmorph`, `fx_starfield`) | repo:docs/2026-06-19-music-effects-RE.md:90-101 |
| **HDMI/GL rendering of any scene, the particle field, the blur feedback, the track-info overlay** | **Not ported**, marked "screen-only, ignored" | repo:docs/2026-06-19-music-effects-RE.md:13,98-101; repo:docs/2026-06-19-particle-screensaver-RE.md:111-112 |
| HDMI output while HDMI audio is selected | Held lit by `nq-hdmi hold` as a **black screen** ("Petr's call", same power as the console). No DRM master on purpose | repo:docs/2026-09-20-hdmi-audio-…md §5; repo:pmos/device-google-steelhead/nq-hdmi:23-32 |
| LXQt-Wayland desktop on labwc, pixman renderer, on demand (app toggle) | Works. `WLR_RENDERER=pixman` because GLES fails | repo:pmos/device-google-steelhead/nexusq-wayland.sh:2-9; repo:PLAN.md:1981-2002 |
| Idle desktop CPU | "~70 % idle; the ~30 % busy baseline is the software-rendered (pixman) wlroots compositor" (dual core, 58–60 °C) | repo:docs/2026-06-23-session-findings.md:61-65 |
| HDMI mode ceiling | 75 MHz pixel clock: 1280×720@60 (74.25), 1024×768@60 (65), and in principle 1920×1080@24/25/30 (74.25) if the sink offers it (untested on the Q) | repo:kernel/patches/0010-…patch:36,43 |
| Now-playing metadata | `nowPlaying` with `artist/track/album/artUrl/source/transport` already in the bridge state | repo:companion/PROTOCOL.md:81-82, 348-351 |

**No measurement in the repo gives labwc/pixman CPU at 1280×720 under an *animated*
load.** The only number is the idle baseline above. Its section does not state the
resolution, but §2 of the same note records that labwc ran at 1280×720@60 that session
after patch 0010, so the ~30 % is most likely a 720p figure (inference). Phase 0 has to
produce the animated baseline.

### 3.2 Use case A: the stock HDMI visualizer (highest value)

- **Why it matters.**
  - It finishes the original Nexus Q experience: the device shipped as an HDMI music
    visualizer.
  - It turns the black hold-screen into content for exactly the users who already have a
    TV or AVR on HDMI. GitHub issue #5 was a Yamaha RX-V473 + LG TV user.
- **What it costs in software.** UNVERIFIED estimate, to be replaced by a Phase 0
  measurement:
  - The particle field is 40 point sprites at `gl_PointSize = 60.0`, about 144 k
    fragments per frame. That is cheap even on the CPU.
  - The expensive part is the **blur feedback** effect. Every frame does a full-screen
    render-to-texture pass that reads the previous frame twice (`blur_distort_splurge_f`:
    one fetch, then a *dependent* fetch at a distorted coordinate, with decay), then an
    output pass (`blur_output_f`).
  - At 1280×720 that is about 0.92 M px × 3 bilinear fetches per frame. Scalar C on a
    Cortex-A9 (~40–60 cycles/px for the whole chain) gives about 1.1–1.7 Gcycles/s at
    30 fps, i.e. **one to one and a half cores at 1.2 GHz**. A NEON-optimised version
    (~10–15 cycles/px) gives about 0.3–0.4 Gcycles/s (~25–35 % of one core). At 640×480
    it is about a third of that.
  - Either way the CPU path moves roughly 3 × 3.7 MB of frame reads per frame
    (~0.33 GB/s at 30 fps), plus two full-frame writes (FBO and output), about
    5 × 3.7 MB ≈ 0.55 GB/s in total before cache effects. *(Corrected 2026-10-11: an
    earlier draft wrote "3 × 3.7 MB … ~0.6 GB/s", which does not multiply out.)* That is
    an **EMIF load comparable to what caused audio crackle** (section 5.4).
    UNVERIFIED estimate.
- **What it costs on the SGX540.** UNVERIFIED: the full-screen pass is a few fragment
  instructions per pixel, and a tile-based deferred renderer does it at 720p30 with large
  margin. The CPU cost drops to the scene logic plus a few draw calls. The scene logic
  already exists in C in `nexusqd`. Memory traffic for full-screen feedback is inherent
  either way, though the GPU avoids the CPU's read-modify-write cache thrash. Rendering
  the blur FBO at half resolution (640×360) and upscaling cuts traffic about 4× on
  either path.
- **Verdict.** The visualizer is the one use case where the GPU changes what is possible:
  a faithful port at 720p30 without burning a core and heating a SoC already measured at
  102.8 °C. It is also self-contained. A single KMS/GBM client needs no compositor, which
  avoids the `GL_EXT_unpack_subimage` problem entirely.

### 3.3 Use case B: the LXQt HDMI desktop on demand (medium-low value)

- Today the compositor alone costs about 30 % of the CPU at idle. A GLES2 wlroots
  renderer would cut compositing cost. Moving windows, opacity and damage would be
  composited by the SGX.
- LXQt apps are QWidget, rendered by Qt's raster engine into SHM buffers. That stays on
  the CPU whatever the compositor does. UNVERIFIED for every LXQt app, but QWidget
  rendering is raster by default.
- The wins are therefore limited to compositing and scaling. The costs are
  `GL_EXT_unpack_subimage` (a shim or patch is needed), a private-prefix Mesa, and the
  SGX's EGL/GBM interaction with omapdrm.
- The desktop is "for occasional debugging/ops" (repo:PLAN.md:2161). **Rank: after the
  visualizer, optional.**

### 3.4 Use case C: a now-playing / album-art HDMI screen (high value, needs no GPU)

- **Content.** `artUrl` + text, changing once per track.
- **The GPU-free path is better.** omapdrm on OMAP4 exposes 4 overlays (GFX + VID1–3):
  - `num_ovls = 4`, `max_downscale = 4`, `has_writeback = true`
    (`build/linux-6.12.12/drivers/gpu/drm/omapdrm/dss/dispc.c:4437-4463`)
  - per-plane `zpos`, `alpha`, `blend_mode` (premultiplied), rotation and colour
    properties (`omap_plane.c:390,568-574`)
  - VID planes can scale (`OMAP_DSS_OVL_CAP_SCALE`, `dispc.c:4119`)

  A tiny KMS client can put the decoded cover on a VID plane, text on GFX, and do
  crossfades by stepping plane `alpha`. Steady state is **zero CPU and zero GPU per
  frame**; the DSS does it during scanout. JPEG decode and text rasterization once per
  track are trivial.
- **Role of the GPU.** Only if animated transitions (Ken Burns, blur-behind) are wanted,
  in which case it should share the Phase 4 client.
- **Recommendation.** Build it independently of the GPU (it could start tomorrow). Design
  the client so the visualizer is a second "scene" inside the same DRM-master process
  (section 6, Phase 4).

### 3.5 Use case D: a browser (not a target)

- Modern Chromium and WebKitGTK GPU paths expect GLES3-class features for GPU raster and
  compositing. UNVERIFIED in detail, but the SGX540 is GLES2-only, so they fall back to
  software anyway.
- 1 GB-class RAM and two A9 cores make any modern browser a poor experience with or
  without the GPU. The MemAvailable minimum is 849 MiB idle (repo:docs/2026-09-26-idle-audit-five-pollers.md:23).
- **Not a reason to do GPU work.**

### 3.6 Value matrix

| Use case | User-visible | Needs GPU | Needs compositor | Device risk | Rank |
|---|---|---|---|---|---|
| A. Stock visualizer on HDMI | yes, for HDMI-audio users | **yes** at 720p30 fidelity (SW only at reduced resolution or fidelity) | no (KMS/GBM client) | medium (EMIF, thermal) | **1** |
| C. Now-playing screen | yes | no (DSS planes) | no | low | 1 (parallel, GPU-independent) |
| B. Accelerated desktop | rarely (ops/debug) | yes | yes (wlroots 0.20) | medium-high | 3, optional |
| D. Browser | — | does not help | yes | — | dropped |
| Video playback (IVA-HD) | maybe | **no**, IVA-HD is a separate engine, out of scope | — | — | separate track |

---

## 4. Alternatives if the closed-blob path stalls

1. **NEON software rendering.**
   - Alpine's armv7 pixman 0.46.4 is built with `--auto-features=auto` (aports
     `main/pixman/APKBUILD`). The `edge` armv7 binary contains the string `arm-neon`.
     That is the implementation name, which pixman only compiles under `USE_ARM_NEON`,
     so NEON fast paths are present. **Verified at instruction level (2026-10-11):** an
     ARM-mode disassembly (`llvm-objdump --triple=armv7a --mattr=+neon`) of
     `libpixman-1.so.0.46.4` from `pixman-0.46.4-r0.apk` (edge/main/armv7) contains
     1500 `vmull.u8`, 1146 `vrshr.u16` and 1149 `vraddhn.i16`, which is pixman's NEON
     combiner idiom (multiply, then divide by 255). Whether the runtime CPU detection
     enables it on the Q is still for Phase 0.
   - pixman therefore already uses NEON for compositing. Phase 0 can confirm on device by
     comparing CPU with `PIXMAN_DISABLE=arm-neon`.
   - For the visualizer, a hand-written NEON renderer straight into a KMS dumb or omapdrm
     buffer is the fallback, at reduced internal resolution (blur FBO at 320×180 or
     640×360, upscaled for free by a DSS VID plane).
2. **DSS planes do the composition** (section 3.4). Scaling, alpha and zpos come for
   free from scanout hardware. For the visualizer: draw particles small, let VID scaling
   upscale, and use plane alpha for fades.
3. **Lower HDMI resolution.** 640×480@60 is 25.175 MHz and about 55 MB/s of scanout,
   against 74.25 MHz and about 212 MB/s at 720p60 (repo:docs/2026-09-20-hdmi-audio-…md §5).
   That is 3× fewer pixels for any software renderer, and one compositor or client
   setting away.
4. **llvmpipe** (Mesa on the CPU, LLVM JIT) was already judged heavier than pixman on
   this A9 (repo:PLAN.md:2170-2171). It is a correctness fallback for GLES2 code (run the
   Phase 4 client under `LIBGL_ALWAYS_SOFTWARE=1`), not a performance path.
5. **libhybris + stock bionic DDK 1.8 blobs.** Rejected:
   - it needs a matching 1.8.785978 KM;
   - bionic linker games;
   - the same reasons pmOS gave in #1316;
   - zero advantage over the maintained 1.17 path.
6. **Lima, etnaviv, Panfrost, the Mesa Rogue driver, mainline `imagination`.** Not
   applicable: different GPU families (section 2.4).
7. **OMAP4 2D engines.** There is no separate 2D blitter besides the SGX itself (2D via
   `libpvr2d`) and DMM/TILER (rotation and remapping only). UNVERIFIED that nothing else
   useful exists. ISS and IVA-HD are camera and video engines.

---

## 5. Device-specific constraints that shape the roadmap

### 5.1 The DT node is already there

- 6.12 `omap4.dtsi:484-509` has `sgx_module: target-module@56000000` (ti-sysc,
  `power-domains = <&prm_gfx>`, `clocks = <&l3_gfx_clkctrl OMAP4_GPU_CLKCTRL 0>`) with
  `gpu@0 { compatible = "ti,omap4430-gpu", "img,powervr-sgx540"; interrupts = <GIC_SPI 21> }`.
- Our DTS patch 0003 has no GPU mentions (grep), so steelhead inherits the node.
- openpvrsgx `pvr-drv.c:363-364` matches `ti,omap4430-gpu` under
  `ti_omap4_sgx540_120`. Maemo's 6.18 `omap4.dtsi` is identical at those lines.
- **Verified 2026-10-11:** the `sgx_module` block of v6.18.48 `omap4.dtsi` (fetched from
  the `gregkh/linux` mirror at tag `v6.18.48`) is identical to the 6.12.12 one and sits at
  the same line 484. Maemo's `maemo-kernel-6.18.51.1` block is identical too.
  `omap4460.dtsi` at v6.18.48 adds nothing GPU-related.
- The DT gives no SGX clock assignment for the 4460, unlike `omap443x.dtsi` (section 5.7).

### 5.2 Boot image ceiling: the module must be on the rootfs

- The staged boot image is 6 719 488 B, about 94 KB under the U-Boot caution
  (repo:PLAN.md:2099, v1.16.0).
- The pvrsrvkm KM is hundreds of KB. **It must be `=m`**, and so must everything only it
  needs.
- `CONFIG_MODULES=y` already (repo:kernel/configs/steelhead_defconfig:689), with 154
  `=m` options.

### 5.3 Kernel OTA and module trees: build the module *with* the kernel

- Kernel OTA keys modules by `CONFIG_LOCALVERSION=-r<pkgrel>`. `/lib/modules/<ver>-rN`
  trees coexist, and `stage-apk` installs the new tree by hand
  (repo:docs/2026-08-18-kernel-ota-phase2.md:111-148).
- A GPU module shipped as a separate, out-of-tree apk would miss every kernel OTA and
  fail its vermagic check.
- **Decision.** Carry the openpvrsgx/Maemo driver as **in-tree kernel patches** in
  `kernel/patches/`, built `=m` by `linux-google-steelhead`. Then it lands in the same
  `/lib/modules/<release>` and rolls back with the A/B slot. This is also the only option
  consistent with "a fix is done when it is in the build".

### 5.4 Audio crackle history: the GPU is a new L3/EMIF initiator

- Playback crackle was **memory-bus / DMA contention on L3/EMIF** (McBSP2 SDMA FIFO
  underflow under contention). It was fixed by an sDMA read-priority patch (0041) plus
  the DPLL_ABE relock (0042) (repo:docs/2026-07-08-audio-crackle-dma-contention.md:26;
  repo:docs/2026-07-12-…md:11).
- The SGX is a heavy L3 master, and HDMI scanout adds about 212 MB/s at 720p60.
- **Every GPU phase that renders must run with audio playing (quietly, the user driving
  the listening test) and must read the XRUN and underflow counters** described in the
  2026-07-08 doc before and during the test.
- **UNVERIFIED** whether L3 initiator QoS for the SGX exists or is needed. That doc
  lists "L3 NoC / EMIF initiator QoS for the audio DMA path" as a lever (line 111).

### 5.5 Thermal

- 102.8 °C was measured under sustained load, above the documented 94–99 °C envelope
  (repo:PLAN.md:2004-2008). PLAN.md still says "true idle is 72–75 °C"; the later
  2026-07-13 note says those reads were heated by the ssh observer and puts the
  unobserved idle floor at ~65–66 °C
  (repo:docs/2026-07-13-idle-power-governor-and-pid1-churn.md:19-20).
- The GFX power domain adds heat on the same die. Any sustained GPU test is
  **frame-capped** (e.g. 30 fps), wrapped in `timeout`, and logs the temperature.
- The KM's SGX idle and active power management (`sgx_idle_*` in stock) must actually
  gate GFX when the visualizer is off.

### 5.6 Never probe GFX registers through `/dev/mem`

- A read of an unclocked OMAP module takes `external abort on non-linefetch` plus an L3
  error. The HDMI investigation hit exactly this on the DSS
  (repo:docs/2026-09-20-hdmi-audio-…md §2).
- With no driver bound, ti-sysc leaves the GFX module idle. Phase 0 is therefore
  **sysfs/debugfs reads only**. The SGX revision register is read by the KM, not by us.

### 5.7 SGX clock: a known pitfall

- Stock forces `gpu_fck` from `dpll_per_m7x2_ck` (section 2.5).
- Maemo's Droid 4 had rendering artifacts from too low an SGX clock (blog 2020-12-27,
  "Corruption"). The fix that survives in mainline is the `omap443x.dtsi` block:
  ```
  &sgx_module {
  	assigned-clocks = <&l3_gfx_clkctrl OMAP4_GPU_CLKCTRL 24>, <&dpll_per_m7x2_ck>;
  	assigned-clock-rates = <0>, <307200000>;
  	assigned-clock-parents = <&dpll_per_m7x2_ck>;
  };
  ```
  (v6.18.48 `omap443x.dtsi:78-86`, comment "like droid4 stock v3.0.8 Android kernel").
  `omap4460.dtsi` has no equivalent, so steelhead needs its own block in patch 0003,
  with the rate taken from stock.
- **KM side (corrected 2026-10-11).** In openpvrsgx 1.17 (`-v3`, old 1.17 branch and
  `linux+pvrsgx` alike), the KM turns the SGX clocks on through
  `pm_runtime_get_sync()` on the platform device (`sysutils_linux.c` `EnableSGXClocks`,
  lines 195-245), i.e. through ti-sysc. It does not reparent anything itself.
  - `SGX_PARENT_CLOCK` is in **`sysutils_linux.c:79-83`**, not `sysconfig.h` (which is
    78 lines long). It is `"cm_96m_fck"` only under `SUPPORT_OMAP3430_SGXFCLK_96M`,
    otherwise `"core_ck"`, and it is never referenced after the `#define`.
  - The `clk_get(NULL, "gpt11_fck")` / `"gpt11_ick"` code (lines 392-418) sits inside
    `#if (defined(DEBUG) || defined(TIMING)) && !defined(PVR_NO_OMAP_TIMER)` (line 275)
    and further inside `PVR_OMAP4_TIMING_PRCM` (defined only for kernel 2.6.34) and
    `AM_VERSION == 5 || 6`. A release build compiles the stub `AcquireGPTimer()` that
    returns `PVRSRV_OK` (lines 566-577). **GPTIMER11 is not used by a release KM**, so the
    earlier "GPTIMER11 is used by the KM" claim is withdrawn.
- **Open items:**
  - which mux parent and rate the 4460 should run (stock: `dpll_per_m7x2_ck`; the rate
    is not in the strings found, so read it from the stock clock code with the
    stock-parity-auditor);
  - whether a DEBUG/TIMING KM build is ever wanted, in which case the GPT11 question
    comes back.

  The OMAP4460 data-manual SGX rates (307 / 384 MHz) are **UNVERIFIED** here. This
  belongs to the kernel/stock-parity workstream, but the roadmap makes it a Phase 1 exit
  criterion.

### 5.8 libc: musl vs glibc for the UM blobs

- The blobs are glibc-linked (`libc6 (>= 2.34)`, `libstdc++6`). There are two routes.
  - **(a) musl + gcompat** (the pmOS 2021 recipe: `depends="libc6-compat"`, `dlsym`
    loading). The whole SGX Mesa must then be built for musl.
  - **(b) the existing glibc runtime.** The Q already carries `/opt/glibc-rt`, an
    unpacked **Debian bookworm armhf** glibc runtime (~182 MB, package
    `nexusq-glibc-rt`, **flash-only**, not in the OTA repo) for Roon
    (repo:docs/2026-08-02-full-system-ota-and-glibc-rt-split.md).
- Bookworm is glibc 2.36. That satisfies Maemo **daedalus** `libegl-mesa0 22.3.6+sgx2`
  and `sgx-ddk-um-ti443x` (`>= 2.34`). It does **not** satisfy **excalibur**'s Mesa
  `24.0.9-sgx1` (`libc6 >= 2.38`).
- Inference: Phase 2 could run Maemo's *prebuilt* daedalus UM + Mesa unmodified inside
  `/opt/glibc-rt` as the fastest "does the GPU work at all" test. This needs no Mesa
  build at all. Caveats: `/opt/glibc-rt` is a *minimal* bookworm base for a bubblewrap
  Roon sandbox, shipped without the apt dirs (repo:pmos/nexusq-glibc-rt/APKBUILD:2-5;
  repo:docs/2026-07-17-roon-bring-up.md:18). The daedalus Mesa debs pull a large
  closure (`libllvm15`, `libdrm*`, `libwayland*`, `libx11-xcb1`, `libxcb-*`,
  `libsensors5`, `libelf1`, `libzstd1`, `libexpat1` per the Packages.gz `Depends`),
  which would have to be fetched from Debian bookworm armhf by hand. UNVERIFIED which of
  these are already present. Also note for route (a): gcompat was already found to
  segfault Roon's Mono (same APKBUILD header), so "gcompat is enough" must be shown for
  the SGX blobs, not assumed.
- The shipped product should still use route (a) or a properly packaged route (b),
  decided at the Phase 2 gate. glibc-rt is flash-only today, so it changes the OTA story.

### 5.9 Mesa: a private prefix, never a replacement

- Alpine `main/mesa` is **26.2.4** with no glvnd (aports `main/mesa/APKBUILD`; no
  `glvnd` string).
- The SGX Mesa forks are 22.3 or 24.0. Installing one as the system `libEGL`, `libgbm` or
  `libGLESv2` would freeze Mesa for labwc, Qt and everything else. That is exactly the
  frozen-override pattern the user's global rules forbid.
- **Rule for this project:**
  - install the SGX Mesa into a private prefix (e.g. `/usr/lib/sgx/`);
  - only GPU clients get it, via `LD_LIBRARY_PATH` or rpath (the Phase 4 visualizer, and
    labwc only if Phase 5 happens);
  - the system Mesa stays Alpine's and keeps receiving updates.

### 5.10 Compositors need `GL_EXT_unpack_subimage`

- wlroots `render/gles2/renderer.c` at 0.19.0 (lines 554-558) and at 0.20.2: missing
  extension → `return NULL`. labwc 0.20.2 links `wlroots0.20` (aports
  `community/labwc/APKBUILD`).
- Weston 16.0.0 `gl-renderer.c`: GLES < 3.0 without the extension → "GL_EXT_unpack_subimage
  not available", `return -1`.
- wlroots also needs `EGL_EXT_image_dma_buf_import` and
  `GL_EXT_texture_format_BGRA8888` (renderer.c 0.20.2:543-552), and in `render/egl.c`
  `EGL_KHR_no_config_context` or `EGL_MESA_configless_context`,
  `EGL_KHR_surfaceless_context`, `EGL_EXT_platform_base`, plus a DRM render node for the
  GBM platform. All of these belong in the Phase 2 extension dump.
- The 2021 evidence says the SGX blob lacks `unpack_subimage` (MR 2573 patch). Whether
  Maemo's 2025 libdbm and Mesa frontend changed the extension string is **UNVERIFIED**.
  Phase 2's `eglinfo` / `es2_info` dump answers it in one command.
- **The proposal that respects the no-fork rule is a small `LD_PRELOAD` shim** next to
  upstream. Upstream wlroots stays untouched. The shim:
  - appends `GL_EXT_unpack_subimage` to `glGetString(GL_EXTENSIONS)`;
  - tracks `GL_UNPACK_ROW_LENGTH_EXT` / `SKIP_PIXELS` / `SKIP_ROWS` in `glPixelStorei`;
  - turns a strided `glTexSubImage2D` into per-row uploads, as the 2021 wlroots patch
    did internally.

  The 2021 patch also needed `GL_CLAMP_TO_EDGE` for PowerVR. wlroots 0.20.2 already sets
  `GL_CLAMP_TO_EDGE` on both wrap axes upstream (`render/gles2/texture.c:343-344`), so
  the shim probably does not need to. Feasibility is better than the earlier draft said:
  wlroots 0.20.2 links `libGLESv2` directly (`render/gles2/meson.build`:
  `dependency('glesv2')`) and calls `glGetString`, `glPixelStorei` and
  `glTexSubImage2D` as plain core symbols (`texture.c:82-94`), which `LD_PRELOAD` can
  interpose. Only extension entry points go through `eglGetProcAddress`. **Still
  UNVERIFIED** until it runs.
- An upstream MR to make the extension optional again is the "send it upstream" option.
  wlroots made it mandatory deliberately, so acceptance is unlikely (UNVERIFIED). Ask
  Petr before posting.

### 5.11 Licensing (Phase 6)

- TI's `omap5-sgx-ddk-um-linux` manifest (`OMAP5-Linux-Graphics-DDK-UM-Manifest.doc` on
  git.ti.com) licenses the UM blobs under the **TI TSPA**:
  - "Redistribution and use in binary form, without modification" is permitted;
  - redistributions must "reproduce this license";
  - "No reverse engineering, decompilation, or disassembly".
- Shipping the **unmodified** `ti443x` blobs in our OTA repo with the license text is
  allowed. UNVERIFIED legal reading; worth Petr's review.
- Maemo's `sgx-ddk-um` changelog has "Weaking libGLESv1 symbols" (leste12, 2022-02-14)
  and "Add glibc weakened libgslscompiler" (leste2, 2021-11-22). *(Corrected 2026-10-11:
  an earlier draft attributed a "weaken glib 2.29 symbol" entry to leste13; leste13 is
  "Add missing build-deps".)* If those entries edit the binaries, that counts as a
  *modification* under the TSPA. Ship the TI-original files, not the Maemo-edited ones,
  and expect to redo whatever the weakening was for. Maemo's `libdbm` is a
  reverse-engineered open replacement (leste14), not a TI blob.
- The KM is GPLv2 or dual MIT/GPL. The Mesa PVR frontend is MIT.
- Public release images (`PUBLIC_RELEASE=1`) must include the license file.
  `scripts/release-preflight-no-secrets.sh` is about secrets, not licenses, so a license
  check is a new preflight item.

### 5.12 Other constraints

- **No serial console, ever.** Crashes are read from ramoops / `/var/lib/systemd/pstore`
  (repo:PLAN.md:2366-2376).
- **GCC 15.2 armv7 codegen bugs** reproduce on hardware and not under qemu (memory
  index). The DDK KM is old, macro-heavy C. Build warnings must be read, and a KM crash
  must not be blamed on the GPU before the compiler is ruled out.
- **Never touch bootloader/xloader.** GPU work touches only the kernel (through the
  kernel-OTA *trial* slot) and the rootfs.

---

## 6. Phased roadmap

Every phase follows the project's rules:

- the first remote command is `hostname`;
- any device load runs under `timeout` + `nice` and is frame-capped;
- `pactl list sink-inputs` is checked before anything that may touch audio, and there are
  no test tones;
- a test must be **seen failing** before it counts;
- the full `nexusq-diag` sweep, including CPU frequency and VDD_MPU against the OPP,
  runs after every flash or OTA;
- every working change goes into an APKBUILD with a `pkgrel` bump in the same session.

Effort is in focused engineer-days and is UNVERIFIED, scaled from the Maemo precedent.

### Phase 0: preparation and baselines (no device risk)

- **Goal.** Know exactly what we are porting and measure what "better" means before
  touching the kernel.
- **Entry.** None.
- **Work:**
  1. **Source pinning.**
     - Pick the KM source: the `pvrsgx/1.17.4948957` + glue diff between Maemo
       `droid4-linux` tag `maemo-kernel-6.18.51.1` (`db432aff895b`, branch
       `leste/maemo-6.18.y`) and mainline v6.18.51, versus openpvrsgx
       `letux/pvrsrvkm-1.17.4948957-v3` + `letux/omap-pvr-soc-glue-v10` +
       `letux/omap-sysc-prm-gfx`. Record commit hashes.
     - Pin the UM: TI `omap5-sgx-ddk-um-linux` commit, or Maemo
       `sgx-ddk-um 1.17.4948957+leste15`. Record sha512 of each `ti443x` `.so`.
     - Pin Mesa: Maemo `maemo/excalibur` vs mobiaqua `mesa-22.3-sgx` vs StaticRocket
       `powervr/23.2.1` (freedesktop).
  2. **DT read-only probe** on the running Q. Only `ls -l /sys/bus/platform/devices/ |
     grep -i 56000000`, the `of_node` `compatible`, `cat .../driver` (expect none), and
     `/sys/kernel/debug/pm_genpd` / clk_summary lines for `l3-gfx`, `gpu`,
     `sgx_clk_mux`. **No `/dev/mem`** (section 5.6).
  3. **Baselines**, each in a 60 s window with `timeout`, with the user's music playing at
     low volume or idle per their choice:
     - labwc/pixman CPU% at 1280×720 and 640×480: idle, and animated
       (`weston-simple-shm`-class client, or a moving window);
     - the same with `PIXMAN_DISABLE=arm-neon` (confirms NEON is in use);
     - die temperature;
     - McBSP/XRUN counters from the 2026-07-08 procedure;
     - HDMI scanout on or off.
  4. **Software reference visualizer** (host-built, unit-tested C). Port
     `particle_screensaver_*` and the `blur_*` chain to a CPU renderer on top of the
     existing nexusqd scene logic, and measure cycles per frame on the device at
     320×180, 640×360 and 1280×720 (bounded run). This replaces the estimate in 3.2 with
     data **and** is the fallback product if the GPU path dies.
  5. **Toolchain.**
     - Add a host build of the KM against our 6.18.48 tree with our defconfig plus
       `CONFIG_SGX=y`, `CONFIG_SGX_OMAP=m`, `CONFIG_SGX_DRM=y`,
       `CONFIG_PVRSGX_1_17_4948957=y`.
     - Check `CONFIG_CMA_SIZE_MBYTES`: ours is 16 (defconfig:5529), Maemo's 6.18
       `omap2plus_defconfig` has 32. omapdrm scanout uses shmem + TILER when DMM is
       present (`omap_gem.c:1298-1320`, `:808-819`), so 16 MB may be enough. Verify.
- **Exit.**
  - A written pin list (hashes).
  - Baseline numbers committed as a dated `docs/` note.
  - The SW reference renderer's cost table.
  - The KM compiles cleanly against 6.18.48 on the host with `-Werror` scrutiny of new
    warnings.
- **Artifacts.**
  - `docs/2026-10-xx-gpu-baselines.md` <!-- docs-check: ignore -->
  - `scripts/diag/gpu-status` (new diag section, read-only)
  - a host-tested `fx_blur` / `fx_particles` SW renderer
- **Test seen failing first.** Add a `gpu` section to the diag sweep that asserts
  "pvrsrvkm bound to 56000000.target-module/…gpu". It must report **FAIL** on today's
  image (no driver). That proves the check can tell the difference.
- **Device safety.** Reads only. Measurement loads are bounded (`timeout 60 nice -n 10`),
  and the user drives any listening.
- **Effort.** 4–6 days.

### Phase 1: the KM loads (`/dev/pvrsrvkm`, `pvrsrvctl --start`, `SGXInit … [ OK ]`)

- **Goal.** The kernel half works on hardware, with the GPU module **not** auto-loaded at
  boot.
- **Entry.** Phase 0 exit. Kernel stock-parity review of the GFX clock, power domain and
  reset done by the stock-parity-auditor.
- **Work:**
  1. Import the KM plus SoC glue as `kernel/patches/00xx-…` (in-tree, `=m`). Bump the
     `linux-google-steelhead` pkgrel. Keep the boot image size and the 94 KB headroom
     (the KM is a module, so it must not grow the zImage beyond config deltas).
  2. Ship `/etc/modprobe.d/nexusq-gpu.conf` with **`blacklist pvrsrvkm_omap4_sgx540_120`**,
     so a GPU fault cannot boot-loop the unit. Loading is explicit (`modprobe`) during
     Phase 1–2. From Phase 4 a unit with a boot-attempt guard loads it, see Phase 6.
  3. Clocks:
     - set the SGX mux parent and rate to match stock (`dpll_per_m7x2_ck`) with an
       `&sgx_module { assigned-clocks … }` block in patch 0003, modelled on mainline
       `omap443x.dtsi:78-86` but with the 4460 rate stock parity gives (section 5.7);
     - GPTIMER11 is not needed by a release KM build (section 5.7); recheck only if a
       DEBUG/TIMING build is made.
  4. Deploy through **kernel OTA to the trial slot** (`nq-kernel-ota stage-apk` → `try`
     → health-gated promote), never by touching slot A first.
  5. On device:
     - `modprobe pvrsrvkm_omap4_sgx540_120`;
     - `pvrsrvctl --start --no-module` (from the UM tools package, glibc: run it from
       `/opt/glibc-rt` or under gcompat);
     - `cat /proc/pvr/*`;
     - dmesg must show `SGXInit: HW core rev (…) and SW core rev (…) match. [ OK ]`;
     - `rmmod` must unload cleanly.
- **Exit.**
  - The above passes 10 load/start/unload cycles.
  - GFX powers down again after unload: genpd/clk_summary returns to the Phase 0
    baseline.
  - No new boot warnings (all boot errors are ours).
  - Full diag sweep clean, including CPU frequency and VDD_MPU.
  - **No audio regression**: XRUN counters stay at baseline with the module loaded and
    idle.
- **Artifacts.**
  - Kernel patches.
  - `nexusq-gpu.conf` in `device-google-steelhead`.
  - Diag section upgraded to report pvr state.
  - A `docs/` note recording the measured SGX clock rate versus stock.
- **Test seen failing first.**
  - (i) The Phase 0 diag check now passes. Revert the clock-parent change and watch
    `SGXInit` fail or hang, or the measured rate drop. That proves the clock fix carries
    weight.
  - (ii) Load with the core revision deliberately mismatched: build 1.17 KM `sgx540_120`
    against a wrong UM revision, or use the KM's skip flag in reverse. Watch the
    `PVRSRV_ERROR_CORE_REVISION_MISMATCH` path trigger. That proves the check is live.
- **Risks.**
  - A GPU or L3 hang locks the box. There is no serial console, but ramoops captures
    panics. A hard hang means a power cycle, so keep the unit on reach.
  - Kernel OTA failure path needs physical access (repo:PLAN.md:2100).
  - GCC 15.2 miscompile in KM code (section 5.12).
- **Device safety.**
  - The module is blacklisted at boot.
  - The trial slot is used, never slot A first.
  - Nothing renders yet, so there is no thermal or EMIF load.
  - Bootloader and xloader are untouched.
- **Effort.** 5–10 days. It is less if the Maemo 6.18 diff applies cleanly, more if the
  4460 clock setup or the ti-sysc/PRM-GFX glue needs stock-parity work.

### Phase 2: offscreen GLES2 works (eglinfo, pbuffer/surfaceless render, pixel readback)

- **Goal.** Prove that the KM, UM and EGL stack renders correct pixels. No display yet.
- **Entry.** Phase 1 exit.
- **Work:**
  1. **Fast route (experiment, not product).** Inside `/opt/glibc-rt`, unpack Maemo
     daedalus `sgx-ddk-um-ti443x` + `libegl-mesa0`/`libgbm1`/`libgl1-mesa-dri`
     `22.3.6+sgx2` (glibc ≥ 2.34 fits bookworm's 2.36, section 5.8). Run `eglinfo` and
     a minimal surfaceless or pbuffer EGL program built against those headers.
  2. **Product route.** Package the SGX Mesa for musl in a private prefix (section 5.9),
     with `gcompat` for the blobs, following the pmOS 2021 recipe. Decide (a) or (b) at
     the gate below.
  3. Dump the full EGL and GL extension strings into the repo. This answers
     `GL_EXT_unpack_subimage`, `EGL_EXT_image_dma_buf_import`, `GL_OES_EGL_image` and
     `GL_EXT_texture_format_BGRA8888` once and for all.
  4. Golden-image test:
     - render a fixed scene (clear, one textured quad with `particle.png`, one
       `blur_distort_plain_f` pass) to a 256×256 FBO;
     - `glReadPixels`;
     - compare against a CPU reference from Phase 0 within a tolerance.
- **Exit.**
  - `GL_RENDERER` names the PowerVR SGX 540.
  - The golden test passes 100/100 runs.
  - Load/unload of the client leaves `/proc/pvr` clean (no leaked contexts).
  - XRUN baseline holds while the test loops for 60 s at a 30 fps cap.
- **Gate (go/no-go).**
  - If GLES2 renders correctly here, the closed path is viable. Continue.
  - If it fails on blob/libc ABI and is not solvable in about 1 week, **stop and ship the
    Phase 0 SW renderer + DSS-plane screen instead** (section 4).
- **Test seen failing first.** Run the golden test with `LIBGL_ALWAYS_SOFTWARE=1` or with
  the KM unloaded. It must fail the `GL_RENDERER == SGX` assertion, or fail to create a
  context. That shows the test really exercises the GPU. Also corrupt one reference
  pixel and watch the comparison go red.
- **Risks.**
  - The musl + gcompat symbol gaps.
  - The UM wants `/dev/dri/renderD*` vs `card*` semantics. Maemo's `libdbm` changes
    render-node handling (commit `ce20a6afdd`).
  - Firmware: the excalibur `sgx-ddk-um-ti443x` file list has **no separate firmware
    file** (checked 2026-10-11 in `Contents-armhf.gz`), so the June note's `sgx540_*.fw`
    assumption is wrong for 1.17. Which UM library carries the microkernel is still
    UNVERIFIED.
- **Device safety.** Frame-capped loops under `timeout`. Temperature is logged. No HDMI
  involvement.
- **Effort.** 4–8 days (fast route about 2 days, product packaging the rest).

### Phase 3: on screen via GBM/KMS on omapdrm (kmscube-class)

- **Goal.** GPU-rendered frames scan out on HDMI through omapdrm, tear-free, with page
  flips.
- **Entry.** Phase 2 go.
- **Work:**
  1. Build `kmscube`, or mobiaqua's `kmscube` fork (last push 2024-06-22), against the
     private-prefix GBM/EGL.
  2. Verify buffer sharing. GBM BOs allocated through omapdrm and imported into SGX
     (dma-buf), or the reverse, must reach the right scanout path (shmem + TILER on
     OMAP4, section 5.9 / `omap_gem.c`).
  3. Coexistence with `nq-hdmi hold`:
     - the GPU client becomes the DRM master only when the desktop (tinydm) is off;
     - it releases master on exit, so `nq-hdmi` and fbcon resume;
     - `nq-hdmi` already checks `_drm_master_present()` (repo:pmos/device-google-steelhead/nq-hdmi:190,285-289),
       so the hold logic must treat the visualizer as a legitimate master and must not
       fight it.
     - This reverses a recorded design decision. The HDMI-audio note rejected "a KMS
       client of our own" because it would have to re-implement the fbdev client's
       modeset, hotplug recovery and hand-back, and fight `tinydm` for mastership
       (repo:docs/2026-09-20-hdmi-audio-the-output-that-was-never-offered.md §5 "No
       second DRM master"; nq-hdmi:23-32). The visualizer must therefore own hotplug
       recovery itself, and the doc should be updated when the decision changes.
  4. Measure CPU%, temperature, XRUNs and the fps the cap allows at 1280×720 and
     640×480.
- **Exit.**
  - 30 min at 720p30 with flips, no visual corruption (the Maemo low-clock artifact
    check), and the XRUN baseline held with music playing.
  - Exit and restart 20× without leaking the DRM master or GEM memory.
  - HDMI audio keeps working across master handover (the hold must not drop the signal).
- **Test seen failing first.**
  - Readback test: render a known frame via GBM, `gbm_bo_map` the scanout BO, checksum
    it. No CRC or writeback connector is exposed by omapdrm (no `drm_writeback` in
    `drivers/gpu/drm/omapdrm/`), so client-side readback is the oracle.
  - Seen failing: clear to the wrong colour in one build and watch the checksum fail.
  - For the clock fix: run at the mainline-default SGX parent and look for the Maemo-type
    late-frame artifacts. Seeing them proves the clock criterion matters.
- **Risks.**
  - omapdrm + SGX dma-buf import quirks (Maemo patched `libdbm` for exactly this).
  - Tiler/rotation paths: openpvrsgx notes "works on Pyra if TILER framebuffer rotation
    … disabled".
  - HDMI pixel-clock cap (patch 0010) is unaffected.
- **Device safety.**
  - 30 fps cap and `timeout` on every run.
  - Thermal stop: the client exits if the temperature exceeds a set limit (e.g. 95 °C).
  - The user drives any listening test.
- **Effort.** 5–8 days.

### Phase 4: the stock visualizer on GLES2 (the product)

- **Goal.** A small DRM-master daemon (`nexusq-visualizer` or a nexusqd sibling) renders
  the stock scenes on HDMI, driven by the same audio state that drives the LED ring.
- **Entry.** Phase 3 exit.
- **Work:**
  1. Reuse the stock shaders verbatim (extract from `/app/Visualizer.apk` at build time
     from the stock image in `reverse-eng/`, or ship our own equivalents).
     **Licensing:** the shaders are "Copyright 2011 Google Inc." and stock APK content.
     Whether they may be redistributed in a public image is **UNVERIFIED**. Plan to
     re-author functionally equivalent shaders for public releases, and keep the
     originals only as a reference to match.
  2. Scene logic is already ported in C for the LEDs (`fx_*`, `BeatProcessor`). Add the
     GL draw side per scene:
     - particle field (40 sprites, `gl_PointSize 60`);
     - blur feedback with the six distort programs;
     - point-morph models;
     - track-info overlay from `nowPlaying` (shared with use case C).
  3. Lifecycle:
     - starts when HDMI audio is the output (or by app toggle) **and** the desktop is
       off;
     - yields the DRM master to tinydm;
     - idles the GPU (no frames) when the screensaver blanks (600 s rule from
       `docs/2026-06-19-particle-screensaver-RE.md:22-23`), so GFX can power-gate.
  4. App integration: a protocol field and toggle, in a new `PROTOCOL.md` section. The
     companion app version is bumped on its own track.
  5. Fallback: if `pvrsrvkm` is not loaded, run the same scenes on the Phase 0 SW
     renderer at reduced resolution, or show the DSS-plane now-playing screen. No black
     screen.
- **Exit.**
  - All five scenes plus the screensaver match stock behaviour. Compare against the
    stock APK's logic, and against a recording of the stock Q if available.
  - CPU at 720p30 is at least 2× lower than the SW reference.
  - XRUN baseline holds with music playing for 1 h.
  - Thermal under the limit.
  - GFX power-gates within N s of the visualizer stopping (genpd/clk shows off).
- **Test seen failing first.**
  - Per-scene golden-frame tests (offscreen FBO at fixed audio input and time) against
    the Phase 0 SW reference. Break one shader constant and watch the test go red.
  - A power test asserting GFX is off after stop. It must fail if the client leaks a
    context: deliberately skip `eglTerminate` in a test build.
- **Risks.**
  - Blur feedback EMIF load against audio. Mitigation: half-resolution FBO.
  - Long-run KM stability (leaks, SGX lockups). The KM's hardware recovery path must be
    exercised by a deliberate GPU hang test only once a recovery path is confirmed. Do
    not try that early.
- **Device safety.** Frame cap, thermal stop, and no blasting audio. The visualizer
  observes audio and never generates it.
- **Effort.** 10–15 days.

### Phase 5 (optional): accelerated labwc / weston

- **Goal.** wlroots' GLES2 renderer on SGX for the on-demand desktop.
- **Entry.** Phase 4 shipped, and the Phase 2 extension dump known.
- **Work:**
  1. If `GL_EXT_unpack_subimage` is absent, build the `LD_PRELOAD` shim (section 5.10).
     Ask Petr about an upstream wlroots MR before posting one.
  2. Start labwc with the private-prefix Mesa (`LD_LIBRARY_PATH` for the labwc process
     only) and `WLR_RENDERER=gles2`. Keep `pixman` as the automatic fallback: the
     session script picks pixman if `/dev/pvrsrvkm` is missing or the GLES2 init fails.
     That edits `nexusq-wayland.sh`.
  3. Measure against the Phase 0 baseline (idle and animated CPU, temperature, XRUN).
- **Exit.**
  - At least 30 % lower compositor CPU on the animated baseline.
  - No rendering artifacts (the `GL_CLAMP_TO_EDGE` issue from the 2021 patch).
  - Fallback to pixman proven by unloading the KM.
- **Test seen failing first.** Start labwc with `WLR_RENDERER=gles2` *without* the shim
  and watch it fail with "GL_EXT_unpack_subimage not supported". With the shim it starts.
  That proves the shim is what makes the difference.
- **Risks.**
  - The shim has to intercept the `eglGetProcAddress` paths.
  - The Mesa 24/22 private stack versus the system libwayland and libdrm ABI.
  - Qt clients that try EGL may pick up the wrong Mesa unless the prefix is scoped to
    the compositor only.
- **Effort.** 10–20 days. **Do it only if the desktop gets real use.**

### Phase 6: packaging, OTA, A/B, public release

- **Goal.** Everything above is reproducible from `docker-build.sh` and OTA-able.
- **Packages:**
  - **KM**: inside `linux-google-steelhead` (in-tree patches, section 5.3). It ships with
    every kernel OTA and rolls back with the slot.
  - **`nexusq-sgx-um`** (new aport, `license="custom:TI-TSPA"`): unmodified `ti443x`
    blobs, `pvrsrvctl`, the TSPA license file, and a `pvrsrvctl` systemd unit ordered
    after the module loads.
    - If the musl route is used: it is in `pmos/ota-packages.list`. It is about 1 MB
      (the ti443x deb is 974 KB), far under the 99 MB OTA guard.
    - If the glibc-rt route is used: glibc-rt is flash-only today, so a UM update would
      need either glibc-rt in OTA (182 MB is over the limit) or a separate glibc-side
      package. This argues for the musl route for the product.
  - **`nexusq-sgx-mesa`** (private prefix). It is built in the builder container, so the
    build stays single-writer.
  - **`nexusq-visualizer`** (Phase 4 daemon).
- **Boot-safety guard.** Change the Phase 1 blacklist to a guarded autoload:
  - a oneshot unit loads the KM only if the previous boot's GPU-attempt marker cleared;
  - if the box went down during the GPU bring-up, the next boot skips the GPU and
    reports through MQTT telemetry / `nq-healthd`;
  - this prevents a boot loop on a unit in the field.
- **A/B.** The KM rides the kernel slot. The UM, Mesa and visualizer ride the rootfs A/B
  (`nexusq-rootfs-ab`, repo:docs/2026-09-26-ab-slots-for-every-unit.md). The KM↔UM ABI
  is fixed at 1.17.4948957, so any kernel slot pairs with any rootfs slot as long as both
  stay on 1.17. A diag check asserts the pair.
- **Public release.**
  - `PUBLIC_RELEASE=1` images include the TSPA text.
  - Add a preflight check that every non-free blob has its license file next to it.
  - The stock-derived shaders are excluded unless cleared (Phase 4 note).
- **Test seen failing first.**
  - Remove the license file from the package. The new preflight must fail.
  - Simulate a crashed GPU boot (marker left set). The guard must skip the KM on the next
    boot.
- **Effort.** 5–8 days.

### Totals and ordering

| Phase | Effort (days) | Cumulative | Device risk |
|---|---|---|---|
| 0 Prep + baselines + SW reference | 4–6 | 4–6 | none (reads, bounded measurement) |
| 1 KM loads | 5–10 | 9–16 | medium (kernel trial slot, possible hang) |
| 2 Offscreen GLES2 + **go/no-go** | 4–8 | 13–24 | low |
| 3 KMS/GBM on omapdrm | 5–8 | 18–32 | medium (EMIF, thermal) |
| 4 Visualizer product | 10–15 | 28–47 | medium |
| 6 Packaging/OTA/licensing | 5–8 | 33–55 (≈ 8–14 weeks at ~4 effective days/week) | low |
| 5 Desktop (optional) | 10–20 | +2–4 weeks | medium-high |

The DSS-plane now-playing screen (use case C) is GPU-independent. It can run in parallel
from Phase 0 and shares Phase 4's DRM-master client.

---

## 7. Decisions this workstream recommends

1. Use **DDK 1.17.4948957** for both KM and UM. Drop 1.9 (`pvr-omap4`) and the stock 1.8
   bionic blobs.
2. Base the KM on **Maemo's 6.18 integration**, cross-checked against openpvrsgx `-v3`.
   Carry it as in-tree `kernel/patches`, built `=m`.
3. Install Mesa into a **private prefix**. Never replace Alpine Mesa.
4. Do the **visualizer first, as a direct KMS/GBM client**. The compositor comes later,
   optionally, through a shim, not a wlroots fork.
5. Build the **now-playing screen on DSS planes** now, without the GPU.
6. Make the **Phase 0 SW reference renderer** both the baseline and the fallback.
7. Measure **audio XRUN/underflow** in every rendering phase.

---

## Open questions

1. Does Maemo's current UM + Mesa (leste15, Mesa 24.0.9-sgx1 or 22.3.6+sgx2) expose
   `GL_EXT_unpack_subimage`? Answer: the Phase 2 extension dump. The 2021 evidence says
   no.
2. **Answered 2026-10-11:** `linux-image-omap 6.18.51.1` comes from `droid4-linux` tag
   `maemo-kernel-6.18.51.1` = `db432aff895b` = tip of branch `leste/maemo-6.18.y`
   (Makefile 6.18.51). *Kconfig choice answered 2026-10-11 (1.17 wins, the later
   line in the defconfig; shipped `/boot/config-6.18.51` has
   `CONFIG_PVRSGX_1_17_4948957=y`, [kdp](kernel-driver-port.md) Addendum A.2).* At that tag
   `omap2plus_defconfig` lists both `CONFIG_PVRSGX_1_14_3699939=y` (line 510) and
   `CONFIG_PVRSGX_1_17_4948957=y` (line 750). The shipped modules live under
   `pvrsgx/1.17.4948957/`, so 1.17 is what is built. The source package name is
   `omap-linux`.
3. Which Mesa source produced Maemo's `24.0.9-sgx1`? The `maemo-leste-upstream-forks/mesa`
   `maemo/excalibur` branch on GitHub still has `VERSION` = 22.3.6; *answered
   2026-10-11:* the Forgejo copy `git.maemo.org/leste-upstream-forks/mesa`
   `maemo/excalibur` = tag `powervr-24.0.9` @ `72c93be7aa29` (2025-12-27) is the
   source [ub Addendum §A.1].
4. SGX clock on the 4460: target rate, mux parent (stock = `dpll_per_m7x2_ck`), and
   whether the KM's DVFS (`sgxfreq_*.c` governors exist in the openpvrsgx OMAP system
   layer) should be enabled. Stock has `RequestSGXFreq` and `SysDvfs*`.
5. ~~GPTIMER11~~ **Mostly answered:** the `gpt11` `clk_get` code is compiled only in
   DEBUG/TIMING builds and only for 2.6.34 with `AM_VERSION` 5/6, so a release KM does
   not touch GPT11 (section 5.7). Open only if a DEBUG/TIMING build is wanted.
6. **Partly answered:** the `sgx-ddk-um-ti443x` file list has no separate firmware file.
   Which UM library embeds the microkernel is still open.
7. Is CMA 16 MB enough once GBM scanout BOs and SGX allocations coexist (Maemo uses 32)?
8. Do the stock Google shaders and PNGs have a redistribution path for public images, or
   must they be re-authored?
9. TI TSPA reading: is shipping the blobs in a public GitHub Pages OTA repo
   "redistribution in binary form without modification"? Petr to confirm.
10. ~~Is 6.18.48's `omap4.dtsi` SGX node identical to 6.12.12's?~~ **Answered: yes**
    (section 5.1). The real DT gap is the missing 4460 SGX clock assignment (section 5.7).
11. EMIF headroom: what is the measured bandwidth margin with HDMI 720p60 scanout,
    playing audio and a 720p30 blur-feedback GPU load? Only Phase 3/4 measurement can
    answer this.
12. Does Petr want the visualizer to run automatically whenever HDMI audio is selected,
    or only on demand? This changes the power and thermal default.

---

## Sources

Repository (at `dc988b9`, 2026-10-11):

- `docs/2026-06-19-gpu-sgx540-acceleration-research.md` (June feasibility note)
- `docs/2026-06-19-particle-screensaver-RE.md`, `docs/2026-06-19-music-effects-RE.md`
- `userspace/nexusqd/src/screensaver.c`
- `pmos/device-google-steelhead/nexusq-wayland.sh`, `pmos/device-google-steelhead/APKBUILD`, `pmos/device-google-steelhead/nq-hdmi`
- `PLAN.md` (§4 GUI 2160-2187, desktop-on-demand 1981-2002, thermal 2004-2008, SMP 2355-2376, hardware map 2095-2114)
- `docs/2026-06-23-session-findings.md` (§3 CPU baseline)
- `docs/2026-09-20-hdmi-audio-the-output-that-was-never-offered.md`
- `docs/2026-07-08-audio-crackle-dma-contention.md`, `docs/2026-07-12-audio-crackle-closed-sdma-priority-and-dpll-abe.md`
- `docs/2026-07-13-idle-power-governor-and-pid1-churn.md`
- `docs/2026-08-18-kernel-ota-phase2.md`, `docs/2026-08-02-full-system-ota-and-glibc-rt-split.md`, `docs/2026-09-26-idle-audit-five-pollers.md`
- `kernel/patches/0010-drm-omapdrm-hdmi4-cap-pixel-clock-steelhead.patch`, `kernel/configs/steelhead_defconfig`
- `companion/PROTOCOL.md`
- `build/linux-6.12.12/` (local mainline source): `arch/arm/boot/dts/ti/omap/omap4.dtsi:484-509`, `drivers/clk/ti/clk-44xx.c:327-339`, `drivers/gpu/drm/omapdrm/dss/dispc.c:4112-4463`, `drivers/gpu/drm/omapdrm/omap_plane.c:390,568-574`, `drivers/gpu/drm/omapdrm/omap_gem.c:800-820,1284-1320`, `drivers/gpu/drm/imagination/pvr_drv.c:1477`, `Documentation/devicetree/bindings/gpu/img,powervr-sgx.yaml`

Stock firmware (`reverse-eng/`, gitignored):

- `vmlinux.bin` strings (`sgxddk 18 1.8@785978`, `gpu_fck`/`dpll_per_m7x2_ck`, `SGXInit` messages, `pvrsrvkm.sgx_idle_*`); `reverse-eng/tools/kallsyms.txt` (279 PVR symbols)
- `factory/tungsten-ian67k/system.raw.img` via `debugfs`: `/vendor/lib/egl/*_POWERVR_SGX540_120.so`, `/vendor/lib/libsrv_um.so` etc., `/vendor/bin/pvrsrvinit`, `/vendor/lib/hw/{gralloc,hwcomposer}.omap4.so`, `/app/Visualizer.apk` (31 shader source files in `res/raw/`), `/app/Visualizer.odex`

Web (opened 2026-10-10/11):

- https://github.com/openpvrsgx-devgroup/linux_openpvrsgx (API): default branch `linux+pvrsgx` @ `2342ce92fdde` 2026-08-26 (7.2.0); `letux/pvrsrvkm-1.17.4948957` @ `584dd33a1557` 2025-05-04; `letux/pvrsrvkm-1.17.4948957-v3` @ `e5de75568819` 2026-08-21; `letux/omap-pvr-soc-glue-v10` @ `57c9a409ba70` 2026-08-16; `letux/pvrsrvkm-1.8.869593` @ `214f07dd8fe4` 2026-08-16; `drivers/gpu/drm/pvrsgx/TODO`; `pvr-drv.c` OF table (lines 363-364); `1.17.4948957/eurasia_km/services4/system/omap/sysutils_linux.c` (lines 79-83, 195-245, 275, 392-418, 566-577)
- https://github.com/openpvrsgx-devgroup/linux_openpvrsgx/issues/17 (2024-11, upstreaming outlook, IMG stopped SGX development); issues #22/#23 (2026-07)
- https://github.com/maemo-leste/droid4-linux branch `leste/maemo-6.18.y` @ `db432aff895b` 2026-09-22 (Makefile 6.18.51, = tag `maemo-kernel-6.18.51.1`) and branch `leste/maemo-6.18.y-glm` @ `858f1778b7b0` 2026-07-29 (Makefile 6.18.39); `drivers/gpu/drm/pvrsgx/`, `arch/arm/configs/omap2plus_defconfig`, `arch/arm/boot/dts/ti/omap/omap443x.dtsi`
- https://github.com/gregkh/linux at tags `v6.18.48` / `v6.18.51`: `arch/arm/boot/dts/ti/omap/{omap4,omap443x,omap4460}.dtsi`, `drivers/clk/ti/clk-44xx.c`, `drivers/gpu/drm/imagination/pvr_drv.c`, `Documentation/devicetree/bindings/gpu/img,powervr-sgx.yaml`
- https://github.com/maemo-leste/sgx-ddk-um (`debian/control`, `debian/changelog` 1.17.4948957+leste15, 2025-01-08; tree `ti443x/usr/lib/*`)
- https://github.com/maemo-leste/pvr-omap4 (last push 2022-02-01, 1.9.0.8.1.3-1)
- https://github.com/maemo-leste-upstream-forks/mesa (branches `maemo/daedalus` 2025-01-12, `maemo/excalibur` 2025-12-05; gallium `pvr`/`sgx` frontends)
- https://github.com/mobiaqua (mesa-sgx `mesa-22.3-sgx` 2024-11-22, libgbm 2023-02-19, kmscube 2024-06-22, sgx-pvr5-module 2025-04-06)
- https://maedevu.maemo.org/leste/dists/excalibur/main/binary-armhf/Packages.gz and `/dists/daedalus/...` (linux-image-omap 6.18.51.1-1+5m7 / 6.6.58.4-1+4m7; sgx-ddk-um-ti443x 1.17.4948957+leste15; Mesa 24.0.9-sgx1+5m7 / 22.3.6+sgx2-1+4m7)
- https://maedevu.maemo.org/leste/dists/excalibur/Contents-armhf.gz (`lib/modules/6.18.51/kernel/drivers/gpu/drm/pvrsgx/1.17.4948957/eurasia_km/pvrsrvkm_omap4_sgx540_120.ko`)
- https://leste.maemo.org/Motorola_Droid_4 (kernel 6.18 LTS, 3D yes/closed; edited 2026-09-27)
- https://leste.maemo.org/Motorola_Droid_4/PowerVR (stub, edited 2020-02-17)
- https://github.com/maemo-leste/maemo-leste.github.io (source branch `content/`: `maemo-leste-update-december-2020.rst`, `-april-2022.rst`, `-january-2023.rst`)
- https://tuxphones.com/maemo-leste-linux-nokia-n900-droid-4-powervr-gpu-acceleration-support/ (2020-04-03)
- https://gitlab.com/postmarketOS/pmaports/-/merge_requests/1868 (API; merged 2021-02-23), `/merge_requests/2573` (p-wlroots patch, opened 2021-10-05, closed 2021-11-01), issues #262, #932, #1316
- https://gitlab.postmarketos.org/postmarketOS/pmaports (clone; HEAD `862c5af2`, authored 2026-10-09, committed 2026-10-10; commits `b2d88000`, `1c1dbf23`, `865ff8dc`, `ed90e5da`, `fa2bae03`, `cecfb418`, `023f8cc1`; archived maguro/maserati packages; `linux-postmarketos-omap` 7.1.5)
- https://nura.eco/blog/2019/06/23/two-years/ (Galaxy Nexus mainline attempt by drebrez; redirected from postmarketos.org)
- https://itsfoss.com/news/postmarketos-nura-rebranding/ (2026-09-28; rename announced ~2026-09-27, domain nura.eco)
- wiki.postmarketos.org device pages for maguro, maserati and pandaboard **could not be read**: they redirect to wiki.nura.eco, which is behind an Anubis bot challenge (Access Denied), and archive.org returned 429. Their content is replaced here by the pmaports packages and history.
- https://lore.kernel.org/linux-arm-kernel/20230327125713.49537a26@aktux/T/ (Epson BT-200 OMAP4460 DTS, 2023-03)
- https://gitlab.freedesktop.org/wlroots/wlroots `render/gles2/renderer.c` at tags 0.19.0 (lines 544-558) and 0.20.2; tag list (0.20.2 2026-07-07)
- https://gitlab.freedesktop.org/wayland/weston `libweston/renderer-gl/gl-renderer.c` at 16.0.0 (2026-07-14)
- https://gitlab.alpinelinux.org/alpine/aports `main/pixman/APKBUILD` (0.46.4), `main/mesa/APKBUILD` (26.2.4), `community/labwc/APKBUILD` (0.20.2, wlroots0.20)
- https://dl-cdn.alpinelinux.org/alpine/edge/main/armv7/pixman-0.46.4-r0.apk (string `arm-neon` present)
- https://git.ti.com/cgit/graphics/omap5-sgx-ddk-um-linux (`OMAP5-Linux-Graphics-DDK-UM-Manifest.doc`, TI TSPA terms; tags `imgddk_ti_1.9.*`, `glsdk_*`)

---

## Verification (2026-10-11)

An adversarial fact-check of this note, done on 2026-10-11. Each claim was re-opened at its
source: GitHub/GitLab APIs, `maedevu.maemo.org` indexes, `gregkh/linux` stable tags,
a fresh blobless pmaports clone, the stock `vmlinux.bin` and `system.raw.img` (via
`debugfs`, nothing mounted), and the repo at `dc988b9`. The body above has been edited in
place. Corrections are marked "Corrected 2026-10-11".

### Confirmed (reproduced independently)

- **Maemo excalibur packages.** `linux-image-omap 6.18.51.1-1+5m7` (source
  `omap-linux`), `sgx-ddk-um-ti443x 1.17.4948957+leste15-1+5m7`
  (`Depends: libc6 (>= 2.34), libdrm2, libstdc++6`; `Conflicts` include `pvr-omap4`
  and `linux-image-droid4 (<< 5.15.0)`), and Mesa `24.0.9-sgx1+5m7` (`libc6 (>= 2.38)`).
  `Contents-armhf.gz` lists
  `lib/modules/6.18.51/kernel/drivers/gpu/drm/pvrsgx/1.17.4948957/eurasia_km/pvrsrvkm_omap4_sgx540_120.ko`.
  Daedalus has `6.6.58.4-1+4m7` and Mesa `22.3.6+sgx2-1+4m7` (`libc6 (>= 2.34)`).
- **Droid 4 wiki.** "6.18 LTS", "PowerVR SGX540 (closed driver)", last edited
  27 September 2026.
- **`leste/maemo-6.18.y-glm`** is 6.18.39 at `858f1778b7b0` (2026-07-29) and carries
  `pvrsgx/` with all DDK directories. It is just not the shipped branch (see corrections).
- **`sgx-ddk-um`.** leste15 is dated 2025-01-08 ("pull latest blobs"). The `libdbm`
  commits `cfd8e0f9a4` and `ce20a6afdd` are dated 2022-02-18. `pvr-omap4` was last
  pushed 2022-02-01, and its top changelog entry is `1.9.0.8.1.3-1`, 2020-05-27.
- **openpvrsgx branch tips.** `584dd33a1557` (2025-05-04), `-v3` `e5de75568819`
  (2026-08-21), `linux+pvrsgx` `2342ce92fdde` (2026-08-26; Makefile 7.2.0),
  `omap-pvr-soc-glue-v10` `57c9a409ba70` and `pvrsrvkm-1.8.869593` `214f07dd8fe4`
  (both 2026-08-16). `pvr-drv.c:363-364` maps `ti,omap4430-gpu` under
  `ti_omap4_sgx540_120`.
- **pmaports history.** `b2d88000`, `1c1dbf23` (tmlind `linux_openpvrsgx` `6ba3430a6fad`,
  5.15.2, `CONFIG_PVRSGX_1_17_4948957=y`), `865ff8dc`, `ed90e5da`, `fa2bae03`,
  `cecfb418` and `023f8cc1` all say what the note says. The 023f8cc1 quote from issue
  #1316 is verbatim. Issue #1316 ran 2021-11-27 → 2022-01-25 and #262 ran 2019-05-19 →
  2021-01-24. MR 1868 was merged 2021-02-23. The `sgx-ddk-um` APKBUILD has
  `pkgver=1.17.494857` (pmOS's own typo), `_commit=551665bf9c32…` and
  `depends="libc6-compat"`. The Jonathan Bakker patch dated 2021-01-02 is in MR 2573.
- **Archived pmOS ports.** maguro (LineageOS tuna 3.0.31) and maserati (3.0.8) are
  archived. There is no toro, tuna or pandaboard package.
- **Compositors.** wlroots 0.19.0 and 0.20.2 `renderer.c:554-558` hard-fail without
  `GL_EXT_unpack_subimage`; tag 0.20.2 is dated 2026-07-07. Weston 16.0.0
  `gl-renderer.c:5655-5659` fails on GLES < 3 without it; the tag is dated 2026-07-14.
- **Alpine.** labwc 0.20.2 builds against `wlroots0.20-dev`, mesa is 26.2.4 with no
  glvnd, and pixman is 0.46.4 with `--auto-features=auto`.
- **Stock firmware.** `CustomerGoogle_Android_ogles1_ogles2_GPL sgxddk 18 1.8@785978`,
  `failed to set gpu_fck to dpll_per_m7x2_ck`, the `pvrsrvkm.sgx_*` parameters and the
  `SGXInit … match. [ OK ]` / `PVRSRV_ERROR_CORE_REVISION_MISMATCH` strings are all in
  `vmlinux.bin`. kallsyms has 279 case-insensitive "pvr" hits, with `PVRSRVDriverProbe`
  at `c0276114`, `EnableSGXClocks` at `c0290d18` and `RequestSGXFreq` at `c0290c28`.
  `/vendor/lib/egl` holds the three `*_POWERVR_SGX540_120.so` files.
- **Repo facts.** These were all re-read at the cited lines:
  - PLAN.md:2099 (6 719 488 B, ~94 KB);
  - the kernel-OTA module-tree text (`docs/2026-08-18-kernel-ota-phase2.md:111-148`);
  - the crackle diagnosis and its 0041/0042 fixes;
  - the 30 % idle-compositor CPU figure;
  - the black-screen hold (§5);
  - the "screen-only, ignored" lines in the music-effects RE doc;
  - `CONFIG_MODULES=y` at defconfig:689, 154 `=m` options, `CONFIG_CMA_SIZE_MBYTES=16`
    at 5529;
  - glibc-rt is still flash-only (not in `pmos/ota-packages.list`);
  - the 99 MB OTA guard.
- **omapdrm (6.12.12).** OMAP4 has `num_ovls = 4`, `max_downscale = 4` and
  `has_writeback = true`. VID planes have SCALE, GLOBAL_ALPHA and PRE_MULT_ALPHA. The
  planes use `alpha`, `normalized_zpos` and `DRM_MODE_BLEND_PREMULTI`. The driver sets
  `DRIVER_RENDER`. The shmem + TILER scanout path is in `omap_gem.c:1298-1320`.
- **Upstream outlook.** openpvrsgx issue #17 quotes are accurate: StaticRocket wrote
  "IMG has stopped all development on SGX … no interest in adding anything older than
  AXE … hard expiration date" on 2024-11-03.
- **TI TSPA.** `strings` on `OMAP5-Linux-Graphics-DDK-UM-Manifest.doc` (git.ti.com, default
  branch) shows "TI TSPA License", "Redistribution and use in binary form, without
  modification", "reproduce" and "No reverse engineering, decompilation, or
  disassembly". The legal reading itself stays UNVERIFIED.
- **Maemo blog posts.** The 2020-12-27 post's "Corruption" section is quoted correctly
  (low SGX clock → late frames → artifacts), as are the 2022-04-16 (EXA, Mesa 21.2.5)
  and 2023-01-12 posts.

### Corrected

1. **Shipped Maemo kernel branch.** It is `leste/maemo-6.18.y` (6.18.51, `db432aff895b`,
   2026-09-22), which equals tag `maemo-kernel-6.18.51.1`, not `-glm` (6.18.39). This
   also answers open question 2.
2. **Visualizer shaders.** There are **31** shader source files (11 vertex, 20 fragment),
   not 25. `muted.png` (100×100) is also present. The APK's file date in
   `system.raw.img` is 2012-07-13 (zip entries are dated 2012-01-26).
3. **HDMI ceiling.** Patch 0010 rejects only `clock > 75000`, so 1920×1080@24/25/30
   (74.25 MHz) also passes. "At most 1280×720@60" is a sensible target, not a hard
   ceiling. The June note never implied 1080p, so that correction-table row was a
   strawman and has been reframed.
4. **SGX clock code in openpvrsgx.** `SGX_PARENT_CLOCK` is in `sysutils_linux.c:79-83`,
   not `sysconfig.h:80`. It is OMAP3-conditional and unused. The GPTIMER11 `clk_get`
   path is dead in a release build (DEBUG/TIMING plus 2.6.34 plus AM_VERSION 5/6 only).
   The claim "GPTIMER11 is used by the KM" and open question 5 are withdrawn.
5. **Mainline SGX clock (new, important).** `omap443x.dtsi` assigns the SGX to
   `dpll_per_m7x2_ck` at 307.2 MHz, but `omap4460.dtsi` (steelhead) does not. Claim 23
   ("may differ from stock") is therefore upgraded: nothing in our DT selects the stock
   parent. The actual runtime parent and rate on the Q are still unmeasured.
6. **MR 2573 dates.** It was opened 2021-10-05 and closed unmerged 2021-11-01; the earlier
   draft said "closed 2021-10-05".
7. **espresso3g today.** The device was renamed `samsung-espresso7` on 2022-11-22. The
   "removed 2022-03-24" date is the commit date; MR 3027 merged 2022-03-26.
8. **Galaxy Nexus 2019 mainline attempt.** It got well past initramfs (USB, storage,
   display, audio). "Only reached initramfs" was wrong.
9. **Maemo changelog.** The "weaken glib 2.29 symbol" entry attributed to leste13 does not
   exist. The real entries are leste12 "Weaking libGLESv1 symbols" (2022-02-14) and
   leste2 "Add glibc weakened libgslscompiler" (2021-11-22).
10. **`pvr-omap4` superseded.** This happened from 2021-11 (initial `sgx-ddk-um` import
    2021-11-15), not "about 2022-01".
11. **Blur traffic arithmetic.** 3 × 3.7 MB × 30 fps is ~0.33 GB/s of reads; ~0.55 GB/s
    with the two frame writes. The earlier "~0.6 GB/s" did not follow from its own
    factors.
12. **pixman NEON.** This is upgraded from "likely" to verified at instruction level:
    1500 `vmull.u8`, 1149 `vraddhn.i16` and 1146 `vrshr.u16` in an ARM-mode disassembly
    of the edge armv7 `libpixman-1.so.0.46.4`.
13. **6.18.48 SGX node.** The `omap4.dtsi` node is now verified identical to 6.12.12
    (claim 12 is upgraded to verified; open question 10 is answered).
14. **wlroots shim feasibility.** wlroots 0.20.2 links `libGLESv2` directly and already
    sets `GL_CLAMP_TO_EDGE` upstream, so the shim concern about `eglGetProcAddress` and
    CLAMP was overstated. Further hard EGL requirements were added (`no_config_context`,
    `surfaceless_context`, render node).
15. **Firmware.** The excalibur `ti443x` file list has no separate firmware file, so the
    June note's `sgx540_*.fw` is wrong for 1.17. This partly answers open question 6.
16. **MR 1868's Mesa** was `freemangordon/mesa` 20.3.2, not mobiaqua `mesa-sgx` as the
    June note says. A row was added to section 1.
17. **Idle temperature.** PLAN.md says 72–75 °C. The ~65–66 °C figure comes only from the
    2026-07-13 note's observer-free reading. Both are now cited.
18. **Archived maserati kernel.** It did build a downstream Android PVR KM (no UM). This
    nuance was added.
19. **DRM master.** The roadmap's DRM-master visualizer reverses the documented "No second
    DRM master" decision (HDMI-audio note §5). Phase 3 now says so.

### Could not reproduce or still unverified

- **Whether the leste15 blob plus Mesa 24.0.9 / 22.3.6 exposes `GL_EXT_unpack_subimage`.**
  The only evidence is from 2021 and indirect (MR 1868 text, MR 2573 patch). It stays
  "likely" until a Phase 2 dump.
- **The source of Maemo's Mesa `24.0.9-sgx1`.** `maemo-leste-upstream-forks/mesa`
  `maemo/excalibur` (`60902e8a0873`, 2025-12-05) has `VERSION` 22.3.6 and no
  `debian/changelog`, and the excalibur `Sources.gz` returned nothing. *Resolved
  2026-10-11:* the GitHub repo is a lagging mirror; the source is on Maemo's Forgejo
  (tag `powervr-24.0.9`, `72c93be7aa29`) [ub Addendum §A.1].
- **The Q's runtime SGX mux parent and rate, and the correct 4460 rate.** Stock only shows
  the parent name. Phase 0's clk_summary read and a stock-parity read of the stock clock
  code are needed.
- **Whether `/opt/glibc-rt` already contains the daedalus Mesa dependency closure.**
  Probably not, since it is a minimal Roon sandbox base.
- **The "X11 broken" claim for espresso3g specifically.** Only MR 1868's general "X-based
  DEs do not currently work" was found.
- **The TSPA legal reading** and **redistribution of the Google shaders.** Both are
  legal questions and were not checked.
- **All effort estimates, cycle-per-pixel estimates and SGX performance statements.**
  They are inference, as marked.
- **Not re-opened:** tuxphones 2020-04-03, the lore BT-200 thread, openpvrsgx issues #22
  and #23, and mobiaqua `libgbm` / `sgx-pvr5-module` dates. They do not change any
  decision here.
