# nexusQ-reloaded — Flutter companion app

(Dart package id `nexusq_companion`; user-facing name **nexusQ-reloaded**.)
Cross-platform (Android / iOS / macOS / web) companion for the postmarketOS Nexus Q,
reproducing the original Holo-dark / glowing-ring look (see
`../../docs/2026-06-30-companion-design-language.md`) and speaking the v1 control protocol
(`../PROTOCOL.md`).

## Run

```sh
# Default: auto-discover the device on the LAN via mDNS (_nexusq._tcp), with a
# manual-host / "Demo" fallback screen if none is found:
flutter run

# In-process demo device (no hardware, no network) — straight to the UI:
flutter run --dart-define=NEXUSQ_MOCK=true

# Connect to a specific bridge directly (skips discovery):
flutter run --dart-define=NEXUSQ_HOST=192.168.x.y
```

`flutter test` runs the test suite (protocol/controller smoke test + the setup-wizard,
BT-client and pairing-color tests — 14 as of 2026-07-13); `flutter analyze` is clean.

## Setup wizard (onboarding step 1, added 2026-07-13 — device side targets v1.9.0)

`lib/setup/` ships an 8-screen wizard (welcome / cables / find / confirm-color /
wifi / name-room / theme / outro) that provisions an unconfigured Q over
**BT RFCOMM** (`../PROTOCOL.md` §8): a Kotlin platform channel `nexusq/btsetup`
does scan/connect/newline-JSON lines, Dart `lib/setup/bt_setup_client.dart` speaks
the envelope, and `pairing_color.dart` stays bit-identical to the device's Python
via the shared vectors `../pairing-color-vectors.json`. Entry points: an **NFC
tap** (the payload is connection-info JSON, §7 — an unprovisioned device routes
into the wizard with the MAC prefilled) and **"Set up new device"** on the connect
gate.

**Stock imagery:** the original Google setup assets are copyrighted and
gitignored — run `../../scripts/extract-stock-assets.sh` (needs the private stock
APKs) to populate `assets/stock/`; without it the wizard still builds and runs
(tracked `.keep` placeholders + icon fallbacks).

**mDNS notes:** discovery works on Android/iOS/desktop on the same subnet (perms are
configured: Android multicast, iOS/macOS Bonjour + local-network usage). On **web** there are no
raw sockets, so discovery is skipped — use the manual host field or `NEXUSQ_MOCK`. On **sandboxed
macOS** mDNS also needs Apple's `com.apple.developer.networking.multicast` entitlement (a
provisioning-profile add-on); without it, use the manual host field (direct TCP works).

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
later. The real device bridge (`nexusq-control`) shipped in v1.6.3 (was "the next piece"
when this was written) — see `../PROTOCOL.md` §6 and `../../userspace/nexusq-control/`.
