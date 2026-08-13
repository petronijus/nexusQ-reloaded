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
BT-client and pairing-color tests — **still 14 as of 2026-07-16**; no new tests through
v1.10.1); `flutter analyze` is clean.

> ⚠️ **`lib/screens/devices_screen.dart` (1.2.0+7) has NO tests of its own** — the 14
> predate it and none cover it, nor the 1.3.1 debug-mode / poll-error changes. It was
> verified on hardware only (Petr, 2026-07-15 / 07-16).

## Build an APK

```sh
./build-apk.sh          # stamps the UI build label from pubspec.yaml
```

Use it rather than a bare `flutter build apk`, so the in-app version stamp
(`kBuildLabel`, shown on the connect gate + welcome) cannot drift from `pubspec.yaml`.

> ⚠️ **The app is versioned on its OWN INDEPENDENT TRACK — deliberately NOT aligned
> to the Nexus Q image/firmware releases** (`v1.8.2`, `v1.9.0`, …). An app-only fix
> must be shippable without implying a firmware release, and a firmware release must
> not force a fake app bump. **Device compatibility is a PROTOCOL concern**
> (`../PROTOCOL.md`) — not something to express by fusing version numbers.
>
> **Bump the build number (`+N`) on EVERY apk handed to the phone**: Android refuses a
> downgrade, and it is how builds are told apart. (It sat at `1.0.0+1` for dozens of
> builds and made "is this the fixed one?" unanswerable — hence `1.1.0+2`, the BT
> setup onboarding release; `1.1.1+5` shipped alongside device **v1.9.0**, `1.2.0+7` —
> the Devices screen — alongside device **v1.10.0**, and **`1.3.1+9`** — debug mode +
> the Devices poll-error fix — alongside device **v1.10.1**.) Gradle reads
> versionName/versionCode straight from `pubspec.yaml`.

## iOS (runs since 2026-08-03 — verified on the iPhone 17 simulator, iOS 26.5)

The app builds and runs on iOS (Flutter 3.44 / Xcode 26.6; `flutter build ios
--release --no-codesign` → 18.8 MB Runner.app). Full record:
`../../docs/2026-08-03-ios-companion-port.md`. What differs from Android:

- **Discovery is native Bonjour, not `multicast_dns`.** iOS 14+ refuses raw
  port-5353 sockets without the restricted
  `com.apple.developer.networking.multicast` entitlement (Apple grants it on
  request only), so `ios/Runner/BonjourDiscovery.swift` browses `_nexusq._tcp`
  with **NWBrowser** and resolves via a throwaway NWConnection (remote IPv4+port
  read once `.ready` — doubles as a reachability check), exposed as the
  **`nexusq/bonjour`** MethodChannel (`discover {timeoutMs} -> {name, host, port}
  | nil`). `lib/protocol/discovery.dart` branches: iOS → channel, everywhere
  else → `multicast_dns` unchanged. `NSBonjourServices` +
  `NSLocalNetworkUsageDescription` are in Info.plist.
- **First-time setup is Android-only** (`BtSetupClient.supported`): the wizard's
  transport is BT Classic RFCOMM, which iOS has no public API for (SPP is
  MFi-gated). The connect gate shows an explanatory note on iOS instead of
  "Set up new device" — **once the Q is on WiFi, iOS works fully**. Phase-2
  idea: a BLE GATT setup transport (device-side BlueZ) would lift this.
- **No self-update on iOS** (`AppUpdate.selfUpdateSupported`): the apk hand-off
  is Android-only; the merged "App update" card degrades to the device-daemon
  track alone (the iOS binary comes from Xcode/TestFlight).
- **CocoaPods, not SPM:** `open_filex` has no Swift-Package-Manager support, so
  `ios/Podfile` + `Podfile.lock` + `macos/Podfile` exist and are tracked.
- **Release mode is not supported on iOS simulators** — run debug on the sim;
  release is for the physical device. Deploying to the physical iPhone is still
  pending (cable + Developer Mode).
- ⚠️ `test/connect_gate_setup_entry_test.dart` does **real mDNS I/O** and fails
  on some networks with `SocketException: No route to host` — pre-existing and
  environment-dependent, not an iOS regression (fails on a clean checkout too).
  **Confirmed NOT hermetic 2026-08-10:** with a **live Q on the LAN** the
  discovery finds the real bridge (it connected to `192.168.20.246:45015`) so
  "Set up new device" is never offered and the test **fails whenever the device
  is online** (passes when it's not). Needs a discovery seam/mock.

### Parity pass 2026-08-07 (v1.11.1)

A full iOS↔Android parity audit (two adversarially-verified agent sweeps + a
manual read) confirmed the shared Flutter UI is identical by construction — one
`MaterialApp`, one theme, no Cupertino/`Platform.is*` render branches — and that
**device-daemon OTA and full-system OTA work identically on iOS** (they go over
the control socket). Three items were reconciled:

- **Status bar:** the dark theme set no `SystemUiOverlayStyle`, so the
  no-AppBar screens (ConnectGate, setup) would draw dark status-bar icons on the
  dark canvas on iOS. Now forced light globally (`main()`) and in `appBarTheme`.
- **"App update" copy on iOS:** the merged card claimed "App is up to date"
  though the app track is never checked on iOS (App Store-managed). It now scopes
  its title/subtitle to the device track when `!AppUpdate.selfUpdateSupported`.
- **Font:** dropped the hard-coded `fontFamily: 'Roboto'` — it rendered Roboto on
  Android but silently fell back to San Francisco on iOS (Roboto isn't bundled).
  Now each platform uses its native face (deliberate: native > pixel-identical).

- **macOS is NOT wired for discovery** (aspirational target — only iOS is
  verified): there is no `macos/Runner/BonjourDiscovery.swift` and no
  `com.apple.developer.networking.multicast` entitlement, so under the app
  sandbox `multicast_dns` (raw 5353) is blocked and auto-discovery returns
  nothing. Use the manual host field / `NEXUSQ_HOST` on macOS, or add a native
  Bonjour bridge mirroring iOS. iPhone is unaffected.

## Devices screen (step 2, added 2026-07-15 — device side released in v1.10.0)

**The Q has no screen and no input device, so this screen IS the Q's Bluetooth
settings panel** — there is no other way to pair anything to it. Reachable from the
home app bar; speaks `../PROTOCOL.md` **§9** (Bluetooth) and **§10** (Desktop).

| | |
|---|---|
| **Pair a phone** | *inbound* — `startPairing` opens a bounded **120 s** window (the ring spins blue exactly while it is open); the phone does the rest |
| **Add a mouse or keyboard** | *outbound* — `startBtScan` → pick → `pairBtDevice`. **A different flow, not a variant**: a mouse never connects TO us, so the Q must discover it and call `Pair()` on it |
| **Paired list** + *Forget* | `listPairedDevices` / `removePairedDevice`; `pairedDevicesChanged` refreshes it |
| **HDMI desktop toggle** | `setDesktop`/`getDesktop` (§10) — pair a keyboard + mouse, switch the desktop on → the appliance is a computer |

> ⚠️ **Show `bonded`, never `paired`.** `paired: true` + `bonded: false` is a device
> that pairs, connects, genuinely types — and is **gone on reboot**. `paired` alone
> **LIES** (PROTOCOL §9.2).

> ⚠️ **No design review yet (2026-07-15).** Petr tested this screen **functionally**;
> the copy is unreviewed and the layout has not been through the Holo-dark design
> pass the setup wizard got (`../../docs/2026-06-30-companion-design-language.md`).

### Debug mode + poll-error fix (1.3.1+9, 2026-07-16 — alongside device v1.10.1)

**Debug mode** (Devices → Developer) reveals an **always-on** in-app connection log.
**Collection is always on** (a 600-entry ring of short strings); the toggle only
reveals the viewer — a collect-only-when-enabled log would always miss the event it
exists for, because the history leading up to a flicker must already be there when the
user reaches for the switch. It records the banner switch (connection UP/DOWN), DROP
causes (peer-closed vs socket-error vs supervisor-disconnect on a failed probe), probe
latency, call timeouts with pending-queue depth, slow/late responses, and lifecycle
transitions (resumed/inactive/paused). **Method names only, never params** (`setWifi`
carries the PSK). This log is what found the device-side **btagent fd leak** on the
first try (v1.10.1 fix; the phone saw "bluetooth agent unreachable" every ~3 s while
the connection itself was healthy).

The **Devices background poll no longer flashes the red error bar**: the 3 s poll now
**logs** a failure instead; only user-initiated actions surface a visible error.

## Health panel (added 2026-08-10 — app 1.12.0+31, released as `app-v1.12.0`; 1.12.1+32 crash fix → 1.13.0+33 device provisioning)

Settings → **"Device health"** → `lib/screens/health_screen.dart`: a live view of
status, problem flags, vitals (die temp / CPU freq / governor / load / memory),
per-OPP residency bars, service chips (Spotify / AirPlay / Roon / USB Audio), and
a WiFi card. **Fed by MQTT, not the control socket** — the on-device
`nexusq-mqtt` daemon (`../../userspace/nexusq-mqtt/`) publishes retained health
JSON + Home Assistant discovery to the home Mosquitto, and the app subscribes to
`nexusq/health/#` via `lib/mqtt/{mqtt_settings,health_mqtt}.dart`
(`mqtt_client ^10.6`, autoReconnect; retained topics populate the panel
instantly). Broker creds are entered in the "Connect to MQTT" dialog and stored
in `flutter_secure_storage` (Android Keystore / iOS Keychain) — the broker
password guards more than the Q, it must not sit in plaintext SharedPreferences.

**Since 1.13.0 the dialog's Save ALSO PROVISIONS the device** (Petr's direction
— "appka to musí nexusu provisionovat"): `HealthScreen` takes the
`NexusQClient` and calls `setMqttConfig` (`../PROTOCOL.md` **§13**,
`nexusq-control` **r28**) so the Q gets the same broker login (atomic 0600
`/etc/nexusq/mqtt.json` on the device, password never logged or returned; a
graceful message when the device build predates r28). **The app is the device's
only credential input** — nothing is baked into the image or hand-edited over
ssh. **1.12.1** fixed the panel's grey-screen crash: a null cast on absent
`led_stall`/`pstore` in an *empty* state map (the daemon omits unavailable
fields) — `healthProblems()` is now top-level with the regression test
`test/health_problems_test.dart`. Record:
`../../docs/2026-08-10-mqtt-health-telemetry.md` (§7 = the follow-up).

⏳ **UNRELEASED change in the working tree (2026-08-13) — the LED problem rule
reads the device's verdict.** `healthProblems()` no longer thresholds the raw
counter (`led_stall >= 6` → "LED ring frame is stalled"); it now checks
**`s['led_stalled'] == true`** → *"LED ring is stalled"*. The old rule fired on
**every idle Q permanently**: `led_stall` counts samples whose LED frame
*content* is identical, which the screensaver does by design (locks at 300 s,
blanks at 600 s) while the 1 Hz AVR keepalive re-commits the same bytes. The
qualification now happens **on-device** (`nexusq-mqtt` **r2**, using the same
distress co-signal `nq-healthd` uses), and a device too old to publish
`led_stalled` raises **nothing** — silence beats a known-false alarm, and a dead
daemon still surfaces via `nexusqd_alive`. `test/health_problems_test.dart` gained
two regression tests (a payload with `led_stall: 9751` **and**
`led_stalled: false` must be EMPTY; `led_stalled` fires only on a real boolean
`true`, not `1`/`"yes"`/`null`); **6/6 pass** under `flutter test`.
⚠️ **Not in any APK yet** — no `pubspec.yaml` version bump, no build, no
`app-vX.Y.Z` GitHub release, no `../app-release.json` bump. The app self-installs
OTA on Petr's phone, so **the release needs his approval**. Record:
`../../docs/2026-08-13-led-stall-verdict-and-progress-window.md`.

## Setup wizard (onboarding step 1, added 2026-07-13 — device side released in v1.9.0)

`lib/setup/` ships an 8-screen wizard (welcome / cables / find / confirm-color /
wifi / name-room / theme / outro) that provisions an unconfigured Q over
**BT RFCOMM** (`../PROTOCOL.md` §8): a Kotlin platform channel `nexusq/btsetup`
does scan/connect/newline-JSON lines, Dart `lib/setup/bt_setup_client.dart` speaks
the envelope, and `pairing_color.dart` stays bit-identical to the device's Python
via the shared vectors `../pairing-color-vectors.json`. Entry points: an **NFC
tap** (the payload is connection-info JSON, §7 — an unprovisioned device routes
into the wizard with the MAC prefilled) and **"Set up new device"** on the connect
gate.

**✅ Status 2026-07-15 (app 1.1.1+5, device **v1.9.0** — released, hardware-accepted):**
BT onboarding works end-to-end from a fresh flash (NFC tap → bond → RFCOMM → WiFi
join → `finishSetup`). Final acceptance on a fresh `v1.9.0-rc5` flash: tap delivered
→ **bond first try (0 failed attempts)** → WiFi joined → pairing window auto-closed
→ `NFC: released preferred` on connect.

### The NFC claim is the tap (1.1.1+5, measured 2026-07-15)

**Routing alone is not enough.** The phone sits in Android 15 **observe mode** and
deliberately never answers a reader's field: `MSG_RF_FIELD_ACTIVATED` /
`_DEACTIVATED` cycling ~150 ms, **no APDU ever reaching `NqHceService`**. The
platform drops observe mode for the **PREFERRED** service when it declares
`shouldDefaultToObserveMode="false"` (ours does) — **so `setPreferredService` IS the
tap**, not an optimisation.

It is therefore claimed **only where a tap is expected**: `setTapCapture` is driven
from Dart, and only the **connect screen** (the "waiting to be tapped" state) asks
for it. It is dropped on connect, on dispose and on every `onPause`; the HCE
component ships `android:enabled="false"`, so a **closed app has ZERO NFC surface**
(previously ANY open app claimed NFC priority, including while just playing music).

| state | preferred | observe mode | AID routed |
|---|---|---|---|
| app closed / backgrounded | `null` | `true` | 0 |
| app on the connect screen | ours | `false` | 1 |

Observe mode **returns to `true` when we let go** — the phone is not left in a
payment-hostile state.

⚠️ **Motivation, and its UNPROVEN status:** the user's contactless payment failed
twice, only ever after a dev session. This is **NOT a confirmed root cause** — it is
**risk reduction**. The NFC telemetry shows observe mode toggled only by
`com.android.nfc` / `com.google.android.gms`, **never by our uid**, and it returns to
`true` on its own. **If payment fails again, capture `dumpsys nfc` AT THE MOMENT OF
FAILURE.**

> ⚠️ **Bond FIRST, then open the socket.** The app calls `createBond()` and waits for
> `BOND_BONDED` **before** `createRfcommSocketToServiceRecord` (the **secure**
> variant; the device profile is `RequireAuthentication=True`, so the PSK is
> encrypted in flight). Letting the socket bond **on demand** is a trap: Android's
> implicit bond against an unbonded Just-Works peer forms and immediately collapses
> (`bonding_attempt_complete status 0x5` → `0x0e`), RFCOMM never reaches the daemon,
> and Android shows a **misleading "incorrect PIN"** toast — *there is no PIN in a
> Just-Works flow*. This was one of the two root causes found 2026-07-15 (the other
> was device-side: `blueman-applet`'s DisplayYesNo agent hijacking SSP).

Also this session: find-device **list overflow fixed** (a `Column` can't scroll →
yellow overflow stripes with many BT devices); connect-gate **ring re-centred** (a
non-positioned `Stack` child gets loose constraints and parks at `topStart` →
`Positioned.fill`). Earlier (2026-07-14): NFC-tap dedup guard (the Q re-emits the
payload ~8 s → the wizard was restarting), BT permission requested inside
`connect()`, confirm-color retry, outro de-flicker, welcome-sphere polish, and a
**build stamp** (`lib/build_info.dart`, shown on the connect gate + welcome).

**Known flake (OPEN):** pairing needed **2 failed attempts before succeeding** on the
fresh-flash run. Not root-caused; suspicion only — the 30 s `ensureBonded` timeout
(the phone log shows a ~27 s gap before the successful bond) and/or a stale
phone-side bond. See
`../../docs/2026-07-15-bt-onboarding-root-caused-blueman-agent-and-bond-first.md`.

**Stock imagery:** the original Google setup assets are copyrighted and
gitignored — run `../../scripts/extract-stock-assets.sh` (needs the private stock
APKs) to populate `assets/stock/`; without it the wizard still builds and runs
(tracked `.keep` placeholders + icon fallbacks).

**mDNS notes:** discovery works on Android/iOS/desktop on the same subnet. On **Android/desktop**
it is `package:multicast_dns` (Android multicast perm configured). On **iOS** it is **NOT**
`multicast_dns` — iOS 14+ refuses the raw port-5353 socket without the restricted
`com.apple.developer.networking.multicast` entitlement (was wrongly claimed working here;
corrected 2026-08-03) — discovery goes through the native Bonjour channel instead (see the iOS
section above). On **web** there are no raw sockets, so discovery is skipped — use the manual
host field or `NEXUSQ_MOCK`. On **sandboxed macOS** mDNS also needs that same multicast
entitlement (a provisioning-profile add-on); without it, use the manual host field (direct TCP
works).

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
- `mqtt/` — `mqtt_settings.dart` (broker creds in the platform secure store) +
  `health_mqtt.dart` (the `nexusq/health/#` subscriber feeding
  `screens/health_screen.dart` — see "Health panel" above).

## v1 scope

Minimal remote: volume/mute, LED theme + brightness, now-playing + transport. Everything else in
the RE triage (outputs, fixed-level, sync delay, calibration, multi-room) extends the same protocol
later. The real device bridge (`nexusq-control`) shipped in v1.6.3 (was "the next piece"
when this was written) — see `../PROTOCOL.md` §6 and `../../userspace/nexusq-control/`.
