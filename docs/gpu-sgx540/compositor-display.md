# SGX540 groundwork 5/7: Compositor and display: what the HDMI output can actually use

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

*Original working title: Workstream 05: the compositor and display side, and which acceleration the Nexus Q HDMI output can actually use*

**Date:** 2026-10-11 (Europe/Prague)
**Scope:** research and planning only. Nothing was built, flashed, committed or run on a device.
**Kernel under discussion:** mainline 6.18.48 plus our patch series (`kernel/patches/`). The omapdrm file and line references below are to **v6.18.48 as fetched from git.kernel.org stable**, before our patches. They were diffed against a local 6.19 tree: `dss/dispc.c`, `dss/hdmi4.c`, `dss/hdmi_pll.c` and `dss/pll.c` are identical, and `omap_plane.c`, `omap_drv.c` and `omap_gem.c` differ only in includes, one helper rename and the dumb-buffer size helper.
**Evidence tags:** every claim carries a file:line, a URL with what was seen there, a symbol or address in `reverse-eng/vmlinux.bin`, or **UNVERIFIED (reasoning)**. **[fact]** marks something read directly. **[inference]** marks a conclusion drawn from facts. **[estimate]** marks arithmetic built on stated assumptions.

---

## TL;DR

1. **What renders today.** The HDMI desktop is an on-demand LXQt-Wayland session: `tinydm`, then `labwc`, which is wlroots, using the **pixman** software renderer (`WLR_RENDERER=pixman`). The fallback session is weston with `renderer=pixman`. The appliance boots to `multi-user.target`, and the desktop runs only when the app asks for it. With no desktop, the in-kernel DRM fbdev client keeps HDMI lit at the `video=HDMI-A-1:1280x720@60` mode for HDMI audio (`nq-hdmi hold`). Alpine edge currently ships **labwc 0.20.2 on wlroots 0.20.2 (`wlroots0.20` r1), weston 16.0.0, Mesa 26.2.4 and pixman 0.46.4**. Which versions are actually on a unit is not verified: nothing was run on a device. `screensaver.c` in nexusqd drives the **LED ring only**. No HDMI visualizer exists today.
2. **Modern wlroots does not run on the SGX540 blobs as published.** Two hard blockers, both confirmed from primary sources:
   - **B1:** `GL_EXT_unpack_subimage` is a hard requirement of the wlroots GLES2 renderer (since 0.13.0, 2021-04-07) and of weston's gl-renderer for GLES2 (since 10.0.0). It is **absent from both SGX540 driver generations we can get**: stock Android DDK **1.8@785978**, read from `system.raw.img`, and TI's Linux DDK **1.17@4948957** for the `ti443x_linux` target, which is OMAP4, read from TI's git. TI itself still carries a weston revert patch for this in 2026 (meta-ti, 2026-03-24).
   - **B2:** wlroots has *checked for* `EGL_EXT_image_dma_buf_import` at renderer creation since 0.14.0 (2021-06-22), and has *functionally* needed it since 0.13.0 (2021-04-07), because from 0.13.0 on it renders into GBM BOs bound through dma-buf EGLImages (`render/gles2/renderer.c:82-108` at tag 0.13.0, `create_buffer` → `wlr_egl_create_image_from_dmabuf`). The Mesa-SGX shim at its HEAD **removed** dma-buf import (TI commit a698020, Randolph Sapp, 2024-09-11): "DDK 1.17's implementation of buffer imports/exports was half-baked and was never fully functional under Linux."

   The June note's "wlroots compositors work" claim comes from pmOS MR !1868 (merged 2021-02-23), which ran in the **wlroots 0.12 era**, when wlroots still rendered into a `gbm_surface`. **That claim is outdated for wlroots 0.20.**
3. **What *does* fit the SGX stack:** clients and compositors that render into an **EGL window surface on a `gbm_surface`**, with no dma-buf import:
   - **kmscube** (smooth mode);
   - **a dedicated full-screen KMS+GLES2 visualizer**;
   - **weston**, whose DRM backend still creates its output through `gbm_surface_create` (`libweston/backend-drm/drm-gbm.c:269-312`), once `GL_EXT_unpack_subimage` is solved.

   Caveat (added in verification): "no dma-buf import" holds at the **EGL API** level only. A `gbm_surface` BO is still allocated by the closed `libpvr_dri_support` (`PVRDRICreateImage` → `CreateImageShared`, mesa-sgx `sgx_ext.c:728`) and shared between pvrsrvkm and omapdrm for scan-out. mobiaqua's OMAP4 kernels carry `ti/0017-Revert-Revert-drm-omap-add-OMAP_BO-flags…`, `0020-restore-dmabuf-map.patch` and `0030-HACK-drm-omap-flush-the-mapped-page-in-kmap-kunmap.patch` (both `linux-ti_6.6.bb` and `linux-ti_6.8.bb`). UNVERIFIED whether even the `gbm_surface` path needs these on 6.18; that is a kernel-workstream question, not a given.

   The cleanest fix for B1 is to **emulate `GL_EXT_unpack_subimage` inside the Mesa-SGX dispatch shim**. That shim is our own non-Alpine package anyway, so the fix does not freeze a copy of wlroots or weston, which the global CLAUDE.md "no frozen fork" rule forbids. It is still a local patch on mobiaqua's mesa-sgx, though, and it needs a tracked base and rebase path, or upstreaming (§3.7). This is a design inference and was not prototyped.
4. **The display engine (DSS) is a capable compositor that needs no GPU.** omapdrm exposes **4 KMS planes: 1 primary and 3 overlays.** They map dynamically onto GFX, VID1, VID2 and VID3, which offer:
   - per-plane zpos, global alpha and premultiplied blending;
   - 5-tap scaling on VID1-3, from 1/8 to 8× in the atomic check;
   - NV12, YUYV and UYVY on the VID pipes;
   - a CRTC gamma LUT.

   `labwc` uses **only the primary plane**: wlr_scene direct scanout, and no `wlr_output_layer` use in labwc 0.20.2. libliftoff is compiled in but only engages with `WLR_DRM_FORCE_LIBLIFTOFF`. weston has a real plane-assignment engine.
5. **The stock particle screensaver does not need the GPU** [estimate]. Its 40 point sprites of 60 px are about 0.14 Mpx per frame. Two designs fit on a fraction of one A9 core with NEON:
   - render them on the CPU at half resolution and let a VID pipe upscale for free;
   - draw them damage-limited at native resolution.

   The **music scenes** (full-frame blur feedback with per-pixel distortion, `blur_distort_*_f`) are where the SGX540 earns its keep. On the CPU they are only feasible at reduced internal resolution plus DSS upscaling.
6. **HDMI modes.** Patch 0010 caps the pixel clock at 75 MHz. The live modes are therefore 640×480@60, 1024×768@60, **1280×720@60** and **1920×1080@24/25/30** (all 74.25 MHz). Interlaced modes are pruned, because the hdmi4 bridge never sets `interlace_allowed`.

   On a TV whose preferred mode is 1080p60, the kernel prunes 1080p60 and labwc picks **1920×1080@30** [inference, not observed on a TV]. The reason is that `drm_mode_compare` sorts by area before refresh, and `wlr_output_preferred_mode` falls back to the first mode in that list. labwc has a config-only lever against this: `<core><reuseOutputMode>yes</reuseOutputMode></core>` makes it test the CRTC's *current* mode (the fbdev 720p60) first (labwc 0.20.2 `src/output.c:474-481`, default `no` per `src/config/rcxml.c:1538`). Our `labwc-rc.xml` does not set it.

   **Stock offered up to 165 MHz.** The `omap4_steelhead_hdmi_device` structure in `vmlinux.bin` holds `regn=15, regm2=1, max_pixclk_khz=165000`. `regn=15`/`regm2=1` are TI's generic default HDMI PLL dividers (`HDMI_DEFAULT_REGN 15`, `HDMI_DEFAULT_REGM2 1`, Tomi Valkeinen, "OMAP: DSS2: HDMI: use default dividers", lkml 2012-03), not a steelhead-specific tuning. That makes the 75 MHz cap likely a *mask* over an omapdrm PLL or mode-set bug (task #13), not a hardware limit [inference].
7. **Fill rate is not the bottleneck** [estimate, with the TMU count UNVERIFIED]:

   | Load | Share of SGX540 peak (2 TMU/clk) |
   |---|---|
   | 1080p60, one opaque full-screen layer, at 307.2 MHz | ~20 % |
   | 720p60, same layer, at 307.2 MHz | ~9 % |

   **The real limits are:**
   - **EMIF bandwidth shared with the McBSP2 audio DMA.** That contention already caused the 2026-07 crackle. A full-screen 1080p60 composite costs about 1.0 GB/s of traffic plus 0.5 GB/s of scanout.
   - **CPU-side driver overhead.**
   - **Texture uploads of `wl_shm` clients.** These are CPU work on the SGX (UNVERIFIED: software twiddling).
   - **Thermals.** The die already reached 102.8 °C under sustained load.
   - **VDD_CORE.** Stock's 384 MHz GPU OPP needs core at 1.25 V. Since v1.4.0 (2026-06-26) VDD_MPU is on the TPS62361 (patch 0014) and VDD_CORE is on TWL6030 VCORE1 with the stock VC ON voltage of 1.200 V (patch 0027). No core DVFS is known on our kernel (UNVERIFIED), so plan for **307.2 MHz (needs ≥ 1.127 V)** until the core rail is measured.
8. **Video:** mainline has the OMAP4 IPU remoteproc driver and a DT node (disabled), but there is **no codec path**. Hardware decode would need:
   - TI's out-of-tree `rpmsg-rpc` patches;
   - `libdce`;
   - an IPU-MM firmware (`omap4-ipu-fw.xem3`), which mobiaqua builds for Pandaboard;
   - and the stock `ducati-m3.bin` is an OMX-over-rpmsg build, not DCE.

   For an audio-first appliance this is the **lowest priority**. The cheap win for occasional video is the DSS: NV12 on a VID pipe with free scaling.

---

## 1. What renders today

### 1.1 Session topology [fact]

| Piece | What it does | Evidence |
|---|---|---|
| Default target | `multi-user.target`. The desktop is **off** by default and starts only on demand (`setDesktop` → `systemctl start tinydm`). | `pmos/device-google-steelhead/APKBUILD:204-216` (comment plus `ln -sf …multi-user.target …/default.target`); PLAN.md:1981-2001 |
| Desktop | LXQt-Wayland (`lxqt-wayland-session`), compositor pinned to **labwc** | `pmos/device-google-steelhead/lxqt-session.conf:1-7`; APKBUILD `depends` lines 48-49 |
| Renderer | `WLR_RENDERER=pixman`, `WLR_NO_HARDWARE_CURSORS=1` from `/etc/profile.d/nexusq-wayland.sh` | `nexusq-wayland.sh:8-9` |
| Fallback session | weston, `[core] renderer=pixman`, `backend=drm-backend.so`, `require-input=false`, background `#000F14` | `weston.ini:8-20`; `weston-nexusq.desktop:6` |
| labwc config | keybind-less; volume is done by nexusqd | `labwc-rc.xml` |
| HDMI with no desktop | in-kernel DRM fbdev client lit by `nq-hdmi hold`: unblank `fb0`, park the console on tty8, cursor off. It **deliberately does not take DRM master** and yields to any compositor. | `nq-hdmi:23-41, 187-214, 280-294` |
| Boot mode | `video=HDMI-A-1:1280x720@60` in the built-in cmdline | `kernel/configs/steelhead_defconfig:489` |
| Pixel clock cap | 75 MHz `.mode_valid` on the hdmi4 bridge | `kernel/patches/0010-…:38-46` |

Inside the session, the GPU-free path is:

```
clients (Qt widgets → wl_shm; QtQuick/GL clients → Mesa llvmpipe)
   → labwc / wlroots 0.20 scene graph
      → pixman renderer, compositing into omapdrm *dumb* buffers
         → atomic commit on the primary plane (omapdrm assigns GFX or a VID pipe)
            → DISPC TV manager → HDMI (TPD12S015 level shifter) → sink
```

### 1.2 Why GLES2 fails today, and what it would take

- **[fact]** `wlr_renderer_autocreate` tries gles2, then vulkan, then pixman. In auto mode, pixman is chosen only if the backend has **no render node** (`render/wlr_renderer.c:219-268` at wlroots tag 0.20.2). omapdrm registers `DRIVER_RENDER` (`omap_drv.c:639`, v6.18.48), so a render node exists. Auto therefore never reaches pixman, and `WLR_RENDERER=pixman` is mandatory today. That matches the comment in `nexusq-wayland.sh:2-7`.
- **[fact]** With stock Alpine Mesa, the only EGL device available for omapdrm is a software one. wlroots refuses it unless `WLR_RENDERER_ALLOW_SOFTWARE` is set (`render/egl.c:330-338`, 0.20.2).
- **[inference]** The device package's `mesa-dri-gallium` dependency (`APKBUILD:45`) therefore serves only GL *clients* (llvmpipe), never the compositor.

### 1.3 Package versions in play

| Package | Version in Alpine edge `master` on 2026-10-11 | Evidence |
|---|---|---|
| labwc | **0.20.2**-r0 (upgraded 2026-08-22, aports `277a1dec`) | `community/labwc/APKBUILD` raw + GitLab commits API |
| wlroots | **wlroots0.20 0.20.2**-r1 (upgraded 2026-07-08 `76562f88`; crash-fix backport 2026-07-15 `6d015184`; made default 2026-03-26). The version/pkgrel was re-confirmed 2026-10-11. The three commit dates could **not** be reproduced: the GitLab commits API returned HTTP 500. | `community/wlroots0.20/APKBUILD` + commits API |
| weston | **16.0.0** (tag 2026-07-14) | `community/weston/APKBUILD`; weston tags API |
| mesa | **26.2.4**-r1, built without libglvnd (no `-Dglvnd`, no `libglvnd-dev` in makedepends) | `main/mesa/APKBUILD` raw |
| pixman | 0.46.4 | `main/pixman/APKBUILD` |
| kmscube | `0_git20220902` | `community/kmscube/APKBUILD` |
| swaybg | 1.2.2 | `community/swaybg/APKBUILD` |

- **[fact]** The build pins **pmaports** to `11e89dfb…` (`docker-build.sh:164`). The `systemd-edge` channel uses the **Alpine edge** binary repos (`docker-build.sh:821-825`), which are not pinned. Packages are therefore whatever edge held at image build time.
- **[inference]** v2.0.2 was released 2026-10-10 (CHANGELOG.md:81). A rootfs built for it would carry labwc 0.20.2 and wlroots 0.20.2. UNVERIFIED: OTA releases only move our own packages, and the last *full* image build date was not checked.
- **To verify on a unit** (not done, by instruction): `apk info -v labwc wlroots0.20 weston mesa-egl pixman`.

### 1.4 Buffer path under pixman, and a cheap CPU-side lever

- **[fact]** wlroots picks its allocator by capabilities (`render/allocator/allocator.c:105-160`, 0.20.2):
  - GBM needs DMABUF on *both* sides. The pixman renderer has only `DATA_PTR`, so GBM is skipped.
  - The shm allocator needs `SHM` on the backend, and the DRM backend has only `DMABUF`, so it is skipped too.
  - That leaves the **DRM dumb allocator**, selected at line 142.
- **[fact]** omapdrm's dumb buffers are created with `OMAP_BO_SCANOUT | OMAP_BO_WC` (`omap_gem.c:594`, v6.18.48). With DMM present, they are shmem pages pinned through a DMM/TILER 1D container at scan-out (`omap_gem.c:816`, `omap_gem.c:1308`). Without DMM, they would come from `dma_alloc_wc` (CMA).
- **[inference]** pixman composites *into* a write-combined, CPU-uncached mapping. Any blend that reads the destination reads uncached memory. That covers OVER on translucent panels, shadows, and the software cursor (`WLR_NO_HARDWARE_CURSORS=1`; omapdrm has no cursor plane anyway). Uncached reads on a Cortex-A9 are typically an order of magnitude slower than cached reads. This is a plausible part of the **~30 % CPU idle-desktop baseline** measured on 2026-06-23 (`docs/2026-06-23-session-findings.md:58-62`). UNVERIFIED: profile `labwc` with `perf` before acting.
- Possible levers, none a shortcut and all to be measured first:
  1. Try the cached omapdrm BO mode for dumb buffers, with correct cache maintenance at flip. This is a kernel change and needs upstream discussion.
  2. A wlroots option to render into a cached shadow buffer and copy damage. That is an upstream wlroots feature request.
  3. Keep translucency off in the LXQt theme. That is configuration only.

### 1.5 What omapdrm exposes on steelhead

| Item | Value | Evidence |
|---|---|---|
| CRTCs / connectors | 1 (HDMI-A-1 only; DPI, VENC and DSI are compiled in but have no DT pipeline on steelhead) | `omap_drv.c` `omap_modeset_init`; DTS patch 0003 only wires `&hdmi` |
| Planes | `num_ovls = 4` on OMAP4: **1 PRIMARY + 3 OVERLAY** KMS planes, each usable on any CRTC | `dss/dispc.c:4282-4321` (`omap44xx_dispc_feats`, `.num_ovls = 4`); `omap_drv.c:427` |
| Plane → hardware mapping | **dynamic**: a KMS plane grabs GFX, VID1, VID2 or VID3 per commit, according to the caps it needs (scaling, format). A plane wider than 2048 px takes **two** overlays (the "right overlay"). | `omap_plane.c:300-353` (`omap_overlay_assign`) |
| Plane properties | `zpos` (normalised), `alpha`, `pixel blend mode` (premultiplied and coverage) on all planes. `COLOR_ENCODING` / `COLOR_RANGE` only on planes whose *advertised* format list has YUV. | `omap_plane.c:568-580`, `omap_plane_supports_yuv` `omap_plane.c:502-514`; `omap_drv.c:525` |
| Advertised formats per KMS plane | Each KMS plane advertises the format list of the hardware pipe with the same index (`omap_plane_init`: `dispc_ovl_get_color_modes(priv->dispc, omap_plane->id)`, `omap_plane.c:543`). So the **primary plane (id 0) advertises the GFX list: no NV12/YUYV/UYVY**, and NV12 video needs one of the three overlay KMS planes, even though the hardware pipe behind a plane is assigned dynamically. | `omap_plane.c:519-556`; `omap_drv.c:427-433` (v6.18.48) |
| Scaling | GFX: none. VID1-3: `OMAP_DSS_OVL_CAP_SCALE`. Atomic check allows 1/8 … 8×. Real limits at commit: `max_downscale = 4`, horizontal decimation ≤ 4 (except NV12), core-clock check `calc_core_clk_44xx` | `dispc.c:3966-3986`, `dispc.c:2383-2440`, `dispc.c:2228-2244`; `omap_plane.c:243` |
| Formats | GFX: RGB565, (A/X)RGB8888, RGBA/RGBX8888, RGB888, 4444/1555 variants. VID1-3 add **NV12, YUYV, UYVY**. **No ABGR/XBGR8888 anywhere.** | `dispc.c:4033-4085` |
| Modifiers | none (linear only; no `format_mod_supported`) | grep of `omapdrm/*.c` |
| Sizes | overlay and manager max 2048×2048. `max_tv_pclk` = **185.625 MHz**. `max_lcd_pclk` = 170 MHz. | `dispc.c:4290-4296` |
| Other | gamma table (`has_gamma_table`), writeback hardware (`has_writeback`, but WB is **not exposed** by mainline omapdrm; mobiaqua and TI carry `drm-omap-wb` patches) | `dispc.c:4316-4320`; mobiaqua `meta-ti/recipes-kernel/linux/linux-ti_6.8/drm/0007-drm-omap-wb.patch` |
| TILER rotation | only for `OMAP_BO_TILED_*` BOs, which need the OMAP-specific GEM ioctl. Generic dumb or GBM buffers cannot rotate. | `omap_fb.c:100-103` (6.19 tree) |
| Cursor plane | none | no `DRM_PLANE_TYPE_CURSOR` in omapdrm |

### 1.6 Particle and screensaver code today

- **[fact]** `userspace/nexusqd/src/screensaver.c:1-63` is the **LED-ring** breathing screensaver: a solid `#0099CC × A` colour, a 10 s cosine, a 5 s fade-in, a lock after 300 s and a blank after 600 s.
- **[fact]** It never touches HDMI. `docs/2026-06-19-particle-screensaver-RE.md:11-13, 111-112` states the particle field is "HDMI/GL only … not ported".
- **[fact]** There is no HDMI visualizer in the repo today.

---

## 2. Ground truth from the stock firmware

| Finding | Evidence |
|---|---|
| Stock GL is **DDK 1.8@785978** ("OpenGL ES 2.0 build 1.8@785978", "1.4 build 1.8@785978"). Blobs are named `*_POWERVR_SGX540_120`, so the core revision is 1.2.0. | `debugfs dump /vendor/lib/egl/libGLESv2_POWERVR_SGX540_120.so` and `/vendor/lib/libIMGegl.so` from `reverse-eng/factory/tungsten-ian67k/system.raw.img`; `strings`; `/lib/egl/egl.cfg` = `0 1 POWERVR_SGX540_120` |
| Stock GLES2 extension names present: `GL_EXT_discard_framebuffer`, `GL_EXT_multi_draw_arrays`, `GL_EXT_shader_texture_lod`, **`GL_EXT_texture_format_BGRA8888`**, `GL_IMG_multisampled_render_to_texture`, `GL_IMG_program_binary`, `GL_IMG_read_format`, `GL_IMG_shader_binary`, `GL_IMG_texture_compression_pvrtc`, `GL_IMG_texture_format_BGRA8888`, `GL_IMG_texture_npot`, `GL_IMG_texture_stream2`, `GL_OES_compressed_ETC1_RGB8_texture`, `GL_OES_depth24`, `GL_OES_depth_texture`, **`GL_OES_EGL_image`**, **`GL_OES_EGL_image_external`**, `GL_OES_egl_sync`, `GL_OES_element_index_uint`, `GL_OES_fragment_precision_high`, `GL_OES_get_program_binary`, `GL_OES_mapbuffer`, `GL_OES_packed_depth_stencil`, `GL_OES_required_internalformat`, `GL_OES_rgb8_rgba8`, `GL_OES_standard_derivatives`, `GL_OES_texture_float`, `GL_OES_texture_half_float`, `GL_OES_vertex_array_object`, `GL_OES_vertex_half_float`. **No `GL_EXT_unpack_subimage`.** | `strings` on the dumped `libGLESv2_POWERVR_SGX540_120.so` (string presence; the runtime `glGetString` output was not captured) |
| Stock EGL (`libIMGegl.so`) extension names: `EGL_ANDROID_blob_cache`, `EGL_ANDROID_image_native_buffer`, `EGL_ANDROID_recordable`, `EGL_IMG_context_priority`, `EGL_KHR_fence_sync`, `EGL_KHR_gl_renderbuffer_image`, `EGL_KHR_gl_texture_2D_image`, `EGL_KHR_gl_texture_cubemap_image`, `EGL_KHR_image`, `EGL_KHR_image_base`, `EGL_KHR_vg_parent_image`. These are Android-only, with no dma-buf or GBM platform. Irrelevant on Linux, where EGL comes from Mesa. | same, `libIMGegl.so` |
| Stock composition used **DSS overlays via `dsscomp`** in `hwcomposer.omap4.so` ("/dev/dsscomp", "Primary display is HDMI", "DSS scaler cannot support HDMI cloning", "used %d z-layers for %d overlays") plus TILER/ION | `strings hwcomposer.omap4.so`; kallsyms families `dsscomp_*` (12), `tiler_*` (25), `ion_*` |
| Stock kernel had **pvrsrvkm built in** (`PVRSRV*`, `sgx_idle*`) and `rpmsg_omx` (Ducati OMX) | `reverse-eng/tools/kallsyms.txt` |
| **Stock GPU OPPs, OMAP446x table:** `gpu`, `core`, `dpll_per_m7x2_ck` at **153.6 MHz @ 0.962 V, 307.2 MHz @ 1.127 V, 384.0 MHz @ 1.25 V**, all `default_available=1` | `vmlinux.bin` OPP structs at `0xc0043e94`, `0xc0043eac`, `0xc0043ec4` (24-byte `omap_opp_def`: hwmod, voltdm, clk, freq, u_volt, avail); the 4430 table at `0xc0043c9c` / `0xc0043cb4` stops at 307.2 MHz |
| **Stock HDMI device:** `type=0x20` (OMAP_DISPLAY_TYPE_HDMI), `channel=1` (DIGIT), **`clocks.hdmi.regn=15`, `regm2=1`, `max_pixclk_khz=165000`** | `omap4_steelhead_hdmi_device` @ `0xc0719cc8` (kallsyms): words at +0x150 = 0x20, +0x154 = 1, +0x194 = 0x0001000f, +0x198 = 165000 (re-dumped 2026-10-11). **[inference]** The field naming matches the TI 3.0 `omap_dss_device.clocks.hdmi` layout. `regn=15`/`regm2=1` equal TI's `HDMI_DEFAULT_REGN`/`HDMI_DEFAULT_REGM2` (lkml.iu.edu/hypermail/linux/kernel/1203.1/01024.html), and the old driver computed `refclk = clkin / (regn + 1)`, so register 15 means N = 16. In the TI 3.0 HDMI driver, `max_pixclk_khz` drops EDID modes above it (ara-mdk `kernel/panda` `hdmi.c`, seen via search snippet only). |
| **Stock omapfb VRAM = 16 MiB** (`steelhead_fb_pdata` +0x30 = 0x01000000). This is exactly enough for **double-buffered 1920×1080×32 bpp** (16 588 800 B ≤ 16 777 216 B). | `steelhead_fb_pdata` @ `0xc071978c`. **[inference]** Stock planned for 1080p. |
| Stock HDMI code honours EDID preference ("Preferred cea_mode[%d], %dx%d@%d") and has `hdmi_set_timings_with_tolerance` | `strings vmlinux.bin`; kallsyms `c02400c4 hdmi_set_timings_with_tolerance` |
| Stock IVA-HD firmware `/vendor/firmware/ducati-m3.bin` (2 314 420 B) exposes **`OMX.TI.DUCATI1.VIDEO.DECODER`, `OMX.TI.DUCATI1.VIDEO.H264E`, `OMX.TI.DUCATI1.VIDEO.MPEG4E`, `OMX.TI.DUCATI1.MISC.SAMPLE`**, built on `codec_engine_3_21_00_13` | `strings ducati-m3.bin` |
| Stock Visualizer renders into **offscreen FBO render targets** (`TextureRenderTarget`, `TextureRenderTargetPool`, `BaseRenderTarget`, `ScreenRenderTarget`, `glFramebufferTexture2D`) and has a `BlurEffect` with `BlurDistortProgram` | `strings /app/Visualizer.odex` (dumped from `system.raw.img`). The FBO size is **not** recovered (see Open questions). |
| Visualizer shaders: particle screensaver = point sprites, `gl_PointSize = 60.0`, textured by a 64×64 `particle.png` times `uColor`. Music scenes use full-screen **feedback blur** passes (`blur_distort_{plain,cells,concave,hstrips,vstrips,splurge}_f`: `texture2D(prev) - vec4(0.002,0.002,0.002,0)` then `× vec4(1,1,1,0.95)`, so the 0.95 factor scales **alpha only**; `blur_distort_plain_f` is self-described as "A non-distorting blurring shader"), plus point and line scenes (`pointmorph`, `circles`, `waveform`, `starfield`, `icebox`) | `private/nexusq-original/visualizer/*` (read-only); PNG headers: `particle.png` 64×64, `particle2.png` 64×64, `muted.png` 100×100 |

---

## 3. Renderer requirements against what the SGX540 stacks expose

### 3.1 wlroots 0.20.2, GLES2 renderer: hard requirements

All references are from the 0.20.2 tag on gitlab.freedesktop.org, fetched 2026-10-11.

| # | Requirement | Where | Hard or soft |
|---|---|---|---|
| W1 | `EGL_EXT_platform_base` (client) | `render/egl.c:207-208` | hard |
| W2 | either `EGL_EXT_platform_device` with `EGL_EXT_device_query`/`enumeration` matching the DRM fd, **or** `EGL_KHR_platform_gbm` on the backend's **render node** (`open_render_node`, `gbm_create_device`) | `render/egl.c:536-608` | one of the two |
| W3 | `EGL_KHR_no_config_context` or `EGL_MESA_configless_context` | `render/egl.c:342-347` | hard |
| W4 | `EGL_KHR_surfaceless_context` | `render/egl.c:349-352` | hard |
| W5 | **`EGL_EXT_image_dma_buf_import`** | `render/gles2/renderer.c:544-548` | **hard** (checked since 0.14.0; functionally needed since 0.13.0) |
| W6 | `EGL_KHR_image_base` | `render/egl.c:279`, `egl.c:737-740` | needed for every dma-buf import |
| W7 | **`GL_EXT_texture_format_BGRA8888`** | `renderer.c:549-553` | hard |
| W8 | **`GL_EXT_unpack_subimage`** | `renderer.c:554-558`; used at `render/gles2/texture.c:82-94, 345-348` | **hard** (since 0.13.0) |
| W9 | `GL_OES_EGL_image` (`glEGLImageTargetRenderbufferStorageOES` for render buffers, `…Texture2DOES` for client dma-bufs) | `renderer.c:586-590` | effectively hard: no render target without it |
| W10 | GLES ≥ 2.0 context | `render/egl.c:629` | hard |
| — | Software EGL device refused unless `WLR_RENDERER_ALLOW_SOFTWARE` | `render/egl.c:330-338` | — |
| — | optional: `GL_EXT_read_format_bgra`, `GL_OES_EGL_image_external`, `GL_KHR_debug`, `GL_KHR_robustness`, `GL_EXT_disjoint_timer_query`, `EGL_EXT_image_dma_buf_import_modifiers` (a fallback format list exists, `egl.c:843-852`), `EGL_KHR_fence_sync` + `EGL_ANDROID_native_fence_sync`, `EGL_IMG_context_priority` | `renderer.c:560-612`; `egl.c:354-367` | soft |

History, read from the tag sources:

| wlroots version | Render target | `GL_EXT_unpack_subimage` | `EGL_EXT_image_dma_buf_import` |
|---|---|---|---|
| **0.12.0** | `gbm_surface` (`backend/drm/renderer.c:86-100`) | not required (`render/gles2/renderer.c` has no such check) | optional (`renderer.c:463`) |
| **0.13.0** (tag 2021-04-07) | swapchain + `wlr_renderer_bind_buffer` | **required** (`renderer.c:880-881`) | not checked at creation (`renderer.c:633` only logs), but **functionally required** to render: `create_buffer` imports every render buffer as a dma-buf EGLImage (`renderer.c:82-108`) |
| **0.14.0** (tag 2021-06-22) | — | — | **required** at creation (`renderer.c:792`) |

### 3.2 weston 16.0.0, gl-renderer

| Requirement | Evidence |
|---|---|
| `GL_RGBA8` FBO support. **[inference]** `GL_OES_rgb8_rgba8`, which SGX has, provides it. | `libweston/renderer-gl/gl-renderer.c:5633-5636` |
| **`GL_EXT_unpack_subimage` when GL < 3.0** | `gl-renderer.c:5655-5659`. Introduced by upstream commit `593d5af43a8e2c2a3371088fa7ae430d0517c82d` "gl-renderer: require GL_EXT_unpack_subimage" (Pekka Paalanen, 2020-12-15), first in tag **10.0.0** (GitLab commit refs API). |
| `EGL_KHR_surfaceless_context` | `gl-renderer.c:5375` |
| dma-buf import **optional**: linux-dmabuf is offered only if `EGL_EXT_image_dma_buf_import` and `GL_OES_EGL_image` | `gl-renderer.c:5406-5407` |
| **Output rendering through `gbm_surface`** (EGL window surface), with no dma-buf import needed for the compositor's own output | `libweston/backend-drm/drm-gbm.c:269-312, 529-537` |
| Plane assignment engine (overlay and underlay planes, `MIXED` / `PLANES_ONLY` states) | `libweston/backend-drm/state-propose.c:50-63, 171-188` |

TI's position, from the meta-ti `[master]` patch "weston: Update to 15.0.0" (Ryan Eatmon, 2026-03-24, seen on ratatoskr.run; thread active until 2026-05-04; whether it was merged was not checked): it carries `0001-Revert-require-GL_EXT_unpack_subimage-commit.patch`, which reverts `593d5af4…`, adds `has_unpack_subimage` and changes the flush-damage upload path. The patch is marked `Upstream-Status: Inappropriate [specific to TI SGX]`. **[inference]** TI's own current SGX5 Linux stack has no `GL_EXT_unpack_subimage`.

### 3.3 kmscube (upstream master, and Alpine `0_git20220902`)

- **[fact]** Default "smooth" mode needs the following (`common.c:110-178, 397-432, 466-486` on gitlab master):
  - GBM;
  - `EGL_EXT_platform_base` (or `eglGetDisplay(gbm)`);
  - a `gbm_surface` with `eglCreateWindowSurface`.

  Optional extras are `EGL_KHR_image_base`, `GL_OES_EGL_image` and `EGL_EXT_image_dma_buf_import_modifiers` (texture and video modes), plus `EGL_KHR_fence_sync` and `EGL_ANDROID_native_fence_sync` (atomic mode).
- **[inference]** kmscube smooth mode with legacy KMS **never imports a dma-buf through EGL**. It is the right first test. Two caveats: the BO sharing between the closed DDK and omapdrm still happens below EGL (see the TL;DR item 3 caveat), and legacy mode calls `drmModeSetCrtc` with its own chosen mode (`drm-legacy.c:69`). If that mode differs from the fbdev 720p60, it is a full modeset, which interrupts HDMI audio. Pass the current mode explicitly. mobiaqua keeps a TI PSDKLA-derived fork for Pandaboard (`github.com/mobiaqua/kmscube`, last commit 2024-06-22 "implement enumerate drm devices").

### 3.4 What the SGX540 Linux stack actually exposes

The modern stack has three layers, per mobiaqua's Pandaboard (OMAP4430/4460) machine config `meta-ti/conf/machine/panda.conf` and recipes:

1. **Kernel:** `panda.conf` pins `PREFERRED_VERSION_linux-ti = "6.6%"`. A `linux-ti_6.8.bb` recipe with the same SGX, rpmsg-rpc and omapdrm patches also exists. Both are mainline plus TI or mobiaqua patches, with `sgx-module-series5`.
2. **Closed userspace:** `ti-sgx-ddk-um` **1.17.4948957** from `git.ti.com/git/graphics/omap5-sgx-ddk-um-linux.git`. The branch is `1.17.4948957/mesa/glibc-2.35`, SRCREV **`84a396a4fb379f10931421e489ac8a199d6a9f2c`** ("all: rebuild with major fixes applied", 2024-10-16). `TARGET_PRODUCT:panda = "ti443x_linux"` (`meta-ti/recipes-bsp/libgles/ti-sgx-ddk-um_1.17.4948957.bb`).
3. **Open shim:** **mesa-sgx** 22.3.7, `github.com/mobiaqua/mesa-sgx`, branch `mesa-22.3-sgx`, built with `-Dgallium-sgx-alias=omapdrm` (`meta-ti/recipes-graphics/mesa/mesa-sgx_22.3.7.bb`, SRCREV **`9d86c74493ec194ed01958eca71c5532b626df27`**).
   - It is a Gallium "frontend" shim (`src/gallium/frontends/sgx/*`, IMG MIT licence).
   - It `dlopen`s `libpvr_dri_support.so` (`sgx_compat.c:43,110`).
   - It installs the closed library's GL entry points into Mesa's glapi dispatch table (`pvrdri_add_mesa_dispatch`, `sgx_context.c:134-175`). It does this primarily with `dlsym` on the closed library handle, and falls back to `PVRDRIEGLGetProcAddress` only when `dlsym` fails.
   - The `meson_options.txt` help for `gallium-sgx-alias` says it "must match the name of the kernel display driver".

What the closed GLES2 library exposes:

- **[fact]** In TI DDK 1.17 for `ti443x_linux`, i.e. OMAP4 (`targetfs/ti443x_linux/lws-generic/release/usr/lib/libGLESv2_PVR_MESA.so.1.17.4948957`, cloned and read 2026-10-11 at `84a396a4`): "OpenGL ES 2.0 build 1.17@4948957", "OpenGL ES GLSL ES 1.00 build 1.17@4948957".
- **[fact]** Extension names present:
  `GL_EXT_blend_minmax GL_EXT_discard_framebuffer GL_EXT_multi_draw_arrays GL_EXT_multisampled_render_to_texture GL_EXT_shader_texture_lod GL_EXT_texture_format_BGRA8888 GL_EXT_texture_rg GL_EXT_texture_storage GL_IMG_multisampled_render_to_texture GL_IMG_program_binary GL_IMG_read_format GL_IMG_shader_binary GL_IMG_texture_compression_pvrtc GL_IMG_texture_format_BGRA8888 GL_IMG_texture_npot GL_IMG_uniform_buffer_object GL_KHR_debug GL_OES_compressed_ETC1_RGB8_texture GL_OES_depth24 GL_OES_depth_texture GL_OES_EGL_image GL_OES_EGL_image_external GL_OES_egl_sync GL_OES_element_index_uint GL_OES_fbo_render_mipmap GL_OES_fragment_precision_high GL_OES_get_program_binary GL_OES_mapbuffer GL_OES_packed_depth_stencil GL_OES_required_internalformat GL_OES_rgb8_rgba8 GL_OES_standard_derivatives GL_OES_surfaceless_context GL_OES_texture_float GL_OES_texture_half_float GL_OES_vertex_array_object GL_OES_vertex_half_float`.
- **[fact]** **No `GL_EXT_unpack_subimage`, no `GL_EXT_read_format_bgra`.** This is from `strings`; the runtime `glGetString(GL_EXTENSIONS)` output was not captured.
- **[fact]** It is ELF32 ARM EABI5 **hard-float, glibc** (`NEEDED libc.so.6`, `ld-linux-armhf.so.3`, `libsrv_um.so.1`, `libpvr_dri_support.so.1`). The highest symbol version it needs is `GLIBC_2.34`. `libpvr_dri_support` needs only `GLIBC_2.4`. These come from `readelf -V` on the two libraries in the session clone. `libsrv_um` was not checked.

EGL is **Mesa's** (`egl_dri2`):

- **[fact]** `KHR_no_config_context` and `KHR_surfaceless_context` are always set (`src/egl/drivers/dri2/egl_dri2.c:1040-1041`, mesa-sgx).
- **[fact]** `EXT_image_dma_buf_import` is set **only if `__DRIimageExtension` version ≥ 8 with `createImageFromDmaBufs`**. `…_modifiers` needs version ≥ 15 (`egl_dri2.c:1117-1123`).
- **[fact]** At yocto's pinned **`9d86c744`** (2024-09-07): `PVR_DRI_IMAGE_VERSION 8`, `.createImageFromDmaBufs = PVRDRICreateImageFromDmaBufs`, so **dma-buf import is advertised** (`sgx_ext.c:76, 1287`).
- **[fact]** At branch HEAD **`a698020be6`** ("sgx_ext: roll __DRIimageExtension back from 8 to 7", Randolph Sapp `<rs@ti.com>`, 2024-09-11): version **7**, `createImageFromDmaBufs` **removed**. The commit message:

  > The createImageFromDmaBufs extension here is implemented correctly but DDK 1.17's implementation of buffer imports/exports was half-baked and was never fully functional under Linux. … most applications expect modifiers to be supported if DMA extensions are present. This is not true here as SGX never had the concept of DRM modifiers.

### 3.5 Gap analysis

| Requirement | wlroots 0.20 | weston 16 | kmscube / own KMS app | Stock DDK 1.8 | TI DDK 1.17 + mesa-sgx `9d86c744` | TI DDK 1.17 + mesa-sgx HEAD `a698020` |
|---|---|---|---|---|---|---|
| GLES 2.0 | hard | hard | hard | yes | yes | yes |
| `GL_EXT_texture_format_BGRA8888` | hard | soft | — | yes | yes | yes |
| **`GL_EXT_unpack_subimage`** | **hard** | **hard** (GLES2) | — | **no** | **no** | **no** |
| `GL_OES_EGL_image` | hard (render targets) | soft | soft | yes | yes | yes |
| EGL platform GBM (Mesa) | hard (or platform_device) | hard | hard | n/a (Android) | yes (Mesa) | yes (Mesa) |
| `EGL_KHR_surfaceless_context`, `KHR_no_config_context` | hard | surfaceless hard | — | n/a | yes (Mesa) | yes (Mesa) |
| **`EGL_EXT_image_dma_buf_import`** | **hard** | soft | — | n/a | advertised; TI says the DDK side is "half-baked" | **no** |
| modifiers | soft | soft | soft | n/a | no | no |
| render via `gbm_surface` | **not possible** (≥ 0.13) | **yes** | **yes** | — | yes | yes |

The blockers that follow from the table:

| # | Blocker | Status |
|---|---|---|
| **B1** | `GL_EXT_unpack_subimage` missing in every SGX540 GLES2 lib we have. | Blocks wlroots and weston as packaged. |
| **B2** | wlroots ≥ 0.13 needs dma-buf import to render *anything* (≥ 0.14 also refuses to create the renderer without it). On SGX5 that path is untrusted by TI and absent at mesa-sgx HEAD. weston and own KMS apps can avoid it entirely. | Blocks labwc. |
| **B3** | Blobs are glibc. The compositor and Alpine userspace are musl. | pmOS solved this with `libc6-compat` (MR !1868 APKBUILD: `depends="libc6-compat"`). On today's Alpine that means `gcompat`. UNVERIFIED that gcompat covers every symbol the 2024 rebuild needs. |
| **B4** | Alpine Mesa 26.2.4 is built **without libglvnd**, so it cannot host a vendor EGL. mesa-sgx is a full Mesa (libEGL, libgbm, libGLESv2, glapi) that **collides by soname** with Alpine's `mesa-egl`, `mesa-gbm` and `mesa-gles`. | Packaging decision (§3.7). |
| **B5** | Kernel DRM display device = omapdrm (render node exists), GPU = separate pvrsrvkm. The mesa-sgx GBM path keys on the omapdrm name (alias). | Fits wlroots' and weston's "GBM on the display device's render node" model. The kernel workstream owns the pvrsrvkm side. |

### 3.6 Correcting the June note

`docs/2026-06-19-gpu-sgx540-acceleration-research.md` §4-§5 says wlroots compositors "work" (from pmOS MR !1868) and plans labwc-on-GPU. With the evidence above, that is **outdated**:

- **[fact]** MR !1868 was **merged 2021-02-23** (GitLab API: `state=merged`, `created_at 2021-01-11`, `merged_at 2021-02-23T21:13:09Z`). Its packages:
  - `main/mesa-pvr-dri-classic`: Mesa **20.3.2** "classic" DRI driver from `xc-racer99/mesa-pvr`, installed as `omapdrm_dri.so`, `exynos_dri.so`, `tilcdc_dri.so` and `tidss_dri.so`;
  - `non-free/sgx-ddk-um`: **1.17.494857** sic, TI commit `551665bf…`, with a `ti443x` subpackage, `depends="libc6-compat"`. `git ls-remote` on 2026-10-11 shows `551665bf9c32…` is the head of TI's `ti-img-sgx/zeus/1.17.4948957` branch. That is an older build line than yocto's `1.17.4948957/mesa/glibc-2.35` @ `84a396a4`.
- **[inference]** At that date the current wlroots was **0.12**, which rendered into a `gbm_surface` (§3.1). "wlroots works with the unpack-subimage patch" referred to that architecture.
- **[inference]** Mesa removed classic DRI drivers long ago and, per Mesa's own refactors, no longer loads external `*_dri.so` drivers in 24.2+. UNVERIFIED for the exact release; mesa-sgx sidesteps the question by being a Mesa fork.

### 3.7 Options to close B1 and B2, ranked against the project rules

**For B1 (`GL_EXT_unpack_subimage`):**

| Option | What | Fit with CLAUDE.md "no frozen copy of system packages" | Cost |
|---|---|---|---|
| **B1-a (recommended)** | Implement `GL_EXT_unpack_subimage` **inside mesa-sgx's dispatch layer**:<br>• wrap `glPixelStorei` to track `GL_UNPACK_ROW_LENGTH_EXT`, `SKIP_PIXELS` and `SKIP_ROWS`;<br>• wrap `glTexImage2D` and `glTexSubImage2D` to repack or upload row-wise when those are non-zero;<br>• append the extension to `glGetString(GL_EXTENSIONS)`. | **Fits better than B1-b/c, but not automatically** [inference, UNVERIFIED design, not prototyped]. mesa-sgx would be our own package, because Alpine has no SGX Mesa. wlroots, weston and Alpine Mesa stay pristine and keep upstream updates. But the emulation is still a local patch on top of mobiaqua's `mesa-22.3-sgx`. Under the global rule it needs the upstream base tracked in git and a rebase on each mobiaqua bump, or it should be offered upstream to mobiaqua (rule option 3, ask Petr before posting). Feasibility: the shim fills Mesa's glapi table itself (`pvrdri_add_mesa_dispatch`, `sgx_context.c:134-175`), so overriding the `glPixelStorei`, `glTexImage2D`, `glTexSubImage2D` and `glGetString` slots is plausible. | A small C change. Correctness must be tested on every client upload path. The cost is an extra CPU copy per damaged rect (rows are tightly re-packed into a scratch buffer). |
| B1-b | Patch wlroots (fallback upload) | **Violates** unless Petr approves a local wlroots0.20 aport *with* a tracked upstream base, an automatic rebase on each Alpine bump and a loud conflict alarm. | Plus a wlroots fork to maintain forever. |
| B1-c | TI's weston revert patch | Same rule problem for weston. | TI maintains it per weston major. |
| B1-d | Upstream a "no unpack_subimage" fallback to wlroots or weston | Fits (rule option 3, but ask Petr before posting). | Upstream is unlikely to accept: both projects removed the fallback on purpose. |

**For B2 (dma-buf import):**

1. **First**, measure whether DDK 1.17 dma-buf import works for the specific case wlroots needs: GBM-allocated, linear, ARGB8888 or XRGB8888 scan-out buffers from omapdrm, imported as an EGLImage and bound as an FBO. Use mesa-sgx at `9d86c744`. TI's message says imports/exports are unreliable; it does not say which cases fail.
2. **If it fails**, weston is the GPU compositor (gbm_surface output). labwc stays on pixman. That is fine for an on-demand debug desktop.
3. **Either way**, the **visualizer** should be a dedicated KMS+GLES2 client on `gbm_surface` (§4.4). It does not depend on B2 at all.

**For B3 and B4 (packaging), two shapes:**

- **Side prefix:** install mesa-sgx under `/usr/lib/sgx/` and point only the GPU consumers at it with `LD_LIBRARY_PATH` (or an `RPATH` on our own visualizer binary). That keeps system Mesa intact for everything else. B3 still needs `gcompat`.
- **Inside the glibc sandbox:** run the GPU consumer *inside* the existing Debian bookworm armhf sandbox (`pmos/nexusq-glibc-rt/APKBUILD:2-37`, glibc 2.36 ≥ the blobs' 2.35 build), with `/dev/dri/*` and `/dev/pvrsrvkm` bound in.

  **[inference]** This works cleanly for a stand-alone visualizer. It does not work for a musl compositor.

Mesa 26 can load an out-of-tree GBM backend through `GBM_BACKENDS_PATH`/`<name>_gbm.so` (`src/gbm/main/backend.c:44-128` at tag mesa-26.2.4). It does **not** solve EGL, because Alpine has no glvnd. So "plug SGX into Alpine Mesa" is not a complete path.

---

## 4. The no-GPU path: DSS planes

### 4.1 What the hardware gives for free

All of this is from §1.5 [fact]:

- **Planes:** 4 hardware pipes (GFX, VID1, VID2, VID3) behind 1 primary and 3 overlay KMS planes.
- **Blending:** per-pixel alpha (ARGB) and per-plane global alpha, premultiplied blending, z-order.
- **Scaling:** VID pipes scale with 5-tap filters, upscale up to the 8× atomic-check limit, and downscale ≤ 4× before decimation rules apply.
- **YUV:** NV12, YUYV and UYVY are scanned out and colour-converted on VID pipes, with `COLOR_ENCODING` (BT.601/709) and `COLOR_RANGE` properties.
- **Gamma:** a CRTC gamma table.
- **Limits:**
  - overlays are ≤ 2048 px wide each (wider takes 2 pipes);
  - no TILER rotation for generic buffers;
  - mainline exposes no writeback;
  - no cursor plane.
- **Bandwidth [estimate]:** each enabled plane is a DMA read stream at scan-out rate. A full-screen 720p60 XRGB plane is about 221 MB/s, and a 1080p60 one about 498 MB/s.

### 4.2 Who can use the planes

| Consumer | Uses overlay planes? | Evidence |
|---|---|---|
| labwc 0.20.2 (wlr_scene) | **No.** Primary-plane direct scanout only (for a fullscreen dma-buf client); labwc has no `wlr_output_layer` code. | labwc tag 0.20.2 source grep (only `magnifier.c:244` touches `direct_scanout`); wlroots `types/scene/wlr_scene.c:198` |
| wlroots libliftoff backend | Only with `WLR_DRM_FORCE_LIBLIFTOFF=1`, and only for output layers a compositor submits | `backend/drm/drm.c:90-98` |
| weston 16 DRM backend | **Yes:** plane assignment (`state-propose.c`) for dma-buf client buffers | §3.2 |
| A dedicated KMS client (visualizer, `mpv --vo=drm`) | **Yes:** full control through atomic commits | — |

**[inference]** With pixman everywhere, wl_shm clients cannot reach planes at all. Only dma-buf clients can, and today nothing in the LXQt session produces scan-out-capable dma-bufs.

### 4.3 Could the particle visualizer be DSS planes plus NEON instead of SGX?

What the stock scene contains [fact, §2]:

| Scene | Content |
|---|---|
| Particle screensaver (idle) | 40 point sprites, each 60×60 px, one 64×64 RGBA texture, colour-modulated, under a throbbing MVP. This is the HDMI half of the RE note. |
| Music scenes | Full-screen ping-pong FBO feedback (`texture2D(prev)` with a sinusoidal or radial distortion, then decay `−0.002`, `×0.95`), plus point, line and sprite primitives. |

Costs [estimate; Cortex-A9 at 920 MHz to 1.2 GHz with NEON; 6.4 GB/s theoretical EMIF from 2 × 32-bit LPDDR2 at 400 MHz per `elpida_ecb240abacn.dtsi` `max-freq = <400000000>`, `io-width = <32>` and both `&emif1`/`&emif2` in DTS patch 0003]:

| Design | Pixels touched per frame | At 60 fps | CPU | Bus |
|---|---|---|---|---|
| A. Particles at native 1280×720, damage-limited (erase and redraw only the 40 sprite boxes) | 40 × 3600 × 2 ≈ 0.29 Mpx | ≈ 17 Mpx/s | NEON alpha blend ~2-4 cycles/px gives ~4-8 % of one core | ~140 MB/s CPU plus 221 MB/s scanout |
| **B. Particles at 640×360 on one VID-pipe plane upscaled 2× by DSS** (the primary plane with scaling makes omapdrm assign a VID pipe automatically) | 40 × 900 × 2 ≈ 0.07 Mpx | ≈ 4.3 Mpx/s | ~1-2 % of one core | ~35 MB/s CPU plus **55 MB/s** scanout (the DSS reads the small buffer) |
| C. Music feedback blur, full frame at 1280×720 on the CPU | 0.92 Mpx (gather-sample, decay, write) | 55 Mpx/s | distorted bilinear gather ~10-20 cycles/px gives 55-110 % of a core. **Not viable.** | ~440 MB/s |
| **D. Music feedback blur at 640×360 plus DSS 2× upscale** | 0.23 Mpx | 13.8 Mpx/s | ~15-30 % of one core | ~110 MB/s plus 55 MB/s scanout |
| E. Same as C, on SGX540 at 307.2 MHz | 0.92 Mpx | 55 Mpx/s | driver overhead only (UNVERIFIED, likely 5-15 % of a core for a few draw calls per frame) | ~440 MB/s (texture read plus tile write) plus 221 MB/s scanout |

Conclusions:

1. **[inference]** The *idle particle screensaver* is a CPU+DSS job: design B. It needs no GPU, no blobs and no glibc. It is the faithful HDMI half of the stock screensaver. An overlay (`muted.png`, track info) goes on a second plane (GFX, native resolution, ARGB, global alpha), composited by the DSS for free.
2. **[inference]** The *music scenes* at native resolution want the SGX (design E). Design D is a credible no-GPU fallback, with a visible softness from the 2× upscale.
3. **Fidelity caveat:** stock sprites are a constant 60 px at the stock render resolution, which is unknown (see Open questions). Design B halves sprite resolution, while the DSS 5-tap filter keeps soft particles soft. UNVERIFIED by eye. Petr drives any visual comparison.

### 4.4 How a visualizer must coexist with HDMI audio and `nq-hdmi`

These are design constraints derived from repo facts:

1. **Do not modeset.**
   - **[fact]** HDMI audio rides in the video stream's data islands, and the output must stay lit (`nq-hdmi:8-21`).
   - **[inference]** Reusing the CRTC's current mode (an atomic commit without `ALLOW_MODESET`, planes only) avoids the TMDS and audio-clock re-init a modeset causes.
   - The same applies to the desktop. labwc picks its *own* mode (§6.1), so toggling the desktop on a TV can change 720p60 to 1080p30 and back. **[inference]** That glitches HDMI audio during the switch. UNVERIFIED on hardware. A config-only mitigation exists: labwc `<core><reuseOutputMode>yes</reuseOutputMode></core>` tests the current CRTC mode first (labwc 0.20.2 `src/output.c:474-481`; default `no`, `src/config/rcxml.c:1538`). When the fbdev hold has lit 720p60, that keeps labwc on 720p60. Not tried.
2. **Take DRM master only while visible, and drop it when done.**
   - **[fact]** `nq-hdmi` re-parks the console only when **no** DRM master exists (`_keep_black`, `nq-hdmi:280-294`). The relight (`_keep_lit`, `nq-hdmi:272-278`) is **unconditional**: it is called on every poll (`nq-hdmi:354-355`) and writes `FB_BLANK_UNBLANK` whenever `fb0` reads blanked. That is harmless under a master, because the fbdev unblank reaches `drm_client_modeset_dpms()`, which returns `-EBUSY` when `drm_master_internal_acquire()` fails (v6.18.48 `drm_client_modeset.c`).
   - **[fact]** It treats an unreadable `/sys/kernel/debug/dri/0/clients` as "do not act".
   - **[inference]** A visualizer master is compatible with the hold by design.
3. **[inference]** **Do not run alongside the desktop.** One DRM master at a time. The app's `setDesktop` and the visualizer must be mutually exclusive, or the visualizer must run as a Wayland client under labwc, which with pixman puts the CPU cost back.
4. **Audio and the bus.**
   - **[fact]** The 2026-07 crackle was EMIF/L3 contention starving McBSP2's SDMA (`docs/2026-07-08-audio-crackle-dma-contention.md:24-31`), closed by sDMA read priority (patch 0041) and the DPLL_ABE relock (patch 0042).
   - Any GPU or visualizer work must be **re-tested for crackle under load**, with Petr listening, at volume ≤ 1-2 % per the repo rules.
   - **[inference]** Design B is the bus-gentlest option.

---

## 5. Video: IVA-HD

| Item | State | Evidence |
|---|---|---|
| IVA-HD sysc target-module | in mainline DT (`iva_hd_target`) | 6.19 `omap4.dtsi:728-740` |
| IPU (Ducati Cortex-M3) remoteproc | mainline driver `omap_remoteproc.c` matches `ti,omap4-ipu`; DT node `ipu@55020000`, `firmware-name = "omap4-ipu-fw.xem3"`, **`status = "disabled"`** | 6.19 `drivers/remoteproc/omap_remoteproc.c:1094` (v6.18.48: line 1097); `omap4.dtsi:360-370` (identical in v6.18.48) |
| rpmsg transport | mainline virtio_rpmsg, rpmsg_char and rpmsg_ctrl only | 6.19 `drivers/rpmsg/` listing |
| **Codec API driver** (`rpmsg-rpc` / `rpmsg-dce`) | **not mainline.** mobiaqua carries TI's `rpmsg-rpc` series (0050-0060), rpmsg sockets, remoteproc fixes and `0011-iva-timer3-always-on.patch` on its OMAP4 kernels. The Panda machine pins `linux-ti` 6.6, and the 6.6 recipe carries the same rpmsg-rpc series. | `mobiaqua/yocto` `meta-ti/recipes-kernel/linux/linux-ti_6.6.bb` and `linux-ti_6.8.bb` `SRC_URI`; `meta-ti/conf/machine/panda.conf` |
| Our defconfig | `CONFIG_REMOTEPROC=y`, but **`# CONFIG_OMAP_REMOTEPROC is not set`** and **`# CONFIG_RPMSG_VIRTIO is not set`** | `kernel/configs/steelhead_defconfig:4116-4124` |
| Userspace | `libdce` (`github.com/mobiaqua/ti-libdce`, last push 2024-06-09) and `libmmrpc`. mobiaqua ships prebuilt `omap4-ipu-fw.xem3` (`meta-ti/recipes-bsp/libdce/libdce-firmware/`) and a build script (`mobiaqua/ti-ducati-fw`, 2024-11-12). The player is `mobiaqua/mplayer-mini` or `mpv-mini` ("Minimal version of MPlayer for TI SOCs (OMAP3, OMAP4, OMAP5, AM572x)"). | GitHub API repo listing 2026-10-11 |
| Codecs | TI docs list IVA-HD decode as H.264, MPEG4, MPEG2 and VC1 (TI Processor SDK multimedia page, via search snippet) | software-dl.ti.com Processor SDK Linux "Multimedia IVAHD" (not opened directly) |
| Stock firmware fit | stock `ducati-m3.bin` is **OMX** (`OMX.TI.DUCATI1.VIDEO.DECODER`) and pairs with the stock kernel's `rpmsg_omx`. **[inference]** It is not the DCE protocol libdce speaks, so it is not reusable as is. | §2 |

**Relevance [inference]:**

- The Q is an audio appliance. HDMI video is the occasional debug desktop, plus HDMI audio which needs only a lit output.
- `mpv` is in the device depends (`APKBUILD:53`), but no product feature plays video.
- Hardware decode would cost a kernel series that is not upstream, a firmware with a TI licence and a player fork. **Not worth it now.**
- If occasional video matters, the cheap 80 % path is:
  - software decode, where 720p H.264 on two A9 cores is borderline (UNVERIFIED);
  - output as **NV12 on a VID-pipe plane**, letting DSS do colour conversion and scaling. `mpv --vo=drm` does swscale to RGB instead (UNVERIFIED whether it can use an NV12 plane on omapdrm), so this needs a player or VO that submits NV12 framebuffers directly.

---

## 6. HDMI modes and fill-rate arithmetic

### 6.1 Which modes are actually in play

- **[fact]** Patch 0010 rejects `mode->clock > 75000` (`kernel/patches/0010-…:38-46`).
- **[fact]** omapdrm alone would allow up to `max_tv_pclk` = 185.625 MHz (`dispc.c:4296`).
- **[fact]** The PHY note says about 186 MHz (`docs/2026-06-23-session-findings.md:47-50`).

Surviving CEA and DMT modes:

| Mode | Pixel clock | Survives the cap? | Note |
|---|---|---|---|
| 640×480@60 | 25.175 | yes | |
| 1024×768@60 | 65.0 | yes | weston verified here on the Philips (PLAN.md:2175-2176) |
| **1280×720@60** | 74.25 | yes | fbdev boot mode; the labwc pick on the Philips monitor |
| 1920×1080@24/25/30 | 74.25 | **yes** | |
| 1920×1080i@60 | 74.25 | **no** | the hdmi4 bridge never sets `interlace_allowed` (v6.18.48 `hdmi4.c`); `display-connector.c:278` does, but `drm_bridge_connector.c:676-689` requires *all* bridges to set it |
| 1440×900@60, 1280×1024@60 | 106.5 / 108 | no | the original blank-screen modes |
| **1920×1080@60** | 148.5 | **no** | stock allowed it (max_pixclk 165 MHz, §2) |

What labwc picks on a typical TV:

- **[fact]** `drm_mode_compare` sorts preferred first, then **area**, then vrefresh, then clock (6.19 `drm_modes.c:1841-1862`).
- **[fact]** `wlr_output_preferred_mode` returns the preferred mode or, failing that, **the first mode** (`types/output/output.c:474-488`, 0.20.2). labwc uses it (`labwc src/output.c:485-491`).
- **[inference]** A TV's preferred 1080p60 is pruned. The first remaining mode is the largest-area one with the highest refresh, which is **1920×1080@30 if the EDID lists it** (most TVs do), otherwise 1080p25 or 24, otherwise 720p60. The kernel cmdline `video=` mode does not change this: a matching probed mode gets `DRM_MODE_TYPE_USERDEF`, not `PREFERRED` (v6.18.48 `drm_probe_helper.c:167-168`). Supporting observation: on the Philips (preferred 1440×900 pruned), wlroots picked **1280×720@60**, the largest-area survivor (`docs/2026-06-23-session-findings.md:32-44`).
- The Samsung soundbar's EDID mode list is not in the repo. UNVERIFIED which mode labwc chose there. Check with `cat /sys/class/drm/card0-HDMI-A-1/modes` on a unit with the sink attached.

### 6.2 The cap hides an omapdrm bug, not a hardware limit

- **[fact]** Stock drove HDMI up to `max_pixclk_khz = 165000` with `regn = 15`, `regm2 = 1` (§2).
- **[fact]** Mainline computes OMAP4 HDMI PLL settings with `dss_pll_calc_b` (`pll.c:272-327`) against `dss_omap4_hdmi_pll_hw` (`hdmi_pll.c:77-100`: `fint` 0.5-2.5 MHz, `clkdco` 500-2000 MHz with `clkdco_low` = 1 GHz, `mX_max` 127).
- **[estimate]** Assuming `sys_clkin` = 38.4 MHz. That is UNVERIFIED for the HDMI PLL's clkin on steelhead; 38.4 MHz is the board's PHY reference per `docs/2026-06-22-ethernet-stock-RE.md:28`. Mainline would choose:

| pclk (MHz) | N | fint | M2 | DCO (MHz) | M | M.f | SD |
|---|---|---|---|---|---|---|---|
| 25.175 | 16 | 2.4 | 20 | 503.5 | 209 | 207530 | 3 |
| 65.0 | 16 | 2.4 | 8 | 520.0 | 216 | 174762 | 3 |
| 74.25 | 16 | 2.4 | 7 | 519.8 | 216 | 147456 | 3 |
| 106.5 (fails) | 16 | 2.4 | 5 | 532.5 | 221 | 229376 | 3 |
| 108.0 (fails) | 16 | 2.4 | 5 | 540.0 | 225 | **0** | 3 |
| 148.5 | 16 | 2.4 | 4 | 594.0 | 247 | 131072 | 3 |

  N = 16 (register value 15) matches stock's `regn = 15`. Stock fixed **M2 = 1**, while mainline varies M2 to keep the DCO near 500 MHz.
- **[inference]** 108 MHz fails with an *integer* M (M.f = 0). That makes "fractional PLL error" an unlikely sole cause. The two failing modes are also exactly the **DMT** (non-CEA) modes, on a **DVI-class** monitor with no CTA extension (`nq-hdmi:124-127`).
- Hypotheses to test in task #13, all UNVERIFIED:
  - (a) DCO or M2 choice versus stock's M2 = 1 regime;
  - (b) DVI-mode handling or AVI infoframe for non-CEA timings on a DVI sink;
  - (c) the TMDS PHY frequency band selection for > 100 MHz (`hdmi_phy.c`, not read here).
- **[inference]** Whatever the cause, **a GPU HDMI UI at the stock resolution (1080p60) requires fixing this root cause first.** AGENTS.md says "Fix root causes; never mask".

### 6.3 Fill-rate and bandwidth budget

Assumptions [estimate]:

- SGX540 = 4 USSE pipes. **[fact]** The USSE count is per mynavi.jp 2008-05-15: SGX540 raised the USSE count to four.
- **2 texels per clock.** UNVERIFIED: the TMU count is not confirmed by a primary source. A secondary source agrees: the Wikipedia PowerVR Series5 table lists SGX540 as "4/2" (USSE lanes/TMUs), read 2026-10-11.
- Clocks from the stock OPPs (§2).
- Bus cost of compositing one opaque full-screen layer on a TBDR: 4 B texture read + 4 B tile write per pixel.

| Mode | Mpx/s | Scanout MB/s | 1 layer compose MB/s | % of SGX tex peak @ 153.6 / 307.2 / 384 MHz |
|---|---|---|---|---|
| 640×480@60 | 18.4 | 74 | 147 | 6.0 / 3.0 / 2.4 |
| 1024×768@60 | 47.2 | 189 | 377 | 15.4 / 7.7 / 6.1 |
| **1280×720@60** | 55.3 | 221 | 442 | 18.0 / **9.0** / 7.2 |
| 1920×1080@24 | 49.8 | 199 | 398 | 16.2 / 8.1 / 6.5 |
| 1920×1080@30 | 62.2 | 249 | 498 | 20.2 / 10.1 / 8.1 |
| 1920×1080@60 | 124.4 | 498 | 995 | 40.5 / **20.2** / 16.2 |

**[inference]** Fill is comfortable even for three overlapping full-screen layers at 1080p60 at 307.2 MHz (~60 % of peak). Damage tracking makes typical desktop load far lower. The limits are elsewhere:

1. **EMIF.**
   - A 1080p60 full repaint is about 1.0 GB/s of compose traffic plus 0.5 GB/s of scanout, against a 6.4 GB/s theoretical peak (realistic sustained is far lower; UNVERIFIED on this board).
   - This is exactly the resource the McBSP2 audio DMA lost to in 2026-07.
2. **CPU.**
   - The SGX driver's user-mode side (`libsrv_um`) and the compositor run on the same two A9 cores as PulseAudio and the players.
   - wl_shm clients need `glTexSubImage2D` uploads. **UNVERIFIED** that the DDK twiddles uploads on the CPU, but if it does, a GPU compositor gains little over pixman for wl_shm-heavy LXQt.
3. **VDD_CORE.**
   - **[fact]** Stock runs the GPU at 307.2 MHz with core at 1.127 V and 384 MHz with core at **1.25 V**.
   - **[corrected]** The 2026-06-25 note (`docs/2026-06-25-cpufreq-vdd-mpu-findings.md:47-49`) describes the state *before* patches 0013-0017. Since v1.4.0 (2026-06-26, `CHANGELOG.md:8555-8566`), VDD_MPU is on the TPS62361 (patch 0014). VDD_CORE is on TWL6030 VCORE1, and its VC channel is programmed with the stock CORE ON voltage of 1 200 000 µV (patch 0027; `docs/2026-07-02-stock-parity-voltage-wifi-idle.md:37`). That is the wake/ON set-point, not a measured runtime level. UNVERIFIED that no core DVFS exists on our kernel; nothing found suggests one does. 1.2 V would cover the 307.2 MHz OPP (1.127 V) but not 384 MHz (1.25 V).
   - **Do not clock SGX above 307.2 MHz until VDD_CORE is measured** (memory rule: CPU and power diagnostics always). Even 307.2 MHz needs the core at ≥ 1.127 V, which also needs verifying.
4. **Thermals.**
   - **[fact]** 102.8 °C was measured under sustained load, above the 94-99 °C envelope (PLAN.md:2004-2008).
   - A GPU on the same die adds heat. Run any GPU soak with the full diag sweep.

### 6.4 CPU reference for the current pixman desktop

- **[fact]** On 2026-06-23, with two cores, the idle LXQt-on-labwc desktop showed load around 1.x and about 70 % idle. The ~30 % busy baseline was attributed to the pixman compositor (`docs/2026-06-23-session-findings.md:58-62`).
- That was at 1280×720@60 on the Philips. It was not re-measured on 6.18 or with the current packages.

---

## 7. Recommended path for this workstream (ordered; each step has an acceptance test)

| # | Step | Needs GPU blobs? | Acceptance (a test must be seen failing first, per AGENTS.md) |
|---|---|---|---|
| 1 | **Measure the baseline.** perf profile of labwc+pixman at 720p60 (WC-read hypothesis §1.4), `modes` list and labwc-chosen mode on the soundbar or TV, CPU %, temperature, and an EMIF-adjacent crackle check during desktop use | no | numbers recorded in a dated `docs/` note |
| 2 | **Root-cause the 75 MHz cap** (task #13) against stock (`regm2 = 1`, 165 MHz) with the stock-parity auditor. Hypotheses in §6.2. | no | 1080p60 lit and stable on a CEA sink; 1440×900 on the Philips. Patch 0010 removed or narrowed, not kept as a mask. |
| 3 | **HDMI particle screensaver, CPU+DSS** (design B §4.3): a small C KMS-atomic client (nexusqd sibling) that takes master only when the desktop is off, never modesets, renders 640×360 ARGB with NEON onto the primary plane scaled 2×, puts the overlay on a second plane, and is idle-gated like the LED screensaver | no | sprites visible, CPU < 5 % of one core, no crackle at ≤ 2 % volume, `nq-hdmi` hold unaffected, diag sweep clean |
| 4 | **SGX bring-up gate** (kernel workstream) followed by **kmscube smooth mode** on `gbm_surface`, using mesa-sgx Maemo `powervr-24.0.9` (`72c93be7aa29`; corrected 2026-10-11 from `9d86c744`, which stays for the step-5 B2 probe only [ub Addendum §A.5]) and DDK 1.17 `84a396a4` `ti443x_linux`, with mesa-sgx in a side prefix (or the glibc sandbox) | yes | spinning cube at 720p60; `pvrsrvkm` clean in dmesg; GPU clock = 307.2 MHz; VDD_CORE logged |
| 5 | **Probe B2:** a minimal test that allocates a GBM BO on omapdrm, imports it as an EGLImage dma-buf, renders to it, scans it out, and loops for an hour | yes | pass, or fail with a documented failure mode. This decides whether labwc is ever a GPU target. |
| 6 | **GL_EXT_unpack_subimage emulation in mesa-sgx** (B1-a) plus a unit test (sub-rect uploads compared against a reference) | yes | weston 16 `renderer=gl` starts unpatched. If step 5 passed, wlroots 0.20 `WLR_RENDERER=gles2` also starts unpatched. |
| 7 | **Music visualizer on SGX** (design E): a native KMS+GLES2 port of the stock scenes (shaders already in `private/nexusq-original/visualizer`), using `gbm_surface` and no dma-buf import | yes | stock-faithful scenes at 720p60 (1080p60 after step 2); crackle-free; thermals inside the envelope |
| 8 | **Video**: DSS NV12-plane path only if a real use case appears. IVA-HD (`libdce`) explicitly parked. | no | — |

---

## 8. Cross-workstream dependencies noticed here

These are for the plan owner.

- **Kernel:**
  - **[fact]** openpvrsgx commit `0affbb5a7b95` "ARM: omap2plus_defconfig: PVR/SGX build now needs CONFIG_PREEMPT=y or CONFIG_PREEMPT_VOLUNTARY=y" (H. Nikolaus Schaller). It was *authored* 2024-10-26 and *committed* 2025-11-16 (a rebase onto branch `pvrsrvkm-6.18-rc6`, head `d2f1e031d58a`, merge committed 2025-11-21). The diff only adds `CONFIG_PREEMPT_VOLUNTARY=y` to `omap2plus_defconfig`. The SGX `Kconfig` on that branch (`drivers/gpu/drm/pvrsgx/Kconfig`) has **no** PREEMPT dependency, so the reason is not stated. It also shows `SGX_DRM` selecting `DRM_LEGACY`, which concerns the kernel workstream. **[fact]** Our defconfig is `CONFIG_PREEMPT_NONE=y` (`steelhead_defconfig:99-102`).
  - mobiaqua's OMAP4 kernel re-adds `dma_buf_kmap` (`0020-restore-dmabuf-map.patch`) and TI's `OMAP_BO_MEM_CONTIG/DMM/PIN` UAPI (`ti/0017-Revert-Revert-drm-omap-add-OMAP_BO-flags…`). It also adds an omapdrm cache-flush hack in dma-buf kmap (`0030-HACK-…`). **[inference]** These hint at what the TI DDK 1.17 KM and UM expect from omapdrm. The kernel workstream should determine whether the openpvrsgx driver needs any of them on 6.18.
  - The openpvrsgx repository has, among others, branches `pvrsrvkm-6.15-rc5`, `pvrsrvkm-6.17-rc7`, `pvrsrvkm-6.18-rc6`, `pvrsrvkm-6.19-rc6`, `pvrsrvkm-7.0`, `pvrsrvkm-7.1`, `pvrsrvkm-7.2-rc2`, `pvrsrvkm-7.2-rc3`, `pvrsrvkm-7.2` and `letux/pvrsrvkm-1.17.4948957{,-v2,-v3}` (`git ls-remote`, 2026-10-11). The June note's "6.15-rc5" is stale.
- **Power:** the GPU OPP depends on VDD_CORE, as in §6.3.
- **Packaging:**
  - B3 needs glibc compatibility (`gcompat`) or the bookworm sandbox.
  - B4 conflicts with the `mesa-egl`, `mesa-gbm` and `mesa-gles` sonames.
  - Any wlroots or weston patching needs Petr's explicit approval plus a rebase pipeline (global CLAUDE.md rule).
- **CMA:** `CONFIG_CMA_SIZE_MBYTES=16` (`steelhead_defconfig:5529`). That is irrelevant for omapdrm scan-out while DMM probes (§1.4), but the SGX KM and any IPU carveout may need CMA. UNVERIFIED; for the kernel workstream.

---

## Open questions

1. **Which mode does labwc pick on the Samsung soundbar or a TV today, and does toggling the desktop interrupt HDMI audio?** Read `/sys/class/drm/card0-HDMI-A-1/modes` and labwc's log on a unit.
2. **Does TI DDK 1.17 dma-buf import work for omapdrm GBM linear XRGB8888 scan-out BOs?** This is step 5, and it decides labwc-on-GPU.
3. **Does the 1.17 `libGLESv2_PVR_MESA` return the same extension list at runtime as its strings suggest?** Run `es2_info` or `eglinfo` once SGX is up.
4. **TMU count and real fill rate of the SGX540 at 307.2 MHz on this board.** Primary sources found give only the USSE count. AnandTech's GLBenchmark pages are now redirected and archive.org was not reachable from this session.
5. **Does the SGX DDK upload `glTexSubImage2D` through CPU twiddling?** This decides whether a GPU compositor helps wl_shm-heavy LXQt at all.
6. **What render-target size did the stock Visualizer use?** `TextureRenderTarget` / `TextureRenderTargetPool` in `Visualizer.odex` would tell; decompile with baksmali and jadx (not installed on this machine). Also: which blend mode did the particle sprites use?
7. **What is the real cause of the 106.5 and 108 MHz failures** (§6.2 hypotheses)? Is `sys_clkin` 38.4 MHz the HDMI PLL clkin on steelhead?
8. **What are the actual VDD_CORE voltage and the SGX functional clock under mainline**, given the `sgx_clk_mux` parents `dpll_core_m7x2_ck` / `dpll_per_m7x2_ck` (6.19 `clk-44xx.c:327-339`)?
9. **Is `gcompat` sufficient for the 2024 glibc-2.35 rebuild of the DDK**, or does the GPU consumer need the bookworm sandbox?
10. **Would Petr accept a mesa-sgx package** (our own, built from a pinned TI/mobiaqua commit), installed in a side prefix? That is the only Mesa this plan adds. And would he accept the wlroots/weston exceptions if B1-a fails?
11. **Does `mpv --vo=drm` on omapdrm use an NV12 plane or swscale to RGB?** This only matters if video becomes a use case.

---

## Sources

**Repository (read-only):**
- `docs/2026-06-19-gpu-sgx540-acceleration-research.md`
- `docs/2026-06-19-particle-screensaver-RE.md`
- `docs/2026-06-23-session-findings.md:25-62`
- `docs/2026-09-20-hdmi-audio-the-output-that-was-never-offered.md`
- `docs/2026-07-08-audio-crackle-dma-contention.md:24-31`
- `docs/2026-06-25-cpufreq-vdd-mpu-findings.md:47-49`
- `PLAN.md:1981-2008, 2095-2115, 2155-2187`
- `CHANGELOG.md:81, 1917-1921, 8644-8648`
- `pmos/device-google-steelhead/{APKBUILD, deviceinfo, nexusq-wayland.sh, weston.ini, weston-nexusq.desktop, labwc-rc.xml, lxqt-session.conf, nq-hdmi}`
- `pmos/nexusq-glibc-rt/APKBUILD:2-37`
- `userspace/nexusqd/src/screensaver.c`
- `kernel/patches/0003-ARM-dts-omap4-add-steelhead.patch`
- `kernel/patches/0010-drm-omapdrm-hdmi4-cap-pixel-clock-steelhead.patch`
- `kernel/configs/steelhead_defconfig:99-102, 489, 2830-2876, 5529`
- `docker-build.sh:164, 785-825`

**Stock ground truth** (`reverse-eng/`, gitignored, read-only):
- `factory/tungsten-ian67k/system.raw.img` via `debugfs -R dump`: `/vendor/lib/egl/*_POWERVR_SGX540_120.so`, `/vendor/lib/libIMGegl.so`, `/vendor/lib/hw/hwcomposer.omap4.so`, `/vendor/firmware/ducati-m3.bin`, `/app/Visualizer.odex`, `/lib/egl/egl.cfg`
- `vmlinux.bin` (OPP structs `0xc0043e94`-`0xc0043ec4`; `omap4_steelhead_hdmi_device` `0xc0719cc8`; `steelhead_fb_pdata` `0xc071978c`)
- `reverse-eng/tools/kallsyms.txt`

`private/nexusq-original/visualizer/*` was read for shaders and PNG headers only.

**Kernel:**
- git.kernel.org stable, `drivers/gpu/drm/omapdrm/{omap_plane.c, omap_drv.c, omap_gem.c, dss/dispc.c, dss/hdmi4.c, dss/hdmi_pll.c, dss/pll.c}` at tag `v6.18.48` (`/plain/…?h=v6.18.48`, fetched 2026-10-11)
- local 6.19 tree: `drm_modes.c`, `drm_bridge_connector.c`, `display-connector.c`, `omap4.dtsi`, `clk-44xx.c`, `omap_remoteproc.c`, `elpida_ecb240abacn.dtsi`

**wlroots:**
- https://gitlab.freedesktop.org/wlroots/wlroots, tags API (0.20.2 = 2026-07-07 `d783533489e1`, 0.13.0 = 2021-04-07, 0.14.0 = 2021-06-22)
- raw files at tag 0.20.2: `render/gles2/renderer.c`, `render/egl.c`, `render/gles2/texture.c`, `render/gles2/pixel_format.c`, `render/wlr_renderer.c`, `render/allocator/allocator.c`, `backend/drm/drm.c`, `backend/drm/libliftoff.c`, `types/scene/wlr_scene.c`, `types/output/output.c`
- tags 0.12.0, 0.13.0 and 0.14.0: `render/gles2/renderer.c`, `backend/drm/renderer.c`

**weston:**
- https://gitlab.freedesktop.org/wayland/weston, tag 16.0.0 (2026-07-14): `libweston/renderer-gl/gl-renderer.c`, `egl-glue.c`, `libweston/backend-drm/drm-gbm.c`, `state-propose.c`
- commit `593d5af43a8e2c2a3371088fa7ae430d0517c82d` (GitLab API: "gl-renderer: require GL_EXT_unpack_subimage", 2020-12-15, first tag 10.0.0)

**labwc:** https://github.com/labwc/labwc tag 0.20.2 tarball (`meson.build` wlroots-0.20 dependency; `src/output.c:485-491`; `src/magnifier.c:244`)

**Alpine aports** (`master`, raw, 2026-10-11):
- `community/labwc`, `community/wlroots0.20`, `community/weston`, `main/mesa`, `main/pixman`, `community/kmscube`, `community/swaybg` APKBUILDs
- GitLab commits API for the labwc and wlroots0.20 histories

**Mesa:** https://gitlab.freedesktop.org/mesa/mesa tag mesa-26.2.4, `src/gbm/main/backend.c` and `meson.build`

**kmscube:** https://gitlab.freedesktop.org/mesa/kmscube master `common.c`

**postmarketOS:** https://gitlab.com/postmarketOS/pmaports/-/merge_requests/1868 (page and `/api/v4/…/merge_requests/1868/changes`: merged 2021-02-23; `main/mesa-pvr-dri-classic`, `non-free/sgx-ddk-um` APKBUILDs)

**TI SGX DDK userspace:** https://git.ti.com/git/graphics/omap5-sgx-ddk-um-linux.git, branch `1.17.4948957/mesa/glibc-2.35` @ `84a396a4fb379f10931421e489ac8a199d6a9f2c` (2024-10-16). `targetfs/ti443x_linux/lws-generic/release/usr/lib/libGLESv2_PVR_MESA.so.1.17.4948957` and `libpvr_dri_support.so.1.17.4948957` cloned into the session scratchpad and inspected with `strings`/`readelf` only.

**mesa-sgx:** https://github.com/mobiaqua/mesa-sgx (branch `mesa-22.3-sgx`)
- commits `9d86c74493` (2024-09-07 "Add shim SGX Gallium driver"), `c5e2e3f4c9` and `a698020be6` (Randolph Sapp, TI, 2024-09-11)
- files `src/gallium/frontends/sgx/{sgx_ext.c, sgx_compat.c, sgx_context.c, sgx_dri.c}`, `src/egl/drivers/dri2/egl_dri2.c`, `meson_options.txt`

**mobiaqua:**
- https://github.com/mobiaqua/yocto: `meta-ti/conf/machine/panda.conf`, `conf/machine/include/mesa-sgx.inc`, `recipes-graphics/mesa/mesa-sgx_22.3.7.bb`, `recipes-bsp/libgles/ti-sgx-ddk-um_1.17.4948957.bb`, `recipes-bsp/libdce/*`, `recipes-kernel/linux/linux-ti_6.8.bb` and its patches (`0007_omap4-sgx.patch`, `0020-restore-dmabuf-map.patch`, `0030-HACK-…`, `ti/0017-…`)
- https://github.com/mobiaqua/kmscube
- GitHub org repo listing (ti-libdce, ti-ducati-fw, ti-ipumm, mplayer-mini)

**openpvrsgx:** https://github.com/openpvrsgx-devgroup/linux_openpvrsgx (branches API; `letux/pvrsrvkm-1.17.4948957` commits up to 2025-05-04; `pvrsrvkm-6.18-rc6` head 2025-11-21)

**meta-ti weston revert:** https://ratatoskr.run/yocto-meta-ti/2026/03/16983011/t ("[meta-ti][master][PATCH] weston: Update to 15.0.0", Ryan Eatmon, 2026-03-24, reverting weston `593d5af4…`, "Upstream-Status: Inappropriate [specific to TI SGX]")

**SGX540 background:**
- https://news.mynavi.jp/techplus/article/20080515-a029 (SGX540 = 4 USSE; search snippet)
- https://www.design-reuse.com/news/202515926-powervr-sgx540-from-imagination-technologies-now-in-silicon/ (2008-11-25: "twice the performance of SGX530"; no fill numbers)

**Could not open:** AnandTech GLBenchmark pages (now redirect to forums.anandtech.com); web.archive.org (blocked from this tool); the TI E2E thread with a DDK 1.17 extension dump (HTTP 403).

---

## Verification (2026-10-11)

This is an adversarial re-check of the key claims above. Each source was re-opened independently, either by fresh `curl` of upstream files at the cited tag or by re-reading the repo, `reverse-eng/` and the session clones. Statements that were wrong or stale have been corrected in place above. This section lists what happened to each claim.

### Confirmed (reproduced from the cited source)

1. **TI DDK 1.17 GLES2 extension list** for `ti443x_linux`:
   - `git ls-remote` shows `refs/heads/1.17.4948957/mesa/glibc-2.35` = `84a396a4fb379f10931421e489ac8a199d6a9f2c` (commit date 2024-10-16, "all: rebuild with major fixes applied").
   - `strings` on `libGLESv2_PVR_MESA.so.1.17.4948957` gives exactly the listed extensions. `GL_EXT_texture_format_BGRA8888`, `GL_OES_EGL_image`, `GL_OES_EGL_image_external`, `GL_OES_surfaceless_context` and `GL_KHR_debug` are present.
   - `GL_EXT_unpack_subimage` and `GL_EXT_read_format_bgra` are absent.
   - The build strings read "OpenGL ES 2.0 build 1.17@4948957". The runtime `glGetString` result is still unverified.
2. **Stock DDK 1.8@785978:**
   - Re-dumped from `system.raw.img` with `debugfs`: `/vendor/lib/egl/libGLESv2_POWERVR_SGX540_120.so` is 372 324 B, dated 13-Jul-2012.
   - It contains "OpenGL ES 2.0 build 1.8@785978" and no `unpack_subimage`. The extension list matches §2.
   - `/lib/egl/egl.cfg` = `0 0 android` / `0 1 POWERVR_SGX540_120`.
3. **wlroots 0.20.2 hard requirements:** tag 0.20.2 = `d783533489e1`, 2026-07-07.
   - `render/gles2/renderer.c:544-558`: dma-buf import, BGRA8888 and unpack_subimage, each a `return NULL`.
   - `render/egl.c:207-208`: `EGL_EXT_platform_base`.
   - `render/egl.c:330-338`: software device refused.
   - `render/egl.c:342-352`: configless and surfaceless context.
4. **wlroots history:** tags 0.12.0 (2020-11-08), 0.13.0 (2021-04-07, `renderer.c:880-881` unpack_subimage required) and 0.14.0 (2021-06-22, `renderer.c:792` dma-buf required). 0.12.0's `backend/drm/renderer.c` uses `gbm_surface_create` and 0.13.0's does not. pmaports MR !1868: `merged`, `merged_at 2021-02-23T21:13:09Z` (GitLab API).
5. **mesa-sgx `a698020`:**
   - `git ls-remote` shows `refs/heads/mesa-22.3-sgx` = `a698020be6888af99daeac6470018a5d85313912`.
   - Author: Randolph Sapp `<rs@ti.com>`, 2024-09-11. The commit message is quoted correctly.
   - `sgx_ext.c:76`: `PVR_DRI_IMAGE_VERSION` is 7 at HEAD and 8 at `9d86c744`.
   - `egl_dri2.c:1117-1123` gates `EXT_image_dma_buf_import` on version ≥ 8.
   - Yocto pins `SRCREV = "9d86c74493ec194ed01958eca71c5532b626df27"` and `-Dgallium-sgx-alias=omapdrm`.
6. **weston 16.0.0:**
   - Tag 2026-07-14. `gl-renderer.c:5655-5659`: unpack_subimage is required when GL < 3.0.
   - `gl-renderer.c:5375`: surfaceless context required.
   - `drm-gbm.c:289/312`: `gbm_surface_create[_with_modifiers]`.
   - Commit `593d5af4…`: "gl-renderer: require GL_EXT_unpack_subimage", Pekka Paalanen, authored 2020-12-15. The earliest tag containing it is 10.0.0.
   - The ratatoskr.run meta-ti thread matches: Ryan Eatmon, 2026-03-24, the revert patch file name, and `Upstream-Status: Inappropriate [specific to TI SGX]`.
7. **kmscube master:** `common.c` uses `gbm_surface_create` (lines 165-178), `eglGetPlatformDisplayEXT` (408-411) and `eglCreateWindowSurface` (466). dma-buf and image extensions are optional.
8. **Alpine edge versions** (raw APKBUILDs, master, 2026-10-11): labwc 0.20.2-r0, wlroots0.20 0.20.2-r1, weston 16.0.0-r0, mesa 26.2.4-r1 (no glvnd option in `meson` args), pixman 0.46.4-r0, kmscube 0_git20220902-r1 and swaybg 1.2.2-r0. The labwc upgrade commit `277a1dec` is dated 2026-08-22. The pmaports pin `11e89dfb…` is at `docker-build.sh:164`.
9. **Auto renderer never reaches pixman:**
   - `render/wlr_renderer.c:219-275` (0.20.2): pixman only if `!has_render_node`.
   - `omap_drv.c:639` (v6.18.48): `DRIVER_ATOMIC | DRIVER_RENDER`.
10. **Dumb buffers under pixman:**
    - The allocator selection logic is in `allocator.c:100-150`. The dumb branch also requires `drmIsMaster`.
    - `omap_gem.c:594`: `OMAP_BO_SCANOUT | OMAP_BO_WC`.
    - The performance impact remains unprofiled, as the report says.
11. **omapdrm planes** (v6.18.48):
    - `omap44xx_dispc_feats` (`dispc.c:4282-4321`): `num_ovls = 4`, `ovl_width_max = 2048`, `max_tv_pclk = 185625000`, `max_lcd_pclk = 170000000`, `has_writeback`, `has_gamma_table`.
    - `omap_drv.c:427-433`: primary versus overlay type.
    - `omap_plane.c:243`: the 1/8 to 8× check.
    - `omap_plane.c:300-353`: dynamic assignment.
    - `omap_fb.c:99-102`: rotation only for TILED buffers.
    - There are no `DRM_PLANE_TYPE_CURSOR` and no `format_mod_supported` in omapdrm.
    - Formats per pipe are as listed, with no ABGR/XBGR.
12. **labwc does not use overlay planes:**
    - labwc 0.20.2 tarball: no `output_layer` anywhere. `direct_scanout` is touched only at `server.c:616` and `magnifier.c:244-245`.
    - wlroots `wlr_scene.c:198` has the direct-scanout switch.
    - `backend/drm/drm.c:90-98` has the `WLR_DRM_FORCE_LIBLIFTOFF` gate.
13. **HDMI mode list:**
    - Patch 0010 rejects `mode->clock > 75000`.
    - `hdmi4.c` never sets `interlace_allowed`. `display-connector.c:286` does, and `drm_bridge_connector.c:670-672` clears it if any bridge lacks it.
    - `drm_mode_compare` (`drm_modes.c:1841-1862`) sorts preferred, then area, then refresh, then clock.
    - `wlr_output_preferred_mode` (`output.c:474-488`) and labwc `output.c:485-491` are as cited.
14. **Stock OPPs** (re-dumped with `reverse-eng/tools/dump.py`):
    - 4460 table: `0xc0043e94`/`eac`/`ec4` = gpu/core/`dpll_per_m7x2_ck`, at 153 600 000 Hz / 962 000 µV, 307 200 000 / 1 127 000 and 384 000 000 / 1 250 000, all with avail = 1.
    - 4430 table (`0xc0043c9c`, `0xc0043cb4`): stops at 307.2 MHz.
15. **Stock HDMI device and VRAM** (re-dumped):
    - `+0x150 = 0x20`, `+0x154 = 1`, `+0x194 = 0x0001000f`, `+0x198 = 165000`.
    - `steelhead_fb_pdata + 0x30 = 0x01000000`.
    - `hwcomposer.omap4.so` strings: "/dev/dsscomp", "Primary display is HDMI", "DSS scaler cannot support HDMI cloning" and "used %d z-layers for %d overlays".
16. **HDMI PLL arithmetic:** recomputed by hand from `dss_pll_calc_b` (`pll.c:272-327`) and `dss_omap4_hdmi_pll_hw` (`hdmi_pll.c:77-98`), with clkin = 38.4 MHz. Every N/M2/DCO/M/M.f/SD row of the §6.2 table matches. The clkin value itself is still UNVERIFIED.
17. **Video:**
    - v6.18.48 `omap4.dtsi:360-370`: IPU node with `omap4-ipu-fw.xem3`, `status = "disabled"`.
    - `omap_remoteproc.c:1097`: matches `ti,omap4-ipu`.
    - mobiaqua linux-ti recipes: `rpmsg-rpc/0050…0060`.
    - `ducati-m3.bin` is 2 314 420 B, with `OMX.TI.DUCATI1.VIDEO.DECODER`/`H264E`/`MPEG4E`/`MISC.SAMPLE` and `codec_engine_3_21_00_13`.
18. **openpvrsgx and PREEMPT:** branch `pvrsrvkm-6.18-rc6` head `d2f1e031d58a…` and commit `0affbb5a7b95` (title verbatim) exist. The defconfig has `CONFIG_PREEMPT_NONE=y` at lines 99-102.
19. **Repo references:**
    - `nexusq-wayland.sh:8-9`.
    - `APKBUILD:45` (mesa-dri-gallium), `:48-49` (lxqt-wayland-session, labwc), `:53` (mpv) and `:204-216` (multi-user default target).
    - `weston.ini:9-20` and `lxqt-session.conf:7`.
    - `steelhead_defconfig:489` (`video=HDMI-A-1:1280x720@60`) and `:5529` (`CMA_SIZE_MBYTES=16`).
    - `CHANGELOG.md:81` (2.0.2, 2026-10-10).
    - `PLAN.md:2004-2008` (102.8 °C) and `PLAN.md:2175-2176` (weston 1024×768).
    - The 2026-06-23 ~30 % CPU baseline is at `docs/2026-06-23-session-findings.md:62-65` (cited as 58-62, a small offset).
20. **Shaders:** `particle_screensaver_v` has `gl_PointSize = 60.0;` and the `blur_distort_*_f` files exist. The count of 40 particles comes from `docs/2026-06-19-particle-screensaver-RE.md:12`.

### Corrected in place

- **B2 timing.** wlroots needed dma-buf import *functionally* from 0.13.0, not 0.14.0. In 0.13.0, `create_buffer` (`renderer.c:82-108`) binds every render buffer through `wlr_egl_create_image_from_dmabuf`. 0.14.0 only added the creation-time check. The TL;DR, §3.1 history table, W5 and B2 are updated. The conclusion that MR !1868 is outdated for modern wlroots is unchanged and only gets stronger.
- **VDD_CORE / VDD_MPU state (§6.3 and TL;DR 7).**
  - The report cited the 2026-06-25 note as showing "VCORE1 still feeding VDD_MPU". That is stale.
  - Since v1.4.0 (2026-06-26), VDD_MPU is on the TPS62361 (patch 0014, `CHANGELOG.md:8555-8566`).
  - VDD_CORE is on TWL6030 VCORE1, with a stock VC ON voltage of 1.200 V (patch 0027).
  - The runtime core voltage is still unmeasured. "No core DVFS" is now marked UNVERIFIED.
- **nq-hdmi master gating (§4.4).**
  - Only the console re-park (`_keep_black`) is gated on "no DRM master".
  - The unblank (`_keep_lit`) runs unconditionally on every poll.
  - It is harmless, because `drm_client_modeset_dpms()` returns `-EBUSY` under a master.
- **mesa-sgx dispatch (§3.4).** Entry points are taken by `dlsym` on the closed library first. `PVRDRIEGLGetProcAddress` is only the fallback.
- **mobiaqua kernel (§3.4, §5).** `panda.conf` pins `linux-ti` 6.6, not 6.8. The 6.6 recipe carries the same rpmsg-rpc and omapdrm patches.
- **openpvrsgx PREEMPT commit (§8).**
  - It was authored 2024-10-26 and committed (rebased) 2025-11-16.
  - Its diff only adds `CONFIG_PREEMPT_VOLUNTARY=y` to `omap2plus_defconfig`. The pvrsgx `Kconfig` has no PREEMPT dependency, so the reason is unknown.
  - The branch list was incomplete: 6.19-rc6, 7.0, 7.1 and 7.2-rc2/rc3 branches also exist.
- **Stock blur shader (§2).** The `× 0.95` factor applies to **alpha only** (`vec4(1,1,1,0.95)`), and `blur_distort_plain_f` is non-distorting.
- **Plane formats (§1.5).** A KMS plane advertises the format list of the pipe with its own index. The primary plane therefore offers no YUV, and NV12 needs an overlay KMS plane. `COLOR_ENCODING`/`COLOR_RANGE` exist only on the YUV-capable (overlay) planes.
- **B1-a rule fit.** This was downgraded from "Fits" to a qualified inference. A patch on mobiaqua's mesa-sgx is itself a local modification of an upstream project. It needs a tracked base plus a rebase path, or upstreaming.
- **Stock HDMI dividers (§2, TL;DR 6).** `regn=15`/`regm2=1` are TI's generic defaults (`HDMI_DEFAULT_REGN`/`HDMI_DEFAULT_REGM2`, lkml 2012-03 "OMAP: DSS2: HDMI: use default dividers"), not a steelhead tuning. Register 15 means N = 16 (`refclk = clkin / (regn + 1)`).

### Added (important points the report missed)

- **labwc `reuseOutputMode`.** labwc 0.20.2 `<core><reuseOutputMode>yes</reuseOutputMode></core>` (`src/output.c:474-481`, default `no`) keeps the CRTC's current mode, which is the fbdev 720p60. It is a configuration-only way to stop the desktop toggle from modesetting the TV and glitching HDMI audio. Our `labwc-rc.xml` does not set it. Not tried.
- **kmscube modesets.** kmscube legacy mode calls `drmModeSetCrtc` with its own mode (`drm-legacy.c:69`). On a TV this can be a full modeset. Pass the current mode explicitly for the first SGX test.
- **The `gbm_surface` path still shares buffers.** It needs no *EGL* dma-buf import. But the BO is allocated by the closed `libpvr_dri_support` and shared between pvrsrvkm and omapdrm. mobiaqua carries omapdrm UAPI and dma-buf kmap patches (`ti/0017`, `0020`, `0030`) even for this. UNVERIFIED whether 6.18 needs them; that belongs to the kernel workstream.
- **Defconfig gaps for video.** Our defconfig has `# CONFIG_OMAP_REMOTEPROC is not set` and `# CONFIG_RPMSG_VIRTIO is not set` (`steelhead_defconfig:4116-4124`).
- **DDK glibc requirement.** `libGLESv2_PVR_MESA` needs at most `GLIBC_2.34`, and `libpvr_dri_support` needs `GLIBC_2.4`. The bookworm sandbox (glibc 2.36) covers both. `libsrv_um` was not checked.
- **MR !1868's DDK commit.** `551665bf…` is the head of TI's `ti-img-sgx/zeus/1.17.4948957` branch (`git ls-remote`). That is an older build line than yocto's `84a396a4`.
- **Empirical support for the mode-pick inference.** On the Philips monitor, after the cap, wlroots chose 1280×720@60, which is the largest-area surviving mode (`docs/2026-06-23-session-findings.md:32-44`). The cmdline `video=` mode only gets `DRM_MODE_TYPE_USERDEF` (v6.18.48 `drm_probe_helper.c:167-168`), so it does not steer the compositor.
- **TMU count, secondary source.** The Wikipedia PowerVR table lists SGX540 as "4/2" (USSE/TMU). This is still not a primary source.

### Could not reproduce, or left UNVERIFIED

- **Alpine `wlroots0.20` commit dates** (`76562f88` 2026-07-08, `6d015184` 2026-07-15, "made default 2026-03-26"): the GitLab commits API returned HTTP 500 on 2026-10-11. The version and pkgrel themselves were confirmed.
- **Merge status of the meta-ti weston 15.0.0 patch:** only the mailing-list post was seen.
- **The TI 3.0 meaning of `max_pixclk_khz`** (it drops EDID modes above the limit): seen only in a search snippet of ara-mdk `kernel/panda` `hdmi.c`. The page was not opened.
- **Unopened or still-estimated items:**
  - the CPU cost estimates in §4.3 (cycles/px, the WC-read slowdown);
  - the SGX fill-rate share (it depends on 2 TMU/clk);
  - the EMIF sustained bandwidth;
  - the claim that Mesa ≥ 24.2 no longer loads external `*_dri.so`;
  - `mpv --vo=drm` behaviour on omapdrm.
- **Things never observed on hardware, as the report itself says:**
  - the labwc mode chosen on a TV or the soundbar;
  - the HDMI audio glitch on a desktop toggle;
  - VDD_CORE at runtime;
  - the SGX clock;
  - the runtime GL extension strings.
