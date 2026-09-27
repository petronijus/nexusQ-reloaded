# 2026-09-27: one volume

## Why

The Q had two volumes in series for Spotify and AirPlay
(`docs/2026-09-23-unified-volume.md` §1):
- the player's own software attenuation (librespot `softvol`, shairport's
  software volume);
- then the PulseAudio sink, which the app, the dome knob and Home Assistant
  move.

The room heard the product of the two. The app showed one factor, and a Spotify
slider move even overwrote the app's number with Spotify's until the next sink
event put it back. The 2026-09-23 investigation parked the fix with a direction:
**a middleware of our own between the players and PulseAudio, neither player
patched**.

## The middleware: `ctl.nexusq_vol`

`userspace/nexusq-alsa-vol` is an ALSA external control plugin. It exposes the
PulseAudio default sink as `Master Playback Volume`, with the dB scale both
players need before they drive a mixer:
- the stock `ctl_pulse` has none, and librespot 0.8.0 fails `NoDbRange` and
  does not start;
- shairport-sync logs "does not have a dB volume scale" and keeps its
  software stage.

The integer is linear in amplitude, `raw = 2^30 · (v/NORM)^3`. The TLV is
therefore an exact `DB_LINEAR` and equals PulseAudio's own dB,
60 log10(v/NORM). The smallest step is −180.6 dB.

- It follows `@DEFAULT_SINK@`, i.e. the output the app selected. `ctl_pulse`
  binds to the sink that was default at open.
- **No playback switch.** librespot 0.8.0 (`alsamixer.rs` `set_volume`) turns
  a mixer's switch on at every start with a non-zero volume. A muted Q would
  come back unmuted at every boot and at every librespot restart. Mute is the
  Q's own.
- Idle cost: none. PulseAudio pushes sink changes, and the plugin subscribes
  only when a client asks for events.

## librespot

`--mixer alsa --alsa-mixer-device nexusq_vol --alsa-mixer-control Master
--volume-ctrl cubic --initial-volume <the sink's %>`, no `--volume-range`.

- **The cubic mapping over the control's own range is the identity.** librespot
  takes the range from the control: the minimum is mute, so it asks the dB of
  the first step, −180.6. Its cubic floor is then 10^(−180.6/60) ≈ 10^−3, and
  Spotify's N % lands on the sink's N %. `tests/test_player_mappings.c`
  reproduces librespot's steps (range probe, mapping, millibel truncation,
  `set_playback_dB` Floor) against a real PulseAudio: all 100 values match,
  read back exactly, and the re-set librespot does at every play moves nothing.
- **`--initial-volume` has to be the sink's current volume.** librespot's help
  says the alsa mixer defaults to "the current volume". Its code
  (`main.rs`) returns `None` for the alsa mixer and then falls back to
  `connect_default_config.initial_volume`, which is 50 %, and `Spirc::new` sets
  the mixer to it. Every boot and every restart would have put the Q at 50 %.
  The launcher reads the sink with `pulse_volume_percent` (`nq-pulse.sh`) and
  refuses to start if it cannot. Any number given there is SET, and a guess of
  100 would be the loudest mistake available.
- Q → Spotify: librespot has no local control interface, but `handle_play`
  re-reads the mixer (`self.mixer.volume()`) at every play. The knob and Home
  Assistant therefore reach the Spotify apps then. The app also mirrors its own
  slider to the Web API on release (`PUT /me/player/volume`). It never does so in
  answer to an event, so nothing rings.

## shairport-sync

`alsa { mixer_device = "nexusq_vol"; mixer_control_name = "Master"; }` with
`volume_range_db = 60`. Its standard curve (`vol2attn`) spreads the sender's
slider over the control's top 60 dB, i.e. 10–100 %, and the slider's half-way
point is −18 dB = 50 %.

Q → sender: shairport's MPRIS `SetVolume` (0..1 = AirPlay −30..0) sends the
sender DACP `setproperty?dmcp.device-volume`. The sender then echoes its new
volume, and shairport applies it through the control. The bridge
(`AirPlayVolumeFollow`) therefore:
- pushes the exact inverse of `vol2attn` (ported line by line; the round trip
  is within 0.01 %);
- waits 0.7 s for the value to settle, so an echo of an early knob position
  cannot drag the Q back;
- does not push a change that came from the sender;
- does not push below 10 %, where the sender's minimum would come back as 10 %
  and raise the Q.

## The bridge, Home Assistant

- `state["volume"]` comes only from the sink. The librespot `volume` hook no
  longer writes Spotify's software level into it.
- Home Assistant: a **Volume** number and a **Mute** switch (nexusq-mqtt r10)
  call `setVolume`/`setMuted`. They share one bridge connection with the LED
  ring (`BridgeFeed`). The read-only Volume sensor is retired.

## Not covered

- **Roon**: set the zone to *Fixed volume* in Roon (a Core setting), so Roon
  adds no stage. A two-way Roon volume would need a mixer on the RoonLoop card.
- **USB audio**: the host's volume stays the host's, as with any DAC without a
  volume control.

## On the hardware (cottage Q, 2026-09-27)

Installed nexusq-alsa-vol r1, device r117, control r54 and mqtt r10 from local
apks, then restarted the bridge, nexusq-mqtt, librespot and shairport-sync.

- **The volume survived the restarts:** 27 % before, 27 % after.
  librespot logged `mixer nexusq_vol, starting at the sink's 27%`, `Mixing with
  Alsa ... Cubic`, a `dB volume range [-180.61..0.00]`, `softvol: false` and
  `playback (mute) switch: false`.
- **A player's write:** the control set to −18.06 dB (what Spotify 50 % asks
  for) put the sink at 50 %, and the bridge's `getState` said 50 within a
  second.
- **The knob's direction:** `pactl` at 35 % read back on the control as
  −27.35 dB, which is 60 log10 0.35.
- **Home Assistant**, over the cottage broker: `volume/set 42` put the Q at
  42 % and `volume/state` followed. The old `sensor/…/volume/config` is gone.
  `update/state` listed the unit's 9 real pending updates (systemd 262-r2, …)
  as `1.0-r117 + 9 updates`; they were not installed.
- **Idle over 60 s:** PulseAudio 0 ticks, shairport-sync 1, librespot 5 (with
  its diagnostics-mode debug logging on).
- **Not yet tried:** a real Spotify session (slider both ways, and the re-read
  at play) and a real AirPlay sender (shairport's first mixer write, and the
  DACP push back). Both need a phone at the Q.
