# nexusq-setupd

BT RFCOMM WiFi-provisioning daemon for the Nexus Q. Implements the
"Setup transport" of `companion/PROTOCOL.md` (**§8**): the same newline-JSON
envelope as the LAN bridge (`nexusq-control`), carried over Bluetooth RFCOMM
(BlueZ Profile1, service UUID `8e1f0cf7-508f-4875-b62c-fcd67e2f3d3a`, **channel 22**
— channel 3 collided with the Headset profile; the app resolves it by SDP UUID).

> ✅ **The transport is BONDED + ENCRYPTED** (`RequireAuthentication=True` + the app's
> secure `createRfcommSocketToServiceRecord`), so the **WiFi PSK never crosses the BT
> link in cleartext**, and the same bond serves **A2DP**. Verified live 2026-07-15
> (v1.9.0-rc4): 0 PSK lines in the journal.
>
> ⚠️ **This daemon registers NO agent.** The Q's single, **permanent**
> `NoInputNoOutput` Just-Works agent is **`nexusq-btagent`** (a hard `depends=` — the
> `RequireAuthentication=True` profile cannot bond without it). Two agents is exactly
> how onboarding broke: `blueman-applet`'s **DisplayYesNo** agent forced SSP into
> **Numeric Comparison** → an unanswerable Confirm/Deny dialog on the HDMI desktop →
> every bond timed out (mgmt `0x0e`); and `RequestDefaultAgent` is last-writer-wins.
> Rationale: `../nexusq-btagent/README.md`.
>
> _(History: rc3 briefly ran insecure/unbonded as a workaround for a pairing failure
> **wrongly** blamed on a BCM4330 hardware limit — retracted; bonding + A2DP work on
> this controller. See `../../companion/PROTOCOL.md` §8.1 and
> `../../docs/2026-07-15-bt-onboarding-root-caused-blueman-agent-and-bond-first.md`.)_

`SetupCore.handle(method, params)` implements the wire methods `getDeviceInfo`,
`confirmColor`, `scanNetworks`, `setWifi`, `getNetworkState`, `setName`,
`setTheme`, `finishSetup`, plus the pure helpers `pairing_color`,
`sanitize_hostname`, `classify_nm_error`, `parse_wifi_list` — see §8 for the
full method/result/error tables. `main()` runs the BlueZ transport (`Profile1`
D-Bus registration — **no `Agent1`**, that is nexusq-btagent's job; one RFCOMM
client thread per connection, the idle-timeout main loop); it imports `dbus`/`gi`
lazily so the module stays import-safe (no D-Bus dependency) for host tests of
`SetupCore`.

`finishSetup` is **refused** (`bad_request`) unless WiFi is already provisioned:
accepting it unprovisioned makes the daemon exit 0, so `Restart=on-failure` does
not restart it and nothing re-arms setup mode until a reboot — stranding the
device off-network with the wizard gone.

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
