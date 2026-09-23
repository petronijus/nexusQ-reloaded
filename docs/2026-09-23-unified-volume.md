# Unified volume — one number for every front end (investigation, 2026-09-23)

Task (AI-handover, p2): *"Changing the volume in Spotify propagates to the koule
and the app; changing it in the app does NOT propagate back to Spotify. Goal:
one authoritative volume, reflected in every direction, for Spotify, AirPlay,
Roon and USB audio."*

This note records what the code actually does (read, not yet measured on the
device), why the task's premise is only half right, and the design proposed.
§3's claims about librespot 0.8.0, shairport-sync and alsa-plugins were read
from their sources, not assumed.

## 1. What happens today

The Q has **two volume stages in series** for Spotify and for AirPlay:

```
Spotify app slider ──▶ librespot softvol ─┐
                                          ├─▶ PA sink-input ─▶ PA SINK volume ─▶ amp
iPhone slider ──────▶ shairport softvol ──┘         ▲
                                                    │
                      app slider / dome knob (nq-vol) / HA ─ all write HERE
```

- **librespot** (`librespot-nexusq`) runs with no `--mixer`, so the default
  **`softvol`**: the Spotify slider scales the samples inside librespot, before
  PulseAudio. `--initial-volume 60` resets that stage to 60 % at every start.
- **shairport-sync** (`shairport-sync.conf`) has no `mixer_control_name`, so it
  also attenuates in software (`volume_range_db = 60`).
- **The app, the dome knob and HA** all act on the active output's **PA sink**
  (`_volume_cmd`, `nq-vol`, `pa_watch_thread`).
- The librespot hook (`kind: "volume"`) **writes the Spotify value into the
  bridge's `state["volume"]`** and broadcasts it as `volumeChanged`, but the PA
  sink never moves.

So the "working" direction is a display lie: after a Spotify volume change the
app *shows* Spotify's number while the loudness is Spotify × sink, and the next
PA event (`pa_watch_thread` re-reads the sink) overwrites the number back. Two
people turning "the volume" are turning two different knobs, and the product
of the two is what the room hears. AirPlay's stage is not reported to the app
at all.

The other two inputs:

- **Roon** writes into the dedicated `RoonLoop` snd-aloop card (index 7), which
  has **no mixer control**. Roon therefore offers only *Fixed* or *DSP volume*
  for this zone; DSP volume is a third stage of the same kind, inside Roon.
- **USB audio** (`nexusq-uac2-in`): the UAC2 gadget is created **without**
  `c_volume_present`, so the host sees a device with no volume and attenuates
  digitally on its own side. That stage belongs to the host computer, like any
  DAC without a volume control.

## 2. The principle

**One volume: the active output's PA sink.** Every input feeds PulseAudio at
unity; every front end reads and writes that one number. Then the app, the
knob, HA, Spotify and the iPhone cannot disagree about loudness — at worst one
of them *displays* a stale number until it next hears the truth.

## 3. Per input

### The obvious fix does not work: the ALSA `pulse` control has no dB scale

The first design was to point both players' hardware-mixer support at the ALSA
`pulse` ctl plugin's `Master` (= the PA default sink). Checked in the sources
before touching any config, and it fails for both:

- **alsa-plugins `pulse/ctl_pulse.c`** exposes `Master` as a plain integer
  (0..`PA_VOLUME_NORM`) with **no TLV / dB information** at all.
- **librespot 0.8.0 `playback/src/mixer/alsamixer.rs`**: a control without dB
  is treated as "softvol", and for that case it calls
  `Ctl::get_db_range(...)` and returns `AlsaMixerError::NoDbRange` on failure —
  **the mixer does not open, and librespot does not start**. `--volume-range`
  does not bypass it.
- **shairport-sync `audio_alsa.c`**: a control without dB logs *"does not have
  a dB volume scale"*, fails `snd_ctl_get_dB_range` too, and **silently keeps
  attenuating in software** — the second stage would stay.

And there is no switch in librespot 0.8.0 that turns its own attenuation off:
`--volume-ctrl fixed` still maps the Spotify slider linearly onto the samples
(`mappings.rs`: `Fixed` passes `range_ok()` and falls through to
`normalized_volume`; `player.rs` multiplies every sample by it below 1.0), and
`--volume-range 0` only switches the log curve to linear. The only path in
librespot with no software stage is `--mixer alsa` (its `get_soft_volume()`
is `NoOpVolume`), which needs a control with dB.

### AirPlay — solvable without patching anything

- **iPhone → Q:** `ignore_volume_control = "yes"` makes shairport play at full
  scale, and it **still emits the `pvol` metadata** with the sender's AirPlay
  volume (`player.c` `player_send_volume_metadata`: with the option set it
  sends `"<airplay_volume>,0,0,0"`). The bridge already reads shairport's
  metadata pipe for now-playing; it maps `pvol` (−30..0 dB, −144 = mute) onto
  the PA sink. One stage.
- **Q → iPhone:** AirPlay 1 senders accept DACP
  `setproperty?dmcp.device-volume=<airplay dB>`; the bridge already talks DACP
  to the sender for transport. On a sink change during an AirPlay session it
  pushes the level back, and ignores the `pvol` echo that follows.
- The two mappings (AirPlay dB ↔ PA %) must be exact inverses, or every
  round trip drifts.

### Spotify — needs a decision

With librespot 0.8.0 as shipped by Alpine, Spotify's slider cannot be made to
drive the PA sink without a second stage. Options:

1. **Carry a patched librespot** (our own aport): in `alsamixer.rs`, when the
   control reports no dB range, fall back to its raw integer range with the
   configured `--volume-ctrl` mapping instead of failing. Then `--mixer alsa
   --alsa-mixer-device pulse --alsa-mixer-control Master --volume-ctrl linear`
   works as first designed: Spotify moves the PA sink, `--initial-volume` falls
   back to "the current volume" so a restart changes nothing, and a Spotify
   client connecting reads the real level. Small, upstreamable patch; the cost
   is a Rust package in our build and following Alpine's librespot bumps.
2. **Give `ctl_pulse` a dB scale** (patch alsa-plugins, C). Fixes both players
   at once, but PA's volume curve is cubic, so a dB TLV either misstates it or
   needs a piecewise `DB_RANGE` approximation — and Spotify's % and the app's %
   would then differ by design.
3. **Keep Spotify's own stage, stop the bridge lying about it**: `state.volume`
   is only ever the PA sink; Spotify's slider stays a per-input level (like a
   mixer channel), shown separately if at all. Honest, but not "one volume".

**Q → Spotify** in every option: librespot has no external volume API (no
MPRIS, no D-Bus, no local control port in 0.8.0); a Spotify client learns the
level at session connect. During a session the companion app pushes its own
slider changes through the Web API (`PUT /me/player/volume`) while Spotify is
playing on this Q — Spotify relays it to librespot, which (with option 1) sets
the PA sink to the same value, a no-op. The app sends only on the user's own
drag, never in reaction to a `volumeChanged` event, so nothing loops. The knob
and HA stay unseen by the Spotify client until the next connect (closing that
needs a Spotify token on the device — declined for now, 2026-09-23).

### Roon

- Set the zone to **Fixed volume** in Roon (a Core setting, not ours), so Roon
  adds no DSP stage. Roon then has no volume of its own for this zone; the
  app/knob/HA control it.
- Two-way Roon volume would need a **mixer on the RoonLoop card** for Roon's
  *Device volume* mode (an ALSA control plugin whose value we mirror into PA),
  or the roon-extension-mqtt volume topics. Both are real work; left for later.

### USB audio

Stays as it is: the host's own volume is the host's. Exposing
`c_volume_present` would give the host a hardware volume to drive, but then
the Q would have to mirror the gadget's control into PA and push PA changes
back to the host over UAC2's interrupt endpoint — later, if wanted.

## 4. The bridge

- `state["volume"]` comes **only** from the PA sink (`pa_watch_thread`, the
  bridge's own writes). The librespot hook's `volume` event stops overwriting
  it — with `--mixer alsa` the same change arrives from PA anyway, and it is
  the PA value that is true.
- Once this is in, **HA volume** (the next AI-handover item) is one more writer
  of the same number, and cannot become a front end with its own idea of the
  level.

## 5. Decision (2026-09-23): parked

**Not implemented for now.** Petr's call on §3's Spotify options: patching
librespot (option 1) is rejected — carrying a fork of someone else's player to
change its mixer is the wrong layer. The direction to pursue when this is
picked up again is **a middleware of our own between the players and
PulseAudio**, which leaves librespot and shairport-sync stock:

- the natural shape is a small **ALSA external control plugin** (`ctl` type,
  our own C, packaged with the device) that exposes a `Master` element **with a
  dB scale** and maps it onto the PA default sink's volume — exactly what
  `ctl_pulse` does, plus the TLV both players require. librespot's
  `--mixer alsa` and shairport's `mixer_control_name` then both drive the one
  PA volume with no software stage, and neither player is patched;
- its dB ↔ PA-volume mapping decides whether Spotify's % equals the app's %
  (PA's curve is cubic: a `DB_RANGE` TLV fitted to it, or a volume curve the
  plugin owns end to end) — to be designed then, not guessed now;
- it would also be the natural place to notice a level change and tell the
  bridge, instead of the bridge polling `pactl`.

The AirPlay path in §3 (`ignore_volume_control` + `pvol` + DACP) needs no
middleware and could go ahead on its own, but it is parked with the rest so
the two inputs get one consistent design.

## 6. Order of work (when resumed)

1. AirPlay: `ignore_volume_control`, `pvol` → PA sink, DACP push-back.
2. Bridge: `state.volume` only from the PA sink.
3. App: Web API push on the user's own slider drag while Spotify plays here.
4. Spotify (and AirPlay's mixer): the middleware control plugin (§5).
5. HA volume entity.
6. Roon: document *Fixed volume*; a device mixer only if wanted.
