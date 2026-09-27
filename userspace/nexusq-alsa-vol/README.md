# nexusq-alsa-vol: the `nexusq_vol` ALSA control

The Nexus Q has one volume: the PulseAudio sink of the active output. The app,
the dome knob and Home Assistant all move it. Until device r117 the players had
a second one. librespot and shairport-sync each attenuated the samples in
software before PulseAudio, so the room heard *Spotify × sink* and the app
showed half of it (`docs/2026-09-23-unified-volume.md` §1).

A player moves a real volume only through a mixer control **with a dB scale**.
The stock PulseAudio control (alsa-plugins' `ctl_pulse`) has none: librespot
refuses to start on it, and shairport-sync falls back to its own software
volume. This plugin is that control with the dB scale. Neither player is
patched.

```
Spotify slider ─▶ librespot ─┐                    ┌─▶ PulseAudio default sink ─▶ amp
                             ├─▶ ctl.nexusq_vol ──┤
iPhone slider ─▶ shairport ──┘   "Master"         │
app / knob / Home Assistant ─────────────────────▶┘
```

## What it exposes

- **`Master Playback Volume`**: one integer, mono, 0 … 2^30, TLV `DB_LINEAR`
  (mute at 0, 0 dB at the top), mapped onto `@DEFAULT_SINK@`. It follows the
  **current** default sink, so an output switch in the app takes it along.
  `ctl_pulse` binds to whichever sink was default when it was opened.
  A write scales the sink's channels together, which keeps a balance.
- **No playback switch, on purpose.** Mute belongs to the Q (app, knob, Home
  Assistant). librespot 0.8.0 switches a mixer's switch on at every start with
  a non-zero volume, so a muted Q would come back unmuted at boot.

## The scale

PulseAudio's software volume is cubic in amplitude: dB = 60 log10(v / NORM).
The control's integer is linear in amplitude,

```
raw = 2^30 · (v / NORM)^3        v = NORM · cbrt(raw / 2^30)
```

so every dB a player asks for lands on the PulseAudio volume with that same dB
(`nexusq_vol_scale.h`). The smallest step is −180.6 dB. librespot reads the
control's range for its cubic mapping (`--volume-ctrl cubic`, no
`--volume-range`), and a floor that deep makes **Spotify's N % the app's N %**.
The test sets all 100 values, reads them back and writes them again with no
drift.

## Using it

The package ships `/etc/alsa/conf.d/60-nexusq-vol.conf` (`ctl.nexusq_vol { type
nexusq_vol }`, with optional `sink` and `server` fields). The players use it as
follows:

- librespot: `--mixer alsa --alsa-mixer-device nexusq_vol --alsa-mixer-control
  Master --volume-ctrl cubic --initial-volume <the sink's current %>`. The
  initial volume **must** be given: librespot 0.8.0 otherwise sets the mixer to
  50 % at every start (its help says "the current volume"; its code does not).
  `librespot-nexusq` reads it with `pulse_volume_percent` (`nq-pulse.sh`).
- shairport-sync: `alsa { mixer_device = "nexusq_vol"; mixer_control_name =
  "Master"; }`. The sender's slider spans the top `volume_range_db` (60 dB, so
  10–100 %) through shairport's standard curve. The iPhone's half-way point is
  the app's 50 %.

Cost at idle: nothing. PulseAudio pushes sink changes, and the plugin
subscribes only when a client asks for events.

## Tests

```sh
make test                          # the scale, on any host with libpulse headers
sh tests/run-integration.sh        # end to end in an Alpine container
```

`run-integration.sh` builds the plugin, installs it with the shipped conf.d file
and starts a real PulseAudio (null sink). `tests/test_player_mappings.c` then
does what librespot 0.8.0 does, step for step (dB range probe, cubic mapping,
millibel truncation, `set_playback_dB` with Floor) and checks:

- Spotify N % → PulseAudio N % for every N;
- reading back gives N %, and the re-set at every play changes nothing;
- the knob's changes read back in dB;
- a muted Q stays muted;
- events arrive;
- the control follows a new default sink.

Dependencies install on each run. A local image saves that:
`docker run --name p alpine:3.22 apk add build-base pkgconf alsa-lib-dev
pulseaudio pulseaudio-dev pulseaudio-utils && docker commit p
nexusq-alsa-vol-test:alpine3.22 && docker rm p`.
