# nexusq_companion — Flutter companion app

Cross-platform (Android / iOS / macOS / web) companion for the postmarketOS Nexus Q,
reproducing the original Holo-dark / glowing-ring look (see
`../../docs/2026-06-30-companion-design-language.md`) and speaking the v1 control protocol
(`../PROTOCOL.md`).

## Run

```sh
# Local dev with the in-process mock device (no hardware needed):
flutter run                      # pick a device; macOS/Chrome are easiest

# Against a real device bridge on the LAN:
flutter run --dart-define=NEXUSQ_HOST=192.168.x.y
```

`flutter test` runs the protocol/controller smoke test; `flutter analyze` is clean.

## Layout (`lib/`)

- `theme/nexusq_theme.dart` — design system: Holo-Blue `#33B5E5` accent, off-black surfaces,
  Roboto, spacing tokens.
- `widgets/glowing_ring.dart` — the hero element: the Nexus Q sphere + equatorial LED arc, drawn
  procedurally (`CustomPainter`), reacting to volume / theme / mute (no copyrighted PNGs).
- `protocol/` — `models.dart` (state + the 7 LED themes), `client.dart` (interface),
  `tcp_client.dart` (real line-JSON over TCP), `mock_client.dart` (in-process fake device).
- `state/device_controller.dart` — `ChangeNotifier` mirroring device state, applying events,
  exposing optimistic intents.
- `screens/home_screen.dart` — v1 remote: ring + now-playing, transport, volume, theme picker,
  brightness.

## v1 scope

Minimal remote: volume/mute, LED theme + brightness, now-playing + transport. Everything else in
the RE triage (outputs, fixed-level, sync delay, calibration, multi-room) extends the same protocol
later. The real device bridge (`nexusq-control`) is the next piece — see `../PROTOCOL.md` §6.
