# Step 2 — BT pairing via the app: design

**Date:** 2026-07-15 · **Status:** design agreed (open questions answered
2026-07-15) — ready to become a plan
**Scope:** step 2 of the software/ease-of-use phase
(`2026-07-13-onboarding-and-companion-phase-design.md`).

The phase spec defined step 2 narrowly:

> **BT pairing via app** — rides on step 1's BlueZ infrastructure (agent,
> discoverable, LED indication); A2DP surfaced as a visible input in the app.

**That framing is too narrow, and the correction reframes the whole step**
(Petr, 2026-07-15):

> "když nechci spárovat třeba telefon, ale nějakou jinou periferii, třeba myš,
> klávesnici, nebo co já vím, tak bez screenu to udělat nemůžu, takže párovat
> bluetooth devices k Nexusu můžu dělat jenom přes aplikaci"

So this is not "let a phone pair for music". **The app is the Q's only input
device — it IS the Q's Bluetooth settings screen.** A display-less, keyboard-less
appliance cannot pair anything without it. That means step 2 must cover BOTH
directions:

| Direction | Who initiates | Example | In the original spec? |
|---|---|---|---|
| **Inbound** | the phone | phone pairs to play music | yes |
| **Outbound** | **the Q** | Q scans for and pairs a **mouse / keyboard** | **no — missing** |

Outbound is a different flow, not a variant: a mouse never "connects to" the Q.
The Q must scan, list what it found, and call `Pair()` on the chosen device.

This also composes with the "desktop on demand" idea (own task): pair a keyboard
and mouse, switch the HDMI desktop on, and the appliance is usable as a computer.

**Relevant luck:** we deliberately did NOT copy stock's
`DisablePlugins = audio,network,input`. That `input` is exactly BlueZ's HID
plugin — keyboards and mice. Stock disabled it because stock supported no
peripherals; we have it.

## 1. What already exists (shipped in v1.9.0 — do not rebuild)

Step 2 was written expecting to build the BlueZ plumbing. It does not have to:
the 2026-07-15 pairing root-cause work built all of it, and it is hardware-
verified.

| Step 2 needs | Status | Where |
|---|---|---|
| Headless Just-Works agent | ✅ **permanent**, not setup-scoped | `nexusq-btagent` (NoInputNoOutput, auto-accept, marks bonds `Trusted`) |
| Discoverable/pairable window | ✅ with the `Pairable == Discoverable` invariant | `nexusq-btagent` |
| LED indication of the window | ✅ ring spins blue ⇔ someone can pair | `nexusq-btagent` (`led_plan`) |
| A2DP actually working | ✅ verified | `bluez_source.<mac>.a2dp_source` s24le/48k + PA `module-loopback` |
| Bond survives reboot / bluetoothd restart | ✅ verified | `/var/lib/bluetooth/<adapter>/<mac>` |
| Class of Device = speaker | ✅ `0x…0428` (Audio/Video, HiFi Audio) | bluez `main.conf` |

**So step 2 is mostly an EXPOSURE problem, not a Bluetooth problem.** What is
missing is: a way to open the window without walking the WiFi wizard, a way to
see/remove bonds, and an input concept in the protocol.

## 2. The problem, concretely

**Inbound.** To pair a phone for BT audio the user must either walk the whole
setup wizard — which re-provisions WiFi, absurd for "play music from my phone" —
or ssh in. If a phone gets un-paired, re-pairing should be *just Bluetooth*, not
a re-run of setup and provisioning.

**Outbound.** There is no way at all to pair a mouse, a keyboard, or anything
else. The Q has no screen and no input; `bluetoothctl` over ssh is the only
route, which is not a product.

**Visibility.** Once paired, the app never shows that Bluetooth is the thing
playing: `nowPlaying.source` is the hardcoded string `"spotify"`.

## 3. Constraints that shape the design

- **`nexusq-control` is stdlib-only.** `depends="python3 pulseaudio-utils
  alsa-utils avahi-tools"` — no `py3-dbus`, by standing rule (step-1 plan, Global
  Constraints). It can only reach BlueZ by shelling out to `bluetoothctl`.
  `nexusq-setupd`/`nexusq-btagent` are the only components allowed dbus.
- **Nothing on the Q can answer a pairing prompt** — NoInputNoOutput/Just-Works
  is the only workable model, and it auto-accepts. So the pairing window is a
  real exposure and must stay short, deliberate and visible. This is why the ring
  invariant exists; step 2 must not weaken it.
- **`blueman-applet` must stay out of the session.** Its DisplayYesNo agent
  re-breaks pairing (see `userspace/nexusq-btagent/README.md`).
- **Stock parity where it is informative**: stock used
  `DiscoverableTimeout = 120` (2 min) and `PairableTimeout = 0`. Stock had **no
  A2DP at all**, so it is NOT a precedent for the input work — do not copy its
  `DisablePlugins = audio,network,input`.

## 4. Design

### 4.1 Opening the pairing window — `startPairing`

**The bridge only has to flip `Discoverable`; everything else already follows.**
`nexusq-btagent` holds `Pairable == Discoverable` and drives the ring, so a single
change produces: pairable adapter + spinning ring + auto-accepting agent + bonds
marked `Trusted`. No new daemon, no IPC, no dbus in the bridge.

```
startPairing  →  bluetoothctl discoverable-timeout <N>
                 bluetoothctl discoverable on
              →  btagent: enforces Pairable=True, takes the ring (blue spin)
              →  window closes itself after N s (bluez timer)
              →  btagent: enforces Pairable=False, releases the ring
```

This is deliberately **not** `startSetupMode`: that arms `/run/nexusq-setup.force`
and starts the WiFi provisioning daemon. Pairing must not touch WiFi.

- `startPairing` → `{ "pairing": true, "timeout": <seconds> }`
- `stopPairing` → `{ "pairing": false }` (close it early)
- `getPairingState` → `{ "pairing": bool, "secondsLeft": int|null }`
- Event: `pairingChanged`

The window MUST be self-closing. A bluez `DiscoverableTimeout` does that without
us running a timer — if the bridge dies mid-window, the window still closes. That
is the fail-safe direction, and it is the same lesson as `nexusq-setup-needed`:
decide which way it fails *before* writing it.

### 4.2 Outbound — the Q pairs a peripheral (mouse, keyboard, …)

The half the original spec missed, and the half that only the app can do.

#### ⚠️ MEASURED 2026-07-15: discovery cannot live in the stdlib bridge

The obvious shape — bridge shells out `bluetoothctl scan on`, returns, and polls
results later — **does not work**, and this was verified on the device rather
than assumed:

```
(bluetoothctl scan on &) ; sleep 20 ; bluetoothctl show
  → Discovering: no        # the scan died with the client
  → 0 devices found

bluetoothctl --timeout 20 scan on          # blocking client, holds the session
  → 28 unique devices, incl. "[LG] webOS TV UK6200PLA"
  → afterwards: Discovering: no
```

**Discovery only lives while a client holds it.** `bluetoothctl` is an
interactive client: `scan on` is bound to its session, so a fire-and-forget call
from the bridge scans for milliseconds and finds nothing. The blocking
`--timeout` form works but would block the bridge's request thread for the whole
scan — unacceptable for a daemon that also serves volume/state to the app.

**Consequence: outbound discovery belongs in `nexusq-btagent`, not the bridge.**
btagent already has dbus (`StartDiscovery`/`StopDiscovery` on `Adapter1`,
`InterfacesAdded` for incremental results) and is long-lived. The stdlib-only
rule on the bridge is not an obstacle to route around — it is a signal that this
work belongs in the component that owns BlueZ.

That implies **the one genuinely new piece of plumbing in step 2**: an IPC from
the bridge to btagent (the bridge is the app's only endpoint). Options — a small
unix socket on btagent (mirrors nexusqd's `/run/nexusqd.sock`, a pattern already
in the tree), or the bridge gaining dbus (breaks a standing rule; needs Petr).
**Recommend the unix socket**: keeps the rule, matches an existing pattern, and
keeps BlueZ knowledge in one component.

```
app → bridge (LAN, JSON)        →  btagent (unix socket)  →  BlueZ (dbus)
      startBtScan/pairBtDevice      StartDiscovery/Pair       adapter/device
```

#### The flow

```
startBtScan        →  btagent: Adapter1.StartDiscovery, auto-stop after N s
listBtScanResults  →  btagent: ObjectManager devices + Class/RSSI/Name
pairBtDevice{mac}  →  btagent: Device1.Pair → Set Trusted → Device1.Connect
stopBtScan         →  btagent: Adapter1.StopDiscovery
```

- `startBtScan` → `{ scanning: true, timeout: <s> }` — MUST self-stop (a
  permanently scanning radio hurts BT/WiFi coexistence on this shared antenna).
- `listBtScanResults` → `{ "devices": [ {mac, name, cls, rssi, paired} ] }`
  where `cls` is derived from the Class of Device so the app can show
  *mouse / keyboard / headphones / phone / other* with the right icon and words.
  This matters: "pair a device" with a list of bare MACs is unusable on an
  appliance with no screen to cross-check against.
- `pairBtDevice` `{ mac }` → `{ paired, connected }`. Errors: `not_found`,
  `timeout`, `unavailable`, plus a `pair_failed` for a refused/failed bond.
  **Pair → Trust → Connect is one operation** from the user's point of view;
  `trust` is what makes a keyboard reconnect by itself after a reboot, and
  forgetting it is the classic "why do I have to re-pair every time" bug.
- Event: `btScanResult` (incremental — discovery trickles in over seconds; a
  poll-only API makes the UI feel broken).

**Pairing model for peripherals.** SSP picks from both ends' IO capabilities. Our
agent is NoInputNoOutput, so:
  - mouse (NoInputNoOutput) → **Just Works** ✓
  - keyboard (KeyboardOnly) → **Just Works** from our side ✓ — but many keyboards
    demand a passkey typed ON the keyboard. Our agent's `RequestPasskey` returns
    0, which such a keyboard will reject. **This needs a real on-device test with
    a real keyboard before we promise it in the UI** — do not assume.
  - headphones (NoInputNoOutput) → Just Works ✓, but the Q is a *speaker*
    (A2DP sink-ish role); pairing headphones is out of scope here.

**⚠️ Design risk our own invariant may have created.** `nexusq-btagent` holds
`Pairable == Discoverable`, so at rest the adapter is `Pairable: no`. `Pairable`
governs INCOMING pairing — but it must be **verified on the device** that BlueZ
still permits an OUTGOING `Device1.Pair()` while `Pairable: no`. If it does not,
outbound pairing needs a scoped exception (open the window for the duration of an
outbound pair, ring and all), and that exception must not become "just leave
Pairable on". **Verify before designing around it** — this is exactly the kind of
assumption that cost a day on 2026-07-15.

### 4.3 Bond management

- `listPairedDevices` → `{ "devices": [ {mac, name, cls, connected, trusted} ] }`
  (`bluetoothctl devices Paired` + `info <mac>`)
- `removePairedDevice` `{ mac }` → `{ removed: true }` (`bluetoothctl remove`)
- `connectBtDevice` / `disconnectBtDevice` `{ mac }` — a paired-but-idle keyboard
  or phone should be reconnectable without re-pairing.
- Event: `pairedDevicesChanged`

Removing the bond a phone is streaming on will drop the stream. Expected —
confirm in the UI, do not prevent.

**Do not offer "Forget" for the device the app itself is talking to over BT
during setup** — that is a foot-gun with no undo on a screenless box.

### 4.4 Bluetooth as a visible input — the actual design question

The protocol has **outputs** (`listOutputs`/`setOutput` — speaker/spdif/hdmi) but
no **inputs**. `nowPlaying.source` is the constant `"spotify"`.

Proposed shape, mirroring the existing outputs API:

- `listInputs` → `{ "inputs": [ {id, label, available, active} ] }`
  with `id ∈ {spotify, bluetooth}`; `bluetooth.available` = a `bluez_source.*`
  exists, `active` = it is not `SUSPENDED`.
- `nowPlaying.source` becomes `"spotify" | "bluetooth"` (it already exists in the
  envelope, so this is a value change, not a shape change).
- Event: `inputChanged`.

**Detection is stdlib-friendly**: `pactl list sources short` already shows
`bluez_source.<mac>.a2dp_source` and its `SUSPENDED`/`RUNNING` state — the bridge
already shells out to `pactl`. No dbus needed.

**Metadata (title/artist over AVRCP) is NOT stdlib-friendly**: it lives on BlueZ's
`org.bluez.MediaPlayer1` D-Bus interface, which the bridge may not use. Options:
  (a) ship BT now-playing without metadata in step 2 (source + connected device
      name only) — honest and cheap;
  (b) have `nexusq-btagent` (which already has dbus) publish AVRCP metadata to a
      small file/socket the bridge reads;
  (c) relax the stdlib rule for the bridge.
**Recommendation: (a) now, (b) later if wanted.** (b) is a real feature, not a
workaround, but it widens step 2 and the value is mostly cosmetic while the phone
already shows what is playing.

`setInput` is **NOT proposed**: the input is whatever is streaming. A phone
connecting IS the switch. Adding a manual selector invites "I pressed Bluetooth
but nothing plays".

### 4.5 LED

No new LED work. The ring already means "someone can pair" while the window is
open, and that meaning is now identical whether the window was opened by setup or
by this button — which is exactly what we want.

## 5. App

- **Settings/device screen**: a "Pair a phone" button → calls `startPairing`,
  shows a countdown and "hold your phone near the Q", closes on `pairingChanged`
  or timeout. Mirrors the ring the user is looking at.
- **Paired devices list**: name + connected state + "Forget".
- **Input indication**: the home screen shows Bluetooth as the source when a
  phone is streaming, with the device name.
- App version bumps on **its own track** (never aligned to the image release).

## 6. Security notes (must not regress)

- The window auto-accepts **any** device that asks. Keep it short, keep it
  ring-visible, keep it user-initiated. Never expose "stay discoverable forever".
- `Pairable == Discoverable` stays intact — do not add a code path that sets one
  without the other. `Pairable`, not `Discoverable`, is what gates bonding.
- `startPairing` is reachable from the LAN bridge, i.e. anyone on the WiFi can
  open a pairing window. That is a genuine (if modest) exposure: the ring makes it
  visible, but there is no authentication on the bridge today. **Flagged as an
  open question, not silently accepted.**

## 7. Non-goals (step 2)

- AVRCP transport control (play/pause/next from the app) — the same "no local
  transport API" reservation as librespot (PROTOCOL §5). Revisit with step 3.
- HFP/headset profile. The Q is a speaker.
- Multi-device audio / switching between two streaming phones.
- Deciding the desktop-toggle feature (Petr's idea, own task) — same button-in-
  the-app shape, but a different subsystem; keep them separate specs.

## 8. Decisions (answered by Petr, 2026-07-15)

1. **Window length: 120 s.** Stock parity, and the ring makes it visible.
2. **BT now-playing metadata: DROPPED from step 2.** No AVRCP metadata bridge;
   BT shows as the source with the device name, nothing more. The phone already
   shows what is playing, so the value did not justify widening the step.
3. **Bridge authentication: accepted as-is for now, documented.** `startPairing`
   is reachable by any LAN client — the same property `startSetupMode` already
   has, so step 2 does not open a new hole. Recorded as a known exposure; the
   ring is the mitigation. Revisit if the bridge ever leaves the home LAN.
4. **Scope confirmed and WIDENED — see the top of this document.** The app is the
   Q's only input device. Two use cases, both real:
   - a phone that got un-paired should be re-pairable **without re-running setup
     and provisioning** — it is "just Bluetooth", not onboarding;
   - **peripherals: a mouse, a keyboard, whatever.** With no screen there is no
     other way to pair them at all. This is what turns step 2 from a convenience
     into the Q's Bluetooth settings screen — and it is why outbound (§4.2)
     exists in this spec at all.

## 9. Verify before planning (do not design around assumptions)

**Done 2026-07-15:**

- ✅ **Can the Q discover anything at all?** Yes — **28 unique devices in a 20 s
  scan**, incl. `[LG] webOS TV UK6200PLA`. The radio is fine; outbound pairing is
  viable.
- ✅ **Can the bridge own discovery?** **No** — a fire-and-forget
  `bluetoothctl scan on` dies with its client (`Discovering: no`, 0 found). This
  moved discovery into btagent + an IPC; see §4.2. Found by testing, not reasoning.

**Still open — must be answered before this becomes a plan:**

- **Does BlueZ allow an outgoing `Device1.Pair()` while `Pairable: no`?** Our
  invariant makes that the resting state. If it blocks, §4.2 needs a scoped
  exception (open the window for the duration of the outbound pair, ring and
  all) — and that exception must never become "just leave Pairable on".
  *Not yet testable end-to-end: it needs a real peripheral in pairing mode.*
- **Does a real Bluetooth keyboard complete Just-Works against our
  NoInputNoOutput agent**, or does it insist on a passkey typed on the keyboard
  (our agent answers `RequestPasskey` with 0, which such a keyboard rejects)?
  This decides whether "pair a keyboard" is a promise we can put in the UI.
  **Needs a physical keyboard** — do not assume either way.
- **Does discovery hurt WiFi** on this shared BCM4330 antenna? WiFi is the app's
  own transport, so a scan that stalls the bridge connection is self-defeating.
  Measure bridge latency during a scan.

## 10. References

- Phase decomposition: `docs/superpowers/specs/2026-07-13-onboarding-and-companion-phase-design.md`
- Step 1 design + plan: same file (§ Step 1) · `docs/superpowers/plans/2026-07-13-onboarding-step1.md`
- The BlueZ infrastructure this rides on: `userspace/nexusq-btagent/README.md`
- Why blueman must stay out / why Just-Works: `docs/2026-07-15-bt-onboarding-root-caused-blueman-agent-and-bond-first.md`
- Protocol envelope + current methods: `companion/PROTOCOL.md`
