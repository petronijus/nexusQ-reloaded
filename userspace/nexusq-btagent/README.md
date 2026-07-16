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

## The `ring ⇔ Pairable` invariant

> **(was `Pairable == Discoverable` in v1.9.0 — corrected 2026-07-15, btagent r3.
> The old invariant was keyed on the wrong property and silently broke OUTBOUND
> bonding. See "The invariant bug" below.)**

An auto-accept Just-Works agent bonds **any** peer that asks, with no confirmation
anywhere. For an input-less appliance that is the only workable model — but it
makes "pairable" a real exposure window, so the window must be visible and must
not outlive its purpose.

Two facts make the naive version wrong:

* bluez leaves `Pairable=true` **permanently** by default.
* **`Pairable`, not `Discoverable`, is what gates bonding.** Discovery only
  affects *inquiry* — anyone who already knows the address can bond a
  non-discoverable but pairable adapter.

So a ring driven by `Discoverable` alone would be a **lie**: dark while still
bondable. This daemon therefore keys the ring on **`Pairable`** — the only
property that gates pairing, and so the only honest thing to show. `Pairable` is
**off at rest**; a window (inbound *or* outbound, §"the control socket") is the
only thing that turns it on, and **bluez's own timer** closes it. Then the ring is
honest:

```
ring spinning blue  ==  someone can pair with this Q
ring not spinning   ==  nobody can
```

`led_plan()` is a pure function of `(pairable, owns_led, setup_running)` so this —
the part that is easy to get subtly wrong — is unit-tested without a BT stack.

## The invariant bug: `Pairable` is what makes a bond DURABLE (2026-07-15)

The v1.9.0 invariant mirrored `Pairable` onto `Discoverable`, so at rest the
adapter was `Pairable: no`. `Pairable: no` does **not** block an *outgoing*
`Pair()` — so an outbound pair appeared to work. It did not **persist**.

A/B on a real Logitech MX Master 4, same agent, **one variable**:

```
Pairable: no   ->  pair "succeeds", Bonded: no,  NO keys stored, gone on restart
Pairable: yes  ->  pair succeeds,   Bonded: yes, [PeripheralLongTermKey] +
                   [IdentityResolvingKey] on disk, SURVIVES restart
```

The chain, **measured from `bluetoothd -d`** — not read from source:

1. The key **ARRIVES**: `new_long_term_key_callback() … new LTK … enc_size 16`.
2. bluez only **persists** a key the kernel marked **`store_hint`**.
3. The kernel only marks it so when **both** sides set the SMP **bonding bit**.
4. Our side only sets that bit under **`HCI_BONDABLE`** — which is exactly
   **`Adapter1.Pairable`**.

So a mouse paired at rest reports success, connects, **genuinely types**, and is
gone after a reboot. **Inbound never hit this** because setup opens a window first.

> **Turning `Pairable` on is not a concession to minimise — it is what makes a
> bond durable.** An outbound `pair` therefore **opens a window like everything
> else**: one mechanism for both directions, and the ring stays honest throughout.

## The control socket — the bridge's only way into BlueZ

`nexusq-control` (the LAN bridge the app talks to) is **stdlib-only by standing
rule**, so it cannot speak D-Bus. That rule is right: **BlueZ knowledge belongs in
the one component that owns BlueZ**. The bridge is the app's endpoint, not a second
Bluetooth stack.

| | |
|---|---|
| Path | `/run/nexusq-btagent.sock` (`$NEXUSQ_BTAGENT_SOCK`) |
| Mode | **0600** — opening a pairing window is a privileged act |
| Framing | newline-JSON, nexusqd's envelope style: `{"m":"openWindow","secs":120}` → `{"ok":true,"secs":120}` |

| Method | Notes |
|---|---|
| `openWindow` / `closeWindow` / `windowState` | `secs` clamped 1–600, default **120** = stock steelhead's own `DiscoverableTimeout` (verified in its `/system/etc/bluetooth/main.conf`) |
| `startScan` / `stopScan` / `scanResults` | scan self-stops (25 s, clamped 5–60) |
| `pair` / `remove` / `connect` / `disconnect` | `pair` is **async** |
| `listPaired` | |

Errors use the LAN protocol's vocabulary directly (`not_found`, `pair_failed`,
`unavailable`, `unknown_method`), so the bridge passes them straight through.

> ⚠️ **Open the listening socket ONCE (r4, 2026-07-16).** `start_control()` sets up the
> listening socket + its GLib watch and is called from `run()` **only** — it is
> **idempotent** and must **never** be called from the reconcile `_tick`. Before r4 it
> was: the 10 s tick reopened the socket every pass, leaking **one fd per tick** until
> the process exhausted its ~1024 fds and crashed mid-tick with the socket file
> removed. Symptom: btagent shows `active` but every BT call fails `unavailable`
> (*"bluetooth agent unreachable: No such file or directory"*) every ~3 s while the
> link is otherwise healthy; the journal repeats `[Errno 24] No file descriptors
> available`. Verified fixed: fd count flat at 8 across ticks.

**bluez owns the window timer, not us.** The window closes even if this daemon is
killed mid-window. Verified 2026-07-15: `openWindow(30)` → open at t+10/t+20,
**CLOSED at t+30/t+40**. This was FALSE before r3 — the 10 s reconcile tick rewrote
`DiscoverableTimeout` every pass and **restarted the countdown**.

**`pair` owns its own discovery**, and is async for a reason:

* BlueZ **forgets an unpaired device object** shortly after discovery stops, so by
  the time the user taps "Pair" in the app the object from their scan is usually
  **gone** (measured: `Pair` → `UnknownObject`). `pair` re-discovers the target
  itself (25 s) rather than trusting a previous scan.
* `Pair()` takes seconds and **our own `Agent1` must answer DURING it** — a
  synchronous call would **deadlock the very agent that completes the pairing**.
* **Discovery only lives while a client holds it**: a fire-and-forget
  `bluetoothctl scan on` dies instantly (`Discovering: no`, 0 devices). That is why
  discovery lives here (D-Bus, long-lived), not in the bridge.

### Two measured traps in `device_kind()` / the scan filter

* **BLE peripherals have NO Class of Device.** The MX Keys and MX Master report
  `Class: <none>`. A CoD-based rule — the first draft — would have made Petr's
  keyboard and mouse **invisible in the app**. `device_kind()` reads
  **`Icon` → `Appearance`** (0x03c1 keyboard / 0x03c2 mouse) **→ `Class`**: bluez
  already derives `Icon` from CoD *or* the BLE Appearance, so it is the right
  primary source.
* **`Alias` can never answer "does this have an identity".** bluez **synthesises
  `Alias` from the ADDRESS** (`"6B-64-CB-F3-81-98"`) when a device has no name, so
  it is never empty. Only a real `Name` counts (or an alias differing from the
  address = user-set). Without this a 25 s scan surfaces **~38 anonymous BLE
  beacons** (measured), mostly the neighbours'.
* **A scan MAC is not a stable identity** — BLE devices change address between
  pairings/channels (the MX Master exposed `…74:F4`, `:F5`, `:F6`, `:F7`).

### Hardware-verified (2026-07-15)

* Mouse paired from the app: `{"paired":true,"bonded":true,"connected":true}`,
  **3 key sections on disk**, kernel created **`MX Master 4 Mouse`** on
  `/dev/input/…` via **uhid**.
* A real BLE keyboard (MX Keys) completes **Just Works** against our
  `NoInputNoOutput` agent — **no typed passkey**; HID works end to end
  (`/dev/uhid` → `/dev/input/event*`).

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
mechanism, its `audio` entry would disable the very A2DP we want — and, proven
2026-07-15, its **`input` entry is exactly BlueZ's HID plugin**, i.e. the thing
that makes a paired mouse or keyboard reach `/dev/uhid` → `/dev/input/event*`.
Copying stock here would have silently disabled outbound peripherals altogether.

## Interfaces

| | |
|---|---|
| D-Bus object | `/org/nexusq/btagent` on the system bus |
| Capability | `NoInputNoOutput` (auto-accept) |
| Control socket | `/run/nexusq-btagent.sock` (`$NEXUSQ_BTAGENT_SOCK`), 0600, newline-JSON — the LAN bridge's only way into BlueZ |
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
