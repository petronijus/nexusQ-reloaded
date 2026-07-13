# nexusq-setupd

BT RFCOMM WiFi-provisioning daemon for the Nexus Q. Implements the
"Setup transport" of `companion/PROTOCOL.md` (**§8**): the same newline-JSON
envelope as the LAN bridge (`nexusq-control`), carried over Bluetooth RFCOMM
(BlueZ Profile1, service UUID `8e1f0cf7-508f-4875-b62c-fcd67e2f3d3a`, channel 3).

`SetupCore.handle(method, params)` implements the wire methods `getDeviceInfo`,
`confirmColor`, `scanNetworks`, `setWifi`, `getNetworkState`, `setName`,
`setTheme`, `finishSetup`, plus the pure helpers `pairing_color`,
`sanitize_hostname`, `classify_nm_error`, `parse_wifi_list` — see §8 for the
full method/result/error tables. `main()` runs the BlueZ transport
(`Profile1`/`Agent1` D-Bus registration, one RFCOMM client thread per
connection, the idle-timeout main loop); it imports `dbus`/`gi` lazily so the
module stays import-safe (no D-Bus dependency) for host tests of `SetupCore`.

Config via env:

| Var | Default |
|---|---|
| `NEXUSQ_SETUP_UUID` | `8e1f0cf7-508f-4875-b62c-fcd67e2f3d3a` |
| `NEXUSQD_SOCK` | `/run/nexusqd.sock` |
| `NEXUSQ_IDENTITY` | `/etc/nexusq/device.json` |
| `NEXUSQ_SETUP_TIMEOUT` | `600` (seconds of inactivity before exit) |
| `NEXUSQ_WLAN_IFACE` | `wlan0` |

Runs only in setup mode: `nexusq-setupd.service`'s `ExecCondition
/usr/bin/nexusq-setup-needed` exits 0 (run) when `/run/nexusq-setup.force`
exists **or** no `802-11-wireless` NetworkManager profile exists yet, so it
fires both on a fresh unprovisioned boot and on demand via the LAN bridge's
`startSetupMode` method. It exits cleanly (discoverable off, LED back to
`auto` unless a theme was chosen, force flag unlinked) after `finishSetup` or
600 s of inactivity; a crash leaves the force flag set so
`Restart=on-failure` re-enters setup mode instead of stranding the user
mid-wizard. Credentials (`psk`) are never logged or printed.

Tests: `docker run --rm -v "$PWD":/src -w /src python:3.11-slim sh -c
"python -m unittest discover -s userspace/nexusq-setupd/tests -v"` (pure
`SetupCore`/framing logic — no BlueZ/D-Bus needed).
