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
BT-client and pairing-color tests — **still 14 as of 2026-07-15**); `flutter analyze`
is clean.

> ⚠️ **`lib/screens/devices_screen.dart` (1.2.0+7) has NO tests of its own** — the 14
> predate it and none cover it. It was verified on hardware only (Petr, 2026-07-15).

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
> setup onboarding release; `1.1.1+5` shipped alongside device **v1.9.0**, and
> **`1.2.0+7`** — the Devices screen — alongside device **v1.10.0**.) Gradle reads
> versionName/versionCode straight from `pubspec.yaml`.

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
