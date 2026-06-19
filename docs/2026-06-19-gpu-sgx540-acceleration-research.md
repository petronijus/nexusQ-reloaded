# Nexus Q — PowerVR SGX540 GPU acceleration: feasibility & parts research

**Date:** 2026-06-19
**Question:** There is no GPU driver today (software rendering only, PLAN.md #4). Can we
*build* hardware acceleration for the Nexus Q's GPU, and what existing pieces are reusable?
**Answer (TL;DR):** **Yes, it is buildable** — and most of the hard work already exists for the
near-identical Motorola Droid 4. The path is: a **GPL kernel module** (actively rebased onto
~6.15 mainline) + **closed TI userspace blobs** (EGL/GLES, version-matched) + a **Wayland**
display stack. It is real engineering work (SoC power/clock glue + version matching + a Wayland
compositor instead of X11), but it is a port, not a from-scratch driver or a reverse-engineering
project.

---

## 1. The hardware reality

| | |
|---|---|
| GPU | **PowerVR SGX540**, Imagination **Series5** (USSE1), core revision **1.2.0** |
| In SoC | TI OMAP4460, on a `gpu` target-module (ti-sysc) inside the L3 / GFX power domain |
| Mainline 3D driver | **None.** Mesa has no Gallium driver for Series5; Imagination's open
`powervr`/Mesa work covers only **Rogue (Series6+)**, not SGX5. |
| Mainline KMS/display | **Works already** — `omapdrm` (DSS + HDMI) gives us a framebuffer and
KMS. We are *only* missing the 3D/GLES engine, not display. |

So "no GPU driver" = no OpenGL ES acceleration. 2D/KMS/HDMI is fine. The win from doing this work
is **hardware GLES2/EGL** — e.g. to render the original Nexus Q HDMI *particle-field visualizer*
(see `2026-06-19-particle-screensaver-RE.md`, the 40-particle GL field) at full speed on a
single Cortex-A9 core, plus accelerated compositing for any HDMI UI.

## 2. Why this is a *port*, not a moonshot — the Droid 4 precedent

The **Motorola Droid 4** is **OMAP4430 + the exact same SGX540**. Two communities have had
working SGX540 acceleration on mainline kernels for years:

- **Maemo Leste** (Devuan/Debian-based) — shipped SGX540 accel on the Droid 4.
- **postmarketOS** pmaports MR **!1868 "PowerVR SGX Acceleration"** — packaged it for pmOS
  (musl!), targeting `motorola-maserati` (Droid 4) and the N900.

Our OMAP4460 differs from the Droid 4's OMAP4430 only in clock speed — **same GPU, same DDK,
same blobs**. Almost everything transfers.

## 3. The stack has three layers — only the middle one is closed

```
  ┌─ userspace app (GLES2 / EGL) ────────────────────────────────────────┐
  │  libGLESv2 / libGLESv1_CM / libEGL  ← CLOSED TI/IMG blobs (version X)  │ ← the only non-free part
  │  libsrv_um (user-mode services)     ← CLOSED, must match kernel KM ABI │
  ├─ display glue ───────────────────────────────────────────────────────┤
  │  Mesa-sgx (GBM/EGL/KMS wrap) OR DRI MIT bits   ← OPEN (Mesa 22.3 fork) │
  │  Wayland compositor (wlroots / weston / Plasma Mobile)                 │
  ├─ kernel ─────────────────────────────────────────────────────────────┤
  │  pvrsrvkm.ko  (/dev/pvrsrvkm)       ← GPL/MIT, BUILDABLE FROM SOURCE   │
  │  omapdrm (DSS/HDMI, KMS) + ti-sysc gpu target-module + GFX clocks/PRM  │
  └───────────────────────────────────────────────────────────────────────┘
```

**Critical constraint:** the closed userspace DDK version **must exactly match** the kernel
module's DDK ABI version (1.9 ↔ 1.9, 1.17 ↔ 1.17). That is the #1 thing that breaks.

## 4. Reusable parts (the shopping list)

| Part | Source | What it gives us | License / notes |
|---|---|---|---|
| **GPL kernel driver** | **`openpvrsgx-devgroup/linux_openpvrsgx`**, branch **`letux/pvrsrvkm-1.17.4948957`** | `drivers/gpu/drm/pvrsgx/1.17.4948957/` — the `pvrsrvkm` DRM module. **Actively rebased onto 6.15-rc5 (commit 2025-05-04, "fix for 6.15-rc1")**. Mainline `omap4.dtsi` here already carries `compatible="ti,omap4430-gpu","img,powervr-sgx540"` + DT binding `img,powervr-sgx.yaml`. | GPLv2. Multiple version branches (1.5→1.17) so the KM can be matched to whatever blob version you pick. |
| **SoC glue (OMAP power/clock)** | same repo, **`letux/omap-pvr-soc-glue-v10`** (and v2…v10) | The OMAP-specific reset/clock/PRM/target-module wiring for the GPU power domain. The integration layer ("L1 glue") between pvrsrvkm and the OMAP4 SoC. | GPLv2. |
| **Closed userspace blobs (OMAP4)** | **`maemo-leste/pvr-omap4`** | Packages TI's `libEGL` / `libGLESv2` / `libGLESv1_CM` ("sgx-lib") for OMAP4 SGX540; `fetch-pvr-omap` pulls the TI Graphics-SDK blobs. Current pkg DDK **1.9.x** (`1.9.0.8.1.3`). | Closed (TI/IMG redistributable). DDK **1.9.2188537** is the canonical OMAP4 SGX540 userspace; the Maemo wiki notes last X11/DRI SDK = **4.10.00.01**, last general SDK = **4.04.00.04**. |
| **Open-ish Mesa path** | **`mobiaqua/mesa-sgx`**, branch **`mesa-22.3-sgx`** | Mesa 22.3 fork with Series5 GBM/EGL/KMS integration (what pmOS MR !1868 calls "the PVR fork of Mesa"). Lets the closed GL run under GBM/Wayland on a modern stack. | MIT (Mesa) wrapping the closed GL. |
| **GBM for SGX5** | **`mobiaqua/libgbm`** | GBM buffer allocation fork for TI SGX5 SoCs — needed for KMS/Wayland buffer sharing with omapdrm. | MIT. |
| **Alt kernel module** | **`mobiaqua/sgx-pvr5-module`** | Standalone DDK KM source (MIT/GPL dual). README is arm64/DRA7xx-tuned but it's the same DDK family — secondary option to the letux module. | MIT or GPLv2. |
| **DKMS packaging** | `mobiaqua/pvr-omap4-dkms` (referenced by Maemo wiki) | Out-of-tree DKMS build of the OMAP4 module — a packaging pattern if we don't build it in-tree. | — |
| **pmOS recipe** | pmaports MR **!1868** | Working APKBUILD layout under **musl**: a Mesa fork pkg + an SGX-blob provider pkg split per-SoC. Proves musl works via `dlsym`. | reference |

## 5. Recommended path for the Nexus Q

1. **Kernel module, built out-of-tree against our 6.12.12.** Take the `pvrsgx/1.17.4948957`
   driver + the `omap-pvr-soc-glue-v10` OMAP wiring from `linux_openpvrsgx`. The maintainer
   targets 6.15-rc; backporting the handful of API shims (e.g. `timer_delete_sync`) down to 6.12
   is small. Build it as a **`.ko` on the rootfs**, *not* baked into the boot image — this sidesteps
   the **≤6.5 MB boot-image kernel ceiling** entirely (module + firmware + blobs all live on the
   13 GB userdata rootfs, udev-loaded). Pick the DDK version (**1.17** preferred, or **1.9** if we
   want the proven Maemo blob set) and **match the kernel branch to it**.
2. **Device tree.** Add the `gpu` / `img,powervr-sgx540` node to `omap4-steelhead.dts`, copying the
   `omap4.dtsi` GPU node + GFX clocks/PRM from the letux tree. (omapdrm/DSS already up, so display
   is done.)
3. **Userspace blobs.** Fetch the matching DDK from `maemo-leste/pvr-omap4` (`fetch-pvr-omap`).
   Confirm musl loads them (pmOS MR proves `dlsym`-based loading works; we're already part-musl in
   `nexusqd`).
4. **Display stack = Wayland, NOT X11.** This is the key product decision. pmOS MR !1868 reports
   **X11/XFCE is the broken path** (glamor/modesetting ES2 bugs); **wlroots compositors and Plasma
   Mobile work**. PLAN.md #4 currently picks XFCE (X11/lightdm) — for GPU accel we'd swap to a
   minimal Wayland compositor (weston/labwc/sway). For the *headless + occasional HDMI* use case
   that's fine, and it's the only way GLES actually paints.
5. **First milestone:** `/dev/pvrsrvkm` appears, `pvrsrvctl` starts the services, and a
   `kmscube`-style GLES2 demo (mobiaqua has a `kmscube` fork) renders over omapdrm. Then port the
   particle-field visualizer to GLES2 on HDMI.

## 6. Risks / open questions

- **Kernel delta 6.12 vs 6.15.** Small but real; the letux branch assumes a recent mainline. Either
  backport the driver shims to 6.12 *or* bump our kernel toward 6.15 LTS (watch the 6.5 MB boot
  ceiling + GCC 13.3 constraint — see `nexusq-boot-constraints` memory).
- **DDK/KM version match.** Mismatched userspace↔kernel ABI = silent failure. Lock the pair early.
- **Single core.** GPU offloads the *3D*, but EGL/driver overhead still runs on the one A9. Expect
  "fast enough for a visualizer/compositor", not a games machine.
- **SGX firmware blob** (`sgx540_*.fw` microkernel) must ship alongside the module — it's in the TI
  SDK / Maemo blob set.
- **OMAP4460 ≠ OMAP4430 clocks.** GPU is identical; double-check the GFX DPLL/clock rates in the
  SoC glue match the 4460 (4460 clocks the SGX higher). Likely just a DT clock-rate tweak.
- **Worth it?** The device is mostly headless (LED ring + audio). GPU accel only pays off if we
  actually want the **HDMI particle visualizer** or an accelerated HDMI UI. If HDMI stays a
  debug-only port, software rendering (current state) is the cheaper call. This is a "because we
  can / to finish the original Nexus Q experience" feature, not a core-function blocker.

## 7. Primary sources

- openpvrsgx-devgroup/linux_openpvrsgx — GPL SGX5 kernel drivers (OMAP/Sunxi/jz4780 glue),
  branch `letux/pvrsrvkm-1.17.4948957` rebased to 6.15-rc5.
- mobiaqua: `mesa-sgx` (`mesa-22.3-sgx`), `sgx-pvr5-module`, `libgbm`, `kmscube`.
- maemo-leste/pvr-omap4 — OMAP4 SGX540 closed userspace blobs (DDK 1.9.x).
- postmarketOS pmaports MR !1868 "PowerVR SGX Acceleration" — musl packaging recipe.
- leste.maemo.org/Motorola_Droid_4/PowerVR — Droid 4 recipe (now points to openpvrsgx-devgroup).
- Mesa docs `drivers/powervr.html` — confirms open driver is Rogue-only (Series6+), not SGX5.
</content>
</invoke>
