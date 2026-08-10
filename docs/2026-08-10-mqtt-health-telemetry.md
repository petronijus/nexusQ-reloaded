# 2026-08-10 — MQTT health telemetry: Q → Mosquitto → Home Assistant + app Health panel

Base: v1.11.0 (tagged 2026-07-31); post-1.11.0 dev. PLAN.md "PLANNED NEXT" task (2)
— **DONE end-to-end**: the Q publishes its health to the home MQTT broker, Home
Assistant auto-creates the sensors (18 entities live with real values), and the
companion app (**1.12.0+31**, apk published as gh release `app-v1.12.0`) grew a
Health panel subscribing to the same feed.
**Everything is uncommitted on `main`** (the commit — which also carries the
staged `app-release.json` bump that makes the app OTA offer live — and the
device-OTA publish pend Petr's go; see HANDOFF.md "WHERE TO CONTINUE").

```
Q (nexusq-mqtt) ──publish──▶ Mosquitto (TrueNAS, 192.168.20.102:1883)
                               ├──▶ Home Assistant  (MQTT discovery → 18 entities)
                               └──▶ companion app   (Health panel, nexusq/health/#)
```

---

## 1. Device side — new aport `pmos/nexusq-mqtt` (0.1.0-r0, noarch)

Daemon in `userspace/nexusq-mqtt/` (`nexusq-mqtt` + `.service` +
`96-nexusq-mqtt.preset` + README + tests). Design decisions:

- **Pure-Python 3 stdlib MQTT 3.1.1 publisher** (like the other daemons — no paho
  on the armv7 image): CONNECT with auth + Last Will, PUBLISH QoS0 + retain,
  PINGREQ with a PINGRESP-timeout dead-link detector, reconnect + backoff. A
  non-subscribing QoS-0 publisher needs only that subset; a lost publish on a LAN
  means a dead TCP connection, which the reconnect loop answers by republishing
  everything (retained).
- **Publishes every 30 s** (`interval_s`, clamped 10–600): retained JSON at
  `nexusq/health/state`; availability at `nexusq/status` (retained LWT
  `online`/`offline` — SIGTERM publishes `offline` explicitly); retained **HA MQTT
  discovery** configs at `homeassistant/(binary_)sensor/nexusq_<factoryMAC>/*/config`
  — **12 sensors + 6 binary_sensors** sharing one state topic via
  `value_template`s. A field whose source is unavailable is **omitted, never
  null** — templates guard with `| default('unknown')`, the app can distinguish
  "absent" from a value.
- **Data:** the tail of nq-healthd's `health.jsonl` (used only when fresh ≤60 s:
  `temp_c`, `freq_mhz`, `governor`, `load1`, `mem_avail_mb`, `nexusqd_alive`,
  `led_stall`, `dmesg_err`, `pstore`) + the daemon's own sampling of what healthd
  doesn't record: **per-OPP residency deltas** from `time_in_state` ("podíl
  frekvencí", `opp350/700/920/1200_pct` of the publish window), WiFi RSSI/SSID via
  `iw`, **volume/mute from the mixer that currently owns the output** (TAS5713
  `amixer` while `alsaloop` runs — the same `pgrep -x alsaloop` detection as
  `nq-vol` — else the uid-10000 PA default sink via `PULSE_SERVER`/`COOKIE`), the
  4 streaming-service states via an instant `cgroup.procs` read (the
  nexusq-control pattern), `uptime_s`.
- **Config `/etc/nexusq/mqtt.json` (0600) is a per-home SECRET — NEVER baked into
  the public image.** The unit has `ConditionPathExists` (unprovisioned device
  skips cleanly) and **deliberately NO `After=`/`Wants=` ordering** (the
  boot-ordering-cycle rule that already bit nexusq-control.service).
- **Enablement is self-contained** (no device-pkg preset edit): the apk bakes the
  `multi-user.target.wants` symlink (covers a live OTA `apk add`) AND ships its own
  priority-96 preset (survives the image build's `preset-all` + 99-default
  `disable *`).
- **25 host tests passing** (incl. a fake TCP MQTT broker): wire encoding
  (CONNECT flags/Will/auth, retain, remaining-length boundaries, CONNACK refusal,
  dead-broker detection), config validation, health-tail parsing, OPP residency
  math, discovery payload contract, identity fallbacks.

**Integration:** `device-google-steelhead` r66 → **r67** (`depends +=
nexusq-mqtt`); `docker-build.sh` Phase 2 checklist + Phase 5 staging + dos2unix
list + a NEW **Phase 7c5** build/export block; `scripts/publish-ota-repo.sh`
`OTA_PACKAGES += nexusq-mqtt`. Built via `OTA_PACKAGES_ONLY=1` →
`output/nexusq-mqtt-0.1.0-r0.apk` + `device-google-steelhead-1.0-r67.apk`
(signed, verified; **NOT yet published to the OTA repo** — pending Petr's go).

## 2. Broker side — new MQTT user `nexusq` on the TrueNAS Mosquitto

- TrueNAS SCALE Mosquitto app (eclipse-mosquitto **2.0.22**,
  `192.168.20.102:1883`, container `ix-eclipse-mosquitto-mosquitto-1`).
  New user **`nexusq`** appended to `password_file
  /mnt/data-fast/data-fast/Apps/mqtt/config/credentials` (backup taken first),
  reloaded via SIGHUP. Password in 1Password: item **"MQTT nexusq (Nexus Q
  telemetry)"**, vault Personal.
- ⚠️ **The broker has NO `acl_file`** — every authenticated user can read/write
  everything, incl. zigbee2mqtt topics. Accepted for now; an ACL would be the
  hardening step.
- **Verified BEFORE the device deploy:** a host-side selftest published a
  discovery config with the daemon's own client → HA created
  `sensor.nexusq_selftest_selftest_temp` = 42.5 °C → retained topics cleaned up.
  Negative auth test: a wrong password is correctly refused.

## 3. Live deploy — 18 entities in Home Assistant

Device reached at **192.168.20.246** (NEW WiFi lease after today's internet
outage; was `.164`). `apk add` of both apks **clean — the mkinitfs trigger passed
(the 2026-08-08 Option-A `/boot` fix holds)**; the baked wants-symlink
auto-created the enablement; `mqtt.json` provisioned (0600); service running,
broker connected. **18 entities live in HA with real values**: die temp 79.9 °C,
1200 MHz / `conservative`, per-OPP shares, −28 dBm RSSI, volume 45 %, uptime
matching the device. Binary sensors cross-checked against device truth —
librespot + shairport-sync are **masked** (Petr turned Spotify/AirPlay off via the
app ~20 h ago — intentional, left alone) and telemetry correctly reports them off.

## 4. App side — companion 1.11.2+30 → **1.12.0+31** (Health panel)

- Settings → **"Device health"** → new `HealthScreen`
  (`lib/screens/health_screen.dart`): status, problem flags, vitals, OPP residency
  bars, service chips, WiFi card. Retained topics make it **populate instantly**
  on connect.
- Manual **"Connect to MQTT" dialog** — **Petr's decision: hand-entered broker
  creds, editable; NO auto-provisioning verb, NO protocol change** (the app reads
  the broker, not the control socket — PROTOCOL.md untouched). Creds live in
  `flutter_secure_storage` (Android Keystore / iOS Keychain) — the broker password
  guards more than the Q, it must not sit in plaintext SharedPreferences.
- Subscriber in `lib/mqtt/{mqtt_settings,health_mqtt}.dart` using
  `mqtt_client ^10.6` (autoReconnect).
- Release apk **built and published as GitHub release `app-v1.12.0`**
  (asset `nexusq-companion-1.12.0.apk`, published 2026-08-10T20:12:53Z). The
  `companion/app-release.json` bump to 1.12.0/31 is **staged in the working tree
  but NOT pushed** — phones fetch the manifest from raw.githubusercontent
  `main`, so the OTA offer goes live only when the commit is pushed.

## 5. Findings / known issues recorded

1. **`test/connect_gate_setup_entry_test.dart` is NOT hermetic** — it performs
   real mDNS discovery; with a live Q on the LAN it finds the real bridge
   (connected to `192.168.20.246:45015`) and fails ("Set up new device" never
   offered). It fails whenever the device is online, passes when it's not. Needs
   a discovery seam/mock.
2. **An internet-only outage still takes the Q off the LAN (~2 h today,
   working-as-designed):** the wifi-watchdog pings the **gateway**; with the
   gateway unpingable it bounces `wlan0`, and (kea down) got no lease. It
   recovered on its own after the outage, on the new lease `.246`. Note for a
   future refinement: a LAN-fine/WAN-dead outage shouldn't have to cost LAN
   reachability.
3. **`opnsense-api` helper currently broken from this PC**:
   `opnsense.home.arpa` has no DNS record and gw `:8443` answered a
   mini_httpd-style 404 (possibly a temporary router swap during the outage) —
   kea lease lookups via the helper are impossible right now. Re-verify once the
   network is back to normal.
4. librespot + shairport-sync **masked** on the device = intentional user state
   (app toggles), not a fault — see §3.

## 6. Where to continue

- `git commit` the working tree (Petr's go) — implementation is all uncommitted.
- OTA publish: `publish-ota-repo.sh` with the built `nexusq-mqtt-0.1.0-r0` +
  `device-google-steelhead-1.0-r67` apks (Petr's go).
- App release: the `app-v1.12.0` gh release + apk **exist**; the staged
  `companion/app-release.json` bump ships with the commit+push (Petr's go) —
  that push is what makes phones see the update.
- Later: broker `acl_file`; the non-hermetic connect-gate test; MQTT telemetry
  was PLAN task (2) — task (1) (USB audio back into PA via snd-aloop) remains.
