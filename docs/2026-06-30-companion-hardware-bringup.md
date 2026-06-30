# Companion ↔ hardware bring-up & wiring

**Date:** 2026-06-30
**Goal:** wire the `nexusQ-reloaded` companion app to the real device end-to-end.
Everything is built and host-verified; this is the on-device checklist for when the Nexus Q is
booted on the LAN.

## Pieces (all on branch `feat/companion-app`)

| Layer | What | Where |
|---|---|---|
| App | Flutter `nexusQ-reloaded` (mDNS discovery + manual/demo fallback) | `companion/app` |
| Contract | v1 JSON-over-TCP protocol | `companion/PROTOCOL.md` |
| Bridge | `nexusq-control` LAN daemon (port 45015, mDNS `_nexusq._tcp`) | `userspace/nexusq-control` |
| LED | `nexusqd` + `brightness` command | `userspace/nexusqd` |
| Audio | ALSA softvol control `NexusQ` + librespot bound to it + `--onevent` | `pmos/device-google-steelhead/{asound.conf,librespot.service}` |
| Packaging | `nexusq-control` aport, pulled in by the device meta-package | `pmos/nexusq-control`, `docker-build.sh` |

## Wiring map (app method → device subsystem)

Consistency audited 2026-06-30 — app client, `PROTOCOL.md`, and the bridge all agree on method
names, event names, port 45015, and the `_nexusq._tcp` service.

| App action | Protocol method | Bridge → device |
|---|---|---|
| volume slider | `setVolume {volume}` | `amixer` set on softvol `NexusQ` |
| mute toggle | `toggleMute` | `amixer` mute on `NexusQ` |
| LED theme chip | `setTheme {theme}` | `theme <name>` → `/run/nexusqd.sock` |
| brightness slider | `setBrightness {brightness}` | `brightness <0-255>` → `/run/nexusqd.sock` |
| (hydrate) | `getState` | cached state + live `amixer` read |
| events | `volumeChanged` / `themeChanged` / `brightnessChanged` / `nowPlayingChanged` | bridge broadcast (librespot `--onevent` feeds now-playing + volume) |
| transport | `playPause`/`next`/`previous` | **unavailable in v1** (librespot has no local transport API) |

## Bring-up steps

1. **Build + flash** the image (it now contains `nexusq-control`, the `nexusqd` brightness
   command, the ALSA softvol, and the librespot mixer/onevent wiring):
   - build via the dockerized pipeline (`docker-build.sh` / the nexusq-build skill),
   - flash in fastboot (INSTALL.md).

2. **Verify on the device** (over SSH / serial):
   ```sh
   systemctl status nexusqd nexusq-control librespot
   amixer -c NexusQSpeaker scontrols | grep -i nexusq     # the softvol control exists
   ss -ltnp | grep 45015                                  # bridge listening
   journalctl -u nexusq-control -b --no-pager | tail
   ```
   - The softvol `NexusQ` control is created when librespot first opens `nexusq_soft`; if it's
     missing, (re)start librespot once and play something.

3. **Install the app** (real, non-mock build — auto-discovers via mDNS):
   ```sh
   adb install -r companion/app/build/app/outputs/flutter-apk/app-debug.apk
   # or, to skip discovery: flutter run --dart-define=NEXUSQ_HOST=<device-ip>
   ```

4. **Verify end-to-end** on the phone:
   - volume slider / mute → audible level change (and Spotify shows the same volume),
   - LED theme chip → ring color on the device changes,
   - brightness slider → ring dims/brightens,
   - now-playing card → updates when a track changes (play from Spotify Connect to "Nexus Q").

## Known v1 limitations / things to confirm against real values

- **Transport** (play/pause/next/previous) returns `unavailable` — control is from the Spotify app.
  A future go-librespot backend (HTTP API) could enable it.
- **Mixer control name/card**: defaults `NexusQSpeaker` / `NexusQ`. If the softvol or card name
  differs on the device, set `NEXUSQ_MIXER_CARD` / `NEXUSQ_MIXER_CTRL` in the service env.
- **librespot event field names** (NAME/ARTISTS/ALBUM/COVERS/VOLUME): confirm against the
  installed librespot version; adjust `nexusq-onevent` if a field differs.
- **mDNS**: needs avahi on the device and the phone on the same subnet. macOS sandbox can't do
  mDNS without the multicast entitlement — use the manual host field there.
- **Volume readback**: the bridge caches what it sets + what librespot reports; external `amixer`
  changes aren't pushed. Fine for v1.

## Next (small, optional)
- Re-pin the slot geometry if the real ring photo differs from the asset.
- Decide whether to hide/disable the transport controls until a backend supports them.
