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
auto-discovers the Q over mDNS and controls **volume** (one ALSA softvol shared with
Spotify-Connect), **LED color theme (breathing) + brightness**, the **music visualisation**,
and shows **now-playing**. The original app was reverse-engineered first — the full feature catalog, the
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
