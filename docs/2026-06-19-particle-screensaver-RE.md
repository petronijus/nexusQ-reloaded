# Nexus Q — idle ParticleScreensaver LED behavior (reverse-engineered from factory ICS)

**Date:** 2026-06-19
**Goal:** Recover the EXACT original idle LED ring animation (the "screensaver" shown when
nothing is playing) so `nexusqd` can reproduce it pixel-perfect.
**Method:** Pulled the factory image (`tungsten-ian67k-factory-d766e5f1.zip`, Android 4.0.4
IAN67K), converted `system.img` (sparse→raw ext4), extracted `/app/Visualizer.odex` +
`/framework/*.odex` via `debugfs`, deodexed with baksmali 2.5.2, assembled the smali back to a
dex and decompiled with jadx. Sources: `com.google.android.tungsten.visualizer.*`.

> ## TL;DR
> The idle ring is **NOT the particle field** — the 40 particles are drawn only to the HDMI/GL
> screen. On the **LED ring** the screensaver renders a **uniform solid color that breathes**:
> - color = `mColor` = `fromRgba(0.0, 0.6, 0.8)` = **#0099CC** (same base as volume).
> - brightness `A = screensaverAlpha × ledAlpha`.
> - `ledAlpha = lock ? 0.1 : 0.1 + 0.35·(1 − throb)`, `throb = cos(2π·(t_ms mod 10000)/10000)`
>   → a **10-second cosine breath**, alpha sweeping **0.1 ↔ 0.8**.
> - `screensaverAlpha`: 0 for the first ~5 s, then fades 0→1 over 5 s (BaseScreensaver).
> - per-channel output = `round(255 · channel · A)` — **linear, no gamma** (`LedController.toByte`).
> - so the ring breathes **#000F14 (dim, A=0.1) ↔ #007AA3 (peak, A=0.8)**. The dim point equals
>   `mDefaultColor`/the volume-0 color (#000F14) — everything is `#0099CC × scalar`.
> - after **300 s without audio** → `ledAlpha` locks at 0.1 (steady dim).
> - after **600 s** since last activity (`aah:blank_screensaver_timeout_s`, default 600) → ring
>   goes **black** and the status (mute) LED is cleared.
> - the ring breathes the same whether muted or not — mute only affects the dedicated mute LED
>   (driven by SystemStatusReceiver, see `2026-06-19-volume-mute-RE.md`), never the ring here.

---

## 1. Classes

- `nodes/ParticleScreensaver` extends `renderer/BaseScreensaver` extends `BaseEffect`.
- `led/LedConfiguration` — a per-frame ring description (SOLID color or per-LED buffer).
- `led/LedController` — pushes a `LedConfiguration` to the `ILedService` (priority **5**).
- `utils/Color` — RGBA 0..1 float color; no gamma.

## 2. ParticleScreensaver — the LED path (the only path that touches the ring)

`mColor = Color.fromRgba(0.0f, 0.6f, 0.8f, 1.0f)`  → RGB (0, 0.6, 0.8) stored verbatim
(`Color.putRgbInBuffer(..., scaleByAlpha=false)` copies the channels; `fromRgba` does not gamma-correct).

`ledRenderScreensaver(LedConfiguration target)` (decompiled):
```java
mColor.putRgbInBuffer(target.configureSolidColor(), 0, false);   // SOLID = (0, 0.6, 0.8)
float ledAlpha = mLockLedAlpha ? 0.1f : 0.1f + 0.35f * (1.0f - mSmoothThrob);
if (mDisableLeds) { ledAlpha = 0.0f; target.setStatusLed(true); target.setStatusLedColor(0,0,0); }
else            { target.setStatusLed(false); }
target.multiply(getScreensaverAlpha() * ledAlpha);              // scales the solid color
```

`updateScreensaver(timestamp, elapsedSecs)` (sets the throb + flags):
```java
if (mLastTimestamp/10000 != timestamp/10000)
    if (mLockLedAlpha != (getElapsedSecondsWithoutAudio() > 300.0f)) { mLockLedAlpha = !mLockLedAlpha; updateBlankScreensaverTimeout(); }
mDisableLeds = (mBlankScreenSaverTimeoutS != -1) && (getSecondsSinceLastActivity() > mBlankScreenSaverTimeoutS);
float throbOffset = (timestamp % 10000) / 10000.0f;            // timestamp is ms
mSmoothThrob = (float) Math.cos(6.2831855f * throbOffset);     // cos(2π·offset), 10 s period, [-1,1]
```

`getSecondsSinceLastActivity()` = `min(getElapsedSecondsWithoutAudio(), (now - mLastVolumeChange)/1000)`
(or just `elapsedSecondsWithoutAudio` if there was never a volume change). `mLastVolumeChange` is
reset on every volume change AND on mute change (`updateLastVolumeChange()`).

`mBlankScreenSaverTimeoutS` = Gservices `aah:blank_screensaver_timeout_s`, **default 600**, `-1`=never.

## 3. BaseScreensaver — the fade-in / alpha (no audio path)

Constants: `mSceneFadeSeconds=1`, `mScreensaverFadeInSeconds=5`, `mSecondsBeforeSceneFadeOut=2`,
`mSecondsBeforeScreensaverFadeIn=5`. At `glInit`: `mElapsedSecondsWithoutAudio = 5`, `mChildAlpha = 0`.

`updateEffect(timestamp, elapsedSecs)` when no audio (`AudioCapture.getVolume() < 0.01`):
- `mElapsedSecondsWithoutAudio += elapsedSecs`
- if a child (music) scene is still fading: fade it out; **else if** `mScreensaverAlpha < 1` and
  `mElapsedSecondsWithoutAudio > 5`: `mScreensaverAlpha += elapsedSecs/5` (clamp ≤ 1).
- when audio returns (`volume ≥ 0.01`): `mElapsedSecondsWithoutAudio = 0`, child fades in,
  `mScreensaverAlpha` fades out (the music scene takes over).

`getScreensaverAlpha() = mAlpha · mScreensaverAlpha` (`mAlpha`=1 when the screensaver owns the ring).

**No-audio steady state (our daemon):** `screensaverAlpha` analytically = `clamp((now − t0)/5, 0, 1)`
(0 for the first 5 s after the screensaver starts, then a 5 s linear ramp to 1).

## 4. LedConfiguration / LedController — solid → 32 LEDs

`configureSolidColor()` sets `FillType.SOLID` and returns `mSolidColor[3]`; `multiply(v)` scales it
(`v==0` → solid black). `LedController.applyConfiguration`:
```java
if (SOLID) mService.setAllLeds(binder, toByte(c[0]), toByte(c[1]), toByte(c[2]));   // uniform ring
private int toByte(float v) { return Math.round(255.0f * v); }                       // LINEAR, no gamma
```
Status (mute) LED index **1000**: only written when the screensaver enables it (i.e. only on
`mDisableLeds`, set to 0,0,0); otherwise it is cleared (`setLed(1000,-1,-1,-1)`) and the client
drops to priority 5. The Visualizer registers as `enable("Visualizer", 5)`.

## 5. Exact port for nexusqd (priority-5 idle layer)

```
mColor      = (R=0.0, G=0.6, B=0.8)                       # ×255 = (0,153,204) = #0099CC
throb(t)    = cos(2π · fmod(t_seconds, 10) / 10)          # 10 s breath, [-1,1]
ledAlpha    = lock ? 0.1 : 0.1 + 0.35·(1 − throb)         # [0.1, 0.8]
saAlpha     = clamp((t − t0)/5, 0, 1)                     # 5 s fade-in (after a 0 s..? see below)
A           = saAlpha · ledAlpha   (0 if blanked)
ring[i]     = ( 0, round(153·A), round(204·A) )  for all 32 LEDs
lock        = elapsedSecondsWithoutAudio > 300
blank       = (blankTimeout != -1) && secondsSinceLastActivity > blankTimeout(=600)
```
- `elapsedSecondsWithoutAudio = (now − lastAudioReset) + 5` (starts at 5; only audio resets it).
- `secondsSinceLastActivity = min(elapsedSecondsWithoutAudio, now − lastVolumeChange)`.
- breathes **#000F14 ↔ #007AA3**; reaches #0099CC only transiently never (peak A=0.8 → #007AA3).
- mute does NOT change the ring (only the dedicated mute LED, Plan 2b).
- the particle field, MVP throb (`-13 - throb·2`), point sprites, and the muted.png overlay are
  **HDMI/GL only** — irrelevant to the 32-LED ring; not ported.

## 6. Music-reactive effects (NOT in this port)

The waveform / pointmorph / icebox / starfield / circles nodes drive the ring from `AudioCapture`
(FFT) when audio is playing. They require a working audio tap and are deferred to **Plan 3b** (gated
on the audio path, PLAN §1). This document + port cover only the **idle screensaver** (no audio).
