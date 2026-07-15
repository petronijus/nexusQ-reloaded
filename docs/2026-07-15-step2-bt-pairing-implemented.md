# 2026-07-15 — Step 2 implemented: BT pairing from the app, BOTH directions, + the HDMI desktop on demand

**Released as v1.10.0** (device r48 / btagent r3 / control r10 / setupd r4 /
nexusqd r10 / kernel r43 `#44` / firmware r2; app on its own track at **1.2.0+7**).
Built on v1.9.0's BlueZ infrastructure. Hardware-verified and user-accepted.

Spec: `docs/superpowers/specs/2026-07-15-step2-bt-pairing-via-app.md` (its §4.1
invariant text is **superseded** by §2 below). Separate subject from the same-day
`docs/2026-07-15-bt-onboarding-root-caused-blueman-agent-and-bond-first.md`
(that one is step 1's root cause).

---

## 1. The framing that matters — and that the spec got wrong

Petr's correction reframed the entire step:

> The Q has **no screen and no input device**, so **the app is the ONLY way to pair
> anything to it — it IS the Q's Bluetooth settings panel.**

The original phase spec only imagined *"let a phone pair for music"*. It missed the
half that **only the app can do**:

| Direction | Who initiates | Example |
|---|---|---|
| Inbound | the phone | pairs for music (A2DP) |
| **Outbound** | **the Q** | scans for and pairs a **mouse / keyboard** |

**Outbound is a different flow, not a variant of inbound.** A mouse never connects
TO us — no amount of waiting or being discoverable makes it appear. We must
*discover* it and call `Pair()` on it. Everything below follows from that.

---

## 2. ⛔ ROOT CAUSE — the v1.9.0 invariant was keyed on the WRONG property

`Pairable == Discoverable` (shipped v1.9.0) **silently broke OUTBOUND bonding**.

A/B on a real **Logitech MX Master 4**, same agent, **one variable**:

```
Pairable: no   ->  pair "succeeds", Bonded: no,  NO keys stored, gone on restart
Pairable: yes  ->  pair succeeds,   Bonded: yes, [PeripheralLongTermKey] +
                   [IdentityResolvingKey] on disk, SURVIVES restart
```

The chain, **measured from `bluetoothd -d`** — not read from source:

1. The key **ARRIVES**:
   `new_long_term_key_callback() … new LTK … enc_size 16`
2. bluez only **persists** a key the kernel marked **`store_hint`**.
3. The kernel only marks it so when **both** sides set the SMP **bonding bit**.
4. Our side only sets that bit under **`HCI_BONDABLE`** — which is exactly
   **`Adapter1.Pairable`**.

So a mouse paired at rest **reports success, connects, genuinely types, and
evaporates on reboot**. `Pairable: no` never blocked the *outgoing* `Pair()` — which
is precisely why this hid: the failure was in **persistence**, not in pairing.
**Inbound never hit it** because setup opens a window first.

### The fix

The ring now keys off **`Pairable`** — the only property that gates pairing, so the
only honest thing to show. `Pairable` is **off at rest**, and an **outbound pair
OPENS A WINDOW like everything else**: one mechanism for both directions.

> **Turning `Pairable` on is not a concession to minimise — it is what makes a bond
> durable.**

Lesson, again ([[verify-hypothesis-against-stock]] in spirit): the safety property
we care about is *"ring dark ⇒ nobody can pair"*. Deriving it from `Discoverable`
mirrored the *wrong* half of the pair — `Discoverable` governs **inquiry** only.

---

## 3. What shipped

### `nexusq-btagent` r3 — a control socket

`/run/nexusq-btagent.sock`, **0600**, newline-JSON. It is the LAN bridge's **only**
way into BlueZ: the bridge is **stdlib-only by standing rule**, and that rule is
right — **BlueZ knowledge belongs in the component that owns BlueZ**, not in a
second Bluetooth stack.

Methods: `openWindow`/`closeWindow`/`windowState`, `startScan`/`stopScan`/
`scanResults`, `pair`/`remove`/`connect`/`disconnect`, `listPaired`.

**`pair` is async, and owns its own discovery:**

- `Pair()` takes seconds and **our own `Agent1` must answer DURING it** — a
  synchronous call would **deadlock the very agent that completes the pairing**.
- BlueZ **forgets an unpaired device object** shortly after discovery stops, so the
  object from the user's scan is usually **gone** by the time they tap Pair
  (measured: `Pair` → `UnknownObject`). `pair` re-discovers the target itself (25 s)
  rather than trusting a previous scan.

### `nexusq-control` r10

`startPairing`/`stopPairing`/`getPairingState`, `startBtScan`/`stopBtScan`/
`listBtScanResults`, `pairBtDevice`/`removePairedDevice`/`connectBtDevice`/
`disconnectBtDevice`, `listPairedDevices`; events **`pairingChanged`**,
**`pairedDevicesChanged`**. Plus **`setDesktop`/`getDesktop`** + **`desktopChanged`**.
Documented in the new **PROTOCOL §9 / §10** (these methods existed **only in code**
until this release).

### `device-google-steelhead` r48

Bakes `/var/lib/systemd/linger/user`.

### Companion app 1.2.0+7

A new **Devices** screen (*Pair a phone* / *Add a mouse or keyboard* / paired list
with *Forget* / **HDMI desktop toggle**), reachable from the home app bar. The app is
versioned on its **own independent track — NEVER aligned to image releases**.

---

## 4. Measured facts that cost real time

- **BLE peripherals have NO Class of Device.** The MX Keys / MX Master report
  `class=none` and identify via BlueZ's **`Icon`** (`input-keyboard`/`input-mouse`) +
  **`Appearance`** (0x03c1/0x03c2). **A CoD-based device-type rule — this spec's
  first draft — would have hidden Petr's keyboard and mouse from the app entirely.**
  `device_kind()` uses **Icon → Appearance → Class**, in that order (bluez already
  derives `Icon` from CoD *or* the BLE Appearance, so it is the right primary source).
- **BlueZ synthesises `Alias` from the ADDRESS** (`"6B-64-CB-F3-81-98"`) when a
  device has no name — so **`Alias` can never answer "does this have an identity"**.
  Only a real `Name` counts. Without this, a scan returns a wall of the neighbours'
  anonymous BLE beacons (**~38 in 25 s**).
- **BLE devices change address between pairings/channels** — the MX Master exposed
  `…74:F4`, `:F5`, `:F6`, `:F7` on different channels. **A scan MAC is not a stable
  identity.**
- **Discovery only lives while a client holds it.** A fire-and-forget
  `bluetoothctl scan on` dies instantly (`Discovering: no`, 0 devices). This is why
  discovery lives in **btagent** (D-Bus, long-lived), not in the bridge.
- **The `user` linger is load-bearing** for the desktop toggle: PA + librespot are
  user units under `user@10000.service`; the desktop is `tinydm` → labwc in
  `session-c1.scope`. **Without linger the user manager exists only because of the
  graphical session, so stopping the desktop would kill the music.** Verified: with
  linger, `systemctl stop tinydm` leaves **pulseaudio + librespot active, both sinks
  present**.
- **Stopping the desktop churns logind** hard enough that ssh auth (`pam_systemd`)
  **hung for ~a minute** during testing. It recovered on its own; `set_desktop`
  therefore uses a **60 s deadline**.
- **A pairing window self-closes via bluez's own timer** — verified: `openWindow(30)`
  → open at t+10/t+20, **CLOSED at t+30/t+40**. **Earlier this was FALSE**: our own
  10 s reconcile tick rewrote `DiscoverableTimeout` and **restarted the countdown**
  every pass. Fixed. bluez owning the timer also means the window closes even if
  btagent is killed mid-window.

---

## 5. `bonded` vs `paired` — **`paired` alone LIES**

`pairBtDevice` returns `{paired, bonded, connected}`. **`paired: true` +
`bonded: false`** is a device that pairs, connects, genuinely types — and is **gone
on reboot**. Only **`bonded`** answers *"will this survive a restart?"*. Any UI or
caller that reads `paired` is reading a lie.

---

## 6. Hardware-verified acceptance

- **Mouse paired from the app**: `pairBtDevice` →
  `{"paired":true,"bonded":true,"connected":true}`, **3 key sections on disk**, and
  the kernel created **`MX Master 4 Mouse`** on `/dev/input/…` via **uhid**.
- **A real BLE keyboard (MX Keys) completes Just Works** against our
  `NoInputNoOutput` agent — **no typed passkey**. HID works end to end
  (`/dev/uhid` → `/dev/input/event*`).
- **Good thing we never copied stock's `DisablePlugins = audio,network,input`** —
  that **`input` is exactly BlueZ's HID plugin**. Copying stock here would have
  silently disabled outbound peripherals altogether. (Its `audio` entry would have
  killed A2DP; already known.)
- **Petr confirmed from the app**: mouse listed with the right icon, desktop toggle
  works both ways, phone paired to the Q, mouse forgotten and re-paired.

---

## 7. Known issues — open, recorded, NOT glossed

- **The v1.9.0 onboarding pairing flake is still un-root-caused** — 1 run × 2
  failures; 3+ runs first-try since.
- **The contactless-payment link is UNPROVEN.** App 1.1.1 scoped its NFC claim, but
  the telemetry **never showed our uid toggling observe mode**. The fix may be
  correct; it is **not demonstrated**.
- **Factory WiFi MAC: ROOT-CAUSED but NOT fixed.** `gen-wifi-profile.sh` pins
  `cloned-mac-address` into the **BAKED dev profile only**; the profile setupd
  creates via `nmcli connection add` does **not**, so NM falls back to `permanent` =
  the chip **OTP MAC `14:7d:c5:3a:35:b5`**. **The device has no source for the
  factory MAC at all** (nvram says a generic Broadcom default). **Proper fix mirrors
  BT**: a `local-mac-address` in the DTS wifi node, **after a stock audit**. Until
  then **use the OTP MAC for lease lookups**.
- **Thermal: 102.8 °C** under sustained load — **above the documented 94–99 °C
  envelope**. True idle **72–75 °C / 52 % at 350 MHz**. The desktop toggle's thermal
  delta was **never measured** — the idle-heat question it was meant to answer is
  still open.
- **librespot boot race** — 5 restarts, self-heals.
- **`onboard` SIGSEGVs every boot** — its native `osk` module. **NOT** the old flash
  corruption.
- **`NEXUSQ_NO_WIFI=1` build flag** — still promised-but-unwritten.
- **The Devices screen has had NO design review.** Petr tested it **functionally**
  2026-07-15; the copy is unreviewed, and the screen has **no Flutter tests of its
  own** (the suite is still 14, all predating it).
