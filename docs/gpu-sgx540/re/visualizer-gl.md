# SGX540 RE 7/7: what the stock Nexus Q HDMI visualizer does on the GPU

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

- **The shader sources are not reproduced in this repo.** They are Google's code
  inside the stock `Visualizer.apk`. The report's Appendix A (31 verbatim
  sources) stays in the scratch area; this note keeps a table of every raw
  resource with its size and full sha256, so a re-extraction from
  `reverse-eng/factory/tungsten-ian67k/system.raw.img`
  (`debugfs -R "dump /app/Visualizer.apk …"`, then `unzip … res/raw/*`) can be
  checked byte for byte. The behaviour of each shader that matters for a port is
  described in §3 and §4.
- The stock GPU OPP table used in §6 agrees with [stock-sysconfig.md](stock-sysconfig.md)
  §3.4. On our kernel 384 MHz must not be used until VDD_CORE scaling exists;
  307.2 MHz is the planned rate (pending a live VDD_CORE read).
- `userspace/nexusqd/src/` already holds LED-side scene implementations
  (`fx_circles.c`, `fx_pointmorph.c`, `fx_starfield.c`, `fx_waveform.c`,
  `fx_waveformsolid.c`); whether they follow the formulas below was not checked
  in this session.

---

## TL;DR

- **API: plain OpenGL ES 2.0** through `android.opengl.GLES20` and `GLSurfaceView`
  (`setEGLContextClientVersion(2)`). There is **no RenderScript, no GLES1 and no
  native code** in the visualizer. The APK contains no `.so` and no `.bc`, and the dex
  references no RenderScript class. All 31 GLSL ES 1.00 shaders sit in the APK as
  `res/raw/*` text files (hashes in Appendix A; the text stays out of this repo). A GLES2 port can reuse them unchanged.
- **The idle "particle field" is tiny.** It draws **40 point sprites** (`GL_POINTS`, `gl_PointSize = 60.0` px)
  of the 64×64 `particle2.png` texture, color `(0, 0.6, 0.8, 0.6·screensaverAlpha)`, with
  **additive blending** (`GL_SRC_ALPHA, GL_ONE`). They sit on a breathing ring (radius 1.5…1.7 world units
  minus `0.5·throb`, z = −13 − 2·throb, 45° vertical-FOV frustum). It renders **directly into the
  screen framebuffer** at the HDMI resolution. On mute it also draws a 4-vertex textured quad (`muted.png`, 100×100).
  GPU cost on SGX540 is negligible, and so is CPU cost in software: about 144 k blended fragments per frame.
  **This one effect does not need the GPU at all** (an unmeasured estimate). A pixman or NEON reimplementation is cheap if the clear is limited to the ring's bounding box.
- **While music plays the visualizer is a "MilkDrop-style" feedback renderer.** Every music frame:
  (1) take a fresh **960×540 RGBA8888 FBO** from a pool of 3;
  (2) redraw the previous frame into it through one of **6 distortion shaders**, using a quad scaled by `1+zo`
  and small-angle rotated by `ro` (per frame, normalised to 30 fps), with additive blending;
  (3) draw the current scene on top;
  (4) **upscale-blit the FBO to the screen** with a linear filter.
  The five scenes rotate every **10 s** from a deterministic `java.util.Random(0)` sequence:
  `Waveform` (GL_LINE_STRIP), `WaveformSolid` (GL_TRIANGLE_STRIP bars), `Circles` (256 point sprites),
  `PointMorph` (258-point 3D models morphing) and `StarField` (100 textured quads, one draw call each).
  Each scene change cross-fades over **5 s**, so **half of all music time renders two scenes**.
  This pipeline is where the SGX540 earns its keep. Not counting the screen clear, it is about 3.2–4.1 M
  fragments per frame at 1080p and about 2.0–3.0 M at 720p (the upper ends cover a cross-fade with two scenes),
  most of it bilinear texture sampling. These are estimates; see §6.1 (corrected 2026-10-11 verification).
- **Audio drive is `android.media.audiofx.Visualizer(0)`**, the global output mix. Waveform and FFT
  capture run at the maximum rate, **20 segments/s × 1024 samples**. Both constants are confirmed in the stock
  `libaudioeffect_jni.so`: `movs r1,#128; add.w r0,r1,#896` and `movw r0,#20000`.
  The stock `libvisualizer.so` applies **per-buffer power-of-two AGC** to the 8-bit waveform, up to
  32×, so the visualizer reacts to the *shape* of the signal, not to its loudness.
  Derived quantities:
  - `volume`: the mean |sample| per segment;
  - a **beat tracker**: spectral flux over the FFT real parts, then a bank of **833 Gaussian comb filters, 50–179 BPM**;
  - `smoothedBeat`: a one-pole filter with coefficient 0.7.
- **Frame pacing:** `GLSurfaceView` runs continuously (vsync-bound), `dt = clamp(Δt, 1 ms, 500 ms)`.
  Geometry motion is time-based. **The feedback decay is per frame**, not per second, so trail length depends on the frame rate.
  The stock frame rate is not stated anywhere in the code.
- **Multi-room sync:** the clock is `SystemClock.elapsedRealtime()` minus an offset re-synced every 30 s to
  `android.os.CommonClock`. Combined with the fixed seed, every Q in a group shows **the same scene at the same
  time** and the same screensaver breath.
- **Side finding (LED, corrects `docs/2026-06-19-particle-screensaver-RE.md`):**
  `RenderEngine.drawFrame` multiplies the *whole* LED configuration by **0.2 while master-muted**
  (`0x01be..0x01c7`), so the ring dims to 20 % on mute. The 2026-06-19 note says mute never changes the ring.

---

## Scope

**Date:** 2026-10-11 · **Scope:** `/system/app/Visualizer.apk` + `Visualizer.odex` of the factory
image `tungsten-ian67k` (Android 4.0.4 IAN67K, build `tungsten-user 4.0.4 IAN67K 403218`) ·
**Status:** static reverse engineering only. Nothing was built, flashed or committed, and no device was touched.

---

## 1. Method and evidence chain

| Step | Command / tool | Result |
|---|---|---|
| Extract | `debugfs -R "dump /app/Visualizer.apk …"`, `…/Visualizer.odex`, `/framework/{core,framework,ext}.odex`, `/lib/libaudioeffect_jni.so`, `/lib/soundfx/libvisualizer.so`, `/build.prop` from `reverse-eng/factory/tungsten-ian67k/system.raw.img` | scratch `<session scratch>/gpu/re/visualizer/` |
| APK listing | `unzip -l Visualizer.apk` | 53 entries: 31 shader text files, 8 model files, 3 PNG textures in `res/raw`, no `classes.dex`, no `lib/`, no `assets/` |
| Resource IDs | SDK `aapt dump resources` (build-tools 36.0.0) | `raw/*` = `0x7f040000…0x7f040029` (table §2.2) |
| Dex | odex header `dey\n036`, dex at file offset `0x28`, length `0x55af4` (350 964 B, `dex\n035`) | |
| Disassembly | SDK `dexdump` cannot decode Dalvik odex opcodes (`GLITCH: run-away instruction`, 6 643 "unused" lines). A purpose-built Dalvik/ICS disassembler `<session scratch>/gpu/re/tools/odis.py` was written instead: opcode table incl. `iget-quick`, `invoke-virtual-quick`, `execute-inline`, `return-void-barrier`; it **re-derives field byte offsets with Dalvik's `computeFieldOffsets` algorithm and vtables with `createVtable`+miranda methods** from the app dex plus the stock `core.odex`/`framework.odex`/`ext.odex`, and tracks register types to resolve each quick op against its receiver class | 2 892 quick ops, **2 888 resolved**, 4 unresolved (all `toString`/`hashCode` on interfaces, irrelevant). Debug info is intact: line numbers, parameter and local names |
| Sanity checks | Resolved names agree with usage everywhere they were checked, e.g. `mRandom.nextFloat()` (`Ljava/util/Random;` vtable #15), `mParticles[]` with `aget`, `glGetUniformLocation("uColor")` result stored into `mColorUniform`; `Random(0).nextInt()` port = −1155484576 (Java's known value) | |
| Native constants | `arm-linux-gnueabihf-objdump -d -M force-thumb` | §5.1 |

Full listing: `<session scratch>/gpu/re/visualizer/vis.smali.txt` (15 335 lines); per-class files in
`visualizer/cls/`. **Execute-inline names** follow the ICS `gDvmInlineOpsTable` order
(index 9 = `Math.abs(F)`, 13 = `Math.sqrt`, 14 = `Math.cos`, 15 = `Math.sin`). This is VERIFIED against the stock
`/lib/libdvm.so`: symbol `gDvmInlineOpsTable` @0xb2780, 352 B = 22 entries × 16 B; entries 9/13/14/15 decode to
`Ljava/lang/Math; abs (F)F`, `sqrt (D)D`, `cos (D)D` and `sin (D)D` (2026-10-11 verification).

---

## 2. Architecture

### 2.1 Process, surfaces, frame loop

`com.google.android.tungsten.visualizer.renderer.OutputActivity` is started by the intent
`com.android.athome.action.VISUALIZER`. Permissions include `RECORD_AUDIO` and `MODIFY_AUDIO_SETTINGS` (AndroidManifest strings).

| Item | Value | Evidence |
|---|---|---|
| GL context | ES 2.0 | `OutputActivity$FullRenderer.setSurface`: `setEGLContextClientVersion(2)` (vtable #503), `setDebugFlags(1)` |
| ES2 gate | `ConfigurationInfo.reqGlEsVersion ≥ 0x20000` or `finish()` | `GlUtils.detectOpenGLES20` |
| Render mode | GLSurfaceView default (continuous). `setRenderMode` is never called | no call site in dex |
| HDMI plugged | `FullRenderer.startRendering` → `onDrawFrame` → `drawFrame(renderSurface=true, renderLeds=mRenderLeds, Clock.getTime())` — **LEDs are updated every display frame** | `OutputActivity.onPluggedState`, `FullRenderer.onDrawFrame` |
| HDMI unplugged | `LedRenderer`: `java.util.Timer.schedule(task, 0, 50)` → `drawFrame(false, …)` every **50 ms (20 Hz)**; no GL at all | `OutputActivity$LedRenderer.startRendering` `const-wide/16 #50` |
| Frame Δt | `elapsedSecs = (time − mLastFrameTime)/1000`, clamped to `[0.001, 0.5]` s | `RenderEngine.drawFrame` 0x0000–0x0013, 0x00d1–0x00d9 |
| Clock | `elapsedRealtime() − mLocalClockOffset`; offset synced to `android.os.CommonClock` (`CommonClockHandler.syncTime`, re-sync message delayed 30 000 ms) | `utils.Clock.getTime`, `Clock$CommonClockHandler` |
| Global GL state | `glEnable(GL_BLEND)`, `glBlendFunc(SRC_ALPHA, ONE_MINUS_SRC_ALPHA)`, `glClearColor(0,0,0,1)`. **No depth test, no culling, no line smooth** (`GL_BLEND` is the only `glEnable` in the app) | `RenderEngine.glInit` 0x0067–0x0075 |
| Shader loader | `BufferedReader.readLine()` + `StringBuilder.append` — **newlines are dropped**; sources are otherwise passed verbatim to `glShaderSource` (hence `/* */` comments only) | `shaders.StreamShaderSource.loadSource` |

### 2.2 Node graph (built in `RenderEngine.<init>`)

```
ScreenRenderTarget (fb 0, HDMI size)
  └─ TrackInfoOverlayEffect          (track metadata bitmap quad, drawn last)
       └─ ParticleScreensaver        ("mNoAudioEffect": draws particles, then its child)
            └─ BlurEffect            (feedback FBO 960×540)       ← when not transitioning
                 └─ Scene[i]         (Waveform | WaveformSolid | Circles | PointMorph | StarField)
            └─ FadeTransition        ← during a scene change; its start/end nodes are Scene or BlurEffect
```

- `mScenes = {Waveform, WaveformSolid, Circles, PointMorph, StarField}` (indices 0…4).
  `needsBlurEffect()` returns `true` for all five, so the blur wrapper is always present.
- `mSceneDurationMillis = 10000`. `mSceneSequence[500]` comes from a separate `new Random(0)`:
  `seq[0] = nextInt(5)`, `seq[i] = nextIntExcluding(rnd, 5, seq[i−1])`, where
  `nextIntExcluding(r, n, ex) = (k = r.nextInt(n−1)) == ex ? n−1 : k` (`utils.Utils`).
  The scene at time `t` is `seq[(t/10000) % 500]`. The first 40 entries, computed by a Java-LCG port in
  Python and cross-checked with `Random(0).nextInt() = −1155484576`:
  `0 3 0 2 4 1 2 0 2 3 1 4 1 2 3 4 3 0 3 0 1 4 0 1 0 2 0 4 2 0 3 2 0 1 2 1 4 0 3 4`. Counts over 500 entries:
  Waveform 101, WaveformSolid 96, Circles 107, PointMorph 96, StarField 100.
- On a scene change: `FadeTransition` with `mDuration = 5.0` s (`BaseTransition.<init>`). The start
  node fades with `alpha·(1−p)`, the end node with `alpha·p`. `BlurEffect.randomizeBlur()` runs when
  progress passes 0.5, or at the start if only the incoming scene needs blur.
  `FadeTransition.glRender`: start node, `glClear(GL_DEPTH_BUFFER_BIT)`, end node.
- The first scene index comes from the *unseeded* activity `Random` (`mSceneIndex = mRandom.nextInt(5)`).
  It is replaced as soon as `seq[t/10000]` differs.

### 2.3 Render targets

| Target | Creation | Format | Sampling |
|---|---|---|---|
| Screen | `ScreenRenderTarget.glSetAsTarget`: `glBindFramebuffer(GL_FRAMEBUFFER, 0)`, `glViewport(0,0,W,H)` | EGL window (config chosen by GLSurfaceView default chooser — UNVERIFIED which) | – |
| 3 × FBO | `RenderEngine.glOnTargetSizeChanged` → `TextureRenderTarget.glCreateTextureTarget(960, 540)` **fixed size, independent of the HDMI mode** | colour `glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA, 960, 540, 0, GL_RGBA, GL_UNSIGNED_BYTE, null)` + depth renderbuffer `GL_DEPTH_COMPONENT16` (0x81A5) | `WRAP_S/T = CLAMP_TO_EDGE` (33071), `MIN/MAG = LINEAR` (9729), no mipmaps |
| Pool | `getTarget()` pops, `returnTarget()` pushes (stack of 3) → effectively 2-buffer ping-pong | | |

### 2.4 Projection helpers (`utils.GlUtils`)

- `sYMax = 0.5·tan(π/8) = 0.2071068`, `sYMin = −sYMax` (`<clinit>`, `Math.tan(0.39269908169872414)`).
- `setDefaultPerspectiveProjection(m, 0, aspect)` =
  `Matrix.frustumM(m, 0, sYMin·aspect, sYMax·aspect, sYMin, sYMax, 0.5, 1000)`. This is a **45° vertical FOV**, near 0.5, far 1000.
- `setDefaultOrthoProjection` = `Matrix.orthoM(m, 0, −1, 1, −1, 1, 0, 100)`. Effectively the identity on x/y.
- Textures: `BitmapFactory.decodeStream` with `inPreferredConfig = ARGB_8888`, then `GLUtils.texImage2D`.
  Parameters: CLAMP_TO_EDGE, LINEAR, no mipmaps. Android `Bitmap`s are premultiplied and `GLUtils.texImage2D` uploads
  them as is. This is LIKELY based on known Android behaviour, not checked in `libandroid_runtime.so`. For a white sprite it means texel = `(a,a,a,a)`.

---

## 3. The idle particle screensaver (HDMI side) — exact spec

Classes: `nodes.ParticleScreensaver` extends `renderer.BaseScreensaver`. Field layout
(objectSize 160): `mvpMatrix@64 [F`, `mColor@68`, `mvpDefaultMatrix@72`, `mVertices@76 FloatBuffer(80)`,
`mProgram@80`, `mParticles@84 float[120]`, `mMutedVertices@88`, `mMutedProgram@92`, `mLastTimestamp@96 J`,
`mLastVolumeChange@104 J`, `mMutedTextureId@112`, `mLockLedAlpha@116`, `mSmoothThrob@136`,
`mTextureId@140`, `mDisableLeds@144`, `mVerticesAttrib@148`, `mColorUniform@152`, `mBlankScreenSaverTimeoutS@156`.

### 3.1 State and update (per frame, only while `mAlpha·mScreensaverAlpha > 0`)

```c
/* initParticles (ParticleScreensaver.java:264-268); i = 0,3,…,117 → 40 particles */
p[i+0] = (rnd.nextFloat() - 0.5f) * 0.5f;      /* angular speed, rad/s, uniform [-0.25, 0.25) */
p[i+1] = rnd.nextFloat() * 6.2831855f;         /* theta, rad */
p[i+2] = 1.5f + rnd.nextFloat() * 0.2f;        /* radius, world units, [1.5, 1.7) */
/* rnd = the activity's unseeded java.util.Random → layout differs per boot */

/* updateScreensaver(timestamp_ms, dt) (lines 150-163) */
mColor.alpha = 0.6f * screensaverAlpha();                           /* line 150 */
/* … lock/blank LED bookkeeping, see 2026-06-19 note … */
throb = cosf(6.2831855f * (float)(timestamp % 10000) / 10000.0f);   /* 10 s period */
updateParticles(dt);

/* updateParticles(dt) (lines 252-260) — note the stock bug */
theta += speed * dt;
if (theta < 0) theta += 2π;
else if (theta > 0) theta -= 2π;  /* compares with 0, not 2π (const/4 v5,#0 @0x001c/0x002c):
                                     theta flips between [0,2π) and [-2π,0) every frame — invisible,
                                     because only cos/sin of theta are used */
```

### 3.2 Draw (`glRenderScreensaver`, lines 190-226) — into the screen framebuffer

```
glActiveTexture(GL_TEXTURE0)
mvp = P · T(0, 0, -13 - 2·throb)        P = frustum(aspect = W/H of the HDMI surface)   (lines 192-193)
if (muted):                                                                                (195-204)
    program particle_screensaver_mute_{v,f}; attrib aVertices: 2×float, quad (-.5,-.5)(-.5,.5)(.5,-.5)(.5,.5)
    texture muted.png (0x7f04000f); uMVPMatrix = mvp; uColor = (1,1,1, screensaverAlpha)
    glDrawArrays(GL_TRIANGLE_STRIP, 0, 4)          ← blend state inherited: (SRC_ALPHA, ONE_MINUS_SRC_ALPHA)
program particle_screensaver_{v,f}                                                          (207)
glBlendFunc(GL_SRC_ALPHA, GL_ONE)                                                           (208)
attrib aVertices: 2×float, stride 0, client-side FloatBuffer (no VBO)                       (210)
texture particle2.png (0x7f040011)                                                          (212)
for each particle: r' = radius - 0.5·throb;  put(cos(θ)·r', sin(θ)·r')                     (213-217)
uColor = mColor.rgba = (0, 0.6, 0.8, 0.6·screensaverAlpha)  (glUniform4fv, NOT premultiplied) (221)
uMVPMatrix = mvp                                                                            (222)
glDrawArrays(GL_POINTS, 0, 40)                                                              (223)
glBlendFunc(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA)                                           (226)
```

Shaders (stock `particle_screensaver_{v,f}`; hashes in Appendix A): the vertex shader sets `gl_Position = uMVPMatrix * aVertices`
(z = 0, w = 1 by default) and `gl_PointSize = 60.0`. The fragment shader is
`texture2D(sTexture, gl_PointCoord) * uColor`.

**Per-fragment result** (black screen, premultiplied texel `(a,a,a,a)`):
`dst.rgb += (0, 0.6a, 0.8a) · 0.6·sa·a`. At the sprite centre with `sa = 1` this adds
`(0, 0.36, 0.48)` = **(0, 92, 122)/255** per sprite, and overlaps accumulate with saturation.

**Screen geometry** (derived from P and T; 1080p assumed):

| | throb = +1 (far, small ring) | throb = 0 | throb = −1 (near, large ring) |
|---|---|---|---|
| z | −15 | −13 | −11 |
| ring radius r' | 1.0…1.2 | 1.5…1.7 | 2.0…2.2 |
| radius on screen, 1080 p | ≈ 87…104 px | ≈ 150…170 px | ≈ 237…261 px |
| radius on screen, 720 p | ≈ 58…69 px | ≈ 100…113 px | ≈ 158…174 px |
| sprite size | **60 px fixed**, independent of resolution | | |
| mute quad (1 world unit) | 87 px | **100 px at 1080 p** | 118 px |

`pixels/unit = H / (2·z·tan 22.5°)`. The mute quad is **exactly 100 px at 1080p and throb = 0**, matching
`muted.png`'s 100×100. That is weak evidence the effect was designed for **1080p** (inference only).
The ring is centred and the screen is otherwise black. On HDMI the sprite colour does **not** depend on throb:
`uColor` is `(0, 0.6, 0.8, 0.6·screensaverAlpha)` in every frame, and only the geometry breathes. With additive
blending, the small ring (throb = +1) packs the 40 sprites closer together, so the overlaps there are brighter.
The throb-driven brightness breath (`0.1 + 0.35·(1 − throb)`) belongs to the LED path only
(`docs/2026-06-19-particle-screensaver-RE.md`). An earlier draft of this note said the ring was "brightest when
it is largest"; that is not supported for HDMI (corrected 2026-10-11).

### 3.3 Timing and alpha (`BaseScreensaver.updateEffect`)

- `mElapsedSecondsWithoutAudio` starts at 5 (`glInit`) and resets to 0 when `volume ≥ 0.01`.
- Music → silence: once there has been no audio for more than 2 s, the scene (`mChildAlpha`) fades out over 1 s.
  After that, and once silence exceeds 5 s, `mScreensaverAlpha` rises over 5 s.
- Silence → music (`volume > 0.01`): the scene fades in and the screensaver fades out, both over 1 s.
- `getScreensaverAlpha() = mAlpha · mScreensaverAlpha`. The draw happens only when `mScreensaverAlpha > 0`,
  and the update only when `mAlpha·mScreensaverAlpha > 0`.
- LED path and blanking (`aah:blank_screensaver_timeout_s`, default 600; lock after 300 s) are
  as in `docs/2026-06-19-particle-screensaver-RE.md`. The GL screensaver keeps drawing while the LEDs are
  blanked, since blanking only affects `ledRenderScreensaver`.

### 3.4 Textures (dumped to `<session scratch>/gpu/re/visualizer/textures/`)

| File | Res ID | Size | sha256 | Content | Used by |
|---|---|---|---|---|---|
| `particle2.png` | 0x7f040011 | 64×64 RGBA8 | `fb206fc0…3230c1` | white RGB; alpha 255 out to r ≈ 11 px, 197 @ r=20, 119 @ r=24, 47 @ r=28, 10 @ r=32, 0 beyond r ≈ 37 | ParticleScreensaver |
| `particle.png` | 0x7f040010 | 64×64 RGBA8 | `76465287…8bb6` | white RGB; alpha 244 at centre, 232 @ r=10, 174 @ r=16, 101 @ r=20, 31 @ r=24, 0 by r ≈ 29 | Circles, PointMorph, StarField |
| `muted.png` | 0x7f04000f | 100×100 RGBA8 | `9a9ea5e2…eb26` | near-white (RGB 219–255 greys) speaker + "×" glyph on transparent; only approximately top/bottom symmetric (alpha differs by up to 48 at 566 pixels) | screensaver mute quad |

Radial profiles come from `<session scratch>/gpu/re/tools/png_profile.py`. On-black previews are the `*_on_black_x4.png` files.

---

## 4. Music scenes — exact spec

Common pieces: `BaseScene.glRender` draws only when the theme `displayMode == 1`, and `ledRender` only when
`ledMode == 1`. Otherwise `LedConfiguration.reset()`. The default theme is `RainbowTheme(s=0.9, v=1.0)`,
`themeColor(pos) = HSV(360·pos, 0.9, 1.0)`, via `android.graphics.Color.HSVToColor` (8-bit quantised).
A theme from HubBroker (`colors[]`) becomes `PaletteTheme`: interpolate between neighbouring palette entries,
with hue interpolated on the unit circle (`atan2` of weighted `sin/cos`) and S/V linear.
HubBroker themes (`extracted-assets/data/apk/HubBroker/res/raw/theme_*`): blue `#33B5E5`;
cool 4 colours; warm 4; spectrum 9; smoke 3 greys; off (display 0, led 0); trackinfo (display 0, led 1, metaOption mode 2).

All scenes draw **into the 960×540 FBO** with blend `(SRC_ALPHA, ONE)`, set by BlurEffect and still in effect.
`aspect` = HDMI W/H, except PointMorph, which uses a fixed 1.5.

| Scene | Primitive / draw calls | Vertex data | Uniforms / texture | Audio coupling | Evidence |
|---|---|---|---|---|---|
| **Waveform** (0) | `GL_LINE_STRIP`, 512 vertices, 1 call; `glLineWidth(max(3, smoothedBeat))` | `x = −1 + 2i/1024`, `y = 0.75·s[i]` for i = 0,2,…,1022; per-vertex RGBA from the theme (if `mMultiColored`, position += 0.0007 per vertex) | ortho MVP; `waveform_{v,f}` | waveform of the latest segment; colour drift `±0.05·beat·dt` | `nodes.Waveform.glRenderScene`, `update` |
| **WaveformSolid** (1) | `GL_TRIANGLE_STRIP`, 512 vertices (capacity/2), 1 call | for li = 0,2,…,510: `x = −1 + 8·li/1024`, emits `(x, max(v,0)), (x, min(v,0))`, `v = 0.8·s[li]`. **Only li < 256 lands on screen (x < 1)** | colour alpha × 0.4; positive samples use theme(pos), negative use theme(pos+0.5) | same | `nodes.WaveformSolid.glRenderScene` |
| **Circles** (2) | `GL_POINTS`, 256 points, 1 call | `r = 0.1·li − 30` (li = 0,4,…,1020), `θ0 = mShift`, `θ += 25·mShift` per point; `x = r·cosθ`, `y = r·sinθ + cosθ` (sic); `aPointSize = max(192·s[li], 10)` px | `MVP = P·T(0,0,−60)`; `uColor` = theme colour; `particle.png` | `mShift += ±(30·dt + smoothedBeat)`; direction flips with probability 1/8 on each beat | `nodes.Circles` |
| **PointMorph** (3) | `GL_POINTS`, 258 points, 1 call | 4 models × 258 xyz (`pointmorph_model_{cube,sphere,spiral,stackedcircles}`); morph `lerp(from, to, (1−cos L)/2)` with `L += 2·dt` up to π (≈1.57 s); a morph starts when `20·rand < timeSinceLastMorph`; `aPointSize = max(150·s[3i], 8)` | `MVP = P(aspect 1.5)·T(0,0,−4)·Rx(45+angle/3)·Rz(45+angle)` (degrees), `angle += 15·dt + 160·beat·dt·volume`; per-vertex colour; `particle.png` | size from the waveform, rotation from beat × volume | `nodes.PointMorph` |
| **StarField** (4) | 100 × `GL_TRIANGLE_STRIP` 4-vertex quads (±0.5), **100 draw calls**, one `glUniformMatrix4fv` each | per particle `MVP = P·Rz(θ°)·T(x, y, −z)`; x, y ~ N(0.5, 1/1.5); z initially U[0,150); `z −= δ` each frame; respawn at U[80,120) when z < 1 | `uColor` = theme colour with V × 0.6 (per particle if `mRainbow`); `particle.png` via `vTextureCoord = 0.5 + aVertices.xy` | `δ = 5·dt + (320·volume)·beat·dt/15`; `θ += 15·s[(off+i)%1024]` | `nodes.StarField` |

Model files: one CSV line each, 774 values = 258 points × xyz. Bounds: cube ±0.75, sphere ±1.414,
spiral −1.5…1.49, stacked circles ±1.33. The LED companion files hold 8 values each (LED ring positions).

### 4.1 BlurEffect — the feedback pass (`nodes.BlurEffect.glRender`, 0x0000–0x0131)

```
next = pool.getTarget(); next.glSetAsTarget()            // 960×540 viewport
glClear(COLOR|DEPTH)                                     // clear colour (0,0,0,1) → FBO alpha = 1
glBlendFunc(SRC_ALPHA, ONE)
if (locked != null):                                     // previous frame
    zo = mZoom·dt·30;  ro = mRotate·dt·30                // normalised to a 30 fps frame
    quad (TRIANGLE_STRIP) = (-1-zo+ro, -1-zo-ro), (-1-zo-ro, 1+zo-ro),
                            ( 1+zo+ro, -1-zo+ro), ( 1+zo-ro, 1+zo+ro)    // scale (1+zo), small-angle rotation ro
    texcoords (0,0)(0,1)(1,0)(1,1); MVP = ortho; program = mActiveBlurProgram (1 of 6)
    draw; pool.returnTarget(locked)
child.glRender(next)                                     // the scene, still additive
glBlendFunc(SRC_ALPHA, ONE_MINUS_SRC_ALPHA)
locked = next
screen.glSetAsTarget(); program blur_v + blur_output_f; uAlpha = mAlpha
full-screen quad ±1, texcoords 0…1, texture = locked (LINEAR) → 960×540 upscaled to HDMI size
```

- `randomizeBlur()`: shader = `rnd.nextInt(6)` from `{plain(0x7f040003), concave(…01), cells(…00),
  hstrips(…02), vstrips(…05), splurge(…04)}`; `mZoom = (rnd + 0.1)·0.04` ∈ [0.004, 0.044) per 30 fps frame;
  `mRotate = ±rnd·mZoom/6` rad per 30 fps frame.
- **Decay arithmetic**, derived from GL semantics, not measured. Because the clear alpha is 1, FBO alpha stays 1
  (`dst.a = src.a² + 1`, clamped). Each frame therefore gives `rgb' = (rgb − 0.002)·0.95`.
  The concave and vstrips shaders apply an extra `·0.95` to alpha, giving `·0.9025`. All of this happens at 8-bit precision.
  An 8-bit simulation, with round-to-nearest per frame, takes a full-white pixel to below 10 % in **40 frames**
  and to 0 in **62 frames** (22 and 38 frames for the ·0.9025 shaders). That is ≈ 1.3–2 s at 30 fps, or
  ≈ 0.7–1 s at 60 fps, before zoom and rotation smear the trail.
  **This is frame-rate dependent**, so a port must fix the frame rate or re-derive per-dt factors.
- **Output blit**: `src = tex·uAlpha` with blend `(SRC_ALPHA, 1−SRC_ALPHA)` and `tex.a = 1`, so
  `screen = tex.rgb·uAlpha² + screen·(1−uAlpha)`. The scene therefore fades in quadratically over the
  screensaver's particles, which were already drawn on the screen.

### 4.2 Track info overlay

`TrackInfoOverlayEffect` inflates `res/layout/track_overlay.xml` (an Android `View` with album art and
artist/track/album text), renders it into a bitmap texture and draws a textured quad with
`trackinfooverlay_{v,f}` (`GL_TRIANGLE_FAN`, 4 vertices, `uAlpha`). It is shown for 5 s with a 1 s fade.
Theme track mode 2 makes it bounce around (`movement.SquareBouncing`).
A port needs a text rasteriser (e.g. freetype or cairo to a texture). It is out of scope for the GPU question.

---

## 5. Audio analysis chain (CPU)

### 5.1 Capture (stock native code, verified)

| Fact | Evidence |
|---|---|
| `Visualizer.getCaptureSizeRange()` = {128, **1024**} | `libaudioeffect_jni.so` JNI table entry @file 0x4274 → fn 0x21d9: `movs r1,#128; str r1,[r0]; add.w r0,r1,#896; str r0,[r2,#4]` |
| `Visualizer.getMaxCaptureRate()` = **20000 mHz** → `SEGMENTS_PER_SECOND = 20` | fn 0x2215: `movw r0,#20000; bx lr`; `AudioCapture.<clinit>`: `getMaxCaptureRate()/1000`, `getCaptureSizeRange()[1]` |
| Session 0 (output mix), waveform + FFT, rate max | `DefaultAudioCapture$CaptureHandler.initVisualizer`: `new Visualizer(0)`, `setDataCaptureListener(this, getMaxCaptureRate(), true, true)`, `setCaptureSize(SAMPLES_PER_SEGMENT)` |
| **8-bit waveform with per-buffer AGC**: `shift = max(3, 25 − clz(max_i |s16_i|))`, `u8 = ((L+R) >> (shift+1)) ^ 0x80` | `libvisualizer.so` `Visualizer_process` @0xc74: min-clz loop 0xcb4–0xcd4, `rsb r3,r6,#25; cmp r3,#3; movlt r3,#3; add r9,r3,#1` 0xcda–0xce8, `asr r5,r0,r9; eor r0,r5,ip(0xffffff80); strb` 0xd68–0xd7a |

The AGC normalises every audio buffer to near full scale in 6 dB steps, with at most 32× gain (shift 3 vs 8).
`volume ≥ 0.01` (the screensaver threshold) is therefore effectively "any non-silent signal".
A port that feeds raw PCM must reproduce this AGC, or the scenes will look dead on quiet tracks.

### 5.2 Java side

- `onWaveFormDataCapture`: `x = ((b & 0xff) − 128)/128` into a ring of 5 × 1024 floats; `mLastSegmentIndex` = start
  of the newest segment; `mVolume = Σ|x|/1024`.
- `onFftDataCapture` → `BeatProcessor.onAudioSegment(volume, fft)` at 20 Hz:
  - `volume < 0.01`: `peakToMean = 0`, `beat = 0`, `smoothed *= 0.7`.
  - `energy = #{k < 512 : |Re_k| > 1 && |Re_k| > |Re_k|prev}`, using **real parts only** (even bytes).
    It is stored in `mBeatValues[120]`, a 6 s history.
  - 833 `Comb`s: for bpm = 50…179, period = 1200/bpm segments, phase step max(2, period/20), Gaussian variance
    period/20. `dot = Σcomb·train − mean(comb)·Σtrain`, updated incrementally (one `exp()` per comb per segment).
  - Hysteresis selects the best comb: confidence capped at 500; switching needs |Δperiod| < 2 and a phase gap
    < 2.01·min(2, period/20), or a peak-to-mean gap > 2.5.
  - A beat fires when the selected comb's nearest-peak offset changes sign and more than half a period has
    passed since the last peak (`mBeatNextFrame`, latched by `onNewFrame` → `isBeatThisFrame`).
  - `beat = max(0, 60·comb(nextIndex, var = max(period/30, period/max(0.5, peakToMean − 8))))`;
    `smoothed = 0.7·smoothed + 0.3·beat`.

CPU cost of the analysis is about 833 `exp()` and about 833×6 flops per segment at 20 Hz. That is
≈17 k `exp()`/s, well under 1 % of one A9 core in C. UNVERIFIED (reasoning).

---

## 6. GPU / CPU cost: SGX540 vs pixman/NEON

Hardware: the stock `omap446x_opp_def_list` has **three** `gpu` OPPs, not two: **153.6 MHz @ 0.962 V,
307.2 MHz @ 1.127 V and 384 MHz @ 1.25 V**. All three are on voltage domain `core` with clock `dpll_per_m7x2_ck`,
and all are `default_available = 1`. They are 24-byte entries `{hwmod, voltdm, clk, freq, u_volt, avail}` at
VA 0xc0043e94, 0xc0043eac and 0xc0043ec4 in `vmlinux.bin`; the table starts at 0xc0043d5c (kallsyms). The earlier
range "0xc0043e8c…0xc0043ecc" was misaligned and dropped the 307.2 MHz entry (corrected 2026-10-11). Whether the
stock board code or the SGX driver disabled any of them at runtime was not checked (UNVERIFIED).
The gsmasia.net spec page does list SGX540 as "4 / 2 Pixel- / Vertexshader" at ~200 MHz. Series5 actually uses
unified USSE pipelines, so read that as a third-party simplification (UNVERIFIED as an architectural statement).
A naive peak of 4 px/clk × 384 MHz ≈ 1.5 Gpx/s is UNVERIFIED arithmetic. For textured, blended fragments
assume roughly 0.3–0.6 Gpx/s (UNVERIFIED).

### 6.1 Fragments per frame

| Pass | 720 p (1280×720) | 1080 p (1920×1080) | Notes |
|---|---|---|---|
| Screen clear | 0.92 M (cheap on TBDR) | 2.07 M | |
| Screensaver 40 sprites | 0.144 M | 0.144 M | 60×60 px each; +10–15 k for the mute quad |
| FBO clear | 0.52 M | 0.52 M | |
| Feedback quad (dependent texture read) | 0.52 M | 0.52 M | `cells`/`strips`/`concave`/`splurge` compute coordinates in the FS; `splurge` does 2 fetches |
| Scene | 0.05–0.5 M | 0.05–0.5 M | Waveform ≈ 1.5–5 k; Circles/PointMorph ≈ 0.2–0.5 M (up to 192 px sprites); StarField ≈ 0.3–0.5 M dominated by z < 3 quads (a quad at z = 1 is ≈ 650 px tall in the FBO) |
| Transition (5 s of every 10 s) | + scene again | + scene again | |
| Output blit | 0.92 M | 2.07 M | 960×540 → screen, bilinear |
| **Total, music** (excluding the screen clear) | **≈ 2.0–3.0 M** | **≈ 3.2–4.1 M** | sum of FBO clear + feedback + scene (0.05–0.5) + optional second scene during a cross-fade (0–0.5) + blit; add ≈ 0.14 M while the screensaver is still fading out. Including the screen clear: ≈ 2.9–3.9 M (720p), ≈ 5.2–6.2 M (1080p). Recomputed 2026-10-11 |
| **Total, idle** | ≈ 0.15 M + clear | ≈ 0.15 M + clear | |

Memory traffic per music frame at 1080p: FBO write 2.07 MB + read 2.07 MB + screen write 8.3 MB ≈ 12.5 MB,
so ≈ 0.75 GB/s at 60 fps (UNVERIFIED reasoning; on a TBDR the FBO and screen are written once per tile flush).

### 6.2 Estimates

| Workload | SGX540 @ 384 MHz (closed DDK) | Cortex-A9 NEON / pixman (software) |
|---|---|---|
| Idle screensaver, 1080 p | ≈ 1–2 % GPU; CPU ≈ 0.2 ms/frame of GL API calls | full-frame clear is 8.3 MB of memset ≈ 4–8 ms; with **damage-rect clearing** (ring bounding box ≤ ≈ 582×582 px: max ring radius 261 px + 30 px sprite half-size, at 1080p) ≈ 1 ms + 40 sprite blends (144 k px, ~2 cycles/px) ≈ 0.3 ms → **≲ 10 % of one core at 30 fps** |
| Music scenes, 1080 p | estimated 6–12 ms GPU/frame → 60 fps plausible, 30 fps comfortable; CPU ≈ 1–3 ms (StarField's 100 draw calls dominate driver overhead) | feedback warp (affine + per-pixel `sin` distortion + bilinear) 0.52 M px × ~20–30 cycles ≈ 10–15 ms; scene 2–5 ms; **upscale blit to 1080 p ≈ 2 M px ≈ 5–8 ms** → ≈ 20–30 ms of single-core CPU per frame, so 30 fps needs ≈ 60–90 % of one A9 core at 1.2 GHz, or both cores if split (the earlier wording "≈ 30 fps using both cores" was internally inconsistent; corrected 2026-10-11); dropping the blit by scanning out 960×540 through a DSS overlay plane with hardware scaling (omapdrm plane scaling: UNVERIFIED) → ≈ 12–20 ms |
| Music scenes, 720 p | lower still | blit ≈ 0.9 M px; ≈ 15–25 ms total |

All rows are UNVERIFIED engineering estimates (cycle counts from typical NEON bilinear and blend kernels).
They have not been measured on the Q.

**Conclusion for the port decision:**
1. The screensaver alone needs no GPU: a NEON/pixman or plain C port into a KMS dumb buffer is cheap,
   and 1:1 reproduction is straightforward (§3).
2. The full music visualizer is the real GPU use case. In software it is feasible at about 30 fps at
   960×540 internal resolution, but it would eat one to two A9 cores at 1080p output. That matters because
   the same cores run the audio daemons and AirPlay, Spotify and Roon decoding.
3. On the GLES2 path every shader ports unchanged. The only GL features used are 2D textures (RGBA8, LINEAR,
   CLAMP), point sprites (`gl_PointCoord`, `gl_PointSize` up to 192 px), `glLineWidth` up to ~60,
   a renderable RGBA8 texture FBO, and client-side vertex arrays. No VBOs, depth test, mipmaps, extensions or float textures are used.

---

## 7. Port checklist (GLES2, 1:1)

1. Create a GLES2 context on the HDMI KMS output. The internal FBO is fixed at **960×540 RGBA8**; the depth
   attachment can be dropped because no depth test is used.
2. Load the 31 shaders as extracted from the stock APK (check them against Appendix A). Keep the semantics exactly; joining lines without newlines is harmless.
3. Global state: blend on, `(SRC_ALPHA, ONE_MINUS_SRC_ALPHA)`, clear `(0,0,0,1)`.
   The screensaver and BlurEffect switch to `(SRC_ALPHA, ONE)` and back as in §3.2 and §4.1.
4. Upload textures **premultiplied** to match Android's `Bitmap`, or compensate in the shader.
5. Audio: capture the post-mixer stream (e.g. a PipeWire/PulseAudio monitor of the sink), mix down to mono,
   and apply the libvisualizer AGC (§5.1) per audio period. Produce 1024-sample segments at 20 Hz and a
   1024-point FFT in the `Visualizer` byte format: `fft[0]` = Re(DC), `fft[1]` = Re(Nyquist), then interleaved
   Re/Im as signed 8-bit. The exact scaling of the stock FFT (`Visualizer::doFft`, libmedia.so @0x4dafd)
   was not examined (open question).
6. Clock: drive `t_ms` from a monotonic clock. For multi-unit sync, align it to a shared time base
   (e.g. the clock our multi-room audio already uses).
7. Scene sequence: `Random(0)` LCG as in §2.2. The Java `nextInt`/`nextFloat`/`nextGaussian` algorithms must be
   reproduced to match the stock order exactly. Only the scene sequence is deterministic; everything else uses
   an unseeded RNG.
8. LEDs: same `RenderEngine`. Apply mute as `×0.2` on the whole ring (TL;DR, side finding).

---

## Appendix A — raw resources of the stock Visualizer.apk (hashes only)

The 42 `res/raw` resources (resource IDs `0x7f040000`–`0x7f040029`, from
`aapt dump resources`) as extracted from the stock APK. Inputs:
`Visualizer.apk` 56 849 B, sha256 `017f3fadb2a996447afea190cb204e47464855555f7be36579aa0ac9c00bb919`;
`Visualizer.odex` 397 024 B, sha256 `9fda0b9f1f6fbbaf39586e06bf9bbecd6a90781e828bedcee0fd1f168bc02d16`. The shader
text itself is Google's code and is deliberately not copied into this repo. 30 of the
31 shader files use CRLF line endings (`blur_distort_splurge_f` uses LF); the
loader's `readLine()` strips both. Identical hashes mark identical files
(`blur_v` = `trackinfooverlay_v`; `particle_screensaver_mute_f` = `starfield_f`;
`waveform_f` = `waveformsolid_f`; `waveform_v` = `waveformsolid_v`).

| File (`res/raw/…`) | Resource ID | Kind | Bytes | sha256 |
|---|---|---|---:|---|
| `blur_distort_cells_f` | 0x7f040000 | GLSL ES 1.00 shader | 584 | `3540a08459c86d4752784d988a63e48dc865f511ae814d3384d48fd0789cfff3` |
| `blur_distort_concave_f` | 0x7f040001 | GLSL ES 1.00 shader | 575 | `437b37d848eaa751d55497bce3fa72cda4a9eefe63e20b8d02d1e0b3d8a226b7` |
| `blur_distort_hstrips_f` | 0x7f040002 | GLSL ES 1.00 shader | 613 | `55e6b0a429fcc70cab65cea87194c257a8eff304e1fd7d534bfd38dc977fc0ef` |
| `blur_distort_plain_f` | 0x7f040003 | GLSL ES 1.00 shader | 319 | `9124d1d857ee82ed47debc12dd8eeb80f3f06dcf5ac3142e9023809d13c62fae` |
| `blur_distort_splurge_f` | 0x7f040004 | GLSL ES 1.00 shader | 645 | `29f66f0e61c4b833fc87821570fdd84fe2ca32b09f0aba62612932cf86b966db` |
| `blur_distort_vstrips_f` | 0x7f040005 | GLSL ES 1.00 shader | 633 | `ff55eeec304207ce174a570af9b6c31ff74154f69464fc176b73fe7176ebcb3f` |
| `blur_output_f` | 0x7f040006 | GLSL ES 1.00 shader | 333 | `02c807ea4b1097e5d891cbb40f952effd2aef914e40f58a36fc3968236e01cc8` |
| `blur_v` | 0x7f040007 | GLSL ES 1.00 shader | 265 | `c7332bd994a03078c5005bed22d90b6ef7d1b5141823f7eeff5765dbe0c94c3a` |
| `circles_f` | 0x7f040008 | GLSL ES 1.00 shader | 213 | `3799aeeab87b05afcd1265010c7c34d3ee874004efa246d41ea438e1cd7aec2d` |
| `circles_v` | 0x7f040009 | GLSL ES 1.00 shader | 228 | `cb90ebedcee7ecfee66fae4a295d7f012291271b1aa2e04e3c5cfa44a495a3e3` |
| `debugoverlay_f` | 0x7f04000a | GLSL ES 1.00 shader | 151 | `d3ce721c30e02c98eeef8248ccc3e9233000e658dc654c8e89a55e3dc58f2852` |
| `debugoverlay_v` | 0x7f04000b | GLSL ES 1.00 shader | 169 | `a595132f904d98d9a621125c731d2a885146eecafd1945e18793218792307037` |
| `icebox_reflect_f` | 0x7f04000c | GLSL ES 1.00 shader | 469 | `36bbba34acd43c16c8ce2313331275644ab4bf64523eac497699b574dc75a658` |
| `icebox_steps_f` | 0x7f04000d | GLSL ES 1.00 shader | 440 | `11eccc539ba65493967f163d9d08e228c680f5b166d8eb56974d627425ab2c85` |
| `icebox_threshold_f` | 0x7f04000e | GLSL ES 1.00 shader | 453 | `ddd20ce08bd1f5a2374ac3af600054c8ec00123800bcd77d3f75af6145057cff` |
| `muted.png` | 0x7f04000f | texture (PNG) | 2566 | `9a9ea5e2791415de8b4665b1b97e36f8253da0570e67ec47ef1321778f06eb26` |
| `particle.png` | 0x7f040010 | texture (PNG) | 16574 | `76465287db3faecf59502599f861afa8fbd50e602ae6a632c01b608fbf008bb6` |
| `particle2.png` | 0x7f040011 | texture (PNG) | 1910 | `fb206fc00bfb3b6efa00e49cf8545f9d1e0529ca3647753bd7814a22d03230c1` |
| `particle_screensaver_f` | 0x7f040012 | GLSL ES 1.00 shader | 219 | `643e669b7dc5b2a39d637ea4528764d6aeeb9477d66bb35fefeffe44e59c1996` |
| `particle_screensaver_mute_f` | 0x7f040013 | GLSL ES 1.00 shader | 248 | `2472becbf66b8c172401b8ba0b1a7dbb30d93aa3f93269053a4ad121c116a2ed` |
| `particle_screensaver_mute_v` | 0x7f040014 | GLSL ES 1.00 shader | 263 | `6720de2ce47ab4d2f0405037bbfbc3d2b0b64476744fd88f3f94551ebdd7709b` |
| `particle_screensaver_v` | 0x7f040015 | GLSL ES 1.00 shader | 195 | `2ddcc20294dae73519a423c509993a2d5649ef7f3d41cbd36e077ac378e0f090` |
| `pointmorph_f` | 0x7f040016 | GLSL ES 1.00 shader | 213 | `07be495418570f6f7bc97d0b72282e4812ed0a90a8abf5dab6eb50aa6b0257ac` |
| `pointmorph_model_cube` | 0x7f040017–1e (sorted order, inferred) | model (CSV) | 5404 | `c5b325d2b84674ea9d2e50d689644bfe9094f7917c7f0609e1a407874dec28a5` |
| `pointmorph_model_cube_led` | 0x7f040017–1e (sorted order, inferred) | model (CSV) | 38 | `5f066914d10feea6a6dc37313fb5f207be3ee460196cec60f47b849f13a529fa` |
| `pointmorph_model_sphere` | 0x7f040017–1e (sorted order, inferred) | model (CSV) | 7064 | `737a7caaabf80a0f6d8ec1c91d7eafdb33d515d54a5d885bf1165f9c42fb4710` |
| `pointmorph_model_sphere_led` | 0x7f040017–1e (sorted order, inferred) | model (CSV) | 42 | `5901a03744bb9e04af4916dd416372fe6f27534ee6bb2a18d32f99f30e72cf54` |
| `pointmorph_model_spiral` | 0x7f040017–1e (sorted order, inferred) | model (CSV) | 12073 | `4dc24f55c24ce34b5c3d65a9303365115c8490f019611d9a8aafad5d79eaec22` |
| `pointmorph_model_spiral_led` | 0x7f040017–1e (sorted order, inferred) | model (CSV) | 54 | `1bd0ebc7f51b862f2e4acf5168f11fa470d8cb34254124d6642285c813e71270` |
| `pointmorph_model_stackedcircles` | 0x7f040017–1e (sorted order, inferred) | model (CSV) | 6220 | `71324adc9b4bf74a6f50d373e3f093559397e038090a5d8ed8a79b2e8902898c` |
| `pointmorph_model_stackedcircles_led` | 0x7f040017–1e (sorted order, inferred) | model (CSV) | 50 | `3770c52255ceb125f1a5f92cacef044889ecfec83073bf7fbc37cc2c0d82d726` |
| `pointmorph_v` | 0x7f04001f | GLSL ES 1.00 shader | 296 | `0079ebfa467ba58e657df153916a8e72b78ed1e7099e13691e34a60a8f64f9f7` |
| `starfield_f` | 0x7f040020 | GLSL ES 1.00 shader | 248 | `2472becbf66b8c172401b8ba0b1a7dbb30d93aa3f93269053a4ad121c116a2ed` |
| `starfield_v` | 0x7f040021 | GLSL ES 1.00 shader | 294 | `9c2d60c6206fd40c46722f0f17cda4b5316f15fe185057867270b12b8e335363` |
| `stresstest_f` | 0x7f040022 | GLSL ES 1.00 shader | 237 | `ed78bdb00b6ea6610069136cc82d3329698d327c90c5049afba3bf97bb46ad10` |
| `stresstest_v` | 0x7f040023 | GLSL ES 1.00 shader | 171 | `31dd76ceb65d0851b7789b4dba793d855c56319075f7a5d35f4f826b505d9061` |
| `trackinfooverlay_f` | 0x7f040024 | GLSL ES 1.00 shader | 261 | `ead818b8a490383e2b09900696b403ce0588c3e360495b20f30bee043e87b99a` |
| `trackinfooverlay_v` | 0x7f040025 | GLSL ES 1.00 shader | 265 | `c7332bd994a03078c5005bed22d90b6ef7d1b5141823f7eeff5765dbe0c94c3a` |
| `waveform_f` | 0x7f040026 | GLSL ES 1.00 shader | 151 | `e3ed528eca37a5ae37168fe64a634b1c7e85a9bf42e3679c3e4f9f30ebdfd3f5` |
| `waveform_v` | 0x7f040027 | GLSL ES 1.00 shader | 237 | `8bfc8d8a0de4fab68b7b71e1f6447ab18ac90bc0dd1c8c2ab72fac30042081c4` |
| `waveformsolid_f` | 0x7f040028 | GLSL ES 1.00 shader | 151 | `e3ed528eca37a5ae37168fe64a634b1c7e85a9bf42e3679c3e4f9f30ebdfd3f5` |
| `waveformsolid_v` | 0x7f040029 | GLSL ES 1.00 shader | 237 | `8bfc8d8a0de4fab68b7b71e1f6447ab18ac90bc0dd1c8c2ab72fac30042081c4` |

## Appendix B — artefacts in the scratch area (not in the repo)

| Path (under `<session scratch>/gpu/re/`) | What |
|---|---|
| `<session scratch>/gpu/re/tools/odis.py` | Dalvik ICS odex disassembler with quick-op resolution (field offsets via `computeFieldOffsets`, vtables via `createVtable` + miranda, receiver-type tracking, debug-info locals, `fill-array-data` float decoding) |
| `<session scratch>/gpu/re/tools/png_profile.py`, `<session scratch>/gpu/re/tools/png_on_black.py` | PNG decode, radial alpha profile, on-black preview |
| `visualizer/vis.smali.txt`, `visualizer/cls/*.txt` | full annotated disassembly of `com.google.android.tungsten.visualizer.*` (82 classes) |
| `visualizer/apk/` | unzipped APK (shaders, models, textures, layouts) |
| `visualizer/textures/` | `particle.png`, `particle2.png`, `muted.png` + ×4 on-black previews |
| `visualizer/{core,framework,ext}.odex`, `lib*.so`, `build.prop` | stock inputs for vtable resolution and native checks |

## Open questions

1. **Stock HDMI mode and frame rate.** It is unknown whether IAN67K drove 720p or 1080p, and whether the GLSurfaceView
   reached 60 fps or ran lower. The feedback decay is per frame, so trail length depends on this. The 100 px mute icon
   at 1080p is only circumstantial. Best answered by a video of a stock unit, or by reading the stock HWC/DSS HDMI
   defaults (`hwcomposer`/`hdmi` code in the stock kernel or `/vendor/lib/hw`).
2. **Premultiplied texture upload.** Did `GLUtils.texImage2D` upload premultiplied RGBA in ICS? This is LIKELY per
   Android behaviour but was not verified in `libandroid_runtime.so`. It changes the sprite falloff from `a` to `a²`.
3. **SGX540 limits.** `GL_ALIASED_POINT_SIZE_RANGE` and `GL_ALIASED_LINE_WIDTH_RANGE` of the stock DDK are unknown.
   Circles uses up to 192 px points and Waveform a line width of `max(3, beat)`. If the driver clamped them,
   stock visuals differ from the "ideal" GLES2 result.
4. **Stock FFT scaling.** The byte-FFT format and scaling of `Visualizer::doFft`
   (`libmedia.so` @0x4dafd, symbol `_ZN7android10Visualizer5doFftEPhS1_`) were not disassembled. This is needed to
   reproduce the beat detector's `|Re| > 1` threshold exactly.
5. **AudioFlinger buffer size.** The AGC block size equals the AudioFlinger mixer period (frames per `process()`
   call), which was not determined. It affects how often the gain may step.
6. **EGL config.** The GLSurfaceView default chooser (RGB565 vs RGB888, depth 16) affects the screen framebuffer
   precision. On ICS the default was RGB888 with depth 16 — UNVERIFIED.
7. ~~**Execute-inline table.**~~ RESOLVED 2026-10-11: extracted from the stock `/lib/libdvm.so` `gDvmInlineOpsTable`
   (@0xb2780, 22 entries). Indices 9/13/14/15 = `Math.abs(F)`/`sqrt`/`cos`/`sin`, as used.
8. **Performance numbers in §6** are estimates. They need a measurement once the SGX stack runs
   (`kmscube`-class test, then this pipeline).
9. **LED mute dimming.** Confirm on stock or in a photo that the ring really dims to 20 % on mute
   (`RenderEngine.drawFrame` 0x01be–0x01c7). This contradicts the 2026-06-19 note, and `userspace/nexusqd/src/screensaver.c`
   does not implement it.
10. **Scene-start RNG.** All per-scene randomness (themes, morph targets, blur choice, StarField spawns) comes from an
    unseeded `Random`. Only the scene order is deterministic. A "1:1" port can match the distributions, but not
    the stock frame-for-frame output.

## Sources

- Factory image `reverse-eng/factory/tungsten-ian67k/system.raw.img` (IAN67K, `ro.build.fingerprint=google/tungsten/phantasm:4.0.4/IAN67K/403218:user/release-keys`):
  - `/app/Visualizer.apk` (56 849 B) and `/app/Visualizer.odex` (397 024 B; dex @0x28, len 0x55af4);
  - `/framework/core.odex`, `framework.odex`, `ext.odex` (vtable and field-layout resolution);
  - `/lib/libaudioeffect_jni.so`: JNI fn 0x21d9 (`getCaptureSizeRange`), 0x2215 (`getMaxCaptureRate`);
  - `/lib/soundfx/libvisualizer.so`: `Visualizer_process` @0xc74;
  - `/lib/libmedia.so` (`android::Visualizer::*` symbols, not disassembled);
  - `/build.prop` (`ro.opengles.version=131072`, `ro.sf.lcd_density=320`).
- `reverse-eng/vmlinux.bin` + `reverse-eng/tools/kallsyms.txt`: `omap446x_opp_def_list` @0xc0043d5c; gpu OPP entries @0xc0043e94, 0xc0043eac, 0xc0043ec4 (153.6 MHz / 0.962 V, 307.2 MHz / 1.127 V, 384 MHz / 1.25 V).
- `reverse-eng/extracted-assets/data/apk/HubBroker/res/raw/theme_*` (theme JSON).
- Repo context: `docs/2026-06-19-particle-screensaver-RE.md`, `docs/2026-06-19-gpu-sgx540-acceleration-research.md`, `userspace/nexusqd/src/screensaver.c`.
- Android SDK build-tools 36.0.0 `aapt` (resource IDs) and `dexdump` (failed on odex opcodes, see §1).
- SGX540 pipeline count: [GSM Asia — PowerVR SGX540](https://www.gsmasia.net/powervr-sgx540.html); [Design-Reuse — Imagination's POWERVR SGX540 demonstrated in TI OMAP 4](https://www.design-reuse.com/news/202518024-imagination-s-powervr-sgx540-demonstrated-in-texas-instruments-latest-omap-4-platform/) ("double the pipelines of SGX530"); clock discussion: [XDA — "shouldn't OMAP 4460's SGX be clocked at 384 MHz?"](https://xdaforums.com/t/erm-shouldnt-omap-4460s-sgx-be-clocked-at-384-mhz.1368873/page-2). The stock OPP table above supersedes it for this firmware.

## Verification (2026-10-11)

Adversarial re-check by a second reviewer. Inputs were re-extracted from
`reverse-eng/factory/tungsten-ian67k/system.raw.img` with `debugfs` into `<session scratch>/gpu/re/tmp/v07/`.
`Visualizer.apk` has sha256 `017f3fad…0bb919` and `Visualizer.odex` has `9fda0b9f…c02d16`; both are byte-identical
to the copies the report used. The dex method/type tables were parsed independently of `odis.py`, the raw Dalvik
bytes of key calls were matched, and the native code was re-disassembled with `arm-linux-gnueabihf-objdump`.

### Claim-by-claim verdicts

| # | Claim | Verdict | Reproduction evidence |
|---|---|---|---|
| 1 | Pure GLES 2.0, no RenderScript, no GLES1, no native libs | **Confirmed** | `unzip -l`: 53 entries, no `lib/`, no `classes.dex`, no `.bc`. The odex-embedded dex (`dey\n036`, dex @0x28, len 0x55af4) has 46 `Landroid/opengl/GLES20;` method refs and no other GL class with `gl*` methods. The only GL-related types are `GLES20`, `javax.microedition.khronos.egl.EGLConfig` and `…opengles.GL10` (the latter two only appear in the `GLSurfaceView.Renderer` signatures). There is no `renderscript` type and no `System.loadLibrary`. `GLSurfaceView` refs are exactly `onPause, onResume, setDebugFlags, setEGLContextClientVersion, setRenderer` (so `setRenderMode` is never called). `setSurface`: `const/4 v1,#2` → vtable#503. Vtable indices 495…509 fit the alphabetical order of GLSurfaceView's own virtuals (onPause 495, onResume 496, queueEvent 497, requestRender 498, setDebugFlags 499, 3×setEGLConfigChooser 500–502, setEGLContextClientVersion 503, … setRenderer 509). |
| 2 | 31 GLSL files in res/raw 0x7f040000–0x7f040029; loader drops newlines | **Confirmed, with a precision note** | `aapt dump resources` (build-tools 36.0.0) reproduces every ID. The range 0x00–0x29 covers all 42 raw resources: 31 shaders, 8 model files and 3 PNGs. All 31 appendix sources match the files in size and sha256 prefix, and their contents are equal **modulo CRLF**: 30 files are CRLF, so "verbatim" was qualified. `StreamShaderSource.loadSource` is `readLine` + `StringBuilder.append` (0x001b–0x0024). No source uses `//` comments or preprocessor lines, so joining the lines is safe. |
| 3 | Screensaver: 40 GL_POINTS, size 60, particle2.png, colour, blend (SRC_ALPHA, ONE), screen FB | **Confirmed** | Raw dex bytes `13 00 28 00 71 30 7b 00 33 00` (= `const/16 v0,#40; invoke-static {v3,v3,v0} glDrawArrays`, method idx 123) at dex offset 0x2601c. `const/16 v0,#770; invoke-static {v0,v10} glBlendFunc` at 0x25f58 with `v10 = 1`. `0x7f040011` is loaded in `ParticleScreensaver.glInit`. `Color.fromRgba(0, 0.6, 0.8, 1.0)` is set in `<init>`, and `setAlpha(0.6·getScreensaverAlpha())` is at line 150. |
| 4 | Particle state / throb / MVP / frustum | **Confirmed** | `initParticles` 0x0000–0x0039 (`(rnd−0.5)·0.5`, `rnd·6.2831855`, `1.5+0.2·rnd`; `float[120]`). `updateScreensaver` 0x0045–0x0057 (`cos(2π·(t mod 10000)/10000)`). `glRenderScreensaver` 0x0015–0x001f (`translateM(0,0,−13−2·throb)`). `GlUtils.<clinit>`: `0.5·tan(0.392699…)`. `setDefaultPerspectiveProjection`: `frustumM(sYMin·a, sYMax·a, sYMin, sYMax, 0.5, 1000)`. The stock `theta > 0` wrap bug at `updateParticles` 0x002a–0x0030 also checks out. |
| 5 | Screensaver cheap enough for CPU | **Plausible (unmeasured)** | The fragment count (40 × 3600 = 144 k) is exact. The ~2 cycles/px figure for a bilinear sprite blend is optimistic, but even at 10 cycles/px it is ≈ 1.2 ms at 1.2 GHz, so the verdict stands as an estimate. The damage-rect bound was corrected to ≈ 582×582 px. |
| 6 | 960×540 RGBA8 FBO, feedback pass, LINEAR upscale | **Confirmed** | `RenderEngine.glOnTargetSizeChanged` 0x0042–0x0046 (`glCreateTextureTarget(960,540)`) loops over a 3-entry array (`<init>` 0x0014 `const/4 v6,#3`). `glTexImage2D(…, 6408, …, 6408, 5121, null)`, `CLAMP_TO_EDGE` (33071) and `LINEAR` (9729) are set; there is a `DEPTH_COMPONENT16` renderbuffer. `BlurEffect.glRender` and `randomizeBlur` match line by line, including the program order {03, 01, 00, 02, 05, 04}. |
| 7 | All 5 scenes `needsBlurEffect()` = true | **Confirmed** | Every body is `const/4 v0,#1; return v0` (Waveform l.80, WaveformSolid l.83, Circles l.100, PointMorph l.148, StarField l.95). The blur chain runs only while `mChildAlpha > 0` (`BaseScreensaver.glRender` 0x0011). |
| 8 | Random(0) sequence, 10 s scenes, 5 s fade | **Confirmed** | An independent Java-LCG port (with the power-of-two `nextInt(4)` path) gives `Random(0).nextInt() = −1155484576` and the same first 40 entries and counts (101/96/107/96/100). No entry equals its predecessor, including the wrap 499→0. `BaseTransition.<init>`: `mDuration = 5.0`. `FadeTransition.glRender`: start node, `glClear(256)`, end node. |
| 9 | Per-frame decay `(rgb − 0.002)·0.95`; ~62 frames to 0 | **Confirmed as derivation (likely)** | The blend algebra checks out: the 0.95 factor comes from `src.a` through `GL_SRC_ALPHA`, not from the shader rgb. An 8-bit re-simulation gives 40/62 frames (round-to-nearest) and 36/53 frames (truncation) for the ×0.95 shaders, and 22/38 and 20/33 for the ×0.9025 shaders. The exact count therefore depends on the SGX blend rounding, which is unknown. |
| 10 | Visualizer(0), 20 Hz × 1024 | **Confirmed** | JNI table @file 0x4274 = {name 0x331f "getCaptureSizeRange", sig 0x3333 "()[I", fn 0x21d9}. fn body: `NewIntArray(2)` (JNIEnv+716), then `movs r1,#128; str r1,[r0]; add.w r0,r1,#896; str r0,[r2,#4]` (0x21f6–0x2202). @0x4280 "getMaxCaptureRate" → fn 0x2215: `movw r0,#20000; bx lr`. `AudioCapture.<clinit>` divides by 1000 and takes `[1]`. `initVisualizer`: `new Visualizer(0)`, `setDataCaptureListener(this, max, true, true)`. |
| 11 | libvisualizer AGC | **Confirmed** | `Visualizer_process` = dynsym @0xc75 (Thumb), size 298. Loop 0xcb4–0xcd4: `s<0 → ~s`, `clz`, min (init 32). 0xcda–0xce8: `rsb r3,r6,#25; cmp #3; movlt #3; add r9,r3,#1`. 0xd66–0xd7a: `ldrsh L, ldrsh R, add, asr r9, eor 0xffffff80, strb`. Gain range 2^(8−3) = 32×. |
| 12 | Beat detection constants | **Confirmed** | `BeatProcessor.<init>`: `float[120]`, the bpm loop 50 → <180, `period = 60·sps/bpm`, `step = max(2, period/20)`, `var = period/20`. A float32 and a double re-count both give **833** combs. In `onAudioSegment`, the 0.01 gate, `0.7·smoothed` (0x0017), `|Re| > 1 && > prev`, `max(period/30, period/max(0.5, ptm − 8))`, `max(0, 60·comb)` and `0.7·s + 0.3·beat` (0x01d3–0x01ff) all match. |
| 13 | CommonClock timebase → lockstep across a group | **Confirmed at code level** | `Clock.getTime = elapsedRealtime − mLocalClockOffset`. `syncTime`: `offset = elapsedRealtime − CommonClock.getTime()/1000`, and the re-sync message (what = 3) is delayed 30000 ms. That grouped units *actually* ran in lockstep depends on the `common_time` service sharing one timeline. This is UNVERIFIED and was not observed. |
| 14 | Stock SGX540 OPPs = 153.6 MHz @ 0.962 V and 384 MHz @ 1.25 V | **REFUTED / corrected** | The table has **three** gpu OPPs: 153.6 MHz/962000 µV, **307.2 MHz/1127000 µV** and 384 MHz/1250000 µV, all on voltdm `core`, clock `dpll_per_m7x2_ck` and `avail = 1`. The entries are at VA 0xc0043e94/0xc0043eac/0xc0043ec4 (24-byte stride). The cited range 0xc0043e8c–0xc0043ecc starts in the middle of the last `iva` entry. §6 and Sources were fixed. |
| 15 | Fragment budget 2–2.6 M (720p) / 3.3–3.9 M (1080p); software ~20–30 ms, "both cores for ~30 fps" | **Partly wrong (internal inconsistency)** | The TL;DR said 2.6 M at 1080p and 1.6 M at 720p, which contradicts §6.1. A recomputation from §6.1's own per-pass rows (excluding the screen clear) gives ≈ 2.0–3.0 M at 720p and ≈ 3.2–4.1 M at 1080p, with the upper end set by the cross-fade's second scene. Both places were fixed. "20–30 ms/frame" means ≈ 60–90 % of *one* core at 30 fps, not "both cores", and the wording was fixed. All GPU throughput numbers remain UNVERIFIED. |
| 16 | LED ring ×0.2 while muted; missing from nexusqd | **Confirmed** | `RenderEngine.drawFrame` 0x01be–0x01c7: `iget-quick mMuted@88; if-eqz; multiply(0.2f)`. `RenderEngine.setMuted` stores `mMuted` (0x0005), and `OutputActivity` line 214 calls it. `LedConfiguration.multiply` scales `mSolidColor` (SOLID) or `mLedBuffer`. The repo doc says the opposite: `docs/2026-06-19-particle-screensaver-RE.md` l.25 and l.110. In `userspace/nexusqd/src/`, the only global ring scaling is `brightfade` (driven by a control command, `nexusqd.c` l.515/780), and `reaction.c` l.47's `muted ? 0.2 : 0.7` drives the *mute LED*, not the ring. So the ring ×0.2 really is absent. |
| 17 | Minimal GL feature set | **Confirmed** | The only `glEnable` call is `glEnable(3042 = GL_BLEND)` (`RenderEngine.glInit` 0x0067). There are no `glGenBuffers`/`glBindBuffer`/`glDisable`/`glDepthFunc` method refs in the dex. Every `glVertexAttribPointer` call uses the `Buffer` overload, none the `(IIIZII)` offset form. Point sizes: `max(192·s,10)` (Circles 0x0053) and `max(150·s,8)` (PointMorph 0x00f1). Line width: `max(3, smoothedBeat)` (Waveform 0x0008–0x0014). |
| 18 | Textures; mute quad 100 px → 1080p hint | **Confirmed with corrections** | Independent PNG decode: particle2 and particle are 64×64 RGBA8 with a single RGB (255,255,255), and the radial alpha profiles match the table. muted.png is 100×100, but its RGB is near-white greys 219–255 and it is only approximately top/bottom symmetric. Projection check: px/unit = 1080/(2·z·tan 22.5°) = 100.3 (z = 13), 86.9 (z = 15) and **118.5 (z = 11, not 122)**; the table was fixed. The 1080p design-target inference stays an inference. |

### Other corrections made in place

- A stray `</content>` / `</invoke>` tool-markup pair after §7 was removed, and the 31 malformed appendix headings
  (`(0x7f04xxxx` + newline + duplicate ID) were joined into one line each.
- §3.2: the labels "dim"/"bright" for the throb states were wrong for HDMI. The GL colour does not depend on throb;
  only the LED path breathes in brightness.
- §1 / open question 7: the execute-inline mapping is now VERIFIED from the stock `libdvm.so`.

### Notes relevant to the blob-on-musl question (not claims of this report, recorded for the parallel workflow)

- The stock native libraries checked here (`libvisualizer.so`, `libaudioeffect_jni.so`) are **softfp** ARMv7
  objects. `readelf -A` shows `Tag_ABI_HardFP_use: Deprecated` and no `Tag_ABI_VFP_args`, and the header flags are
  `0x5000000` (EABI5, no hard-float flag). This is the normal ICS/bionic ABI. Any stock-firmware ICS GLES/EGL blob is
  therefore expected to be softfp bionic too, which cannot link directly against an armhf musl rootfs. That is
  an expectation, not checked for the GPU blobs in this review. Disassembling them with
  `arm-linux-gnueabihf-objdump` is harmless (the instruction decoding does not depend on the float ABI).
- Nothing in this report involves DDK version numbers or pvrsrvkm ioctls, so no DDK 1.8/1.9/1.17 mix-ups were
  possible here.

### Not re-verified

§2.1 HDMI-unplugged 50 ms LED timer; §3.3 fade timing; the §4 per-scene vertex formulas beyond the point-size and
line-width constants; the §4.2 track overlay; §5.2 hysteresis details; the ICS `GLSurfaceView` default EGL config;
premultiplied `GLUtils.texImage2D` upload (still LIKELY). These are not among the key claims, and they stay as the
report states them.
