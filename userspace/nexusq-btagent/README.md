# nexusq-btagent — the Q's Bluetooth pairing agent

The Nexus Q's single, permanent BlueZ `Agent1`. It exists because of one fact:

> **Nothing is attached to the Q that can answer a pairing prompt.** No keyboard,
> no mouse, no touchscreen. The HDMI output is not an input.

Everything below follows from that.

## The bug this fixes (root-caused live 2026-07-15)

Secure Simple Pairing chooses its pairing model from **both** ends' IO
capabilities:

| Phone | Nexus Q | Model chosen | Prompt? |
|---|---|---|---|
| DisplayYesNo | `NoInputNoOutput` | **Just Works** | none — bonds silently |
| DisplayYesNo | `DisplayYesNo` | **Numeric Comparison** | **both ends must confirm** |

`blueman-applet` (autostarted by the LXQt session) registered a **DisplayYesNo**
agent, forcing the second row. bluetoothd then raised a Confirm/Deny dialog on
the HDMI desktop that **no attached input device could click**, so every bond
timed out with mgmt status `0x0e` (authentication failed). To make it worse,
`RequestDefaultAgent` is **last-writer-wins**, so the applet also stole the
default agent from whoever registered first.

The symptom looked like a controller fault — an HCI trace showed the ACL connect,
features/name exchange, then a teardown with **no pairing HCI at all**. It was
not. Pairing + A2DP were user-confirmed working on **2026-07-09** (after kernel
r40 gave the BT UART its `max-speed`, see
`docs/2026-07-09-bluetooth-uart-max-speed-and-crackle-isolation.md`), and were
re-verified live on **2026-07-15** the moment the applet was out of the way:
a Pixel 9 Pro Fold bonded instantly, with A2DP authorized, without a single
agent callback — exactly what Just Works looks like.

> **Never re-derive a hardware limit from a userspace symptom.** An earlier
> revision of `nexusq-setupd` and the companion app both carried comments
> claiming "the BCM4330 will NOT complete SSP bonding with modern phones". That
> was wrong, and it cost a day and a cleartext-PSK workaround.

The device package therefore keeps `blueman-applet` out of the session
(`/etc/xdg/nexusq/autostart/blueman.desktop`, `Hidden=true`). The blueman
*package* stays installed — only the autostarted applet is suppressed. **Starting
`blueman-applet` by hand will break pairing again until it exits.**

## Why it is permanent, not part of setup

`nexusq-setupd` runs for a few minutes and exits. A bond has to outlive it:

* **BT audio (A2DP) needs a bond** — that is the whole point of pairing a phone
  to a speaker, and it happens long after onboarding.
* The setup RFCOMM profile is registered `RequireAuthentication=True`, so setup
  itself cannot bond without an agent present.

One always-on `NoInputNoOutput` agent serves both, and `nexusq-setupd` registers
none of its own (two agents is exactly how this broke).

Newly bonded devices are marked **`Trusted`** so their profiles reconnect later
without re-asking for service authorization.

## The `Pairable == Discoverable` invariant

An auto-accept Just-Works agent bonds **any** phone that asks, with no
confirmation anywhere. For an input-less appliance that is the only workable
model — but it makes "pairable" a real exposure window, so the window must be
visible and must not outlive its purpose.

Two facts make the naive version wrong:

* bluez leaves `Pairable=true` **permanently** by default.
* **`Pairable`, not `Discoverable`, is what gates bonding.** Discovery only
  affects *inquiry* — anyone who already knows the address can bond a
  non-discoverable but pairable adapter.

So a ring driven by `Discoverable` alone would be a **lie**: dark while still
bondable. This daemon holds `Pairable == Discoverable` (Discoverable is the
intent; Pairable is derived from it — never the reverse, which would *widen* the
exposure). Then the ring is honest:

```
ring spinning blue  ==  someone can pair with this Q
ring not spinning   ==  nobody can
```

## LED ownership

`nexusq-setupd` drives the ring while setup runs (its own blue spin, plus
connecting / success / error states) and deliberately **leaves the chosen theme
up** when it finishes successfully.

So this daemon only touches the ring when **it** took it — i.e. the adapter
became discoverable while setupd was *not* running (a manual or anomalous
exposure, precisely the case worth showing). It never releases a ring it did not
take, which is what stops it wiping setupd's applied theme. `led_plan()` is a
pure function so those rules are unit-tested (`tests/test_btagent.py`).

The ring is a soft dependency throughout: `led_send()` tolerates nexusqd being
down, and the 10 s reconcile retries once it comes back.

## Stock parity

Stock steelhead had **exactly one** agent — BlueZ 4.93 made a second one
*impossible* (`RegisterAgent` was per-adapter and returned
`org.bluez.Error.AlreadyExists`), and `RequestDefaultAgent` did not exist at all.
Our two-agent race is a **BlueZ-5-only failure mode with no stock analogue**.

Two deliberate, documented divergences from stock:

* **IO capability.** Stock used `DisplayYesNo`
  (proven in `libandroid_runtime.so`'s `register_agent()`), but its setup path
  **never bonded at all**, so that capability was never exercised by onboarding.
  `NoInputNoOutput` is strictly better for an input-less Q; we do not "fix" this
  toward stock.
* **Bonded setup.** Stock's setup channel was insecure, unbonded RFCOMM
  (`listenUsingInsecureRfcommWithServiceRecord`; no `createBond` anywhere in
  `HubBroker.odex`) and accepted a **cleartext WiFi PSK**. We require
  authentication instead — see the rationale in `nexusq-setupd`. Stock could
  afford unbonded because it shipped **no A2DP whatsoever**
  (`DisablePlugins = audio,network,input`); we want BT audio, so a bond must
  exist regardless, and reusing it encrypts the PSK for free.

Do **not** copy stock's `DisablePlugins = audio,network,input`: it is a BlueZ 4
mechanism, and its `audio` entry would disable the very A2DP we want.

## Interfaces

| | |
|---|---|
| D-Bus object | `/org/nexusq/btagent` on the system bus |
| Capability | `NoInputNoOutput` (auto-accept) |
| LED | `spin 0 153 204` / `auto` via `/run/nexusqd.sock` (`$NEXUSQD_SOCK`) |
| Unit | `nexusq-btagent.service`, `Restart=always`, enabled via `95-nexusq.preset` |

Resilience: re-registers on `NameOwnerChanged` for `org.bluez` (bluetoothd
restarts, or starts after us, and drops every agent when it does), with a 10 s
reconcile tick as a backstop for missed signals and late adapters.

## Tests

```sh
python3 -m unittest discover -s userspace/nexusq-btagent/tests -v
```

D-Bus/gi are imported inside `_run()` (same pattern as `nexusq-setupd`) so the
pure logic stays importable on a host with no BlueZ.
