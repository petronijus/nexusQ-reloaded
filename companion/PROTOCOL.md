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

## 8. Setup transport (BT provisioning) — v1.8.x onboarding

A **second transport for the same envelope** (§3), used only before the device has a
WiFi profile: the companion app carries the device through WiFi join + naming over
**Bluetooth RFCOMM** instead of the LAN TCP socket of §1. Implementation:
`userspace/nexusq-setupd/nexusq-setupd` (device side); the app's Kotlin BT RFCOMM
platform channel is the client (see the onboarding plan, Task 5/Task 9–10).

### 8.1 Transport

- **BlueZ Profile1 RFCOMM server.** `nexusq-setupd` registers `org.bluez.Profile1`
  with `ProfileManager1.RegisterProfile`, UUID **`8e1f0cf7-508f-4875-b62c-fcd67e2f3d3a`**,
  fixed **channel 3**, `Role: server`, `RequireAuthentication: true`,
  `RequireAuthorization: false`. `RequireAuthentication` means BlueZ requires
  link-layer **encryption** on the ACL link (established by the Just-Works pairing
  below) before it hands the daemon the connection — not an app-layer credential.
- BlueZ delivers each incoming connection as a **file descriptor** via
  `Profile1.NewConnection(device, fd, properties)`; the daemon wraps it in a
  `socket.socket(fileno=...)` and runs one reader thread per connection
  (`_client_loop`).
- **Framing: the same newline-JSON envelope as §3** — one compact JSON object per
  line, `\n`-terminated, UTF-8, request/response/error shapes identical to §3
  (`{"id", "method", "params"}` → `{"id", "ok": true, "result"}` /
  `{"id", "ok": false, "error": {"code", "message"}}`). `id`-less requests are
  fire-and-forget (no response line), matching §3. There is no `event` push channel
  in v1 of the setup transport — every result is a direct response.
- No app-layer auth beyond the BT link encryption above: v1 trust model is
  "whatever paired over BT during the setup window," mirroring §1's "trusted LAN,
  no auth" for the same reason (single-user appliance, time-boxed exposure — see
  the accepted-risk note in §8.6).

### 8.2 When it runs

`nexusq-setupd.service` (`Type=simple`, `Restart=on-failure`, `RestartSec=3`) is
gated by `ExecCondition=/usr/bin/nexusq-setup-needed`, which exits 0 (run) when
**either**:
- `/run/nexusq-setup.force` exists, **or**
- no `802-11-wireless` NetworkManager connection profile exists yet (fresh/unprovisioned
  boot — `nmcli -t -f TYPE connection show`).

and exits 1 (skip) otherwise. Two entry points follow from this:
- **Unprovisioned boot**: no WiFi profile → the condition is satisfied on every
  boot until `setWifi` succeeds and creates one.
- **On demand**: the LAN bridge's `startSetupMode` (§4, Device info table) touches
  the force flag and runs `systemctl start nexusq-setupd.service` — re-enters setup
  mode even on an already-provisioned device (re-pairing/reconfiguration).
- **Crash re-arm**: `_run_transport()` writes the force flag itself at the top of
  its own run (not just `startSetupMode`), so `Restart=on-failure` re-running
  `ExecCondition` after a crash still finds it set and restarts — a daemon bug
  mid-wizard (e.g. after `setWifi` already created a profile) does not strand the
  user outside setup mode. The flag is unlinked only on a **clean** exit (idle
  timeout or `finishSetup`); a crash leaves it for the restart to consume.
- **Inactivity timeout**: `NEXUSQ_SETUP_TIMEOUT` (default **600 s**) since the last
  `core.touch()` (i.e. the last handled request) → the GLib main loop quits and the
  daemon exits cleanly.
- **Clean-exit cleanup** (in the `finally` around `loop.run()`, always runs):
  `Discoverable` set back to `false`; the LED ring returns to `auto` **unless** a
  theme was chosen via `setTheme` during this session (in which case `finishSetup`
  already applied it and it is left alone); `/run/nexusq-setup.force` unlinked.

### 8.3 Methods

Same request/response shapes as §3. Errors use codes analogous to §3's
(`unknown_method`, `unavailable`, `internal`) plus setup-specific codes
`bad_request`, `wrong_password`, `not_found`, `timeout` for malformed params /
WiFi-join failures.

> Note: the setup daemon's code for malformed params is spelled `bad_request`
> (the implementation's exact string) — not §3's `bad_params`.

| Method | params | result | Errors |
|---|---|---|---|
| `getDeviceInfo` | — | `{ model:"steelhead", btMac, swVersion, provisioned: bool, proto: 1 }` | — |
| `confirmColor` | — | `{ "rgb": [r,g,b] }` — drives the LED ring solid in the pairing color (§8.4) via nexusqd `set R G B` | `unavailable` (nexusqd unreachable) |
| `scanNetworks` | — | `{ "networks": [ {ssid, signal, security} ] }` — deduped by SSID (strongest kept), `security` is `wpa-psk` or `open` | `unavailable` (nmcli scan failed) |
| `setWifi` | `{ ssid, psk?, security?: "wpa-psk"\|"open", hidden?: bool }` | `{ ok: true, ip, mdns }` — `ip` is the joined `wlan0` IPv4 (or `null`), `mdns` is `"<hostname>.local"` | `bad_request` (no ssid / wpa-psk without psk), `wrong_password`, `not_found`, `timeout`, `internal` (profile create/other nmcli failure) |
| `getNetworkState` | — | `{ "state": "idle"\|"associating"\|"online", "ip"? }` — `ip` present only when `state:"online"` | — |
| `setName` | `{ name, room?: string }` | `{ name, room, hostname, mdns }` — `hostname` is the sanitized form of `name` (§8.5), `mdns` is `"<hostname>.local"`; also sets the system hostname and restarts `nexusq-control`(+`librespot` if the user session exists) so the new name is re-advertised | `bad_request` (missing/blank name, or non-string room), `internal` (hostname change failed) |
| `setTheme` | `{ theme: "blue"\|"warm"\|"cool"\|"rose"\|"smoke"\|"off" }` | `{ theme }` — applies the color theme's `breathe`/`off` nexusqd command immediately and remembers it for `finishSetup` | `bad_request` (unknown theme), `unavailable` (nexusqd rejected the command) |
| `finishSetup` | — | `{ done: true }` — green success breathe, 2 s hold, then the chosen theme (or `auto` if none was set) via nexusqd; marks the session finished, which ends the RFCOMM loop and triggers the clean-exit lifecycle (§8.2) | — |

`setWifi` validates everything (ssid/psk/security) **before** any side effect
(LED, profile delete/create), so a malformed request can never destroy an
existing WiFi profile before failing. On any join failure it deletes the
half-created `wifi` NM profile before returning the error, so a retry starts clean.
WiFi credentials (`psk`) are never logged, and are never allowed into an error
`message` string (nmcli subprocess errors are classified via `classify_nm_error`,
never stringified raw).

### 8.4 Pairing-color contract

`confirmColor` is the visual pairing check: the app and the device independently
derive the **same** color from the device's BT adapter MAC and the user confirms
they match. Contract + cross-language (Python/Dart) test vectors:
`companion/pairing-color-vectors.json`.

Algorithm (one-liner): `hue = ((mac[4] << 8) | mac[5]) % 360`; `rgb = hsv_to_rgb(hue,
s=1.0, v=1.0)`, channels rounded to the nearest int (0–255) — i.e. the last two MAC
octets pick a fully-saturated hue around the color wheel.

### 8.5 LED choreography

| Phase | Command | Trigger |
|---|---|---|
| Setup mode active / joining WiFi | `spin 0 153 204` (stock `#0099CC` "starting up" rotating dot) | daemon start (`_run_transport`), and again at the top of `setWifi` (resumes the spinner after `confirmColor` left a solid color) |
| Pairing confirmation | `set R G B` (solid, the pairing color) | `confirmColor` |
| Theme chosen mid-wizard | `breathe R G B` / `off` (per `THEME_CMDS`) | `setTheme` |
| Setup complete | `breathe 0 200 0` (green), held 2 s, then the chosen theme or `auto` | `finishSetup` |
| Setup abandoned (idle timeout, no `finishSetup`) | `auto` | clean-exit cleanup (§8.2) |

### 8.6 Accepted risk: Just-Works auto-pairing during setup mode

While setup mode is active, `nexusq-setupd` registers a **`NoInputNoOutput`**
BlueZ agent (`org.bluez.Agent1`) and calls `RequestDefaultAgent`, making it the
system's default pairing agent for that window. This agent **auto-accepts**
everything it is asked: `RequestConfirmation` (Just-Works pairing) and
`RequestAuthorization`/`AuthorizeService` (incoming connections/service use) are
all no-ops that return success without any user interaction on the device. This
is deliberate, not an oversight, and is accepted as-is:

- It is **window-limited**: the agent only exists while `nexusq-setupd` runs
  (setup mode only), the adapter is discoverable only for that window, the
  session self-terminates after 600 s of inactivity (§8.2), and `Discoverable`
  is forced off again on every exit path.
- It is **stock-parity behavior** — the original Nexus Q onboarding flow used the
  same Just-Works, no-PIN pairing model; this is not a regression.
- It is **acceptable for a single-user appliance**: there is no persistent
  multi-user trust boundary to protect on this device outside the setup window.
- **The residual risk**: a hostile actor within BT range during an active setup
  window could initiate pairing and have it silently accepted, since the agent
  never prompts or checks anything. This is mitigated in practice by (a) the
  **LED visual-confirm step** (§8.4/`confirmColor`) — the legitimate user compares
  the ring color against the app before proceeding, so a rogue device that pairs
  but can't also produce the matching LED color is caught at that step — and (b)
  the **short exposure window** (idle timeout, and discoverable is normally only
  on for the duration of one onboarding session).

### 8.7 Relationship to NFC (§7)

The NFC tap payload (§7) is how the app discovers *which* transport to use: it
decodes `{"v":1,"bt":"<BT MAC>","host":..., "ip":..., "prov": bool}` and when
`prov` is `false` (no WiFi profile yet), it connects over BT RFCOMM to `bt` using
this §8 transport to run the setup wizard; when `prov` is `true` it instead
connects over the LAN using §1–§4. NFC itself carries no setup-transport
traffic — it only hands the app the address to dial.
