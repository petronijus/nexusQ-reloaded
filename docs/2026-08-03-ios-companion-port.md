# 2026-08-03 — iOS companion-app port: native Bonjour discovery + platform gating

Base: `main` @ `c0ae9fb` (post-v1.11.0 dev line; companion app **1.11.0+28**).
**App-side only — no device/image change; the app's own version track is
unchanged.** As of this writing the work sits **UNCOMMITTED in the working tree**
(`companion/app/` — 12 modified files + `ios/Runner/BonjourDiscovery.swift`,
`ios/Podfile`, `ios/Podfile.lock`, `macos/Podfile` new).

Toolchain: **Flutter 3.44 / Xcode 26.6**. Verified on the **iPhone 17 simulator,
iOS 26.5**. `flutter build ios --release --no-codesign` passes → **18.8 MB
Runner.app**.

## The problem: `package:multicast_dns` cannot run on iOS

Discovery of the Q rides mDNS `_nexusq._tcp` (PROTOCOL §2), implemented with
`package:multicast_dns` — a **raw port-5353 multicast socket**. iOS 14+ refuses
that without the restricted **`com.apple.developer.networking.multicast`**
entitlement, which Apple grants **on request only** (a form, per-app). The
sanctioned path is the Bonjour API, which needs nothing beyond the
`NSBonjourServices` + `NSLocalNetworkUsageDescription` declarations — **both
already in Info.plist** from the earlier scaffold.

## Native Bonjour bridge (`nexusq/bonjour`)

New `companion/app/ios/Runner/BonjourDiscovery.swift`:

- **NWBrowser** browses `_nexusq._tcp`; the first result is resolved by opening a
  **throwaway NWConnection to the endpoint** (Network.framework resolves Bonjour
  endpoints on connect) and reading the **remote IPv4 + port** once the
  connection is `.ready`. That doubles as a **reachability check** — a Q that
  advertises but does not accept is not reported.
- Exposed as MethodChannel **`nexusq/bonjour`**, one method:
  `discover {timeoutMs} -> {name, host, port} | nil`. All state confined to one
  DispatchQueue (browser/connection callbacks delivered there → completion-
  exactly-once without locking); a newer `discover` supersedes an in-flight one.
- Registered in `AppDelegate.didInitializeImplicitFlutterEngine`; the Swift file
  had to be added to `Runner.xcodeproj` **by hand** (classic pbxproj — four
  sections: PBXBuildFile, PBXFileReference, group children, Sources build phase).

Dart side (`lib/protocol/discovery.dart`): `discoverNexusQ()` branches —
**iOS → the channel, everywhere else → `multicast_dns` unchanged**. Same
contract: any channel failure (missing implementation in tests, local-network
permission denied, timeout) reads as *nothing found* → the manual-host fallback,
never a throw.

## Platform gating (what iOS can and cannot do)

- **`BtSetupClient.supported`** (new, Android-only): first-time setup rides
  **BT Classic RFCOMM** (PROTOCOL §8), and iOS has **no public API** for that —
  SPP is MFi-gated. ConnectGate's fallback now shows an explanatory note on iOS
  instead of a "Set up new device" button that would die on the first
  platform-channel call: **first-time setup stays on the Android app; once the Q
  is on WiFi, iOS works fully.**
- **`AppUpdate.selfUpdateSupported`** (new, Android-only): self-update is an apk
  hand-off to the Android package installer. On iOS `_checkUpdate` no-ops, so
  the merged "App update" card (1.11.0) degrades to the **device-daemon track
  alone** — the binary itself comes from Xcode/TestFlight.
- **NFC/HCE** was already Android-gated — no change.

## Build plumbing

- **`ios/Podfile` + `ios/Podfile.lock` + `macos/Podfile` now exist and belong in
  git** — `open_filex` does not support Swift Package Manager, forcing the
  projects onto **CocoaPods** (the xcconfigs gained the `#include?
  "Pods/..."` lines).
- Signing team `ASFPR2T2DQ` + bundle id `org.nexusq.nexusqCompanion` were
  already configured — nothing to change there.

## Verified on the simulator (iPhone 17, iOS 26.5)

- **ConnectGate**: discovery runs (via the channel) + the fallback UI renders
  with the new iOS setup note.
- **HomeScreen** via `--dart-define=NEXUSQ_MOCK=true`: sphere + LED ring,
  volume, output selector, brightness, light themes all render correctly.

## Known findings (record, don't re-derive)

- **`test/connect_gate_setup_entry_test.dart` fails on this Mac** with
  `SocketException: No route to host` from a **real multicast send** — the test
  does real mDNS I/O. **PRE-EXISTING and environment-dependent** (fails on clean
  HEAD `c0ae9fb` too); **not** caused by this port.
- **Release mode is not supported on iOS simulators** — use debug there;
  release builds are for the physical device.
- **Deploying to the physical iPhone ("Běla") is still PENDING** — needs the
  phone on cable with Developer Mode enabled.

## Phase-2 idea: lift the iOS setup limitation via BLE GATT

A **BLE GATT-based first-time setup** (device-side BlueZ GATT server carrying
the §8 envelope) would work from iOS — CoreBluetooth exposes GATT publicly,
unlike RFCOMM. Device-side BlueZ work; recorded as the candidate path, not
started.
