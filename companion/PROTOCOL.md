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
  `id=<stable device id>`.
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
  "theme": "spectrum",
  "nowPlaying": { "playing": true, "artist": "...", "track": "...", "album": "...",
                  "artUrl": "...", "source": "spotify" } }
```

### Volume / mute  (→ real ALSA mixer, see §6)
| Method | params | result | Event emitted |
|---|---|---|---|
| `setVolume` | `{ "volume": 0..100 }` | `{ volume, muted }` | `volumeChanged` |
| `adjustVolume` | `{ "steps": int }` | `{ volume, muted }` | `volumeChanged` |
| `setMuted` | `{ "muted": bool }` | `{ volume, muted }` | `volumeChanged` |
| `toggleMute` | — | `{ volume, muted }` | `volumeChanged` |

### LED ring  (→ nexusqd Unix socket `/run/nexusqd.sock`)
| Method | params | result | Event |
|---|---|---|---|
| `setTheme` | `{ "theme": "<name>" }` | `{ theme }` | `themeChanged` — names from §3.2 of the RE doc (spectrum/warm/cool/blue/smoke/off/trackinfo) |
| `listThemes` | — | `{ "themes": [ {name, colors[], display, led, mode} ] }` | — |
| `setBrightness` | `{ "brightness": 0..255 }` | `{ brightness }` | `brightnessChanged` — **new**: a software scalar applied in nexusqd `frame_pack` |

### Now-playing  (→ librespot `--onevent`, see §6)
| Method | params | result | Event |
|---|---|---|---|
| `getPlayState` | — | `nowPlaying` object | `nowPlayingChanged` (pushed on every librespot track/state change) |
| `playPause` | — | `{ playing }` | `nowPlayingChanged` — transport control via librespot |
| `next` / `previous` | — | `{ }` | `nowPlayingChanged` |

### Device info
| Method | params | result |
|---|---|---|
| `getDeviceInfo` | — | `{ name, model:"steelhead", serial, swVersion }` |

## 5. Reserved for later (not v1)
`hello`/pairing handshake + token, multi-room grouping, output routing (HDMI/analog/SPDIF),
fixed-volume line-out, sync delay, calibration, the stock UDP beacon for cross-compat. All extend
this same envelope (new `method`/`event` names) without breaking v1 clients.

## 6. Device-side wiring (informative — see the gap analysis in the RE doc §9)
- **Volume/mute** → an ALSA control. v1 plan: add an ALSA `softvol` (or use the TAS5713 hw mixer
  control if usable), bind `librespot --mixer alsa --alsa-mixer-control <name>` so Spotify-Connect
  volume and companion volume are the *same* knob, and read/write it via `amixer`/libasound.
- **LED theme** → write `theme <name>` to `/run/nexusqd.sock` (already supported).
- **LED brightness** → **new** nexusqd command + a software brightness scalar in `frame_pack`.
- **now-playing** → `librespot --onevent <hook>` publishes track/artist/album/art + play state to
  the bridge; transport via librespot.
- **state readback** → the bridge owns current state (nexusqd's `status` is unimplemented); it
  caches what it sets + what librespot/ALSA report.

The bridge is a small standalone daemon (keeps the nexusqd render loop lean); it owns the LAN
socket + mDNS + ALSA + librespot glue and talks to nexusqd over the existing Unix socket.
