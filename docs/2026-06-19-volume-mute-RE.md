# Nexus Q — Volume / Mute / Idle LED behavior (reverse-engineered from factory ICS)

**Date:** 2026-06-19
**Goal:** Recover the EXACT original Nexus Q LED behavior for the volume ring, the mute
indicator, and idle so `nexusqd` can reproduce it pixel-perfect.
**Method:** Deodexed the factory ICS Dalvik ODEX with baksmali 2.5.2 (API 15) and read the
smali. Source artifacts under `C:\Users\petro\AppData\Local\Temp\tungsten\deodex\`,
deodexed output under `…\deodex\out\`.

> ## TL;DR (headline numbers)
> - **Volume color (`mColor`)** = `Color.argb(0xFF,0x00,0x99,0xCC)` = **`#0099CC`** (Holo Blue Dark).
> - **Volume → LEDs:** the WHOLE ring (all N LEDs, no arc, no count mapping) is set to one
>   uniform color = `mColor × brightness`, where
>   `brightness = 0.1 + (volume/100) × 0.9` (linear, volume is 0..100, a master-volume
>   percentage — NOT current/max steps).
>   - vol 0 → `#000F14`, vol 25 → `#003142`, vol 50 → `#005470`, vol 75 → `#00769E`, vol 100 → `#0099CC`.
> - **Mute LED** (dedicated status LED, index 1000): muted = `mColor × 0.2` = **`#001E28`**;
>   unmuted = `mColor × 0.7` = **`#006B8E`**. While muted the ring is dimmed to
>   `mDefaultColor` (see below).
> - **Idle / default ring color (`mDefaultColor`)** = `mColor × 0.1` per channel = **`#000F14`**
>   (a very dark blue). **The `0x00385c` hypothesis is DISPROVEN** — that constant does not
>   appear anywhere in the LED code.
> - **Volume overlay duration:** 1000 ms after the last volume change, then the ring is set to
>   **black (0,0,0)** and the overlay client drops its priority to 0 (handing the ring back to
>   whatever lower-priority client — visualizer/screensaver — is running).
> - **Commit mode:** immediate `setLed`/`setAllLeds`, each followed by a native
>   `commitLedValues()` flush. The only "interpolation" is the explicit volume change-in
>   animation (21 frames @ 16 ms, decelerate) generated in software.

---

## 0. Architecture — where the logic actually lives

**`android.view.VolumePanel` is STOCK AOSP here — it has NO `setVolumeLeds` and NO LED code at
all.** (Confirmed: deodexed `framework.odex` →
`out/framework_smali/android/view/VolumePanel.smali`; grep for `Led`/`LED` yields nothing but an
unrelated ToneGenerator string. The method list is the plain ICS VolumePanel.)

The real volume/mute LED driver is a **separate broadcast receiver in the LED service**:

```
com.google.tungsten.ledservice.SystemStatusReceiver   (TungstenLEDService.apk)
```

It listens for system broadcasts and drives the ring/mute LED through the AIDL `ILedService`:

- `android.media.MASTER_VOLUME_CHANGED_ACTION` → `masterVolumeChanged(volume)`
- `android.media.MASTER_MUTE_CHANGED_ACTION`   → `masterMuteChanged(muted)`
- `com.android.athome.broker.SETUP_COMPLETE`   → arms the receiver (`mSetupComplete`)

Volume/mute broadcasts are ignored until `SETUP_COMPLETE` with `state == 3` is seen.
(Evidence: `SystemStatusReceiver.smali:onReceive` lines 898–1015; volume guarded by
`mSetupComplete` at smali:923.)

File: `out/TungstenLEDService_smali/com/google/tungsten/ledservice/SystemStatusReceiver.smali`.

### Two LED clients exist (priority-arbitrated by the service)

| Client | Priority | Path |
|---|---|---|
| `SystemStatusReceiver` (volume/mute overlay) | **100** while active, **0** after timeout | `setAnimation` + `setAllLeds`/`setLed` |
| Visualizer (`OutputActivity`/`LedController`) — music feedback & idle screensaver | **5** | `setAllLeds` / `setLedRange` per-LED |

Higher priority wins the ring. So the volume overlay momentarily preempts the visualizer, then
relinquishes (drops to priority 0) so the visualizer reclaims it.

---

## 1. VOLUME RING — full recovery

### 1a. The constants (`SystemStatusReceiver.<init>`, smali:108–166)

```smali
# mColor = Color.argb(0xff, 0x00, 0x99, 0xcc)        -> #0099CC, alpha FF
const/16 v5, 0xff   # a
const/16 v6, 0x99   # g     (note arg order: argb(a, r, g, b) with r=v8=0x00)
const/16 v7, 0xcc   # b
invoke-static {v5, v8, v6, v7}, Landroid/graphics/Color;->argb(IIII)I   # v8(=0x00)=red
iput v5, … ->mColor:I

# defaultScalar = 0.1   (0x3fb999999999999aL)
# mDefaultColor = Color.rgb(red*0.1, green*0.1, blue*0.1)  -> #000F14
```

- `mColor`        = `#0099CC` (the canonical "active"/volume color).
- `mDefaultColor` = `#000F14` (r=0, g=15, b=20 — `mColor` each channel × 0.1).

### 1b. `masterVolumeChanged(int volume)` (smali:593–653)

The `volume` extra is `android.media.EXTRA_MASTER_VOLUME_VALUE`, a **0..100 percentage**
(master volume), read at `onReceive` smali:928.

```
setPriority(client, 100)            # take the ring
setVolumeLeds(volume)               # the animated bar (below)
setLed(client, 1000, 0,0,0)         # 1000 = mute/status LED -> OFF during volume change
removeCallbacks(mVolumeTimeoutTask)
postDelayed(mVolumeTimeoutTask, 1000)   # 0x3e8 = 1000 ms overlay timeout
```

### 1c. `setVolumeLeds(int volume)` — the change-in animation (smali:761–894)

State machine on `mAnimationStart` (an `elapsedRealtime` timestamp; sentinels `-1`=idle,
`-2`=static-set-in-progress):

- **First change** (`mAnimationStart == -1`): start an animation.
  ```
  mAnimationStart   = SystemClock.elapsedRealtime()
  mGlobalBrightness = service.getGlobalBrightness()        # save current global brightness
  setAllLeds(client, 0,0,0)                                # clear ring (1001/all -> black)
  setGlobalBrightness(100)                                 # 0x64 = full global brightness
  anim = generateVolumeAnimation(ledCount, volume)
  setAnimation(client, anim, loop=false)
  ```
  Then schedules a Handler message `what=0x6f(111), arg1=volume` at
  `mAnimationStart + 350 ms` (`0x15e`). At that time the handler calls `setLeds(volume)` to
  paint the **static** final bar (smali:855–869, handler in `SystemStatusReceiver$2.smali`).
- **Subsequent change while a bar is already shown** (`mAnimationStart > 0`): skip the
  animation, immediately post `what=111` (→ `setLeds(volume)`) with no delay (smali:876–887).

### 1d. `generateVolumeAnimation(int ledCount, int volume)` (smali:335–485)

Builds a software fade-in for EVERY LED simultaneously (uniform ring, not an arc):

```
totalFrames = 0x15 = 21
animation   = new LedAnimation(21 * ledCount)         # capacity
endBrightness = FloatEvaluator.evaluate(volume/100.0, 0.1f, 1.0f)   # linear: 0.1 + f*0.9
frameTimeMs = 0
for frameIndex in 0..20:
    t          = DecelerateInterpolator.getInterpolation(frameIndex / 21.0)
    brightness = FloatEvaluator.evaluate(t, 0 /*from*/, endBrightness /*to*/)  # 0 -> end, eased
    LED = new LedAnimation.LED(
              1001 /*0x3e9 = ALL LEDS*/,
              red(mColor)*brightness, green(mColor)*brightness, blue(mColor)*brightness,
              frameTimeMs)              # 5th arg = start time (ms) of this frame
    animation.addLed(LED)
    frameTimeMs += 0x10               # 16 ms per frame  -> 21*16 = 336 ms total
```

So the animation ramps the **whole ring** from black up to `mColor × endBrightness` over
~336 ms with a decelerate ease, targeting LED id **1001 = ALL LEDs**.
`LedAnimation.LED(id, r, g, b, startMs)` — param order confirmed from
`LedAnimation$LED.smali:30–59`.

### 1e. `setLeds(int volume)` — the static held bar (smali:655–759)

```
mAnimationStart = -2
brightness = FloatEvaluator.evaluate(volume/100.0, 0.1f, 1.0f)   # 0.1 + (volume/100)*0.9
cancelAnimation(client)
setLed(client, 1001 /*ALL*/, red(mColor)*brightness, green*…, blue*…)
```

This is the steady state the ring sits at after the animation finishes and until the 1000 ms
timeout. The bar is a **uniform full-ring color**, brightness encodes the volume:

| volume | brightness | ring color |
|---|---|---|
| 0   | 0.100 | `#000F14` |
| 1   | 0.109 | `#001016` |
| 25  | 0.325 | `#003142` |
| 50  | 0.550 | `#005470` |
| 75  | 0.775 | `#00769E` |
| 100 | 1.000 | `#0099CC` |

> **Key insight for the daemon:** there is NO "number of LEDs lit", NO arc, NO starting index
> or direction, NO per-LED gradient. Volume is encoded purely as **uniform ring brightness**
> of the single color `#0099CC`. (`FloatEvaluator` is a plain linear lerp; the only nonlinearity
> is the decelerate ease *during the fade-in*, not in the final value.)

### 1f. `mVolumeTimeoutTask` (1000 ms later) — overlay teardown (`SystemStatusReceiver$1.smali`)

```
mAnimationStart = -1                      # back to idle
setGlobalBrightness(mGlobalBrightness)    # restore the saved global brightness
setLed(client, 1001 /*ALL*/, 0,0,0)       # ring -> BLACK
setPriority(client, 0)                     # relinquish the ring (visualizer @5 reclaims it)
masterMuteChanged(mMuted)                  # re-apply mute LED state
```

The volume overlay does **not** persist the bar — it blanks the ring and yields. Anything that
should be on the ring at idle comes from the lower-priority client (visualizer/screensaver),
not from this code.

---

## 2. MUTE — full recovery

### `masterMuteChanged(boolean muted)` (smali:487–591)

```
alpha = muted ? 0.2f : 0.7f
# 1000 = 0x3e8 = the DEDICATED mute/status LED -> native LEDController.setMuteLed(r,g,b)
setLed(client, 1000, red(mColor)*alpha, green(mColor)*alpha, blue(mColor)*alpha)
# 1001 = ALL ring LEDs -> mDefaultColor (the dim idle blue)
setLed(client, 1001, red(mDefaultColor), green(mDefaultColor), blue(mDefaultColor))
```

| state | mute LED (idx 1000) | ring (idx 1001 / all) |
|---|---|---|
| **muted**   | `mColor × 0.2` = **`#001E28`** | `mDefaultColor` = `#000F14` |
| **unmuted** | `mColor × 0.7` = **`#006B8E`** | `mDefaultColor` = `#000F14` |

So the ring is **NOT blanked** on mute — it drops to the dim `mDefaultColor` (`#000F14`), and
the dedicated mute LED carries the mute indication (dim blue `#001E28` when muted, brighter
blue `#006B8E` when unmuted). The mute LED is always lit some blue; muted = dimmer.

`masterMuteChanged` is also called: once at construction (smali:201, from
`AudioManager.isMasterMute()`), on every `MASTER_MUTE_CHANGED_ACTION`, on `SETUP_COMPLETE`,
and at the end of the volume-overlay timeout (so the mute LED is restored after a volume bar).

### Mute LED at the service/HAL level

Index 1000 is special-cased in `LEDService$Client`:
`setLed(client,1000,r,g,b)` → `setStatusLed(r,g,b, sticky=true)` (if r≥0) →
native **`LEDController.setMuteLed(r,g,b)`** (LEDController.smali:106;
`LEDService$Client.smali:497`). `r<0` → `clearStatusLed()` (LEDService$Client.smali:1057).
The Visualizer also drives this LED: enabled → `setLed(1000, r,g,b)`; disabled →
`setLed(1000, -1,-1,-1)` (clear) then `setPriority(5)` (`LedController.smali:251–376`).

---

## 3. IDLE / DEFAULT — recovered (with a caveat)

There are two distinct "idle" notions:

1. **The LED-service overlay's own default** (`mDefaultColor` = **`#000F14`**, `mColor × 0.1`):
   this is what `SystemStatusReceiver` paints on the ring while **muted** and is the dim base
   the volume bar fades up from. **The `0x00385c` subdued-blue fallback is NOT present anywhere
   in the deodexed LED code** — grep for `385c`/`0x00385c`/`3675740` across all of
   `out/` returns nothing. The recovered subdued-blue is `#000F14`, not `#00385C`.

2. **What the ring shows when nothing is playing and no volume overlay is up:** after the
   overlay times out it sets the ring to **black** and drops to priority 0, so the visible idle
   ring is owned by the **Visualizer** (priority 5), which runs a `ParticleScreensaver`
   (`out/Visualizer_smali/.../nodes/ParticleScreensaver.smali`) and renders the ring on a timer
   (`OutputActivity$LedRenderer`). The screensaver computes per-frame colors from a GL
   `Color`/particle simulation (`mColor`, `mParticles`), with a configurable blank-screensaver
   timeout (`mBlankScreenSaverTimeoutS`) after which it goes dark. It is a dynamic, audio/random
   driven animation, **not a single static idle color or a simple "breathing" constant**. There
   is no fixed idle ring color emitted by the system LED code itself — at true idle the ring is
   either the screensaver animation or black.

   The visualizer paints the ring via either `setAllLeds(r,g,b)` (FillType.SOLID,
   `configureSolidColor`/`configureSolidBlack`) or `setLedRange(0, ledCount, int[])` for the
   per-LED particle buffer (`LedController.applyConfiguration`, smali:171–381).

**Conclusion for the daemon:** if `nexusqd` only needs to reproduce the *system* volume/mute
behavior (not the music visualizer), the correct idle/default ring color is **`#000F14`**
(`mColor × 0.1`), the mute LED idle is **`#006B8E`** (unmuted) / **`#001E28`** (muted), and the
ring is otherwise black between overlays. No breathing/pulse exists in the LED-service code; the
only animated idle is the Visualizer screensaver app.

---

## 4. LedController / ILedService API surface (to mirror in the daemon)

### AIDL — `com.google.tungsten.ledcommon.ILedService`
(`out/TungstenLEDService_smali/com/google/tungsten/ledcommon/ILedService.smali`)
Every per-client call takes the client `IBinder` first:

| Method | Meaning |
|---|---|
| `enable(IBinder client, String name, int priority)` | register a client at a priority |
| `disable(IBinder client)` | unregister |
| `setPriority(IBinder client, int priority)` | change arbitration priority (overlay=100, vis=5, released=0) |
| `getLedCount() → int` | number of physical ring LEDs (from native `nativeInit`, HAL-defined) |
| `getGlobalBrightness() → int` / `setGlobalBrightness(int)` | 0..100 master scale (overlay sets 100, restores prior) |
| `setLed(IBinder client, int led, int r, int g, int b)` | one LED (or magic index, see below) |
| `setAllLeds(IBinder client, int r, int g, int b)` | fill the whole ring with one RGB |
| `setLedRange(IBinder client, int start, int count, int[] colors)` | per-LED RGB buffer (interleaved r,g,b) |
| `setAnimation(IBinder client, LedAnimation anim, boolean loop)` | play a software animation |
| `setBuiltinAnimation(IBinder client, int preset)` | a HAL/preset animation |
| `cancelAnimation(IBinder client)` | stop animation |

There is **no** `setMute`/`setRange`/`commit` in the AIDL; mute is `setLed(...,1000,...)`,
range is `setLedRange`, and commit is implicit (native flush).

### Magic LED indices (decoded in `LEDService$Client.smali`)
- **`1000` (0x3e8) = dedicated mute/status LED** → native `LEDController.setMuteLed(r,g,b)`.
  `r < 0` clears it.
- **`1001` (0x3e9) = ALL ring LEDs** → native `LEDController.setAllLeds(r,g,b)`.
- **`0 … getLedCount()-1` = individual physical ring LED i** → writes
  `mLedBuffer[i*3 + {0,1,2}] = r,g,b` then flushes.

### Native HAL — `com.google.tungsten.ledservice.LEDController` (JNI `led_service_jni`)
(`out/TungstenLEDService_smali/com/google/tungsten/ledservice/LEDController.smali`)

| Native method | Notes |
|---|---|
| `nativeInit() → boolean` | opens `/dev/leds`, sets `mLedCount` (ring size) |
| `getLedCount() → int` | returns `mLedCount` |
| `setLed(int idx, int r, int g, int b)` | single LED into the kernel buffer |
| `setAllLeds(int r, int g, int b)` | whole ring |
| `setMuteLed(int r, int g, int b)` | the dedicated mute/status LED |
| `setRange(int start, int count, int[] colors)` | per-LED range |
| `commitLedValues()` | **flush buffered values to hardware** (the "commit") |
| `setBrightness(int)` (default 0x64=100) / `setDisplayMode(int)` / `getDisplayMode()` | global brightness + display mode |

**Commit model:** writes are buffered then flushed via `commitLedValues()` inside the service's
`drawLedBuffer()` (`LEDService$Client.smali:521–557`). Each `setLed/setAllLeds/setLedRange`
sets a dirty "mode" and triggers a redraw → commit. There is **no hardware-side interpolation**
between commits — colors change instantly on commit; the only smoothing is the explicit 21-frame
software animation generated for the volume change-in.

### `LedAnimation` data model
(`LedAnimation.smali`, `LedAnimation$LED.smali`)
- `LedAnimation(int capacity)` (dynamic) or `LedAnimation(int[] program)` (static).
- `addLed(LED)` appends; flat program is **5 ints per entry**:
  `[id, r, g, b, startMs]`. `getLength()` = number of entries.
- `LED(int id, int r, int g, int b, int startMs)` — id may be a real LED, `1000`, or `1001`;
  `startMs` is the absolute frame start time within the animation.

---

## 5. Exact values cheat-sheet for `nexusqd`

| Thing | Value |
|---|---|
| Base/active color `mColor` | `#0099CC` (`Color.argb(0xFF,0x00,0x99,0xCC)`) |
| Idle/default ring `mDefaultColor` | `#000F14` (`mColor × 0.1`/chan) |
| Volume ring (all LEDs) | uniform `mColor × (0.1 + volume/100 × 0.9)`, volume∈[0,100] |
| Volume change-in animation | 21 frames, 16 ms/frame (~336 ms), DecelerateInterpolator, target id 1001, 0 → endBrightness |
| Volume static bar shown after | `+350 ms`, then held |
| Volume overlay timeout | 1000 ms after last change → ring black + priority 0 + restore mute LED + restore global brightness |
| Volume overlay priority | 100 (active) / 0 (released) |
| Global brightness during overlay | forced to 100, restored on timeout |
| Mute LED (idx 1000) muted | `mColor × 0.2` = `#001E28` |
| Mute LED (idx 1000) unmuted | `mColor × 0.7` = `#006B8E` |
| Ring while muted | `mDefaultColor` = `#000F14` |
| LED count | HAL-defined via `nativeInit()` (not a literal in this code; physical Nexus Q ring) |
| Magic indices | 1000 = mute LED, 1001 = all LEDs, 0..N-1 = ring LED i |
| Commit | buffered → `commitLedValues()` flush; no HW interpolation |

---

## 6. What could NOT be recovered / caveats

- **Physical LED count** is not a literal in this code — it comes from the native HAL
  (`nativeInit()` reads the kernel driver). Map it to the daemon's known ring size (32).
- **Idle ring at true idle** (no overlay, music app not in foreground) is governed by the
  Visualizer screensaver, whose per-frame colors come from a GL particle simulation, not a
  single constant. If you only mirror the *system* volume/mute behavior, treat idle as
  `#000F14` ring + mute LED, with the ring black between overlays.
- The exact mapping of physical LED index → angular position on the ring (origin/direction) is
  irrelevant for volume/mute because both use the "all LEDs" broadcast (index 1001) — the ring
  is always uniform for these behaviors. (Per-LED ordering only matters for the visualizer's
  `setLedRange`.)

## 7. Tooling notes (for reproducibility)

- baksmali **2.5.2** (`org.jf.baksmali.Main`) on Java 26. The bundled `jcommander.jar` (1.72)
  has the wrong `getMainParameter()` signature → `NoSuchMethodError`. **Fix:** use
  **jcommander 1.64** (has `getMainParameter():ParameterDescription`). Also add
  **guava failureaccess 1.0.1** (missing `InternalFutureFailureAccess`).
- Colon/`C:\` clash avoided by `cd`-ing into the deodex dir and using `-d framework` with bare
  filenames in `-b`, e.g.:
  ```
  java -cp "baksmali.jar;dexlib2.jar;util.jar;guava.jar;failureaccess.jar;jc-1.64.jar" \
       org.jf.baksmali.Main deodex -a 15 -d framework \
       -b "core.odex:core-junit.odex:bouncycastle.odex:ext.odex:framework.odex:android.policy.odex:services.odex:apache-xml.odex:filterfw.odex" \
       -o out/<App>_smali app/<App>.odex
  ```
- Deodexed smali saved under `…\deodex\out\` (`framework_smali`, `TungstenLEDService_smali`,
  `Visualizer_smali`). Not added to the repo.
</content>
</invoke>
