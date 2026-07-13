# Software & Ease-of-Use Phase — Onboarding Design (+ phase decomposition)

**Date:** 2026-07-13 · **Status:** approved design, pre-implementation
**Scope:** the "software / ease-of-use" phase for the Nexus Q (steelhead)
postmarketOS port: app-driven onboarding for a display-less device, music
services, Bluetooth pairing, OTA updates — mirroring the original stock
experience as faithfully as practical, **reusing the original stock imagery**.

## Approved decisions (from brainstorming, 2026-07-13)

| Decision | Choice |
|---|---|
| Onboarding fidelity | **Stock UX, our protocol** — same flow (NFC tap → BT → WiFi creds → LED color pairing) + original graphics; JSON over BT RFCOMM instead of the stock TLV v10 |
| Services to add | AirPlay (shairport-sync), Roon Bridge, Tidal Connect; investigate Google Cast / Miracast (Cast receiver expected infeasible — closed, device certs) |
| BT pairing UX | App button → discoverable window + LED indication + headless Just-Works agent |
| OTA mechanism | **Full-image OTA** (stock-like known states, v1.8.x releases), app-triggered |
| App platform | **Android primary** (NFC + BT Classic RFCOMM possible only there) |
| Extra stock features | Device name + room (with stock icons), fixed volume (line-out), setup outro video + sounds. **Not** doing mic-based A/V sync calibration |
| Baseline assumption | The user has the companion app installed (our reverse-HCE NFC cannot deep-link to Play Store like the stock tag did) |
| Architecture | **Approach A** — extend existing pieces: `nexusq-control` stays the LAN control bridge; new small `nexusq-setupd` owns BT provisioning; NFC daemon payload becomes connection info; Flutter app grows a setup wizard |

## Phase decomposition (approved order)

Each step is its own spec → plan → implementation cycle. This document is the
detailed design for **step 1** only; steps 2–5 record the agreed direction.

1. **Onboarding** (this design) — setup mode + BT provisioning daemon + app
   setup wizard with original assets, incl. naming/room and outro (part of the
   stock setup flow).
2. **BT pairing via app** — rides on step 1's BlueZ infrastructure (agent,
   discoverable, LED indication); A2DP surfaced as a visible input in the app.
3. **Services** — shairport-sync, Roon Bridge, Tidal Connect as PulseAudio
   clients with now-playing integration. Known risk: Roon Bridge and Tidal
   Connect are glibc binaries on musl Alpine → gcompat or container, to be
   designed then. Cast receiver: propose to drop (closed ecosystem, device
   certificates); Miracast: feasibility check only.
4. **OTA full-image via app** — app shows available release; device downloads
   the image and reflashes safely (via a recovery/flasher environment — the
   running rootfs cannot overwrite itself), then reboots.
5. **Polish** — fixed volume (line-out) mode + items falling out of steps 1–4.

---

# Step 1 — Onboarding: detailed design

## 1. Device: setup mode and lifecycle

**Unprovisioned** := no NetworkManager profile of type wifi with credentials
exists (today baked from `private/access/wifi.nmconnection`; public builds have
an empty guarded placeholder, so a freshly flashed public device is
unprovisioned).

**Boot of an unprovisioned device → setup mode:**

- New systemd unit **`nexusq-setupd.service`**, conditioned on "no WiFi
  profile"; also startable on demand via a new LAN bridge method
  `startSetupMode` (later re-provisioning, e.g. WiFi change).
- Setup mode: BT adapter powered + discoverable (no time limit while setup is
  active), RFCOMM profile registered, and the LED ring plays a **setup
  animation — rotating blue dot** (the stock "starting up" visual), driven
  through the existing `nexusqd` socket as a new `setup` theme.
- The USB-RNDIS fallback stays untouched (if setup fails, the device remains
  reachable over cable).

**Successful setup sequence:**

1. App sends WiFi credentials over BT (protocol §2).
2. setupd writes the NM profile (`nmcli`), waits for activation, verifies
   connectivity (DHCP lease + internet reachability).
3. Returns the result to the app with the new IP + mDNS name → the app
   switches to the LAN connection.
4. After `finishSetup` (name/room/theme set): LED success animation,
   discoverable off, setupd exits — only normal operation runs from then on.

**Failure (wrong password etc.):** NM activation fails → setupd deletes the
bad profile, returns a specific error (`wrong_password` / `not_found` /
`timeout`), and stays in setup mode for another attempt.

## 2. Provisioning protocol over BT RFCOMM

**Transport:** BlueZ D-Bus `Profile1` — a custom SPP-style profile with **one
fixed UUID** (our own; stock's 5 rotating SDP UUIDs worked around 2012 Android
bugs and are pointless now). The app connects with an RFCOMM socket to that
UUID. Pairing: **Just Works** (no PIN); setupd acts as an auto-accept agent —
only while in setup mode; after pairing the RFCOMM link is BT-link-layer
encrypted.

**Format:** newline-delimited JSON with the same envelope as
`companion/PROTOCOL.md` v1 (`{"id":…,"method":…,"params":…}` /
`{"id":…,"result":…}` + error objects). Same style → the app shares its client
code between BT and TCP, only the transport differs. Documented as a new
"Setup transport" section of PROTOCOL.md.

**Methods:**

| Method | Purpose |
|---|---|
| `getDeviceInfo` | model, FW version, BT MAC, provisioning state |
| `confirmColor` | device lights a **BT-MAC-derived color** on the ring; the app shows the same color; the user confirms by eye they're talking to the right sphere (stock trick, replicated 1:1 incl. the MAC derivation) |
| `scanNetworks` | WiFi scan from the device → SSIDs + strength + security (app renders stock WiFi icons) |
| `setWifi` | `{ssid, psk, security, hidden}` → NM profile + connect + verification; returns `{ok, ip, mdns}` or an error |
| `getNetworkState` | live state (associating/dhcp/online) for app progress |
| `setName` | `{name, room}` → hostname/mDNS/Spotify/AirPlay name (§4) |
| `setTheme` | LED theme selection during setup |
| `finishSetup` | closes setup mode, plays the success animation |

**Behavior:** if the BT connection drops mid-setup, setup mode keeps running;
the app reconnects and continues (methods are idempotent, the device owns the
state). Credentials are never logged.

## 3. NFC tap

Stock: tap → NDEF with a Play Store link + a record with the BT MAC. Our roles
are inverted (reverse-HCE: the phone emulates the card, the Q reads — the
PN544 cannot do HCE), so the information flow for onboarding (device → phone)
must ride inside the existing ISO-DEP session.

**Design — bidirectional exchange during the tap:** extend the APDU dialogue
between `nexusq-nfc-send` (Q, reader) and `NqHceService` (Android, card): after
SELECT AID the Q sends the phone its **connection info** as a response —
`{bt_mac, hostname, ip?, proto, provisioned}` (compact JSON in the APDU
response, ~250 B budget). The app reacts by state: `provisioned=false` → jump
straight into the setup wizard and connect to the BT MAC from the tap
(skipping BT scan/device pick); `provisioned=true` → connect over LAN to the
IP/mDNS from the tap. This also completes the standing backlog item **"NFC
payload = connection info"** (replacing the static greeting).

**Acknowledged limit:** the tap only works with the app installed and its HCE
service registered — NFC is an **accelerator, not the entry gate**. Primary
discovery remains BT scan (setup) / mDNS (operation).

## 4. App setup wizard + original assets

**Screen flow** (mirrors the stock layouts available in the decompiled APK —
`activity_setup_warlock`, `fragment_first_run`, `activity_wifi_password`, …):

1. **Welcome** — the 36-frame rotating-sphere animation (`q000–q035.png`)
2. **Hook-up** — original cable diagrams (`cables_diagram_01/02.png`)
3. **Find device** — BT scan (or skipped via NFC tap), list of found Qs
4. **Visual confirm** — `confirmColor` screen: "Is the sphere lit this color?"
5. **WiFi** — network list from `scanNetworks` with stock WiFi icons
   (`ic_wifi_signal_1–4` + locked variants), password entry, progress via
   `getNetworkState`
6. **Name + room** — original room icons (bedroom/kitchen/livingroom/garage/
   office/…)
7. **LED theme** — stock themes (`theme_blue/cool/smoke/spectrum/warm/…`,
   definitions available from `res/raw`)
8. **Done** — **`q_outro.mp4` + original sounds**, then the main control screen
   (already over LAN)

**Asset pipeline:** `scripts/extract-stock-assets.sh` extracts the graphics
from the decompiled APK in `private/nexusq-original/` into
`companion/app/assets/stock/` (all densities + raw themes + outro
video/sounds). **The assets are Google copyright — they must not enter the
public repo:** the extract output is gitignored and the app build generates it
locally from `private/` (same pattern as `private/access/wifi.nmconnection`).
A public build without `private/` gets neutral fallback icons (guard in the
script, not a broken build).

**Name + room on the device:** `setName {name, room}` → hostname + avahi
(mDNS `<name>.local`), name in the `_nexusq._tcp` TXT, librespot `--name`,
AirPlay name (once present), room as a TXT key (the app renders the icon).
Hostname sanitization handles diacritics/spaces; the display name stays full.

**BT RFCOMM on Android:** a small dedicated Kotlin platform channel (next to
the existing `NqHceService` — same pattern), not the unmaintained
flutter_bluetooth_serial plugin.

## 5. Error handling and testing

**Device-side errors:**

- Wrong password / network not found / DHCP timeout → specific error code to
  the app, bad NM profile deleted, setup mode continues (§1). The app returns
  the user to the WiFi screen with an explanation.
- BT drop → setupd keeps state; the app reconnects with retry (same heartbeat
  pattern as the LAN client).
- Setup abandoned after WiFi but before `finishSetup` → the device IS online;
  after 10 min of inactivity setupd closes setup mode on its own (WiFi kept,
  name stays default "Nexus Q"). The app finds it via mDNS normally.
- Total setup failure → USB-RNDIS/ethernet fallback persists; `startSetupMode`
  over the LAN bridge allows retrying.
- nexusqd unavailable (no LED animation) → setup still works, just without the
  visual; `confirmColor` returns an error and the app skips that screen.

**Testing:**

- **Protocol tests without HW:** setupd gets unit tests with mocked
  nmcli/BlueZ (pure Python, like the bridge) — parsing, state machine,
  method idempotence.
- **On real HW** (per the "inform every step" rule): delete the WiFi profile →
  reboot → verify setup mode (LED animation, discoverable) → run the whole
  wizard from a phone incl. a deliberately wrong password → verify the end
  state (`nmcli`, hostname, mDNS, LED theme). Ask before any reboot/sound step.
- **Acceptance = definition of done for step 1:** the complete "factory fresh"
  flow on a freshly flashed device.
- The mandatory post-flash diag sweep stays in force.

## Non-goals (step 1)

- iOS onboarding (no BT Classic RFCOMM without MFi; revisit with BLE later if
  ever needed).
- Mic-based A/V sync calibration (explicitly dropped).
- Stock TLV protocol compatibility (the stock app cannot complete setup against
  the dead Google cloud anyway).
- Multi-room / social streaming (needs a second unit; Snapcast declined for
  now).

## Key references

- Stock companion app RE: `docs/2026-06-30-companion-app-RE.md` (BT-RFCOMM TLV
  provisioning §2, control vocabulary §3.1)
- LAN control protocol: `companion/PROTOCOL.md` (v1 envelope; §7 NFC)
- NFC reverse-HCE: `docs/2026-07-08-nfc-tap-to-send-reverse-hce.md`
- Decompiled stock APK + assets: `private/nexusq-original/companion/`
  (`NexusQ-1.0.8.406084.apk`, apktool/jadx trees); archival source
  https://archive.org/details/com-google-android-setupwarlock-8406084-1
- Stock factory image (device-side UI assets): `reverse-eng/factory/inner/` and
  https://archive.org/details/Nexus_Q_Archive
