# 2026-07-01 — librespot softvol bootstrap fix + breathing color themes + selectable visualisations + app-mute LED

More fixes/features folded into **v1.6.5** (on top of the LED-ring AVR keepalive and the
companion-over-WiFi nftables rule — those are in
`docs/2026-07-01-led-ring-avr-starvation-keepalive.md`). Final v1.6.5 pkgrels:
`nexusqd` **r5**, `nexusq-control` **r4**, `device-google-steelhead` **r17**. `boot.img`
is **byte-identical** to v1.6.2/v1.6.3 (kernel unchanged; md5
`36a3dec2c4a493710dffa18c4d796236`). The companion APK is rebuilt + reinstalled separately
(not part of the device image).

## 1. librespot crash-loop on a fresh boot — the softvol control did not exist yet

**Symptom.** On a fresh boot `librespot.service` crash-loops forever with
`Could not find Alsa mixer control` and never advertises "Nexus Q"; a **reboot never
helps**.

**Root cause.** Since v1.6.3 librespot drives volume through the ALSA **`NexusQ` softvol
control** (`--mixer alsa --alsa-mixer-control NexusQ`), which lives on the `nexusq_soft`
softvol PCM in `asound.conf`. An ALSA **softvol control does not exist until its PCM is
first opened** by *something* — the control is created lazily on first open and, crucially,
is **recreated empty on every boot** (it is not persisted). But librespot opens its ALSA
**mixer control BEFORE it opens the sink**, so on a cold boot — where nothing has opened
`nexusq_soft` yet — the control is absent, librespot exits, and `Restart=on-failure`
respawns it into the same missing-control state indefinitely. Because the control is
recreated empty each boot, rebooting cannot break the loop.

**Fix (`device-google-steelhead` pkgrel 17).** `librespot.service` gained an
`ExecStartPre` that opens `nexusq_soft` once (1 s of digital silence) so the softvol
control is created before librespot's mixer opens it:

```ini
ExecStartPre=-/bin/sh -c 'timeout 5 aplay -q -D nexusq_soft -f cd -d 1 /dev/zero'
```

- The leading `-` makes the pre-step non-fatal (audio may not be ready on the very first
  attempt); `Restart=on-failure` then retries until `sound.target` settles.
- `timeout 5` bounds the bootstrap so a stuck ALSA open cannot wedge the unit start.
- **Side effect (intended):** this also fixes **companion VOLUME**. The `nexusq-control`
  bridge sets volume via `amixer … set NexusQ …`, which likewise needs the `NexusQ`
  control to exist; the bootstrap guarantees it after boot regardless of whether librespot
  or the companion touches it first.

## 2. Color themes are now a BREATHING animation, not a solid fill

Previously a companion "LED theme" mapped to `nexusqd theme <name>` / a solid `set R G B`,
which painted a **static solid** color and, once the idle screensaver blanked
(`SS_BLANK_S`) or while music played, could leave the ring dark ("pick a color, ring stays
dark"). v1.6.5 makes a color theme a **breathing manual override** — the ring gently pulses
in the theme's hue and is **always visible**, over the music visualizer and over a
blanked/idle screensaver.

> **Design correction (design was reverted).** An earlier iteration made `breathe` retint
> the *idle screensaver's* base color (a `br/bg/bb` field + `screensaver_set_color`). That
> approach was **reverted** — it was invisible once the screensaver blanked or while audio
> played (the music layer sits above it). `screensaver.c/.h` no longer carry `br/bg/bb` or
> `screensaver_set_color`. The shipped design drives the **compositor manual layer**
> instead.

**nexusqd side (`nexusqd` pkgrel 5).** New control command **`breathe R G B`**:

- `control.h` / `control.c` — new `CTL_BREATHE` kind, parsed from `breathe R G B`
  (0–255 per channel), reusing the same `rgb3()` parser as `set`.
- `nexusqd.c` — the **manual override layer** (compositor priority **8**) gained a
  `breathe` flag (`struct manual_ctx { int rgb[3]; int breathe; }`). When the flag is set,
  `manual_render()` fills the ring with `rgb` scaled by the **same throb envelope as the
  idle screensaver breathe** — `A = 0.1 + 0.35*(1.0 - screensaver_throb(t))` — reusing
  `screensaver_throb()` (the 10 s cosine) but rendered at priority 8, so it is **always on
  top**. The `CTL_BREATHE` handler sets `manual.rgb`, `manual.breathe = 1`, and activates
  the manual layer. A plain `set` clears `breathe` (solid) and `auto` deactivates the layer
  (resume screensaver/music).

**Bridge side (`nexusq-control` pkgrel 4).** `setTheme` maps a color theme to **just**
`breathe R G B` (no `auto` — the breathing override is meant to stay visible over the
music/idle layers). `off` blanks the ring (`off`). The theme set is breathing hues:

| theme  | nexusqd command   | hue        |
|--------|-------------------|------------|
| blue   | `breathe 0 153 204`   | `#0099CC` (the original breathe) |
| warm   | `breathe 255 90 10`   | `#FF5A0A`  |
| cool   | `breathe 0 200 140`   | `#00C88C`  |
| rose   | `breathe 255 40 90`   | `#FF285A`  |
| smoke  | `breathe 110 115 135` | `#6E7387`  |
| off    | `off`                 | ring blanked |

(The stale `spectrum` / `trackinfo` themes were dropped.) The companion app mirrors the
same hues in `models.dart kLedThemes`.

## 3. Five music visualisations selectable from the app

`nexusqd` already had all five RenderEngine effects behind `scene 0..4` (Plan 3b:
`music_set_scene`, compositor music layer priority 7, shown while audio plays). v1.6.5
exposes them as an **independent picker** in the companion — separate from the color theme.
A **color theme is the breathing override hue; a visualisation is the music-reactive
effect** (priority 7, below the priority-8 breathing override — so a chosen breathe stays
visible; select `auto`/a scene to see the visualiser while audio plays).

**Bridge side (`nexusq-control` pkgrel 4).** New methods `setScene` / `listScenes`.
`setScene` maps a name → index and sends `auto` (drop any solid override so the audio
visualiser at priority 7 is actually visible) + `scene N`. `getState` now also carries a
`scene` field.

| index | scene name      | label      |
|:-----:|-----------------|------------|
| 0 | `waveform`      | Waveform   |
| 1 | `waveformsolid` | Solid Wave |
| 2 | `circles`       | Circles    |
| 3 | `pointmorph`    | Morph      |
| 4 | `starfield`     | Starfield  |

**Companion app.** A dedicated **VISUALIZATION** section (`home_screen.dart`) with a
`scene` field on `DeviceState`, `Visualization` model + `kVisualizations` (`models.dart`),
`setScene()` on `DeviceController` (`device_controller.dart`), `sceneChanged` event
handling, and `setScene`/`scene` in the mock client (`mock_client.dart`). The color theme
picker and the visualisation picker are now two independent controls.

## 4. App-mute now lights the device mute LED

Previously only the **hardware** mute key lit the dedicated ring mute LED (the dim-teal
`#001E28` / `#006B8E` indicator driven by `apply_mute_led()` → `reaction_mute_led()` +
`avr_set_mute()`); a mute from the companion app changed only the ALSA softvol, so the
device gave no visual cue.

**nexusqd side (`nexusqd` pkgrel 5).** New control command **`muted 0|1`** (`CTL_SETMUTED`,
`control.c`): `nexusqd.c` sets the daemon's `muted` state and calls the same
`apply_mute_led(muted)` the hardware mute key uses (and refreshes the screensaver activity
timer). So a socket `muted 1` / `muted 0` drives the identical mute LED as the physical key.

**Bridge side (`nexusq-control` pkgrel 4).** The volume/mute code path
(`setVolume`/`adjustVolume`/`setMuted`/`toggleMute`) now, after setting the ALSA softvol,
also sends `nexusqd_send("muted 1|0")` — so a companion mute has a **device-side indicator**
on the ring, matching the hardware key.

## Protocol

`companion/PROTOCOL.md` (updated by hand) documents the new `scene` state field, the
`setScene` / `listScenes` methods + `sceneChanged` event, and that a color theme now maps
to a breathing override (`breathe R G B`) rather than a solid fill.

## Verification

- `nexusqd` builds/runs as **`0.1.0-r5`**; `nexusq-control` as **`0.1.0-r4`**;
  `device-google-steelhead` as **`1.0-r17`**.
- Kernel unchanged → `boot.img` byte-identical to v1.6.2/v1.6.3.
- Companion APK rebuilt + reinstalled on the phone (separate from the device image).

**Caveats.**
- The LED-ring AVR keepalive's "never wedges again" claim still awaits an **overnight idle
  soak** (the wedge took ~20 h) — see the keepalive doc.
- **Known limitation (deferred to v1.6.6):** companion volume/mute act on the ALSA `NexusQ`
  softvol (the Spotify/librespot stream) + the mute LED, but do **not** mirror to the LXQt
  desktop taskbar volume/mute icon. The physical keys emit `KEY_MUTE` / `KEY_VOLUME*` input
  events that the desktop catches (→ taskbar + desktop audio) and nexusqd reads (→ mute
  LED); the app path goes straight to the softvol, so app vs desktop can diverge. Unifying
  app + hardware + desktop + Spotify onto one canonical volume/mute control is a v1.6.6
  task (investigate whether the desktop drives ALSA `Master` vs PulseAudio/PipeWire, and
  whether emitting `uinput` KEY events or driving the canonical control is cleaner).
