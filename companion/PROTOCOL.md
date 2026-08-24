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
  (Client note, 2026-08-03: on **iOS** the browse is native Bonjour — NWBrowser via the
  app's `nexusq/bonjour` channel — because raw-socket mDNS needs a restricted Apple
  entitlement; the wire protocol is identical DNS-SD, nothing changes device-side.)
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

> nexusqd's LED-command vocabulary (over `/run/nexusqd.sock`) also carries the OTA
> primitives **`progress <pct> [R G B]`** (a determinate ring bar) and
> **`mblink R G B | mblink stop`** (an autonomous mute-LED blink) — driven by the
> bridge during a system update, see **§12.3**. They are not app-facing methods.

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

> **Client availability (2026-08-03):** RFCOMM restricts this transport to the
> **Android** app — iOS has no public BT Classic RFCOMM API (SPP is MFi-gated), so
> the iOS app hides the setup entry point. A future **BLE GATT** carrier for the
> same envelope (device-side BlueZ) is the recorded candidate to lift that.

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

## 11. Streaming service toggles — v1.11.0 (USB Audio added post-v1.11.0)

Each streaming INPUT is an independent uid-10000 systemd USER unit, so the box can
run only what its owner wants — one runs only Spotify, another only Roon+AirPlay —
and nothing runs unless switched on (the resource policy: an off service costs no
memory or CPU). The choice is **persistent** across reboots. As of the post-v1.11.0
dev line there are **four** inputs: Spotify, AirPlay, Roon, and **USB Audio** (the Q
as a USB DAC).

| Method | Params | Result |
|---|---|---|
| `listServices` | — | `{ services: [{ id, name, on }] }` |
| `setService` | `{ id: string, on: bool }` | `{ id, name, on }` — emits `servicesChanged` (the full list) |
| `serviceLog` | `{ id: string, lines?: int (≤1000, default 200) }` | `{ id, name, lines: [string] }` — recent journal, newest last, ANSI stripped |

`serviceLog` reads the SYSTEM journal by `_SYSTEMD_USER_UNIT=<unit>` (a root
service can't attach to the uid-10000 user journal — `journalctl --machine …
--user` refuses non-root — but the user unit's records are tagged there).

Service ids → units: `spotify` → `librespot.service`, `airplay` →
`shairport-sync.service`, `roon` → `roon.service`, `usbaudio` →
`nexusq-uac2-in.service` (the UAC2 USB-DAC loopback; **post-v1.11.0**). (The HDMI
desktop stays on its own §10 `setDesktop` — a system unit with different,
non-persistent semantics.) Each entry carries a **`vendor_on`** flag: `spotify` and
`airplay` are vendor-default-ON; `roon` and `usbaudio` are default-OFF (see §11.2).

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

## 12. OTA — the Q updates its own software — v1.11.x (dev)

The Nexus Q **updates its own software over the air**, no reflash, no adb, no ssh.
There are **two tracks**, surfaced in the app's Settings as **two Update items**:

- **§12a — App update (daemons):** the four small daemons — `nexusq-control`,
  `nexusqd`, `nexusq-btagent`, `nexusq-setupd` (`OTA_PACKAGES`) — versioned together
  with the phone app as the "companion system" (`checkNexusUpdate` /
  `installNexusUpdate`). This is what the phone-app **App update** item drives on the
  device side.
- **§12b — System:** the "apt upgrade" of the whole appliance — **every** upgradable
  package (base musl/systemd/python + our config + daemons), **minus the kernel**
  (`checkSystemUpdate` / `installSystemUpdate`).

> The app's **Update cluster is two items**: **App update** (phone app + device daemons,
> whichever is newer, merged notes) and **System** (kernel version read-only + every
> package). Install order for App update = **device daemons first, then the phone app**
> (installing the app restarts the phone, so it goes last, onto an already-updated
> device).

> ✅ **Proven end-to-end on hardware 2026-08-02** — the reference Q was taken
> `nexusqd` r10 / `nexusq-control` r16 → r11 / r19 entirely from the app's *Nexus Q*
> Settings section. Record: `../docs/2026-08-02-device-ota-and-wifi-nogw-heal.md`.

### 12.1 Trust model — the signed apk repo (no new key)

A signed **apk repository on GitHub Pages** hosts the device packages:
`https://petronijus.github.io/nexusQ-reloaded/nexusq` (the `gh-pages` branch,
republished after a build with `scripts/publish-ota-repo.sh`). The device **already
trusts the `pmos@local` build key** (baked in `/etc/apk/keys` at image build), which
signs every one of our packages — so `apk` installs them straight from the repo with
**no new key and no reflash**. `nexusq-control` adds the repo to
`/etc/apk/repositories` idempotently on first check.

**Scope (updated 2026-08-02):** the four daemons **and** `device-google-steelhead` +
its firmware subpackage are now published — the ~180 MB glibc-rt Roon base was **split
into its own aport `nexusq-glibc-rt`** (flash-only), so the config apk dropped from
~191 MB to 58 KB and fits the 100 MB limit. `publish-ota-repo.sh` refuses any apk
≥ 99 MB. **Flash-only (never OTA'd):** `nexusq-glibc-rt` (~182 MB) and the **kernel**
(a boot-partition flash / fastboot-over-ssh — §—see INSTALL). ⚠️ A pre-split device
must be **reflashed once** to adopt the split (it can't OTA config r62 without the
flash-only glibc-rt dep); afterward the config is incremental.

### 12a.1 Methods — App update (daemons)

| Method | Params | Result |
|---|---|---|
| `checkNexusUpdate` | — | `{ packages: [{ name, installed, available, upgradable }], updateAvailable: bool, repo }` — `apk update` + `list --upgradable`/`--installed`; installs nothing |
| `installNexusUpdate` | — | `{ ok: true, upgraded: [name], restarting: bool, output }` — `apk upgrade`s the daemons, animates the LEDs, then restarts the changed daemons (incl. this bridge) off-thread |

`installNexusUpdate` is guarded by an **install lock**: a concurrent install is
refused with error **`busy`** ("an update is already installing") rather than racing a
second `apk upgrade`. (A flaky link had the app resend the call; with per-request
threads that launched a second upgrade over the first, and the first got killed =
`Terminated` when control restarted itself.) Other errors: `unavailable`
(`apk upgrade` failed / cannot edit `/etc/apk/repositories`), `timeout` (apk did not
respond).

> **The install DROPS the app link — that is EXPECTED, not a failure.** The upgrade
> restarts `nexusq-control` itself (last, via `systemctl --no-block`), so the TCP
> connection closes mid-call. The client confirms success by **reconnecting and
> re-checking the version** (`checkNexusUpdate` with no pending update == success),
> never by treating the disconnect as an error.

### 12.3 LED narration (→ nexusqd `progress` / `mblink`, see §4/§6)

An update that merely **waits** is signalled **only on the dedicated mute LED** — the
ring stays on the user's colour theme. The mute LED "software update available" blink
is a **persistent** indicator (it survives a theme change or the music visualiser),
suppressed only while the mute LED is doing its real job (an actual mute or a volume
overlay) and resuming the moment that ends.

| Phase | LED |
|---|---|
| Update available (`checkNexusUpdate`) | mute LED **blinks amber** — `mblink 255 140 0` (else `mblink stop` when nothing is pending) |
| Installing (`installNexusUpdate`) | mute-LED blink cleared (`mblink stop`); the RING shows a **determinate progress bar** — `progress <pct>` in `#0099CC`, eased toward a soft cap while `apk upgrade` runs, snapped to 100 % on finish |
| Success | ring flashes **green** (`set 0 255 0`), held ~2.5 s, then back to the theme |
| Failure | ring restored straight to the theme; the mute LED is not re-lit |

These use two nexusqd LED primitives (r11), also listed in the §4 LED-ring table:
- **`progress <pct> [R G B]`** — a determinate ring bar: lights `pct`% of the 32-LED
  ring in the colour (default `#0099CC`), the rest a dim track. A manual mode, cleared
  by `set` / `off` / `breathe` / `spin` / `auto`.
- **`mblink R G B | mblink stop`** — an autonomous blink of the **mute LED** in the
  given colour; the daemon owns the on/off cadence. `mblink stop` clears it and
  restores the mute LED to the current muted state.

### 12b. System — the whole-appliance "apt upgrade" (`nexusq-control` r21+)

The **System** track upgrades **every** upgradable package (base musl/systemd/python
from the Alpine·pmOS mirrors + our config + daemons from the OTA repo) — the
"apt upgrade" of the appliance — **except the kernel**.

| Method | Params | Result |
|---|---|---|
| `checkSystemUpdate` | — | `{ packages: [{ name, installed, available }], updateAvailable: bool, kernel, repo }` — `apk update` + `apk version -l '<'`, **minus the kernel**; `kernel` is the running `uname -r` (read-only). Installs nothing. Does **NOT** blink the mute LED (that stays the §12a "daemon available" indicator). |
| `installSystemUpdate` | — | `{ ok: true, changed: [name], daemons: [name], rebootRecommended: bool, output }` — `apk upgrade --available` across the system **except the kernel**; restarts changed daemons off-thread, **reboots if base libc/init churned**. |

**Kernel is never OTA'd.** No repo the device reads offers a newer kernel, and applying
a kernel is a **boot-partition flash = Phase 2** (fastboot / fastboot-over-ssh, see
INSTALL). `checkSystemUpdate` skips `linux-google-steelhead`; `installSystemUpdate`
runs `--available` (which the mirrors never offer a newer kernel for).

**Reboot contract.** `rebootRecommended` (and the actual `systemctl reboot`) fire when
any changed package name starts with **`musl` / `systemd` / `kmod` / `eudev` /
`busybox` / `openrc`** — base libc/init that only fully takes effect after a reboot.
On reboot the ring stays **green** (last thing seen = success); the app reconnects when
the Q is back. Otherwise the theme is restored and only changed daemons restart.

**LED: the INDETERMINATE spinner, not the determinate bar.** A full-system upgrade is
slow and of unknown length (downloads + triggers like mkinitfs), so the determinate
`progress` bar would ease to its ~92 % cap and sit there looking frozen. The system
install narrates with **`spin 0 153 204 2`** (fast blue) → **green** `set 0 255 0` on
success (which also stops the spin). The daemon track (§12.3) keeps the determinate bar
— its upgrade is small and short. Guarded by the same install lock (`Err "busy"`); the
install can drop the app link (bridge restart / reboot) — that is **expected**, success
is confirmed by reconnect + re-check.

## 13. MQTT telemetry provisioning — v1.12.x (dev)

The Q publishes health telemetry over the home MQTT broker (`nexusq-mqtt`
daemon → `nexusq/health/state` + Home Assistant discovery). The broker
credentials are a **per-home secret**: they are never baked into the (public)
image, and the appliance has no input surface of its own — so **the companion
app is the only provisioner**. The app's "Connect to MQTT" dialog saves the
credentials for its own subscription AND hands the same values to the device
here. The device stores them in `/etc/nexusq/mqtt.json` (0600, root-only);
`nexusq-mqtt` has `ConditionPathExists` on that file and is restarted by the
provision call, which is what arms it the first time.

### 13.1 `getMqttStatus`

→ `{}`
← `{"configured": bool, "host": str, "port": int, "username": str,
    "prefix": str, "active": "active"|"inactive"|"unknown"}`

The **password is never returned** — by any verb, ever. `active` is the
`nexusq-mqtt.service` unit state (a truthful "is the device publishing").

### 13.2 `setMqttConfig`

→ `{"host": str, "username": str, "password": str,
    "port"?: int (1..65535, default 1883), "prefix"?: str (default "nexusq"),
    "interval_s"?: int (10..600, dropped when out of range)}`
← the same shape as `getMqttStatus` (password-less), after the restart.

Errors: `bad_request` (missing/empty host, username or password; bad port
type/range), `unavailable` (config not writable), `timeout` (restart hung).
The write is atomic (0600 tempfile + rename — never world-readable, even
transiently); host/username are trimmed, the **password is taken verbatim**
(trailing whitespace could be legitimate). The password is never logged.

Event: `mqttStatusChanged` (the password-less status) is pushed to every
subscribed client so their MQTT panels reconcile.

Security note (accepted trade-off, Petr's call 2026-08-10): the credentials
transit the **unauthenticated plaintext LAN TCP 45015** control link — the
same trust level as every other verb (anyone on the LAN can already control
the device). The alternative (a dedicated low-privilege broker user for the
device) was rejected in favour of one household broker login.

## 14. Hardware EQ (TAS5713 biquads) — 7-band parametric, kernel r50+

GitHub issue #2 asked for an EQ ("the bass is horrible" on a donor speaker).
It is implemented **in the amplifier's own DSP**, not in software: the TAS5713's
main EQ bank is **7 biquads per channel**, exposed by our kernel as ALSA
integer-array controls (`CH1/CH2 - Biquad 0..6`). All seven are used, written
identically to both channels (stereo-linked).

Filtering is post-mix in the amp die: one EQ covers Spotify/AirPlay/Roon/USB
alike, **zero CPU, zero added latency** (measured 2026-08-24: PulseAudio 22.24 %
flat vs 22.11 % at bass+6/treble+6 — the biquad is in the path either way), and
the digital chain before the amp stays bit-exact. Coefficients are RBJ, computed
for the chain's pinned 48 kHz and packed as 3.23 fixed point (TI convention:
a1/a2 negated). The device persists state in `/etc/nexusq/eq.json` and re-applies
it at every `nexusq-control` start (the DAP powers up flat).

⚠️ **Kernel r50 or newer is required.** r49 exposes the controls — so
`supported` is `true` — but its write path is broken by an upstream 32-bit bug
that loads `0xFFFFFFFF` into the amp whatever you ask for. That is **not**
detectable from this API; see `docs/2026-08-24-eq-biquad-write-broken.md`.

### 14.1 Band model

```json
{"type": "peaking", "freq_hz": 900.0, "gain_db": -3.5, "q": 1.4, "enabled": true}
```

| field | values |
|---|---|
| `type` | `lowshelf` · `peaking` · `highshelf` |
| `freq_hz` | 20 … 20000 |
| `gain_db` | −12 … +12 (`0`, or `enabled:false`, writes exact unity — not a computed 0 dB filter) |
| `q` | 0.3 … 8 — the **Q** of a peaking band; for a shelf it is RBJ's **S (slope)**, 1.0 being the maximally flat shelf |
| `enabled` | bool |

Defaults, chosen so a device upgraded from the two-knob version sounds
identical (bands 0 and 6 keep the old 100 Hz / 8 kHz shelves):

| band | 0 | 1 | 2 | 3 | 4 | 5 | 6 |
|---|---|---|---|---|---|---|---|
| type | lowshelf | peaking | peaking | peaking | peaking | peaking | highshelf |
| Hz | 100 | 200 | 430 | 900 | 1800 | 3800 | 8000 |

Out-of-range numbers are **clamped**, not rejected; an unparseable band falls
back to its default rather than failing the request — a corrupt stored file must
never stop the daemon starting. What *is* refused outright, before any I2C
write, is an **unstable filter** or a coefficient that will not fit 3.23: on a
25 W amp a wrapped coefficient is worse than a declined filter, which is exactly
what the 32-bit `max` bug produced.

### 14.2 Preamp and headroom

Seven bands can stack past +12 dB and clip. `preamp_db` (−24 … 0) attenuates the
whole chain; it is folded into **band 0's feed-forward coefficients**, because
the amp's only gains (`Master Volume`, `Speaker Volume`) are the **user's
volume** and must never be hijacked for headroom.

`headroom_db` is the peak of the summed response over a 1/12-octave grid,
20 Hz–20 kHz, *including* `preamp_db`. Positive means the chain can clip.
Sending `auto_preamp: true` sets `preamp_db` to exactly cancel that peak.

### 14.3 `getEq`

→ `{}`

← ```json
{"supported": true, "bands": [...7...], "preamp_db": 0.0, "headroom_db": 0.0,
 "max_bands": 7, "limits": {...}, "bass_db": 0.0, "treble_db": 0.0}
```

`supported=false` means a kernel without the biquad controls — show the EQ
disabled. **`bass_db`/`treble_db` are still returned**, derived from the first
`lowshelf` and last `highshelf` band, so the shipped **1.14.0** app (which knows
only those two fields) keeps working against a newer daemon.

### 14.4 `setEq`

→ `{"bands"?: [...], "preamp_db"?: number, "auto_preamp"?: bool,
    "bass_db"?: number, "treble_db"?: number}`

← the same shape as `getEq`, after the hardware write.

Either shape is accepted. `bass_db`/`treble_db` set the gain of the shelf bands
and **leave the other five alone**, so an old client cannot silently wipe a
parametric curve. A short `bands` array leaves the remaining bands unchanged.
Emits `eqChanged` with the applied state.

Errors: `bad_params` (wrong type, or more than `max_bands` bands),
`unavailable` (kernel without the controls, a failed `amixer` write, or an
unwritable config file). **Hardware first, persist second** — a failed write
leaves the stored file matching what the chip actually runs.

### 14.5 `listEqPresets`

→ `{}`

← `{"presets": [{"id": "loudness", "label": "Loudness", "bands": [...], "preamp_db": -5.0}]}`

Presets live on the device so every client sees the same ones. Applying one is
just a `setEq` with its `bands` and `preamp_db` — one write path, not two. Each
ships with enough preamp not to clip.
