# MQTT telemetry at the cottage — and the cloned MAC it uncovered (2026-08-29)

**Symptom as reported:** *"tenhle novej nexus na sumperaku nereportuje stav pres
mqtt, asi se na to nedostane."*

The reachability guess was wrong in an interesting way. Nothing was blocked;
two separate things were simply never in place, and fixing them exposed a third
that was actively corrupting the *other* Nexus Q's Home Assistant entities.

---

## 1. The Q was never provisioned

`nexusq-mqtt.service` was `enabled` and the package (`nexusq-mqtt-0.1.0-r4`)
installed, but the unit had been skipped at every boot since the reflash:

```
Condition: start condition unmet
  └─ ConditionPathExists=/etc/nexusq/mqtt.json was not met
```

`/etc/nexusq/` held only `device.json` and `shairport-sync.conf`. This is the
designed behaviour — broker credentials are per-home secrets and are never baked
into the public image (see `userspace/nexusq-mqtt/README.md`) — but it means a
reflash silently un-provisions telemetry, and the only symptom is silence. The
journal line above is the whole diagnosis; look there first.

## 2. The cottage broker was loopback-only

Mosquitto 2.0.21 *was* running at the cottage, on the DietPi
(`<cottage-pi>`) — but `conf.d/zigbee2mqtt.conf` bound it to localhost, because
it had only ever served zigbee2mqtt on the same host:

```
listener 1883 127.0.0.1
allow_anonymous true
```

From the Q: `ConnectionRefusedError: [Errno 111]`. And there is no fallback —
the Q is **not** on Tailscale, so the Prague broker (`<broker-host>`) is
unroutable from it. `ping` to that address fails from the device.

Note for future probing: the Q's busybox `sh` has no `/dev/tcp`, so the port
check has to go through Python:

```sh
python3 -c 'import socket;s=socket.socket();s.settimeout(3);s.connect(("<cottage-pi>",1883))'
```

### What was changed on the Pi

`conf.d/zigbee2mqtt.conf` now binds `0.0.0.0`, still anonymous — the cottage
WLAN is the trust boundary, chosen deliberately over a password file. And the
bridge to Prague (`conf.d/bridge-home.conf`, `home-truenas` →
`<broker-host>` over Tailscale) gained one rule:

```
topic nexusq-sumperak/# out 1
```

Without it Home Assistant in Prague would have created the entities — discovery
already rides the pre-existing `homeassistant/# out 1` rule — pointing at a
state topic that never arrives. Backups of both files are on the Pi as
`*.bak-20260829-220023`.

## 3. The state topic is flat, and two Qs collided on it

Provisioning with the default `prefix` made it immediately visible that **two
devices were publishing to `nexusq/health/state`**: one payload with
`wifi_ssid: "<cottage-ssid>"`, the next with
`"<home-ssid>"`.

The topics are built as `<prefix>/health/state` and `<prefix>/status` with **no
per-device component** (`nexusq-mqtt` lines 795–797) — only the HA discovery
*configs* are namespaced, by `node_id`. So **one prefix per device is a hard
requirement**, not a preference. The cottage Q moved to `nexusq-sumperak`,
matching the existing `zigbee2mqtt-sumperak` convention, and the bridge rule
above was written for that prefix.

## 4. The real fault: the cottage Q was wearing the Prague Q's MAC

Even with the prefixes split, both units reported the same `node_id`
`nexusq_f88fca2048e1` — which keys the HA device registry entry *and every
`unique_id`*. On the cottage Q:

```
wlan0 in use     f8:8f:ca:20:48:e1   ← the FIRST (Prague) box
wlan0 permanent  f8:8f:ca:05:1f:11   ← its own, from DTS kernel patch 0043
```

`wifi-<cottage-site>.nmconnection` carried
`cloned-mac-address=<first-unit-mac>`. The `wifi-<home-site>`
profile on the *same device* was correctly on `permanent`.

### Why the 2026-08-28 fix did not cover it

It is not a regression in the repo — `gen-wifi-profile.sh`,
`pmos/device-google-steelhead/wifi-stable-mac.conf` and the baked ethernet
profiles are all correct. The window is visible in the history of a single day:

| commit | date | state |
|---|---|---|
| `1fb7f33` | 2026-08-28 | multi-site profiles added — **still hardcoding the MAC** |
| `50e57c0` | 2026-08-28 | per-unit identity fix — `cloned-mac-address=permanent` |

The Šumperák profile was generated between the two and injected onto the device;
it was never regenerated afterwards. **A fix to a generator does not reach
artifacts it has already written.** And nothing can defend against it from the
repo side at runtime: an explicit `cloned-mac-address` in a profile *overrides*
the `wifi-stable-mac.conf` NetworkManager default, and NM logs nothing when it
does.

This is the same shape as the 2026-08-28 finding — *"a redundant override stops
being harmless the moment the value it duplicates becomes per-device"* — one
layer further out: the override outlived the code that emitted it.

### The diagnostic

Two commands, on any unit, any time:

```sh
ethtool -P wlan0                    # permanent, per-unit, from the DTS
cat /sys/class/net/wlan0/address    # what is actually on the air
```

If they differ, grep **every** profile, not just the active one:

```sh
grep -r cloned-mac-address /etc/NetworkManager/system-connections/
```

Bluetooth was checked at the same time and is fine: the cottage unit reports
`F8:8F:CA:73:AC:9C`, the per-unit address recorded on 2026-08-28. Only the WiFi
identity had escaped.

### Fixing it in place

Set the profile to `permanent` and reconnect. The change is safe to do remotely
when the profile is `method=manual` — the static address survives the MAC change
(the cottage Q kept `<cottage-q>` throughout). It was applied through a
detached `systemd-run` unit carrying its own revert: restore the backup and
reconnect if the link does not come back within 90 s, so a bad edit cannot
strand a device that is only reachable over that link. It came back in 7 s.

Afterwards `nexusq-mqtt` on the **Prague** Q has to be restarted too: discovery
configs are retained and published only on connect, so the ones the cottage Q
had overwritten (all 19, repointed at `nexusq-sumperak/health/state`) stay wrong
until their real owner reconnects and republishes them.

## Result

```
nexusq_f88fca2048e1  "Nexus Q"           → nexusq/health/state            (Praha)
nexusq_f88fca051f11  "Nexus Q Šumperák"  → nexusq-sumperak/health/state   (chalupa)
```

Two Home Assistant devices, two topic trees, no shared identity.

## What changed in the repo

- `scripts/verify-rootfs.sh` — new section 4, **per-unit network identity**: a
  built image fails verification if any baked `*.nmconnection` pins a literal
  `cloned-mac-address`. Absent, `permanent` and `preserve` pass. This would have
  caught the injected cottage image at build time.
- `userspace/nexusq-mqtt/README.md` — the one-prefix-per-device requirement is
  now stated where the config is documented, instead of being implicit in the
  topic construction.

## Follow-ups not done

- The cottage profile has `dns=<home-dns>;1.1.1.1;`. The first is a Prague
  resolver, unreachable at the cottage; resolution works only via the 1.1.1.1
  fallback, after that one times out.
- Provisioning still has no self-healing story after a reflash. The companion
  app is the intended provisioner (`setMqttConfig`, PROTOCOL.md §13) but it has
  to be opened by hand; nothing notices that a device that used to publish has
  gone quiet.
