# nexusq-control protocol v1 (companion ↔ device)

The contract between the **device-side control bridge** (`nexusq-control`, runs on the pmOS Nexus Q)
and the **companion app** (cross-platform / Flutter). Both ends implement this document.

Design basis: the reverse-engineered original control RPC (see
`docs/2026-06-30-companion-app-RE.md` §3.1) — we keep its *action/field vocabulary* but replace
the bespoke TLV-over-mutual-TLS mechanism with something single-box-appropriate, since we now own
both ends on a trusted LAN.

## 1. Transport

- **TCP**, line-delimited **JSON** (one compact JSON object per line, `\n`-terminated, UTF-8).
  Chosen over the original TLV framing for debuggability (`nc`/`websocat`-friendly) and trivial
  cross-platform client code.
- Default port **`afd7` → 45015** (decimal; `0xAFD7`, mnemonic "A@home" — avoids the 1100–1120
  range and well-known ports). Configurable.
- One connection carries **requests** (client→device), **responses** (device→client), and
  **events** (device→client, unsolicited). Multiple clients may connect concurrently; the bridge
  fans events to all.
- v1 trust model: **trusted LAN, no auth** (matches the original's effectively-open client side).
  A future `hello`/pairing handshake slot is reserved (§5) but not required in v1.

## 2. Discovery

- **mDNS / DNS-SD**: the bridge advertises **`_nexusq._tcp.local`**, instance name = device name
  (default `"Nexus Q"`), TXT records: `proto=1`, `name=<device name>`, `model=steelhead`,
  `room=<room>`, `id=<stable device id>`.
- The companion browses `_nexusq._tcp` and connects to the resolved host:port.
- (Optional/bonus, not v1) also answer the stock §1 UDP beacon so the *original* app could discover
  the device. Deferred.

## 3. Message shapes

All messages are a single JSON object.

**Request** (client→device):
```json
{ "id": 7, "method": "setVolume", "params": { "volume": 42 } }
```
- `id`: client-chosen integer, echoed in the matching response. Omit `id` for fire-and-forget.
- `method`: one of §4. `params`: method-specific object (may be omitted when empty).

**Response** (device→client), correlated by `id`:
```json
{ "id": 7, "ok": true, "result": { "volume": 42, "muted": false } }
{ "id": 7, "ok": false, "error": { "code": "bad_params", "message": "volume out of range" } }
```
Error codes: `bad_params`, `unknown_method`, `unavailable` (subsystem not ready, e.g. librespot
down), `internal`.

**Event** (device→client, no `id`):
```json
{ "event": "volumeChanged", "data": { "volume": 42, "muted": false } }
```

## 4. v1 methods & events — the minimal remote

Scope v1 = volume/mute + LED theme/brightness + now-playing + state readback. Maps onto the RE'd
vocabulary (`setMasterVolume`/`getMasterMute`/`setBrightness`/`setTheme`/`getPlayState`).

### State
| Method | params | result | Notes |
|---|---|---|---|
| `getState` | — | full state object (below) | one-shot snapshot; the bridge also pushes events on change |
| `subscribe` | `{ "events": ["*"] }` | `{ "subscribed": [...] }` | opt into event stream (default: all) |

**Full state object** (also the shape of `getState.result`):
```json
{ "volume": 42, "muted": false,
  "brightness": 200,
  "theme": "blue", "scene": "waveform",
  "output": "speaker",
  "nowPlaying": { "playing": true, "artist": "...", "track": "...", "album": "...",
                  "artUrl": "...", "source": "spotify" } }
```
- `output`: id of the active audio output (the current PulseAudio default sink) —
  one of `speaker` (TAS5713 banana terminals) / `spdif` (optical) / `hdmi`.

### Volume / mute  (→ the active output's PulseAudio sink + nexusqd mute LED, see §6)
| Method | params | result | Event emitted |
|---|---|---|---|
| `setVolume` | `{ "volume": 0..100 }` | `{ volume, muted }` | `volumeChanged` |
| `adjustVolume` | `{ "steps": int }` | `{ volume, muted }` | `volumeChanged` |
| `setMuted` | `{ "muted": bool }` | `{ volume, muted }` | `volumeChanged` — also drives the device mute LED via nexusqd `muted 0\|1` |
| `toggleMute` | — | `{ volume, muted }` | `volumeChanged` — also drives the device mute LED |

Volume/mute act on the **currently-active output's PA sink** (input-agnostic —
follows the selected output, and applies to any input feeding it).

### Audio output  (→ PulseAudio default sink + move-sink-input, see §6)
| Method | params | result | Event emitted |
|---|---|---|---|
| `listOutputs` | — | `{ "outputs": [ {id, label, sink, available} ], "active": "<id>" }` | — |
| `setOutput` | `{ "output": "<id>" }` | `{ output }` | `outputChanged` — also re-emits `volumeChanged` (new sink's level/mute) |

Output ids: `speaker` ("Reproduktor", TAS5713 banana terminals) · `spdif`
("Optický výstup", optical S/PDIF) · `hdmi` ("HDMI", listed only when a real HDMI
sink is present — it is usually `PULSE_IGNORE`'d). `setOutput` errors `bad_request`
for an unknown/unavailable id. Switching the output is **input-agnostic**: the
bridge sets the PA default sink (for new streams) **and** moves every existing
sink-input onto it (so a currently-playing stream follows). As a hardware-amp
safety, the class-D TAS5713 amp is powered on only when `speaker` is active and
switched off for `spdif`/`hdmi`.

### LED ring  (→ nexusqd Unix socket `/run/nexusqd.sock`)
| Method | params | result | Event |
|---|---|---|---|
| `setTheme` | `{ "theme": "<name>" }` | `{ theme }` | `themeChanged` — a color theme is a **breathing override** (blue/warm/cool/rose/smoke/off) via nexusqd `breathe R G B` (a manual-layer pulse in the theme hue, always visible); `off` blanks the ring |
| `listThemes` | — | `{ "themes": [ {name, label} ] }` | — |
| `setScene` | `{ "scene": "<name>" }` | `{ scene }` | `sceneChanged` — **new**: picks the music-reactive visualisation (waveform/waveformsolid/circles/pointmorph/starfield) via nexusqd `auto`+`scene 0..4`; shown while audio plays |
| `listScenes` | — | `{ "scenes": [ {name, label, index} ] }` | — |
| `setBrightness` | `{ "brightness": 0..255 }` | `{ brightness }` | `brightnessChanged` — a software scalar applied in nexusqd |

### Now-playing  (→ librespot `--onevent`, see §6)
| Method | params | result | Event |
|---|---|---|---|
| `getPlayState` | — | `nowPlaying` object | `nowPlayingChanged` (pushed on every librespot track/state change) |
| `playPause` | — | `{ playing }` | **`unavailable` in v1** — librespot is a Spotify-Connect receiver with no local transport API; control from the Spotify app. Reserved (§5) |
| `next` / `previous` | — | `{ }` | **`unavailable` in v1** — see `playPause`. Reserved (§5) |

### Device info
| Method | params | result |
|---|---|---|
| `getDeviceInfo` | — | `{ name, model:"steelhead", room, serial, swVersion }` |
| `startSetupMode` | — | `{ started: true }` — arms `/run/nexusq-setup.force` and starts `nexusq-setupd` (BT re-provisioning; see §8). Errors `unavailable`. |

## 5. Reserved for later (not v1)
`hello`/pairing handshake + token, multi-room grouping, fixed-volume line-out, sync delay,
calibration, the stock UDP beacon for cross-compat. All extend this same envelope (new
`method`/`event` names) without breaking v1 clients. _(Output routing — speaker/optical/HDMI —
graduated from reserved to implemented: see `listOutputs`/`setOutput` above.)_

## 6. Device-side wiring (informative — see the gap analysis in the RE doc §9)
- **Audio topology** → PulseAudio is the hub: each **input** (librespot now; BT-A2DP / Tidal /
  casting later) is a PA client, and the **output** is the PA default sink. PA runs in the
  uid-10000 `user` session; the root bridge reaches it via `pactl` with `PULSE_SERVER`/`PULSE_COOKIE`.
- **Volume/mute** → `pactl set-sink-volume`/`set-sink-mute` on the **active output's sink** (read
  back with `get-sink-volume`/`get-sink-mute`), so the knob is input-agnostic and follows the output.
  Mute also sends nexusqd `muted 0|1` so the device **mute LED** matches the app (the same LED the
  hardware mute key lights). _(Follow-up tuning: the TAS5713 amp gain is very hot/steep — app ~8% is
  already deafening — so a usable-range gain cap on the TAS5713 `Master`/`Speaker` control is planned;
  v1 is plain linear %.)_
- **Output routing** → `pactl set-default-sink <sink>` (new streams) **+** `move-sink-input` for every
  current sink-input (so a playing stream follows). Known sinks: `alsa_output.platform-sound-tas5713.*`
  → `speaker`, `alsa_output.platform-sound-spdif.*` → `spdif`, an HDMI sink → `hdmi` (usually
  `PULSE_IGNORE`'d). The class-D TAS5713 amp is toggled on/off (`amixer sset Speaker`) so it is silent
  unless it is the active output.
- **LED theme** → a color theme is a **breathing override**: the bridge sends `breathe R G B`
  to `/run/nexusqd.sock`; nexusqd pulses the compositor manual layer (priority 8) in that hue with
  the idle-screensaver throb, **always visible** (over the music visualizer / a blanked screensaver);
  `off` blanks. _(An earlier idle-screensaver-retint design was reverted — invisible once blanked / while music played.)_
- **Visualisation** → `auto` + `scene 0..4` selects one of the 5 music-reactive scenes (priority 7,
  shown while audio plays — below the breathing override).
- **LED brightness** → a nexusqd `brightness` command + a software brightness scalar.
- **now-playing** → `librespot --onevent <hook>` publishes track/artist/album/art + play state to
  the bridge (read-only metadata). **Transport (playPause/next/previous) is `unavailable` in v1** —
  librespot exposes no local transport API; control happens from the Spotify app.
- **state readback** → the bridge owns current state (nexusqd's `status` is unimplemented); it
  caches what it sets + what librespot/ALSA report.

The bridge is a small standalone daemon (keeps the nexusqd render loop lean); it owns the LAN
socket + mDNS + ALSA + librespot glue and talks to nexusqd over the existing Unix socket.

## 7. NFC tap-to-send (out-of-band — NOT over this TCP protocol) — v1.7.0

Separate from the LAN control channel above: when you **tap the phone on the Q's
dome**, the Q sends a short UTF-8 text to the phone over **NFC**, shown as a SnackBar
in the app. This does not use the TCP/JSON envelope; it is a distinct NFC APDU link.

- **Direction / roles: reverse-HCE.** The PN544 (2011) can't host-card-emulate (its
  card-emulation RF path needs a hardware Secure Element this device lacks) and Android
  Beam is gone, so the **phone runs a HostApduService (HCE)** and the **Q is the ISO-DEP
  reader** (device daemon `nexusq-nfc-send`). Data flows **Q → phone** as APDUs.
- **AID:** `F0010203040506` (custom, category `other`).
- **Wire protocol (both ends implement exactly this):**
  1. `SELECT` by AID: `00 A4 04 00 07 F0 01 02 03 04 05 06 00` → phone answers `90 00`
     iff the AID matches (else `6A82`).
  2. Payload: `80 10 00 00 <Lc> <Lc UTF-8 bytes>` → phone extracts the text, shows it,
     answers `90 00`. Unknown INS → `6D00`.
- **App side:** `NqHceService` (HostApduService) + `apduservice.xml` — note
  **`android:shouldDefaultToObserveMode="false"`** (Android 15 otherwise defaults HCE to
  observe-mode and never answers), `requireDeviceUnlock/ScreenOn="false"`. `HceBridge`
  persists the last message with **`.commit()` (not `apply()`)** and hands it to Flutter;
  `MainActivity` claims `setPreferredService` while foreground; `HceListener` renders it.
- **Requires** the companion app **installed + foreground**, screen on; **tap and hold
  steady ~5–10 s** (the reader's RATS activation NOKs if the phone moves).
- **Payload** (since step-1 onboarding): compact JSON connection info, rebuilt per tap:
  `{"v":1,"bt":"<BT MAC>","host":"<hostname>","ip":"<wlan0 IPv4>"|null,"prov":true|false}`.
  The app parses it: `prov=false` → jump into the setup wizard and connect over BT to `bt`;
  `prov=true` → connect over LAN to `ip` (fallback `<host>.local`). A non-JSON payload is
  still displayed as a plain text SnackBar (`NQ_NFC_MESSAGE` override, older devices).
- Full design + the enabling kernel fix: `../docs/2026-07-08-nfc-tap-to-send-reverse-hce.md`.
