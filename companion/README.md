# companion/ — modern Nexus Q companion app

A new, modern companion app for the **postmarketOS / `nexusqd`** Nexus Q. The original Google
"Nexus Q" Android app (`com.google.android.setupwarlock`) is dead — its entire setup/control flow
depended on Google's Android@Home cloud, which was decommissioned in 2013, so it can no longer even
finish pairing a device.

This app replaces it for a Q we now fully control on the local network.

## Status

**Shipped — v1.6.3 (2026-06-30), verified live on hardware.** _(v1.6.5, 2026-07-01: the
bridge is now reachable over **WiFi** — the app's normal path — via a new
`../pmos/device-google-steelhead/55_nexusq-control.nft` opening TCP 45015 on `wlan*` (was
previously USB-gadget-net only); a **color theme is now a *breathing override*** (`setTheme`
→ `breathe R G B`, the compositor manual layer pulsing in the theme hue, always visible)
instead of a static solid; a separate **VISUALIZATION picker** selects one of the 5
music-reactive scenes (`setScene`/`listScenes` → `auto` + `scene 0..4`), shown while audio
plays; and an **app-mute now lights the device mute LED** (the volume/mute path also sends
`nexusqd muted 0|1`). See
`../docs/2026-07-01-librespot-softvol-bootstrap-and-breathe-scenes.md`.)_ The Flutter
companion (`app/`) and its device-side LAN bridge (`nexusq-control`,
`../userspace/nexusq-control/`, aport `../pmos/nexusq-control/`) are done: the app
auto-discovers the Q over mDNS and controls the **audio output** (speaker / optical
SPDIF / HDMI — `listOutputs`/`setOutput`, a Holo-dark segmented control · v1.6.15),
**volume/mute** (since v1.6.15 the active PulseAudio output's sink — input-agnostic,
was one ALSA softvol), **LED color theme (breathing) + brightness**, the **music
visualisation**, and shows **now-playing**. _(Since v1.6.15 audio is PA-centric:
librespot is a PulseAudio input and the output is the PA default sink; see
`../docs/2026-07-07-audio-outputs-spdif-mcbsp2-and-pa-routing.md`.)_ _(v1.7.0 adds two
things: an **NFC tap-to-send receiver** — the app runs a HostApduService so the Q
(the NFC reader) can push a short text onto the phone on a tap, shown as a SnackBar,
see `../docs/2026-07-08-nfc-tap-to-send-reverse-hce.md` + [`PROTOCOL.md`](PROTOCOL.md) §7;
and **auto-reconnect on resume/drop** so backgrounding the app no longer needs an
app-kill to recover the connection.)_ _(**Onboarding step 1 implemented 2026-07-13,
targets v1.9.0 — committed, NOT yet in a flashed image:** an 8-screen **setup wizard**
(welcome/cables/find/confirm-color/wifi/name-room/theme/outro, with the original stock
imagery via `../scripts/extract-stock-assets.sh` — Google-copyright assets gitignored,
fresh clones fall back gracefully) provisions the Q's WiFi over **BT RFCOMM**
([`PROTOCOL.md`](PROTOCOL.md) §8; Kotlin `nexusq/btsetup` channel + Dart
`BtSetupClient`; pairing-color parity via `pairing-color-vectors.json`), entered from
an **NFC tap** — the tap payload is now live connection-info JSON (§7), so a
provisioned tap auto-connects and an unprovisioned one jumps into the wizard — or
"Set up new device" in the app. See
`../docs/2026-07-13-onboarding-step1-implementation.md`.
**✅ Status 2026-07-15 (built + flashed as v1.9.0-rc4, hardware-ACCEPTED; all
UNCOMMITTED, NOT tagged): BT onboarding works autonomously from a fresh flash.**
It was two independent bugs, both ours: `blueman-applet`'s **DisplayYesNo** agent
forced SSP into **Numeric Comparison** (an unanswerable dialog on the Q's HDMI
desktop → every bond timed out), and the app let the RFCOMM socket **bond on
demand** (Android's implicit bond collapses → the misleading "incorrect PIN"
toast). Now: the device runs one **permanent** `NoInputNoOutput` agent
(`nexusq-btagent`) and the app **bonds explicitly first**, then opens a **secure**
RFCOMM socket (channel 22, `RequireAuthentication=True`) — so the **WiFi PSK is
encrypted in flight** and the same bond serves **A2DP**. Record:
`../docs/2026-07-15-bt-onboarding-root-caused-blueman-agent-and-bond-first.md`.)_ The original app was reverse-engineered first — the full feature catalog, the
three local wire protocols (discovery / pairing / control RPC), and a keep/modernize/drop/add
triage live in [`../docs/2026-06-30-companion-app-RE.md`](../docs/2026-06-30-companion-app-RE.md).

Decompiled originals (non-redistributable Google code) are kept out of this public repo, under
`private/nexusq-original/companion/` (gitignored).

## What v1 ships

The control surface distilled from the RE: **master volume/mute**, **LED color theme
(breathing hue) + brightness**, the **music visualisation** (5 scenes), **now-playing**, and
device/state readback — over the v1 protocol ([`PROTOCOL.md`](PROTOCOL.md), line-delimited
JSON on TCP 45015, mDNS `_nexusq._tcp`), bridged to `nexusqd` + ALSA softvol +
`librespot --onevent` by `nexusq-control`.

**Transport (play/pause/next) is `unavailable` in v1** (librespot has no local transport API —
control happens from the Spotify app). Deferred to a future protocol revision (PROTOCOL.md §5):
output routing (HDMI/analog/S-PDIF), fixed-volume line-out, A/V sync delay, pairing/auth.
