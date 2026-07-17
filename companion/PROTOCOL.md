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

> ✅ **Bonded + encrypted (2026-07-15, v1.9.0 — released, hardware-accepted).** The
> transport requires authentication: the setup link is a **bonded, encrypted** ACL,
> so the **WiFi PSK never crosses the air in cleartext** (verified: 0 PSK lines in
> the journal). The bond is created by the phone **before** the socket opens
> (§8.6) and **also serves A2DP** — one pairing for both.
>
> _(History: rc3, 2026-07-14, briefly ran **insecure/unbonded**
> `RequireAuthentication=False` as a workaround for a pairing failure **wrongly**
> attributed to a BCM4330 hardware limit. That attribution was WRONG — bonding +
> A2DP work on this controller — and the workaround is **retired**. It was in fact
> **stock parity**: stock never bonded during onboarding and accepted a cleartext
> PSK. We moved beyond stock deliberately. See
> `../docs/2026-07-15-bt-onboarding-root-caused-blueman-agent-and-bond-first.md`.)_

- **BlueZ Profile1 RFCOMM server.** `nexusq-setupd` registers `org.bluez.Profile1`
  with `ProfileManager1.RegisterProfile`, UUID **`8e1f0cf7-508f-4875-b62c-fcd67e2f3d3a`**,
  fixed **channel 22**, `Role: server`, **`RequireAuthentication: true`**,
  `RequireAuthorization: false`.
  - **Channel 22** (was 3): a server-role ext profile only starts its RFCOMM
    listener when a `Channel` is given; **channel 3 collided with the Headset
    profile** (`rfcomm_bind` "Address in use" → the server never started). 22 is clear
    of the Q's audio/PBAP stack (3,9,10,13–17). The app resolves the channel via SDP
    by UUID, so the exact number only has to be free and stable.
  - **`RequireAuthentication: true`** means BlueZ only hands the daemon the RFCOMM
    fd over an **encrypted, bonded** ACL link — established by the Just-Works
    pairing of §8.6. The phone connects with the **secure**
    `createRfcommSocketToServiceRecord`, and **must already be bonded** when it does
    (§8.6 — letting the socket bond on demand is a documented trap).
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
  "whatever bonded over BT during the setup window," mirroring §1's "trusted LAN,
  no auth" for the same reason (single-user appliance, time-boxed exposure — see
  the accepted-risk note in §8.6). No app-layer ECDH is needed for the PSK: the
  bonded link already encrypts it.

### 8.2 When it runs

`nexusq-setupd.service` (`Type=simple`, `Restart=on-failure`, `RestartSec=3`) is
gated by `ExecCondition=/usr/bin/nexusq-setup-needed`, which exits 0 (run) when
**either**:
- `/run/nexusq-setup.force` exists, **or**
- a **SUCCESSFUL** `nmcli -t -f TYPE connection show` lists no `802-11-wireless`
  NetworkManager connection profile (fresh/unprovisioned boot).

and exits 1 (skip) otherwise.

> 🔒 **This check FAILS CLOSED (setupd r4, v1.9.0).** nmcli's **exit code is
> load-bearing**: an earlier version piped it straight into `grep -q` and discarded
> it, so "nmcli failed / NetworkManager is not up yet" was indistinguishable from
> "there is no WiFi profile" → exit 0 → a **provisioned** device arms setup mode and
> advertises itself **discoverable + pairable**. The agent auto-accepts by design
> (§8.6 — nothing attached to this appliance can answer a prompt), so that transient
> hands a passer-by a bond. **Anything other than a successful nmcli listing no wifi
> profile assumes provisioned and stays out of setup mode**; the cost of being wrong
> that way is one `startSetupMode` to re-enter setup, versus an open pairing window
> on a live device.

Two entry points follow from this:
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
  daemon exits cleanly — **but only if the device is already WiFi-provisioned**. If
  it is still unprovisioned when the timeout fires, leaving setup mode would strand
  the device (nothing re-arms it until a reboot), so the daemon **stays discoverable
  and keeps spinning** and resets its activity clock instead of exiting (v1.9.0-rc3,
  2026-07-14).
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
| `finishSetup` | — | `{ done: true }` — green success breathe, 2 s hold, then the chosen theme (or `auto` if none was set) via nexusqd; marks the session finished, which ends the RFCOMM loop and triggers the clean-exit lifecycle (§8.2) | `bad_request` (**not wifi-provisioned yet** — see below) |

> **`finishSetup` is REFUSED unless WiFi is already joined** (v1.9.0, setupd r4). Accepting
> it unprovisioned was a trap: `finished` makes the daemon exit **0**, so
> `Restart=on-failure` does **not** restart it and nothing re-arms setup mode until a
> reboot — **the device is stranded off-network with the wizard gone**. (Same hazard
> the idle-timeout path already guards, §8.2. The app reached this state live on
> 2026-07-15.)

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

The `spin` command takes an optional rotation speed (`spin R G B [rev_per_s]`,
nexusqd r10) so setup phases read as distinct rates (default 0.75 rev/s).

| Phase | Command | Trigger |
|---|---|---|
| Setup mode active / idle-waiting | `spin 0 153 204` (stock `#0099CC` "starting up" rotating dot, default rate) | daemon start (`_run_transport`) |
| Pairing confirmation | `set R G B` (solid, the pairing color) | `confirmColor` |
| Joining WiFi ("working on it") | `spin 0 153 204 0.4` (same blue, **slow**) | top of `setWifi` |
| WiFi joined ("got it!") | `spin 0 220 60 1.6` (**fast green**), briefly, before the wizard moves on | `setWifi` success |
| WiFi join failed | `spin 220 30 30 0.5` (**slow red**, persists until the next attempt re-sends the slow-blue) | any `setWifi` join failure (`_fail_join`) |
| Theme chosen mid-wizard | `breathe R G B` / `off` (per `THEME_CMDS`) | `setTheme` |
| Setup complete | `breathe 0 200 0` (green), held 2 s, then the chosen theme or `auto` | `finishSetup` |
| Setup abandoned (idle timeout, no `finishSetup`) | `auto` | clean-exit cleanup (§8.2) |
| **Pairable OUTSIDE setup** (a manual/anomalous exposure) | `spin 0 153 204` / `auto` | **`nexusq-btagent`**, not setupd (v1.9.0) |

> **The pairing-exposure indicator** (`nexusq-btagent`, 2026-07-15). The invariant
> is **`Pairable == Discoverable`**, so the ring is honest device-wide:
> **spinning blue ⇔ anyone can pair with this Q.** (`Pairable`, not `Discoverable`,
> gates bonding — discovery only affects *inquiry*, and anyone who already knows the
> address can bond a non-discoverable but pairable adapter.) **Ownership rule:**
> btagent only touches the ring when **it** took it — i.e. the adapter became
> discoverable while setupd was *not* running — and never releases a ring it did not
> take, so it cannot wipe the theme `finishSetup` applied. During setup the table
> above (setupd) owns the ring.

### 8.6 Pairing: Just-Works, bond-first — and the accepted risk

**`nexusq-setupd` registers NO agent.** The system's single, **permanent**
`NoInputNoOutput` BlueZ `Agent1` is **`nexusq-btagent`** (a separate package,
running for the whole uptime — A2DP needs a bond long after setup exits). Full
rationale: `../userspace/nexusq-btagent/README.md`.

**Why not a setup-scoped agent (2026-07-15 root cause).** SSP picks its pairing
model from **both** ends' IO capabilities:

| Phone | Nexus Q | Model | Prompt? |
|---|---|---|---|
| DisplayYesNo | `NoInputNoOutput` | **Just Works** | none — bonds silently |
| DisplayYesNo | `DisplayYesNo` | **Numeric Comparison** | **both ends must confirm** |

`blueman-applet` registered a **DisplayYesNo** agent → the second row → an
unanswerable Confirm/Deny dialog on the HDMI desktop (**nothing attached to the Q
can click it**) → every bond timed out (mgmt `0x0e`). And because
`RequestDefaultAgent` is **last-writer-wins**, two agents race for the default
slot. Hence: exactly **one** agent, device-wide (blueman-applet is suppressed since
device r47), and setupd defers to it.

> ⚠️ **Client contract: the phone MUST bond BEFORE opening the socket.**
> Call `createBond()` and wait for `BOND_BONDED`, *then*
> `createRfcommSocketToServiceRecord`. Letting the socket bond **on demand** fails:
> Android's implicit bond against an unbonded Just-Works peer forms and immediately
> collapses (`bonding_attempt_complete status 0x5` → `0x0e`), no link key is ever
> written, RFCOMM never reaches setupd — and Android reports the **misleading
> "incorrect PIN"** toast, *even though no PIN exists in a Just-Works flow*.

**Accepted risk.** The agent auto-accepts everything (`RequestConfirmation`,
`RequestAuthorization`/`AuthorizeService` are no-ops returning success) — for an
input-less appliance that is the only workable model. Accepted as-is:

- **The exposure window is bounded and VISIBLE.** The ring spins blue exactly while
  the Q is pairable. (`Pairable`, **not** `Discoverable`, is what gates bonding —
  bluez leaves `Pairable=true` forever by default, so a ring driven by
  `Discoverable` alone would be a *lie*: dark while still bondable.) The setup session
  self-terminates after 600 s of inactivity (§8.2) and `finishSetup` closes the
  window (`enforcing Pairable=False`).

  > **(was `Pairable == Discoverable` in v1.9.0, now `ring ⇔ Pairable` as of
  > v1.10.0 / 2026-07-15)** — the mirrored invariant was keyed on the wrong
  > property and silently broke OUTBOUND bond persistence. `Pairable` is now off
  > at rest and the ring keys off it directly. See **§9.7**.
- It is **beyond stock parity, not a regression**: the original Nexus Q onboarding
  never bonded at all and sent the PSK in cleartext. We bond and encrypt.
- It is **acceptable for a single-user appliance**: no persistent multi-user trust
  boundary outside the setup window.
- **The residual risk**: a hostile actor within BT range during an active pairing
  window could bond silently, since the agent never prompts. Mitigated by (a) the
  **LED visual-confirm step** (§8.4/`confirmColor`) — a rogue device that pairs but
  can't produce the matching ring color is caught there — and (b) the **short,
  now visibly-indicated exposure window**.

### 8.7 Relationship to NFC (§7)

The NFC tap payload (§7) is how the app discovers *which* transport to use: it
decodes `{"v":1,"bt":"<BT MAC>","host":..., "ip":..., "prov": bool}` and when
`prov` is `false` (no WiFi profile yet), it connects over BT RFCOMM to `bt` using
this §8 transport to run the setup wizard; when `prov` is `true` it instead
connects over the LAN using §1–§4. NFC itself carries no setup-transport
traffic — it only hands the app the address to dial.

## 9. Bluetooth (pairing, both directions) — v1.10.0

The Q has **no screen and no input device**. The app is therefore not a convenience
on top of a settings panel — **it IS the Q's Bluetooth settings panel**. There is no
other way to pair anything to this device.

Two directions, and they are **different flows, not variants of one**:

| Direction | Who initiates | Example | Method |
|---|---|---|---|
| **Inbound** | the phone | a phone pairs for music (A2DP) | `startPairing` → the phone does the rest |
| **Outbound** | **the Q** | the Q pairs a **mouse / keyboard** | `startBtScan` → `pairBtDevice` |

A mouse never connects *to* us: nothing about waiting makes it appear. We must
discover it and call `Pair()` on it. Hence the separate scan/pair vocabulary.

### 9.1 Wiring

`nexusq-control` is **stdlib-only by standing rule** and cannot speak D-Bus, so every
method below is forwarded over a Unix socket to **`nexusq-btagent`**
(`/run/nexusq-btagent.sock`, mode **0600**, newline-JSON), the one component that
owns BlueZ. The bridge is the app's endpoint, not a second Bluetooth stack. btagent's
error codes are already this protocol's vocabulary (`not_found`, `pair_failed`,
`unavailable`, `unknown_method`) and pass straight through; an unreachable socket is
`unavailable`.

> ℹ️ **Reliability (v1.10.1, btagent r4):** the listening socket is opened **once** at
> startup, not per reconcile tick. A prior bug reopened it every 10 s, leaking one fd
> per tick until btagent exhausted its fds (~1024) and crashed with the socket file
> removed — the app then saw every BT call fail as `unavailable`
> (*"bluetooth agent unreachable: No such file or directory"*) every ~3 s while the
> TCP connection itself stayed healthy. `start_control()` is now idempotent.

### 9.2 `bonded` vs `paired` — **`paired` alone LIES**

> ⚠️ **Read `bonded`, never `paired`, to answer "will this survive a reboot?"**

Measured A/B on a real Logitech MX Master 4, same agent, one variable (2026-07-15):

```
Pairable: no   ->  pair "succeeds", Bonded: no,  NO keys stored, gone on restart
Pairable: yes  ->  pair succeeds,   Bonded: yes, [PeripheralLongTermKey] +
                   [IdentityResolvingKey] on disk, SURVIVES restart
```

`Paired: true` with `Bonded: false` is a device that pairs, connects, genuinely
types — and evaporates on reboot. `pairBtDevice` returns both; the app must treat
`bonded: false` as a failure to persist. Full chain: §9.7 and
`../userspace/nexusq-btagent/README.md`.

### 9.3 The pairing window

`startPairing` opens a **bounded, visible** window: the adapter goes `Pairable` +
`Discoverable`, and the ring spins stock blue exactly while it is open.

- **Default 120 s** (`WINDOW_TIMEOUT`) — stock steelhead's own `DiscoverableTimeout`,
  verified in its `/system/etc/bluetooth/main.conf`. `secs` is clamped to 1–600.
- **bluez's own timer closes it**, not ours — so the window still closes if btagent
  is killed mid-window. (Verified 2026-07-15: `openWindow(30)` → open at t+10/t+20,
  **CLOSED at t+30/t+40**. This was FALSE earlier: our own 10 s reconcile tick
  rewrote `DiscoverableTimeout` and restarted the countdown each pass — fixed.)
- **`Pairable` is off at rest.** An outbound pair OPENS A WINDOW like everything
  else — one mechanism for both directions (§9.7).

### 9.4 Methods — inbound

| Method | Params | Result |
|---|---|---|
| `startPairing` | `{ secs?: 120 }` | `{ pairing: true, timeout }` — opens the window; emits `pairingChanged` |
| `stopPairing` | — | `{ pairing: false }` — closes it early; emits `pairingChanged` |
| `getPairingState` | — | `{ pairing: bool }` — reads `Adapter1.Pairable` live (not a cached flag) |

### 9.5 Methods — outbound (scan / pair a peripheral)

| Method | Params | Result |
|---|---|---|
| `startBtScan` | `{ secs?: 25 }` | `{ scanning: true, timeout }` — clamped 5–60 |
| `stopBtScan` | — | `{ scanning: false }` |
| `listBtScanResults` | — | `{ devices: [Device] }` |
| `pairBtDevice` | `{ mac }` | `{ paired, bonded, connected }` — **async**, up to ~100 s |
| `removePairedDevice` | `{ mac }` | `{ removed: true }` — emits `pairedDevicesChanged` |
| `connectBtDevice` / `disconnectBtDevice` | `{ mac }` | `{ ok: true }` — emits `pairedDevicesChanged` |
| `listPairedDevices` | — | `{ devices: [Device] }` |

**`Device`**: `{ mac, name, kind, paired, bonded, connected }`, where `kind` ∈
`keyboard` · `mouse` · `input` · `headphones` · `audio` · `phone` · `computer` ·
`other`.

**A scan self-stops.** A permanently scanning radio hurts BT/WiFi coexistence on this
shared BCM4330 antenna — and WiFi is the app's own transport. Discovery also cannot
be fire-and-forget: it **only lives while a client holds it** (measured: a detached
`bluetoothctl scan on` dies instantly — `Discovering: no`, 0 devices). That is why
discovery lives in btagent (long-lived, on D-Bus), not in the bridge.

**`pairBtDevice` owns its own discovery.** BlueZ forgets an unpaired device object
shortly after discovery stops, so the object from the user's scan is usually **gone**
by the time they tap Pair (measured: `Pair` → `UnknownObject`). `pair` therefore
re-discovers the target itself (25 s) rather than trusting a previous scan. It is
async because `Pair()` takes seconds and **our own `Agent1` must answer DURING it** —
a synchronous call would deadlock the very agent that completes the pairing.

### 9.6 What the app may show — two measured traps

- **BLE peripherals have NO Class of Device.** The MX Keys / MX Master report
  `class=none`. A CoD-based device-type rule — this design's first draft — would have
  hidden Petr's keyboard and mouse from the app **entirely**. `device_kind()` reads
  **`Icon` → `Appearance` (0x03c1 keyboard / 0x03c2 mouse) → `Class`**, in that order:
  BlueZ already derives `Icon` from CoD *or* the BLE Appearance, so it is the right
  primary source.
- **`Alias` can never answer "does this have an identity".** BlueZ **synthesises
  `Alias` from the ADDRESS** (`"6B-64-CB-F3-81-98"`) when a device has no name, so it
  is never empty. Only a real `Name` counts (or an alias that differs from the
  address = user-set). Without this filter a scan returns a wall of the neighbours'
  anonymous BLE beacons (**~38 in 25 s**, measured).
- **A scan MAC is not a stable identity.** BLE devices change address between
  pairings/channels — the MX Master exposed `…74:F4`, `:F5`, `:F6`, `:F7` on different
  channels. Do not persist a scan MAC as a device's identity.

### 9.7 Why `Pairable` must be ON for an outbound pair (root cause, 2026-07-15)

The `Pairable == Discoverable` invariant shipped in v1.9.0 was based on the **wrong
property** and silently broke **outbound** bonding. Chain, measured from
`bluetoothd -d` (not read from source):

1. The key **ARRIVES** — `new_long_term_key_callback() … new LTK … enc_size 16`.
2. BlueZ only **persists** a key the kernel marked **`store_hint`**.
3. The kernel only marks it so when **both** sides set the SMP **bonding bit**.
4. Our side only sets that bit under **`HCI_BONDABLE`** — which is exactly
   **`Adapter1.Pairable`**.

So a mouse paired at rest (`Pairable: no`) reports success, connects, genuinely
types, and is **gone after a reboot**. Inbound never hit this because setup opens a
window first.

> **Turning `Pairable` on is not a concession to minimise — it is what makes a bond
> durable.** The ring now keys off `Pairable` (the only property that gates pairing),
> `Pairable` is off at rest, and an outbound pair opens a window like everything else.

This **supersedes** §8.6's `Pairable == Discoverable` wording and the spec's §4.1.

### 9.8 Errors

`pair_failed` (BlueZ refused/aborted the bond, or the target never appeared within
the 25 s discovery deadline — usually "is it in pairing mode?"), `not_found`
(unknown MAC on remove), `unavailable` (btagent socket unreachable, bluetoothd down,
or Connect/Disconnect refused), `bad_params` (missing/invalid `mac`).

## 10. Desktop on demand — v1.10.0

The HDMI desktop idles the GPU/display path and heats the sphere, so it is
**on-request**, not always-on. Composed with §9: pair a keyboard + mouse, switch the
desktop on → the appliance is a computer.

| Method | Params | Result |
|---|---|---|
| `getDesktop` | — | `{ desktop: bool }` — live `systemctl is-active tinydm.service` |
| `setDesktop` | `{ on: bool }` | `{ desktop: bool }` — emits `desktopChanged` |

### 10.1 The `user` linger is a PREREQUISITE, not a detail

The desktop is `tinydm.service` → labwc in **`session-c1.scope`**. PulseAudio and
librespot are **user units under `user@10000.service`** — a *different* cgroup.

> Without linger, the user manager exists **only because of the graphical session** —
> so stopping the desktop would **kill the music**.

`device-google-steelhead` **r48** bakes `/var/lib/systemd/linger/user`, which
decouples them. Verified live 2026-07-15: with linger, `systemctl stop tinydm` leaves
**pulseaudio + librespot active, both sinks present**.

### 10.2 `setDesktop` uses a 60 s deadline

Stopping the desktop **churns logind** hard enough that ssh auth (`pam_systemd`) hung
for ~a minute during 2026-07-15 testing. It recovered on its own — but a snappy
timeout here would report a false failure, so `set_desktop` allows 60 s.

## 11. Streaming service toggles — v1.11.0

Each streaming INPUT is an independent uid-10000 systemd USER unit, so the box can
run only what its owner wants — one runs only Spotify, another only Roon+AirPlay —
and nothing runs unless switched on (the resource policy: an off service costs no
memory or CPU). The choice is **persistent** across reboots.

| Method | Params | Result |
|---|---|---|
| `listServices` | — | `{ services: [{ id, name, on }] }` |
| `setService` | `{ id: string, on: bool }` | `{ id, name, on }` — emits `servicesChanged` (the full list) |

Service ids → units: `spotify` → `librespot.service`, `airplay` →
`shairport-sync.service`, `roon` → `roon.service`. (The HDMI desktop stays on its
own §10 `setDesktop` — a system unit with different, non-persistent semantics.)

### 11.1 `on` is `is-active`, not `is-enabled`

`on` is the unit's **`systemctl --user is-active`**. `is-enabled` is deliberately
NOT used: it reports `disabled` for BOTH a vendor-enabled *running* unit
(`librespot`/`shairport`, enabled via a `/usr/lib` `default.target.wants` symlink)
AND a genuinely-off unit (`roon` at rest) — it cannot tell them apart. Only
`is-active` distinguishes them (measured 2026-07-17). Because the on/off actions
below keep active-state and boot-state in sync, `is-active` also reflects the
persistent choice after a reboot.

### 11.2 ON = `enable --now`, OFF = `mask --now`

- **ON**: `systemctl --user unmask <u>` (clear any prior off — `enable` refuses a
  masked unit) then `enable --now`. Runs now AND on boot.
- **OFF**: `systemctl --user mask --now`. Stops now AND won't start on boot.
  `mask` (not `disable`) is required: `librespot`/`shairport` ship **default-ON**
  via a `/usr/lib/systemd/user/default.target.wants` **vendor** symlink that a
  plain `disable` cannot remove; a `mask` in the user's own config
  (`/home/user/.config/systemd/user`) overrides it. A reflash resets all services
  to the image defaults (Spotify + AirPlay on, Roon off).

The control bridge runs as root and reaches the uid-10000 manager via
`systemctl --machine=user@.host --user` (linger keeps that manager up — §10.1).
Toggling a service that is mid-playback stops it (expected — turning it off means
off); a Roon zone re-announces and reconnects when switched back on.
