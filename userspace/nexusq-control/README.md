# nexusq-control — companion LAN control bridge

The device-side daemon the Flutter companion (`companion/app`) talks to. It is the single
LAN endpoint that implements the v1 control protocol (`../../companion/PROTOCOL.md`) and fans
the work out to the subsystems that already run on the device:

| Concern | Backend |
|---|---|
| volume / mute | ALSA softvol control **`NexusQ`** via `amixer` (librespot is bound to the same control, so Spotify-Connect and companion volume are one knob) |
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
NEXUSQ_BIND_HOST=127.0.0.1 NEXUSQ_MIXER_CARD=… NEXUSQ_MIXER_CTRL=… ./nexusq-control
```
Config via env: `NEXUSQ_BIND_HOST/PORT` (0.0.0.0:45015), `NEXUSQ_MIXER_CARD` (NexusQSpeaker),
`NEXUSQ_MIXER_CTRL` (NexusQ), `NEXUSQD_SOCK` (/run/nexusqd.sock), `NEXUSQ_HOOK_SOCK`
(/run/nexusq-control.sock), `NEXUSQ_NAME` ("Nexus Q").

## v1 limitations
- **Transport (play/pause/next/previous) is `unavailable`** — librespot is a Spotify-Connect
  receiver with no local transport API; control happens from the Spotify app. A future backend
  (e.g. go-librespot's HTTP API) could fill this in (PROTOCOL.md §5).
- The softvol `NexusQ` control is created when librespot first opens `nexusq_soft`; until then
  `amixer` reads fail and the bridge reports a default volume, reconciling on the first event.

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

Re-verify after a reflash: `systemctl status nexusq-control`, `amixer -c NexusQSpeaker sget
NexusQ`, then point the app at the device (`flutter run --dart-define=NEXUSQ_HOST=<ip>`) and
check volume/theme/brightness + now-playing.
