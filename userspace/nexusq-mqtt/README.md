# nexusq-mqtt — MQTT health telemetry publisher

Pushes the Nexus Q's health picture to the home MQTT broker so **Home
Assistant** (via MQTT discovery) and the **companion app** (subscribing to the
same feed) get a live health panel without a direct link to the device:

```
Q ──publish──▶ Mosquitto broker
                 ├──▶ Home Assistant   auto-created sensors, dashboards,
                 │                     automations (MQTT discovery)
                 └──▶ companion app    subscribes nexusq/health/#
```

Pure Python 3 **stdlib only** (like nexusq-control / -setupd / -btagent): the
MQTT 3.1.1 subset a non-subscribing QoS-0 publisher needs is tiny (CONNECT with
auth + Last Will, PUBLISH, PINGREQ, DISCONNECT), so there is no paho dependency
to ship on the armv7 image. Retained messages don't need QoS>0, and on a LAN a
lost publish means a dead TCP connection — which the reconnect loop answers by
republishing everything.

## What it publishes

Every `interval_s` (default 30 s), one retained JSON document:

| Topic                  | Payload                                        |
|------------------------|------------------------------------------------|
| `nexusq/health/state`  | the full state JSON (below), retained          |
| `nexusq/status`        | `online` / `offline` (retained; LWT covers ungraceful death, SIGTERM publishes `offline` explicitly) |
| `homeassistant/…/config` | retained HA discovery configs, republished on every connect |

State JSON fields (a field whose source is unavailable is **omitted**, never
null — HA templates guard with `| default('unknown')`, the app can distinguish
"absent" from a value):

- from **nq-healthd**'s latest `health.jsonl` sample (only when fresh, ≤60 s):
  `temp_c`, `freq_mhz`, `governor`, `load1`, `mem_avail_mb`, `nexusqd_alive`,
  `led_stall`, `dmesg_err`, `pstore`
- sampled live by this daemon (things healthd does not record):
  - `opp350_pct` `opp700_pct` `opp920_pct` `opp1200_pct` — per-OPP share
    ("podíl frekvencí") from `time_in_state` deltas over a **rolling 1 h
    window** (`NQMQTT_OPP_WINDOW_S`, default 3600 — r1; was publish-to-publish
    30 s in r0, which swung wildly: one governor burst = tens of percent,
    Petr: "lítá to úplně jak se to zlíbí"). Until an hour of history exists
    the window is honestly shorter (since daemon start); a kernel counter
    reset discards the history rather than poisoning an hour of readings
  - `wifi_rssi_dbm`, `wifi_ssid` — `iw dev wlan0 link`
  - `volume_pct`, `muted` — the mixer that currently owns the output: TAS5713
    hardware mixer while USB-audio's alsaloop bridges the gadget straight to
    the amp (same `pgrep -x alsaloop` detection as `nq-vol`), the uid-10000
    PulseAudio default sink otherwise
  - `services` — `{spotify, airplay, roon, usbaudio}` booleans (instant
    cgroup.procs read, the nexusq-control pattern)
  - `uptime_s`, `healthd_fresh`, `healthd_age_s`

## Home Assistant entities

Discovery creates one device ("Nexus Q" / the name from
`/etc/nexusq/device.json`, keyed by the factory WiFi MAC) with:

- sensors: die temperature, CPU frequency, governor, load, memory available,
  uptime, WiFi RSSI, volume, 4× per-OPP residency
- binary sensors: Spotify Connect / AirPlay / Roon / USB Audio (running),
  LED daemon + Health sampler (problem class — ON means something is wrong)

## Configuration (NOT baked into the image — provisioned by the companion app)

Broker credentials are per-home secrets — the (public) image ships **no**
config and the unit has `ConditionPathExists`, so an unprovisioned device
skips the service cleanly.

**The companion app is the provisioner** (since 2026-08-10, `nexusq-control`
r28 / app 1.13.0 — Petr's direction: "appka to musí nexusu provisionovat"):
saving the app's **"Connect to MQTT" dialog** calls `setMqttConfig`
(`companion/PROTOCOL.md` **§13**) on the control bridge, which validates,
**atomically writes** `/etc/nexusq/mqtt.json` (0600 tempfile + rename — never
world-readable, even transiently; password verbatim, never logged or returned)
and restarts this service (Condition* is only evaluated at unit start, so the
restart is what arms the first provision). `getMqttStatus` reports the
password-less state + the unit's active state.

Manual fallback / file format reference (ssh):

```sh
cat > /etc/nexusq/mqtt.json <<'EOF'
{
  "host": "mqtt.home.arpa",
  "port": 1883,
  "username": "…",
  "password": "…",
  "interval_s": 30,
  "prefix": "nexusq",
  "discovery_prefix": "homeassistant"
}
EOF
chmod 600 /etc/nexusq/mqtt.json
systemctl restart nexusq-mqtt   # Condition* is only evaluated at start
```

Only `host`, `username`, `password` are required; the rest defaults as shown.
`interval_s` is clamped to 10–600. (In Petr's home the Q logs in with the
household broker user — a dedicated device user was rejected + deleted
2026-08-10.)

## Enablement

The aport ships both the `multi-user.target.wants` symlink (covers a live OTA
`apk add nexusq-mqtt`) and its own `96-nexusq-mqtt.preset` (survives the image
build's `systemctl preset-all` + 99-default `disable *`). The unit deliberately
carries **no `After=`/`Wants=` ordering** — an `After=` on an enabled peer
forms the boot ordering cycle that deletes the start job (see
nexusq-control.service), and the reconnect loop rides out a late network or
broker anyway.

## Tests

Host tests (fake TCP broker, fixture files — no device needed):

```sh
python3 -m unittest discover -s userspace/nexusq-mqtt/tests -v
```

Covered: MQTT wire encoding (CONNECT flags/Will/auth, retain bit,
remaining-length boundaries, CONNACK refusal, dead-broker detection), config
validation, health-tail parsing (torn lines, staleness), OPP residency math
(rolling-window pruning + since-boot fallback + counter-reset discard),
discovery payload contract (unique_ids, shared topics, device block),
identity fallbacks. 28 tests as of r1.
