# Nexus Q — music-reactive visualizer effects (reverse-engineered from factory ICS)

**Date:** 2026-06-19
**Goal:** Recover the EXACT original audio-reactive LED behavior (the 5 music "scenes")
so `nexusqd` (Plan 3b) can reproduce them pixel-perfect.
**Method:** Same pipeline as the screensaver RE — factory `tungsten-ian67k` image →
deodexed `Visualizer.odex` (baksmali) → jadx. Sources:
`com.google.android.tungsten.visualizer.{nodes,audio.capture,led,utils,renderer}`.

> ## TL;DR
> The ring (32 LEDs) is driven ONLY by each node's `ledRenderScene` → `LedConfiguration`
> (SOLID or per-LED buffer) → `LedController.toByte = round(255*f)` (linear, no gamma).
> The GL/HDMI render (shaders, particles, point sprites, MVP) is screen-only and ignored.
> All effects color the ring from a `ColorTheme` — the default is `RainbowTheme(0.9, 1.0)`
> (`setHsv(360*pos, 0.9, 1.0)`), with theme rotation driven by `getSmoothedBeatValue()`.
> `RenderEngine` holds 5 scenes (indices): Waveform[0], WaveformSolid[1], Circles[2],
> PointMorph[3], StarField[4]; `ParticleScreensaver` is the no-audio idle (Plan 3, separate doc).

## Audio contract (audio/capture/*)

- `SAMPLES_PER_SEGMENT = Visualizer.getCaptureSizeRange()[1] = 1024` (ICS).
- `SEGMENTS_PER_SECOND = Visualizer.getMaxCaptureRate()/1000 = 20` (ICS).
- **getVolume** = `mean(|waveform|)`, waveform normalized to [-1,1]
  (`(b&255-128)/128` for the original 8-bit; we use `sample/32768` for 16-bit PCM).
- **getAudioBuffer** = rolling `float[SAMPLES_PER_SEGMENT*5]`; **getLastSegmentIndex** = newest
  segment's start offset. Used by StarField (per-particle theta) and the GL renders.
- **BeatProcessor** (Comb-filter tempo tracker): per segment, `energy` = count of FFT real
  bins whose `|real|` rose vs the previous segment AND `> 1`; a bank of ~1300 comb filters
  spanning BPM 50–179 (offset combs per BPM) score the recent `energy` train; the
  highest-scoring comb is tracked with hysteresis; `getSmoothedBeatValue()` =
  `0.7·prev + 0.3·(60·combScore)`, decaying `·0.7` on silence; `isNewBeat()` fires when the
  selected comb's nearest-peak offset crosses zero. **Ported line-by-line** (`Comb`, `BeatProcessor`).

**FIDELITY CAVEAT (FFT):** the original FFT came from `android.media.audiofx.Visualizer` (a
fixed-point AudioFlinger engine) — **not bit-reproducible**. `audiocap.c` computes a real
radix-2 FFT of each PCM segment and packs the real parts to signed 8-bit in the exact layout
BeatProcessor consumes (`fft[2*li]` = real part of bin `li`). The byte scale
(`AUDIOCAP_FFT_SCALE = 127/512`) approximates the unrecoverable android scaling; BeatProcessor
is scale-robust (it counts which bins *rise*, and comb scores are relative), so tempo tracking
is faithful even though the FFT bytes are not bit-identical. The effects never read the FFT
directly — only BeatProcessor does.

**RNG:** effects make per-start choices via `java.util.Random` (`nextFloat/nextBoolean/nextInt`,
StarField `nextGaussian`). The original seeded from the clock (never reproducible run-to-run);
`jrandom.c` is a bit-faithful port of the algorithm — same distributions, caller-seeded
(deterministic in tests).

## Color (utils/Color, RainbowTheme, PaletteTheme)

`Color.setHsv` → `android.graphics.Color.HSVToColor` (Skia `SkHSVToColor`, rounds to 0..255
bytes) → `/255` floats. `themecolor.c` reproduces `SkHSVToColor` exactly (`round`, the p/q/t
sextant formula). `RainbowTheme.themeColor(pos)` = `HSV(360·pos, 0.9, 1.0)`. `PaletteTheme`
(custom JSON themes) interpolates hue in polar form — ported in `rtheme_init_palette` (default
is Rainbow; palette is wired when a theme JSON is loaded). `putRgbInBuffer(buf,i,scaleByAlpha)`
= `buf[i+k] = rgb[k]·alpha` (the node fade alpha).

## Per-effect LED algorithm (each = the exact `ledRenderScene`)

- **Waveform** (`fx_waveform`): if `multiColored`, a rotating theme gradient laid around the
  ring in the original's arc order (top arc fwd from `(RING*3/4)*3`, bottom arc fwd to
  `(RING/4)*3`, middle arc backward), step `ledThemeDelta=(1024·7e-4)/RING`; else a SOLID
  theme color at `themePosition`. `themePosition` drifts at `smoothedBeat·0.05·dt`. (The audio
  waveform itself is GL-only; the ring is theme-color + beat rotation.)
- **WaveformSolid** (`fx_waveformsolid`): not-multi → top+bottom arcs = color@pos, middle arc =
  color@(0.5+pos) (complementary); multi → full rotating gradient (`ledThemeDelta=1/RING`).
- **Circles** (`fx_circles`): one rotating theme color; per-LED alpha =
  `scale·gaussian(((i+shift/30) mod 8) − 3)`, `gaussian(o)=exp(-o²/3.2)/√10.0531` normalized to
  peak 1 — a bright band every 8 LEDs, moving with `shift += ±(30·dt + smoothedBeat)`; beat may
  flip direction (`isBeatThisFrame && nextInt(8)==0`).
- **PointMorph** (`fx_pointmorph`): gaussian blobs (`gaussian(o)=exp(-o²)/√π`, peak-normalized,
  width ±1 LED) summed (clamped to 1) at each of 8 LED-model points × RING, for 4 morphing
  shapes (cube/sphere/spiral/stackedcircles, embedded from `pointmorph_model_*_led`), smooth
  morph `(1-cos(linear))/2`; whole buffer then ×nodeAlpha. Single theme color. NOTE: the
  original's `multiColored` branch uses integer `i/modelLedPoints` (=0 for i<8) → it's a **no-op
  on the ring**; replicated faithfully.
- **StarField** (`fx_starfield`): 100 particles, the ring samples every 16th (7 particles);
  each is a gaussian blob (`gaussian(o)=exp(-o²/1.5)/√4.7124`, peak-normalized, width ±2 LEDs)
  at `theta·RING/360`, summed+clamped, ×nodeAlpha; theme color with **value×0.6**
  (`setValue(value*0.6)`); `rainbow` → per-particle hue `themePos+themeOffset`. Particle `theta`
  advances by `audioBuffer[...]·15` (audio-driven), `z` recedes by a volume·beat delta and
  respawns (gaussian x/y, used only by GL).

## Files (all NEW, under `userspace/nexusqd/`)

- `include/jrandom.h`, `src/jrandom.c` — java.util.Random port (+ test_jrandom.c)
- `include/themecolor.h`, `src/themecolor.c` — SkHSVToColor + Rainbow/PaletteTheme (+ test_themecolor.c)
- `include/ledcfg.h`, `src/ledcfg.c` — LedConfiguration mirror + toByte
- `include/audiocap.h`, `src/audiocap.c` — waveform/volume/FFT/BeatProcessor/Comb (+ test_audiocap.c)
- `include/fx_waveform.h`, `src/fx_waveform.c` (+ test_fx_waveform.c)
- `include/fx_waveformsolid.h`, `src/fx_waveformsolid.c` (+ test_fx_waveformsolid.c)
- `include/fx_circles.h`, `src/fx_circles.c` (+ test_fx_circles.c)
- `include/fx_pointmorph.h`, `src/fx_pointmorph.c` (+ test_fx_pointmorph.c)
- `include/fx_starfield.h`, `src/fx_starfield.c` (+ test_fx_starfield.c)

Each effect module API: `fx_X_init(&fx, &rtheme, &jrandom)` (runs `onStarted` + `ledOnCountChanged`),
`fx_X_update(&fx, &audio_state, dt)`, `fx_X_render(&fx, alpha, &frame)`. All host-tested, 0 warnings.

## Not ported (out of scope here)
- Scene cycling / `FadeTransition` between effects (`RenderEngine`), the `BlurEffect`
  (HDMI-only blur framebuffer), and `TrackInfoOverlayEffect` (track metadata overlay).
- GL/HDMI rendering of every effect (screen-only).
