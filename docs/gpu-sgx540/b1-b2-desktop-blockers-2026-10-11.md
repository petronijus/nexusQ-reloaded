# B1 and B2 solved: the two blockers of an accelerated labwc, 2026-10-11

Gate for an accelerated labwc desktop. wlroots 0.20 (labwc) refuses to create
its GLES2 renderer without `EGL_EXT_image_dma_buf_import`, and renders every
frame into GBM buffers it imports back through that extension
([compositor-display.md](compositor-display.md) §3, blocker B2). TI removed
the extension from mesa-sgx (`a698020`, "DDK 1.17's implementation of buffer
imports/exports was half-baked and was never fully functional under Linux").
This note measures the case wlroots needs on our kernel.

## Result

**PASS, both buffer origins, no kernel error.** On the Prague unit, kernel
6.18.48-r24 (trial slot B, patches 0063-0074), DDK 1.17.4948957 `ti443x`
blobs @84a396a4, route B sandbox:

| Run | Mesa | Buffer | Frames | `glReadPixels` mismatches | dma-buf `mmap` mismatches |
|---|---|---|---|---|---|
| control | Maemo 22.3.6+sgx2 (image ext v7) | GBM | — | `eglCreateImageKHR` fails `EGL_BAD_PARAMETER`, extension ABSENT | — |
| 1 | 24.0.9 + B2 patch | GBM (`XRGB8888`, `RENDERING\|SCANOUT`) | 200 | 0 | 0 |
| 2 | 24.0.9 + B2 patch | omapdrm dumb BO, prime fd | 200 | 0 | 0 |
| 3-5 | 24.0.9 + B2 patch | GBM | 3 × 300 | 0 | 0 |

`dmesg` stayed free of errors and warnings; `/proc/pvr/queue` empty after.

## What was run

- **Mesa:** Maemo `leste-upstream-forks/mesa` tag `powervr-24.0.9` @
  `72c93be7aa29` (the pick in userspace-blobs.md Addendum A.5), plus one
  change: `PVR_DRI_IMAGE_VERSION` 7 → 8 and
  `.createImageFromDmaBufs = PVRDRICreateImageFromDmaBufs`, i.e. TI's
  `a698020` reverted
  ([drafts/mesa-sgx-b1-b2/0001-…patch](drafts/mesa-sgx-b1-b2/)). The import code
  itself was never removed: `createImageFromFds` (v7) already reached the same
  `CreateImageSharedFromDmaBufs` → `PVRDRIBufferCreateFromFds` path.
  Cross-built for Debian bookworm armhf (glibc, the sandbox's base) with
  `-Dgallium-drivers=sgx -Dglvnd=true -Dgbm=enabled -Dplatforms=wayland`
  ([drafts/mesa-sgx-b1-b2/Dockerfile.mesa-sgx-glibc-cross](drafts/mesa-sgx-b1-b2/Dockerfile.mesa-sgx-glibc-cross)),
  installed in the sandbox under `/opt/mesa-b2` next to Maemo's Mesa.
- **Probe:** [drafts/mesa-sgx-b1-b2/b2probe.c](drafts/mesa-sgx-b1-b2/b2probe.c). GBM
  device on `card0`, surfaceless GLES2 context, buffer → dma-buf fd →
  `eglCreateImageKHR(EGL_LINUX_DMA_BUF_EXT)` →
  `glEGLImageTargetRenderbufferStorageOES` → FBO → per frame a different
  clear colour, `glFinish`, then checked through `glReadPixels` and through a
  CPU `mmap` of the dma-buf bracketed by `DMA_BUF_IOCTL_SYNC` (what omapdrm
  scans out).

## Limits

- Clears only. A textured draw from an imported **client** buffer (sampling
  side, `glEGLImageTargetTexture2DOES`) is the next case; labwc + LXQt clients
  use `wl_shm`, so that path matters less for the desktop than for video.
- No modifiers: SGX has none, and wlroots falls back to its implicit format
  list when `EGL_EXT_image_dma_buf_import_modifiers` is absent
  (compositor-display.md §3, W5 table). Our own KMS clients must not pass
  `DRM_FORMAT_MOD_INVALID` to AddFB2 (first-light note, Step 4).
- Route B (glibc) only. The product build is musl (route A); the result holds
  for the kernel and DDK side, the Mesa side gets rebuilt for musl.

## B1: `GL_EXT_unpack_subimage`, emulated in mesa-sgx

**PASS.** The DDK's GLES2 library lacks the extension (blocker B1, required by
wlroots ≥ 0.13 and weston ≥ 10). It only adds three pixel-store parameters
honoured by `glTexImage2D`/`glTexSubImage2D`, so mesa-sgx now provides it in
the GLES2 dispatch table it fills from the DDK (option B1-a of
compositor-display.md §3.7): `sgx_unpack.c` wraps `glPixelStorei`, the two
uploads, `glGetIntegerv/Floatv/Booleanv` and `glGetString`. The state is per
context (a thread-local current context set at make-current); an upload with
a parameter set hands the DDK the selected rows, as an offset pointer when
they are contiguous, otherwise as a packed copy read with alignment 1. If any
of the seven DDK entry points is missing the table is left untouched and the
extension is not advertised.
[drafts/mesa-sgx-b1-b2/0002-…patch](drafts/mesa-sgx-b1-b2/).

Test: [drafts/mesa-sgx-b1-b2/b1test.c](drafts/mesa-sgx-b1-b2/b1test.c).
A 61×40 source whose texels encode their coordinates is uploaded in parts
(whole-texture window with `ROW_LENGTH` + both skips; a 13×11 damaged rect
via `glTexSubImage2D` over a base fill; `SKIP_ROWS` with contiguous rows) in
RGBA, BGRA, RGB with alignment 4 (odd width, padded rows) and RGB with
alignment 1, drawn with a nearest sampler into an RGBA FBO and compared per
pixel; plus the `glGetIntegerv` round trip and `glGetError` at the end.

| Mesa | Extension | Result |
|---|---|---|
| Maemo 22.3.6+sgx2 (none) | ABSENT | **15 of 15 checks fail** (640/640 or 143/640 pixels wrong, `GL_INVALID_ENUM`) |
| 24.0.9 + B1 + B2 | advertised | **15 of 15 pass**, 0 pixels wrong, no GL error |

(The first run of the test had a bug of its own: the base fill was uploaded
with `ROW_LENGTH` still set to the source width. The wrong pixel named the
texel it came from, which pointed at the test, not the emulation.)

Cost: one CPU copy of the damaged rows when the client stride differs from
the rect width, which is the normal case for a damaged sub-rect of a
`wl_shm` buffer. Measured as part of the desktop gate, not here.

## Consequence

B2 is not a blocker on our kernel; TI's "half-baked" verdict does not hold
for linear XRGB8888 render targets on 6.18 with patches 0063-0074. The
accelerated desktop goes ahead on labwc as packaged by Alpine, unpatched. With
B1 emulated as well, both hard blockers are solved inside mesa-sgx, our own
package; what remains is route A (mesa-sgx and the DDK on musl), the session
wiring with a pixman fallback, and the measured gate.
