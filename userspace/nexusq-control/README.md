# nexusq-control — companion LAN control bridge

The device-side daemon the Flutter companion (`companion/app`) talks to. It is the single
LAN endpoint that implements the v1 control protocol (`../../companion/PROTOCOL.md`) and fans
the work out to the subsystems that already run on the device:

| Concern | Backend |
|---|---|
| audio output | PulseAudio default sink via `pactl` — `set-default-sink` + `move-sink-input` for every stream (input-agnostic); class-D amp toggled for safety. PA runs in the uid-10000 `user` session, reached from root with `PULSE_SERVER`/`PULSE_COOKIE` |
| volume / mute | `pactl set-sink-volume`/`set-sink-mute` on the **active output's** PA sink (input-agnostic, follows the output) |
| LED theme / brightness | `nexusqd` control socket `/run/nexusqd.sock` (`theme <name>` / `brightness <0-255>`) |
| now-playing | `librespot --onevent /usr/bin/nexusq-onevent` pushes track/volume changes to the bridge's local socket `/run/nexusq-control.sock` (read-only metadata + transport state) |
| discovery | mDNS `_nexusq._tcp` via `avahi-publish-service` (best-effort) |

Pure Python 3 (stdlib only — the device ships `python3`). Threaded: TCP accept loop, a unix
accept loop for the librespot hook, one handler thread per client; shared state under a lock;
device events broadcast to all clients (ack precedes async events).

## Files
- `nexusq-control` — the daemon (`/usr/bin/nexusq-control`).
- `nexusq-onevent` — the librespot event hook (`/usr/bin/nexusq-onevent`).
- `nexusq-control.service` — systemd unit (enabled via the aport).

Packaged by `pmos/nexusq-control/APKBUILD`; pulled into the image by the device meta-package
(`depends=nexusq-control`); staged + built by `docker-build.sh` (Phase 6 + Phase 7c2).

## Run / test on the host
```sh
NEXUSQ_BIND_HOST=127.0.0.1 NEXUSQ_PULSE_SERVER=unix:/run/user/1000/pulse/native ./nexusq-control
```
Config via env: `NEXUSQ_BIND_HOST/PORT` (0.0.0.0:45015), `NEXUSQ_MIXER_CARD` (NexusQSpeaker,
for the amp toggle), `NEXUSQ_AMP_CTRL` (Speaker), `NEXUSQ_PULSE_SERVER`
(unix:/run/user/10000/pulse/native), `NEXUSQ_PULSE_COOKIE` (/home/user/.config/pulse/cookie),
`NEXUSQD_SOCK` (/run/nexusqd.sock), `NEXUSQ_HOOK_SOCK` (/run/nexusq-control.sock),
`NEXUSQ_NAME` ("Nexus Q").

## v1 limitations
- **Transport (play/pause/next/previous) is `unavailable`** — librespot is a Spotify-Connect
  receiver with no local transport API; control happens from the Spotify app. A future backend
  (e.g. go-librespot's HTTP API) could fill this in (PROTOCOL.md §5).
- Volume/mute follow the **active output's PA sink**; if PulseAudio isn't up yet (no sinks), the
  bridge reports a default volume and reconciles on the first event / a later `setOutput`.
- **TAS5713 gain is very hot/steep** (app ~8% ≈ deafening); v1 sends plain linear pactl % — a
  usable-range gain cap on the TAS5713 `Master`/`Speaker` control is a known follow-up tuning.

## Device verification (verified live — v1.6.3, 2026-07-01)
Verified on hardware from a clean v1.6.3 flash: the bridge auto-starts (`active`, no boot
ordering cycle), answers every protocol method, volume works (the `nexusq_soft` softvol over
the v1.6.2 tee, shared with librespot), and the LED visualizer still tracks playback.

Boot enablement gotcha (now fixed): the unit must carry **no `After=`** — an
`After=nexusqd.service` formed a boot ordering cycle (`nexusq-control` → `nexusqd` →
`multi-user.target` → `nexusq-control`) that systemd broke by **deleting the bridge's start
job**, so it was enabled but never auto-started (manual `systemctl start` masked it). It is
enabled durably via the `95-nexusq.preset` systemd preset (a `/usr/lib` vendor wants and a bare
`/etc` symlink were both stripped by the image build's `preset-all` + pmOS's `disable *`).

Re-verify after a reflash: `systemctl status nexusq-control`, `pactl list short sinks` (as the
uid-10000 user, or from root with `PULSE_SERVER`/`PULSE_COOKIE`), then point the app at the
device (`flutter run --dart-define=NEXUSQ_HOST=<ip>`) and check output switching + volume/theme/
brightness + now-playing. **Still needs a live device test** (output selection + volume/mute on
PA sinks landed as repo code only): confirm `setOutput` moves a currently-playing stream, that
the amp toggle silences the banana terminals on `spdif`, and calibrate the TAS5713 gain range.
