# nexusq-setupd

BT RFCOMM WiFi-provisioning daemon for the Nexus Q. Implements the
"Setup transport" of `companion/PROTOCOL.md` (§8): the same newline-JSON
envelope as the LAN bridge, carried over Bluetooth RFCOMM (BlueZ Profile1,
service UUID `8e1f0cf7-508f-4875-b62c-fcd67e2f3d3a`).

This task (4) provides the transport-agnostic core: `SetupCore.handle(method,
params)` implementing `getDeviceInfo`, `confirmColor`, `scanNetworks`,
`setWifi`, `getNetworkState`, `setName`, `setTheme`, `finishSetup`, plus the
pure helpers `pairing_color`, `sanitize_hostname`, `classify_nm_error`,
`parse_wifi_list`. The BlueZ RFCOMM transport lands in Task 5; `main()` here
is a stub (prints and exits 0) so the module stays import-safe with no
D-Bus dependency.

Config via env:

| Var | Default |
|---|---|
| `NEXUSQ_SETUP_UUID` | `8e1f0cf7-508f-4875-b62c-fcd67e2f3d3a` |
| `NEXUSQD_SOCK` | `/run/nexusqd.sock` |
| `NEXUSQ_IDENTITY` | `/etc/nexusq/device.json` |
| `NEXUSQ_SETUP_TIMEOUT` | `600` (seconds of inactivity before exit) |
| `NEXUSQ_WLAN_IFACE` | `wlan0` |

Runs only in setup mode (unit `ExecCondition`: no WiFi profile yet, or the
bridge's `startSetupMode` force flag), and exits after `finishSetup` or
600 s of inactivity. Credentials (`psk`) are never logged or printed.
