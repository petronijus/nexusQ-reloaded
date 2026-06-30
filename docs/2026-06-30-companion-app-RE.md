# Nexus Q companion app — complete feature catalog & reverse-engineering

**Date:** 2026-06-30
**Subject:** the original Google **"Nexus Q"** mobile companion app
(package `com.google.android.setupwarlock`, v**1.0.8.406084**, minAPI 10), the phone/tablet
app used to set up and control the Nexus Q.
**Source:** APKMirror (signature-verified), sha256
`05579cbaff4a4209985e013d1d633dd9439b2f0a89afa5e5e5568e4432b94e5d`.
**Artifacts (gitignored, non-redistributable Google code):**
`private/nexusq-original/companion/` — raw APK + `apktool/` (smali+res) + `jadx/` (Java) +
`triage.txt`. Re-run with `private/nexusq-original/companion/decompile.sh`.
**Method:** `apktool d` + `jadx` of the APK (pure Java, **no native libs**), then a 7-way
parallel read of the decompiled tree (setup flow, discovery, pairing, RPC/security, control
surface, cloud bridge, diagnostics).

> ## TL;DR
> - The app is a **Google "Android@Home" / Project "Tungsten" / "Place"** client. The same
>   APK contains **both ends** of several protocols (the phone-side controller *and* the
>   on-device hub-side `:broker` code).
> - **Three independent local protocols**, all cleanly specified below and all reimplementable:
>   1. **Discovery** — JSON-over-UDP multicast beacons (`235.10.10.1:21212` request /
>      `235.10.10.2:21213` announce / `:21214` unicast cert), `protocol_version=1`.
>   2. **Pairing** — RFCOMM (5 rotating SDP UUIDs) carrying a length-prefixed TLV message
>      protocol (`protocol version 10`), pushes Wi-Fi creds, hands off to TCP `:12345`.
>   3. **Control RPC** — a bespoke **TLV-over-mutual-TLS** transport on the first free TCP port
>      in **1100–1120** (`packet protocol version 0x0101`), carrying **JSON** payloads,
>      addressed as `(endpointId, actionString, {named JSON args})`.
> - The **control RPC method vocabulary is the gold** — it is a precise spec of every knob the
>   Q exposed: LED theme + brightness, master/group volume + mute, HDMI/analog/SPDIF output
>   routing, fixed-volume line-out, A/V sync delay, audio calibration, multi-room grouping,
>   now-playing metadata, device info / factory-reset.
> - The **entire Google-cloud spine is dead** (servers decommissioned 2013): account linking,
>   OTA, Play-app gating, email guest invites, cloud security-DB sync. A fresh device **hard-blocks
>   at `STATE_JOINING_CLOUDBRIDGE`** today — the stock app can no longer set up a Q at all.
> - Crypto is obsolete: RSA-1024 self-signed certs (`CN=Android@Home`, valid to 2033),
>   `SHA1withRSA` request signing, `TLS_RSA_*_CBC_SHA`, and a **no-op `checkClientTrusted`**.
> - ⚠️ Two baked-in secrets in the binary: a **leaked OAuth client_id/secret**, and
>   `res/raw/aah_dsa` — a **DSA SSH private key the stock firmware accepted as `root`/`shell`**
>   (used only by `Bugreport.java`, *not* by pairing/RPC). Neither is carried forward.

---

## 0. Architecture & naming

| Codename | Meaning |
|---|---|
| **warlock** | the companion app's package (`com.google.android.setupwarlock`) |
| **tungsten** | Google's project name for the Nexus Q control stack |
| **steelhead** | the device hardware (our pmOS device tree) |
| **athome / Place / broker** | the Android@Home framework: discovery + RPC + trust + multi-room |
| **TGS** | Tungsten Grouping System — the synchronized multi-room audio engine |

Topology in 2012: a phone (**controller**) discovers a Nexus Q (**hub/master** of a **Place**)
over UDP beacons, pairs over Bluetooth to push Wi-Fi creds, then opens a mutually-authenticated
TLS RPC channel to drive **Connectors** (services) the device advertises. Identity is a Google
account; the cloud is the source of truth for cross-device trust. **Today we run pmOS + `nexusqd`
on the device and own both ends, so almost all of the topology/cloud scaffolding is dead weight —
what survives is the control vocabulary.**

The phone wizard lives in `com.google.android.setupwarlock.*`; the on-device hub logic in
`com.android.athome.broker.*` + `android.support.place.*` (shipped in the same APK so the phone
could understand the protocol). Bundled libraries (not app logic): BouncyCastle (crypto/TLS),
Volley (HTTP), Guava, gdata/gtalk (GSF), Trilead/Ganymed SSH.

---

## 1. Discovery — JSON-over-UDP beacon protocol

Constants: `android/support/place/beacon/BeaconDiscoveryConstants.java`.

| Purpose | Address | Port | Dir |
|---|---|---|---|
| Discovery **request** (scanner→all) | `235.10.10.1` multicast **+** `255.255.255.255` bcast | **21212** | controller→hub |
| Beacon **announce** (hub→all) | `235.10.10.2` multicast **+** `255.255.255.255` bcast | **21213** | hub→controller |
| Unicast **get_beacon / get_cert** | hub unicast IP | **21214** | controller↔hub |

- **Cadence:** hub re-announces on *any* inbound request **and** every **15 s** keepalive.
  Scanner sends a **zero-length** "anybody there?" datagram on start / listener-register /
  connectivity-change. Buffers fixed at **1024 bytes** — a beacon must fit in 1 KB.
- **Encoding:** plain **UTF-8 JSON** (`android.support.place.rpc.RpcData` = a `JSONObject`;
  the Parcelable paths are in-process AIDL only, never on the wire). `protocol_version` must be
  `1` or the packet is dropped.
- **Beacon payload** (announce, :21213):
  ```jsonc
  { "protocol_version": 1,
    "place_info": { "placeId":"…", "placeName":"…",
                    "address":"<hub IP>", "port":<RPC port 1100-1120>, "id":"_broker",
                    "masterSessionId":"…",
                    "extras": { "guest_mode":<bool>, "master_cert":"<base64 X.509, optional>" } },
    "beacon_data": { "network_type":1|2,            // 1=WiFi, 2=Ethernet
                     "link_speed":<Mbps, WiFi only> } }
  ```
  Note `place_info.address`/`port`/`id="_broker"` **is** the hub's RPC endpoint — discovery
  bootstraps the control channel.
- **Unicast handshake (:21214):** `{"command":"get_beacon"}` → `{response_type:"beacon", beacon_field:{…}}`;
  `{"command":"get_cert"}` → `{response_type:"cert", cert_field:"<base64 X.509>"}` (150 ms timeout
  probe). Lets a controller learn/pin the hub cert before TLS.
- **Scanner state machine** (`PlaceDiscoveryManager`): byte-hash dedup (duplicate refreshes the
  timestamp, no UI churn), identity key = `(placeId, master endpoint)`, **30 s** cache expiry;
  first successful multicast beacon disables the unicast "ping" fallback scanner.

## 2. Pairing — Bluetooth RFCOMM → Wi-Fi push → TCP handoff

- **Entry:** optional **NFC tap** (Android Beam): the Q beams an NDEF MIME record
  `application/com.google.android.setupwarlock.SETUP` whose payload is its **BT MAC** (+ a
  `…SETUP_IP` record with its IP). Without NFC, the user taps the device in a scanned list.
- **BT scan:** classic inquiry, re-scan every 4 s, filtered by Google OUIs
  `^(00:1A:11|F8:8F:CA)`. The device's **BT adapter name is a side-channel**:
  `"<taskBitmask> <name>" (#rrggbb-#rrggbb<flags>)` carries the setup-type bitmask and the LED
  pairing color before any connection exists.
- **Transport:** **insecure RFCOMM over SDP** (not GATT), rotating through **5 service UUIDs**
  (`578f077f-…`, `c9e53035-…`, `ef845772-…`, `67debdcf-…`, `a3330af0-…`), 5 s/UUID, ~125 s total.
- **Framing** (shared with the TCP handoff, big-endian): `PacketReaderWriter`
  `[int32 len][payload]`; message `[int32 opcode][body]`; strings/byte[] are length-prefixed.
  **Pairing protocol version = 10.** Opcode table (`PairingUtils`):
  `GET_PROTOCOL_VERSION 110, ERROR 120, START_SETUP 310, GET_NETWORK_STATE 320,
  SET_WIFI_INFO 330, WAIT_FOR_NET_CHANGE 340, RUN_NETWORK_TEST 343, GET_HUB_IDENTIFIERS 345,
  JOIN_CLOUDBRIDGE 350, CREATE_PLACE 360, GET_CERTIFICATE 370, JOIN_PLACE 380,
  CHECK_FOR_OTA 390, OTA_PROGRESS 392, WAIT_FOR_FIRST_RUN 400`.
- **Wi-Fi push** (`MSG_SET_WIFI_INFO`): `{authAlgo, keyMgmt(0/1/2), groupCiphers, hidden, ssid,
  password, [enterprise k/v…]}` → device builds a `WifiConfiguration`, connects, and persists
  the credential. 64-hex passwords are treated as a raw PSK; WEP/EAP handled (legacy).
- **LED visual pairing** (`LedColorChooser` + `LedSetupSession2`): a color is deterministically
  derived from the BT MAC, with collision-avoidance against neighbouring Q's (read from their BT
  names); the ring shows it (60 fps, blue idle pulse → rotating two-color sweep → white "done").
  The controller shows the same swatch for the user to confirm by eye.
- **Handoff:** once the hub reports CONNECTED and version ≥ 6, the controller drops BT and opens
  a plain **TCP socket to `hubIP:12345`**; the hub then **disables its BT adapter** and continues
  the *same* message protocol over TCP, ending by restoring master volume to 60 %.

## 3. Control RPC — TLV-over-TLS broker (the spec that matters)

`com/android/athome/broker/rpc/RpcBroker.java` + `…/protocol/{RpcConstants,TlvReader,TlvWriter}`.

- **Listener:** first free TCP port in **[1100,1120]** (NIO selector, 15-thread pool, 1 MiB max
  request, keep-alive socket reuse). Port is published in the beacon + every `EndpointInfo`.
- **Wire framing** (big-endian, 4-byte-aligned nested **TLV**):
  ```
  [int32 totalLen][int16 ver=0x0101][int16 type:1=REQ/2=RESP] <TLV chunks>
  REQUEST : MESSAGE{ HEADERS{ ACTION(200)=method, ENDPOINT(201)=id, FLAGS(202)=ONEWAY|SIGNED },
                     PAYLOAD(101)=<RpcData JSON, UTF-8> }
            [ AUTH{ CERTIFICATE(400)=base64 cert, SIGNATURE(401)=SHA1withRSA(message) } ]  // if SIGNED
  RESPONSE: MESSAGE{ HEADERS{ STATUS(300)=1 OK|2 ERROR }, PAYLOAD(101)=JSON | ERROR(102)=string }
  ```
  Payloads are JSON (`RpcData`); return values are wrapped under key `"_result"`. Dispatch is by
  endpoint-id lookup → action-string switch (`EndpointBase.process`), with an `@Rpc`-annotation
  reflection path and a listener/`pushEvent` model for server→client events.
- **Security:** mutual TLS (`SecureSocketFactory`, `setNeedClientAuth(true)`, cipher suites
  `TLS_RSA_WITH_AES_{256,128}_CBC_SHA`) but **`DefaultTrustManager.checkClientTrusted` is a no-op**
  — caller auth is enforced at the **app layer** (`IncomingRequestAuthenticator`: allow if cert ==
  self, or a trusted-peer cert, or guest-mode auto-trust), with optional per-request SHA1withRSA
  signatures. Identity = `CertDealer` **RSA-1024** self-signed X.509 (`CN=Android@Home`, alias
  `client-private-RSA`, passwordless keystore). Cross-device trust was synced from Google's cloud
  (`GoogleSecuritySync`, C2DM-nudged) — now dead.
- **Well-known endpoints:** `_broker, _registry, _authService, _coordinator, _placeState`.

### 3.1 The exposed control surface (endpoint → actions)

| Endpoint (service) | Key actions · args |
|---|---|
| **TungstenLedConnector** | `setBrightness{brightness}`, `getBrightness`; evt `onBrightnessChanged` |
| **ThemeService** | `setTheme{theme}`, `getTheme`, `getThemeEngines`; evt `onThemeChanged` |
| **TungstenReceiverService** (per device) | `setMasterVolume{volume,mute}`, `getMasterVolume`, `getMasterMute`, `adjustMasterVolume{steps}`, `setOutputEnabled{enabled,output}`/`isOutputEnabled`, `setFixedVolumeOut{fixed_vout,output}`, `setFixedVolumeLevel{value,output}`, `setSyncDelay{sync_delay,output}`/`getSyncDelay`, `start`/`stop`/`reset`/`setEndpoint` — `output ∈ {hdmi, analog, spdif}` |
| **AudioCalibrator** | `startCalibration{output}`, `stopCalibration{compensationValue}`, `setTickTrack{…}`, `getCalibrationOutput`; evt `onCalibrationStateChanged` |
| **TungstenGroupingService** | `createGroup{groupId,rxIds}`, `assignRxToGroup`, `removeRxFromGroup`, `deleteGroup`, `getGroupState`, `getRxVolumes`/`setRxVolumes`, `adjustGroupVolume{groupId,steps}`, `setIsPlaying{groupId,isPlaying}`, `setGroupTransmitterConfig`; evts `onStateChanged`,`onVolumeChanged` |
| **TgsTransmitter** (phone→device stream) | `configureMediaPlayer`, `setGroupId`/`getGroupId`, `pauseTransmitter`, `resumeTransmitter`, `getPlayState`; evt `onPlayStateChanged{playing,artist,track,album,album_art,album_art_url}` |
| **DeviceConnector** | `setDeviceName{name}`/`getDeviceName`, `getDeviceSerialNumber`, `getBuildVersion`, `getModelName`, `getDeviceState`, `getDebugInfo`, `setAdbState`/`getAdbState`, `getAvailableUpdate`/`set/getUpdateWindow`, `getLegalInfo`, `factoryReset{confirmation="reset"}`, `getBluetoothMac`, `getMaster`, `ping` |
| **Coordinator** (`_coordinator`) | `setPlaceName{name}`, `getPlaceName`, `versionCheck`; evt `onPlaceNameChanged` |
| **SecurityService** (`_authService`) | `enableGuestMode`, `isGuestModeEnabled`, `updateRoles{add,remove}`, `revokeAccount`, `banUser`, `hasPermission`, `listUserAccounts` (roles: owner/admin/user/guest/banned) |
| **ConnectorRegistryRpc** (`_registry`) | `listConnectors{type}`, `registerConnectors`, `unregisterConnector`; evts `onConnectorAdded/Removed` |
| LightingService / MeshService / TtsService / IHealthService | A@H radio peripherals / TTS / AIDL health — **not Nexus-Q hardware**, ignore |

### 3.2 LED themes (shipped presets — `res/raw/theme_*`, parsed to `Theme{display,led,colors[],mode}`)

| Name | display | led | colors | mode |
|---|---|---|---|---|
| Spectrum | 1 | 1 | 9-color rainbow | transient |
| Warm | 1 | 1 | `#CC0000 #FF4444 #FF8800 #FFBB33` | transient |
| Cool | 1 | 1 | `#99CC00 #669900 #0099CC #33B5E5` | transient |
| Blue | 1 | 1 | `#33B5E5` | transient |
| Smoke | 1 | 1 | `#070707 #222222 #111111` | transient |
| Off | 0 | 0 | `#000000` | transient |
| Track Info | 0 | 1 | 9-color rainbow | **bouncing** (ring reacts to now-playing) |

`display`=on-device HDMI visual on/off, `led`=ring on/off, `mode`: NONE/TRANSIENT/BOUNCING.
On-device LED arbitration priority: `VOLUME_ACTIVE 100 > NFC_ADMIN 25 > BROKER_SETUP 20 >
NETWORK_STATUS 10 > VISUALIZER 5 > VOLUME_INACTIVE 0`.

## 4. The on-device setup UI (`:broker` `SetupActivity`)

Runs on the Q itself (hardware-only, no Google dependency): multilingual "Welcome" carousel,
Roboto-Light, LED ring animation (`LedColorChooser`/`LedSetupSession2`), screen-dim timer, an
**outro video** (`res/raw/q_outro.mp4`) on completion, and a hidden on-device **Wi-Fi scanner**
(`DiagnosticWifiFragment`, revealed by 20× / volume-up×3) showing SSIDs + signal + lock type.

## 5. Diagnostics suite (local network tests)

Client/server pairs (phone ↔ Q), graded FAILED(-20)…EXCELLENT(40):
- **UDP packet-loss/jitter** — port **1747**, 500×500-byte packets @10 ms; thresholds
  <50 % UNACCEPTABLE … ≥98 % EXCELLENT. (The only test with a real graded table.)
- **Bandwidth** — TCP port **1745**, 10 MiB bulk; grading trivial (any completion = EXCELLENT),
  Mbps shown in UI (formula hardcoded to a 10 Mbit reference — buggy).
- **Unicast latency** — TCP port **1744**, 10 iterations of `"Hello world!"`.
- **Setup liveness** — TCP port **12345**, expects `"Hello from the hub!"` (= the pairing handoff port).
- Host checks: interface IP enumeration + external HTTP-200 reachability.
Failure taxonomy (`BluetoothSetupController`): version-skew, BT-connect, multicast, unreachable,
cloudbridge, Wi-Fi down/incompatible. `BrokerService` (`START_STICKY`, launched at boot only on
hub-role devices) ties discovery + RPC + pairing + security + hub-election + network/power monitors
(`NetworkStateMonitor` eth-over-wifi debounced 15 s; `WifiLockMonitor` swaps full↔high-perf lock
when BT toggles).

## 6. The dead Google-cloud spine (CloudBridge)

HTTP-protobuf POST to `https://android.clients.google.com/athome/<verb>` (XSRF header
`X-AAH-Xsrf`, `X-AAH-Version:1`; two identities: user `com.google` cookie `ANDROID_AT_HOME`, and
robot `android.athome` OAuth Bearer). Verbs: `create_account, register_device, register_service,
register_master/get_master, user_checkin, invite_user, add_guest/clear_guests/revoke_user,
update_user_roles/update_place_roles, get/set_user_settings, get/set_place_settings, user_history,
user_sync, robot_data_sync, robot_security_sync`. Push via **C2DM** (sender `aahgcm@gmail.com`) only
*nudged* a security re-sync — **media/"Play to" never went through XMPP/GTalk**; audio grouping
("TGS") is LAN-only device-to-device. What the cloud actually provided: **account linking,
device registration, master rendezvous, the Place security/trust DB (which certs+roles are allowed),
settings sync, and emailed guest invites (optionally sharing Wi-Fi creds)**. All endpoints are
decommissioned → every call fails → **a fresh device cannot complete setup with the stock app.**

⚠️ **Baked-in secrets:** an OAuth `client_id` + `client_secret` (value redacted — it lives in the
gitignored decompile; dead, but a leaked credential, so not reproduced here), and `res/raw/aah_dsa`
(PEM **DSA SSH private key** the stock Android firmware accepted as `root`/`shell` — used only by
`Bugreport.java` to SSH in and run `bugreport`; *not* part of pairing or RPC). Do **not** carry
either forward.

---

## 7. Consolidated triage

Legend: **KEEP** = reimplement against `nexusqd` largely as-is · **MODERNIZE** = good idea, dated
mechanism · **DROP** = dead/irrelevant · **N/A** = no counterpart on a standalone pmOS device ·
**ADD** = not in the original, worth adding now.

### KEEP — the worthwhile control surface (small & clean)
| Feature | Original mechanism | Notes for `nexusqd` |
|---|---|---|
| **LED theme select** | `ThemeService.setTheme` + 7 `theme_*` JSON presets | Reuse the `{display,led,colors[],mode}` schema verbatim; ship a fixed local set. Iconic Q control. |
| **LED brightness** | `TungstenLedConnector.setBrightness` | Trivial local RPC; LED ring is live hardware (`leds-steelhead-avr`). |
| **Master volume / mute / step** | `TungstenReceiverService.{set,adjust}MasterVolume` | Core, local. |
| **Output routing HDMI / analog / S/PDIF** | `setOutputEnabled{output}` | Maps to ALSA routing; S/PDIF/TOSLINK is already on the roadmap. |
| **Fixed-volume line-out + level** | `setFixedVolumeOut`/`setFixedVolumeLevel` | Genuinely useful feeding an external amp / hi-fi. |
| **A/V sync delay (per output)** | `setSyncDelay{output}` | Keep as a manual slider. |
| **Now-playing metadata (read)** | `TgsTransmitter` `onPlayStateChanged` | "What's playing" view if the device exposes it (we run librespot/Spotify Connect now). |
| **Device info** | `DeviceConnector.get{BuildVersion,DeviceSerialNumber,DeviceState,DebugInfo}` | Health/info endpoints. |
| **Discovery beacon** | UDP 21212/21213 JSON `protocol_version:1` | Cheap; a small `nexusqd` responder would even let the *stock* app discover the device. Modernize crypto only. |

### MODERNIZE — keep the idea, replace the mechanism
| Feature | Why |
|---|---|
| Audio **calibration** | Auto tick-track measurement assumed paired-channel HW + Android mic → reduce to a **manual** sync-delay path unless a measurement is rebuilt. |
| **Pairing / provisioning shape** ("push Wi-Fi creds, then hand off to TCP") | The flow is exactly what a headless box still needs, but reimplement over **BlueZ + NetworkManager/wpa_supplicant** with modern crypto (Ed25519 / TLS 1.3), drop WEP/EAP. |
| **BT-name state side-channel** + **LED visual-pairing** (MAC-derived color, collision-avoid) | Lovely UX; reimplement over BlueZ adapter alias + the live LED path. |
| **Volume hardkey panel** (`AudioEndpointSelector`) | Good interaction, but welded to grouping/places → rebuild as a simple local volume+output panel. |
| **Network diagnostics** (UDP-loss/bandwidth/unicast) | Useful for bring-up/health; move off `AsyncTask`, fix the Mbps math + the unicast `computeResults` bug, drop the shell `netstat`. |
| **Network monitors** (`NetworkStateMonitor`/`WifiLockMonitor`) | Eth-over-WiFi debounce + IP-change detection is good logic; modern `ConnectivityManager.NetworkCallback`, current Wi-Fi-lock APIs. |
| **Place security/trust DB** (`robot_security_sync` shape) | If multi-device ever returns, reimplement as a **local** trust file seeding roles — no cloud. Keep the `RobotSecuritySyncResponse`/`RoleWithPermissions` *shapes* as schemas. |
| **Guest invite + Wi-Fi share** | Re-do as **local QR / LAN pairing**, not a Google-emailed invite. |
| **Master rendezvous** (`register_master`/`get_master`) | Replace with **mDNS/zeroconf** (or the §1 beacon). |

### DROP / N/A — dead topology, cloud, or no-HW-counterpart
- **Cloud bridge** (account linking, registration, OTA, settings sync, C2DM, `UpdateAppsActivity`
  Play-app gating, `bazaar://`) — servers gone; OAuth secret & SSH `aah_dsa` are dead leaked
  secrets, **do not reuse**.
- **Places / Broker / ConnectorRegistry / Coordinator / master-hub election / X.509 trusted-peer
  signing** — replace wholesale with one direct LAN connection to `nexusqd`.
- **Multi-room grouping / TGS transmitter RTP retransmit** (`TungstenGroupingService`,
  `MediaPlayerConfigurator`, unicast/multicast) — needs ≥2 Tungsten receivers + phone-as-transmitter.
  **DROP** unless resurrecting synchronized multi-Q audio.
- **TLV-over-bespoke-TLS framing** — needless now we own both ends; use length-prefixed JSON / gRPC
  / HTTP over localhost or a Unix socket.
- **Roles/ban/guest-mode, cloud invites, video/YouTube picker, Bluetooth place discovery, OTA
  window, ADB toggle (SSH replaces it), `helloFromHub`/`getMaster` handshake, NFC admin
  bug-report, legal/license screens, support-lib UI shims** — N/A or DROP.

### ADD — candidates that didn't exist in 2012 (for the new companion)
- Direct **Spotify Connect / librespot** status & control (the device already runs it) — surface
  now-playing + transport without the dead "Play to" stack.
- **Modern transport UI** (play/pause/next over whatever `nexusqd` exposes) instead of the
  read-only transmitter metadata.
- **Health dashboard** wired to the existing `scripts/diag/` + `nq-healthd` (temp, governor, LED-ring
  liveness) — a real "is my Q OK" screen.
- Cross-platform: a **web/desktop** companion (the device is on the LAN; no app store needed),
  not only Android.

---

## 8. Open questions for the new companion app (to decide together)

1. **Scope of v1** — minimal "remote" (volume + LED theme + power/now-playing) vs. full settings
   (outputs, fixed-level, sync delay, calibration, device info)?
2. **Platform** — Android, cross-platform (Flutter/KMP), or a **web app** served on the LAN?
3. **Device-side protocol** — does `nexusqd` already expose a control socket, or do we design one
   now (recommended: length-prefixed JSON over localhost/LAN TCP, mirroring the action-string
   vocabulary in §3.1)? This is the real blocker — the companion needs something to talk to.
4. **Wire-compat with discovery?** — implement the §1 beacon so the device is auto-discoverable
   (and, as a bonus, the stock app could find it), or skip and use mDNS?
5. **Pairing/auth** — trusted LAN (no auth) vs. a modern pairing (QR/PIN + TLS)?

See the triage above for recommendations; nothing here is built yet — this document is the basis
for choosing **what to modernize, what to drop, and what to add**.

---

## 9. Current `nexusqd` control surface & gap analysis (2026-06-30)

Decided direction: **cross-platform (Flutter/KMP) companion**, **v1 = minimal remote**
(volume/mute + LED theme/brightness + now-playing), **map the device side first**. Here is what
the device exposes today and what is missing for that v1.

### What exists
- **`nexusqd` control socket** — a **Unix domain socket** `/run/nexusqd.sock` (`SOCK_STREAM`),
  one line per connection, replies `ok`/`err`. Commands (`ctl_parse`):
  `theme <name>`, `set R G B`, `mute R G B`, `off`, `vol <0-100>`, `mtoggle`, `auto`,
  `scene <0-4>`, `status`.
- **LED ring** — `nexusqd` owns it, composites frames in software and writes the AVR sysfs
  (`/sys/bus/i2c/devices/1-0020/{frame,commit_mode,mute}`; driver `leds-steelhead-avr`). `theme`
  works (reads `/etc/nexusqd/themes/theme_<name>`).
- **now-playing source** — `librespot` (Spotify Connect, service name "Nexus Q",
  `--initial-volume 60`, output via the `nexusq` ALSA PCM). Metadata is *available* from librespot.
- **audio** — `pcm.nexusq` = plug→`hw:CARD=NexusQSpeaker` resampled to 48 kHz; `ctl.nexusq` =
  `type hw` on the TAS5713 card.

### Gaps for the minimal remote
| v1 feature | Status | Gap |
|---|---|---|
| **LED theme** | ✅ exists (`theme` cmd) | only reachable on the **Unix socket** — a phone can't hit it over LAN |
| **LED brightness** | ❌ not exposed | no `brightness` command; trivially addable as a **software scalar** in the compositor/`frame_pack` (multiply packed RGB) — no firmware change needed (driver already does full RGB frames; LED-class `max_brightness=255` exists but `nexusqd` writes raw frames) |
| **Volume / mute** | ❌ **no real audio volume anywhere** | `nexusqd`'s `vol`/`mtoggle` only drive the **LED overlay**, not audio. Volume keys only animate the ring. No ALSA `Master`/softvol is wired; real volume today is whatever the Spotify client sets **inside librespot**. Need a real volume knob (TAS5713 hw mixer control *or* an ALSA `softvol` + bind `librespot --mixer alsa --alsa-mixer-control …`) and route the companion + volume keys to it. |
| **now-playing** | ⚠️ available, not surfaced | wire `librespot --onevent <hook>` (or its event pipe) to publish track/artist/album/art + play state to the control channel |
| **state readback** | ❌ `status` parsed but **not implemented** | the socket is effectively write-only; the companion needs to *read* current volume/mute/theme/brightness/now-playing |
| **LAN transport** | ❌ Unix-socket only | a phone app needs a **network-facing** endpoint (the original used TCP 1100–1120) |

### Recommended shape (to confirm)
A small **LAN-facing control bridge** is the missing piece that makes a companion possible. Two
ways to get there:
- **(A)** extend `nexusqd` itself with a TCP listener + `status`/`brightness`/now-playing, or
- **(B)** a separate tiny **`nexusq-control` daemon** that owns the LAN endpoint and the
  volume/now-playing concerns, and talks to `nexusqd` over the existing Unix socket.

**(B) is recommended**: keeps the real-time render loop in `nexusqd` lean and isolated, puts the
network surface + audio/librespot glue in one place, and is independently testable. Wire format:
**length-prefixed (or newline) JSON** over LAN TCP, using the action-string vocabulary from §3.1
(`setMasterVolume`, `getMasterMute`, `setBrightness`, `setTheme`, `getPlayState`, …) so the schema
is documented and future-proof. Discovery via **mDNS** (advertise `_nexusq._tcp`); the §1 stock
beacon is optional/bonus.

Then the **Flutter companion v1** talks only to that bridge: volume slider + mute, LED theme
picker + brightness slider, and a now-playing card. Everything in the §7 KEEP list extends this
later; nothing in DROP/N-A is needed.
