# 2026-07-15 — BT onboarding ROOT-CAUSED + FIXED: blueman's agent hijacked SSP, and the app bonded on demand

**Status: onboarding WORKS from a fresh flash, autonomously, user-accepted —
RELEASED as v1.9.0.** Root-caused and first accepted on **v1.9.0-rc4**; the
release is built from **v1.9.0-rc5**, which adds the **fail-closed** fix (§6),
the `startSetupMode` result (§7) and the NFC-claim scoping (§8). This
**supersedes** `docs/2026-07-14-bt-onboarding-state-as-is.md` ("does NOT work
autonomously"), which is kept as the record of what was known then — its §2
hypothesis was right, its §4 "insecure RFCOMM workaround to revisit" is now
**retired**.

Base: v1.8.2 (`1504ef3`, kernel r43 `#44`). Shipped package set: device **r47**,
setupd **r4**, btagent **r1**, nexusqd **r10**, kernel **r43**, firmware **r2**;
companion app **1.1.1+5** (its own independent track). Pairing/A2DP evidence
reference: `docs/2026-07-09-bluetooth-uart-max-speed-and-crackle-isolation.md`.

---

## 1. The bottom line

BT onboarding failed for **two independent bugs, BOTH ours, NEITHER hardware**.
Both are fixed and verified live on the device.

### Bug 1 — `blueman-applet` hijacked the SSP pairing model

Secure Simple Pairing picks its model from **both** ends' IO capabilities:

| Phone | Nexus Q | Model | Prompt? |
|---|---|---|---|
| DisplayYesNo | `NoInputNoOutput` | **Just Works** | none — bonds silently |
| DisplayYesNo | `DisplayYesNo` | **Numeric Comparison** | **both ends must confirm** |

`blueman-applet` (autostarted by the LXQt session) registers a **DisplayYesNo**
agent → the second row → bluetoothd raised a Confirm/Deny dialog on the HDMI
desktop that **nothing attached to the Q can click** (no keyboard, no mouse, no
touch; HDMI is an output). Every bond timed out with mgmt status **`0x0e`**.
Compounding it: `RequestDefaultAgent` is **last-writer-wins**, so the applet also
stole the default agent from setupd's own agent.

**Live proof:** with blueman gone, bluetoothd logged

```
user_confirm_request_callback ... confirm_hint 1
```

`confirm_hint 1` = Just Works (no user confirmation expected), and a Pixel 9 Pro
Fold bonded **instantly, with zero agent callbacks**.

### Bug 2 — the companion app let the RFCOMM socket bond on demand

Android's implicit bond from `createRfcommSocketToServiceRecord` against an
unbonded Just-Works peer **forms and immediately collapses**:

```
bonding_attempt_complete status 0x5     # auth failed
... 0x0e                                # disconnected
```

No link key is ever written and the RFCOMM connection never reaches setupd.
Android surfaces this as the **misleading toast "incorrect PIN"** — even though
**no PIN exists in a Just-Works flow**. Fix: the app now calls `createBond()`
explicitly and waits for `BOND_BONDED` **before** opening the socket.

### ⚠️ RETRACTED: "the BCM4330 cannot complete SSP bonding"

That claim (made 2026-07-14, carried by earlier `nexusq-setupd` / app comments)
is **WRONG**. Pairing + A2DP worked **2026-07-09** after kernel r40 gave the BT
UART its `max-speed`, and were **re-verified 2026-07-15**.

> **Lesson: never re-derive a hardware limit from a userspace symptom.** The HCI
> trace (ACL connect → features/name → teardown, no pairing HCI at all) *looked*
> like a controller fault. It was two userspace bugs. It cost a day and a
> cleartext-PSK workaround. See [[never-conclude-dead-hardware]].

---

## 2. What shipped (v1.9.0-rc4)

### NEW package `nexusq-btagent` 0.1.0-r0

`userspace/nexusq-btagent/` + `pmos/nexusq-btagent/APKBUILD`. The appliance's
**single, permanent** BlueZ `Agent1`: `NoInputNoOutput`, auto-accept, marks new
bonds **`Trusted`**. **Permanent, not setup-scoped** — BT audio/A2DP needs a bond
long after setupd exits. Full rationale, interfaces and stock-parity analysis:
**`userspace/nexusq-btagent/README.md`** (not duplicated here).

**The `Pairable == Discoverable` invariant** (a user requirement — security
visibility). The key insight:

> **`Pairable`, not `Discoverable`, gates bonding.** Discovery only affects
> *inquiry*; anyone who already knows the address can bond a non-discoverable but
> pairable adapter — and bluez leaves `Pairable=true` **forever** by default.

So a ring tied to `Discoverable` alone would be a **LIE** (dark while still
bondable). btagent holds the two equal, so the ring is honest:
**ring spins blue ⇔ anyone can pair.**

### `nexusq-setupd` r0 → **r3**

- **Registers NO agent** (two agents is exactly how this broke); `depends=`
  nexusq-btagent as a **hard** dep — the profile cannot bond without it.
- Profile **`RequireAuthentication=True`** (was `False`) → bonded + encrypted
  setup link → **the WiFi PSK no longer crosses the air in cleartext.**
- **`finishSetup` REFUSED unless wifi is provisioned** (`bad_request`). Accepting
  it unprovisioned made setupd exit 0, so `Restart=on-failure` did not restart it
  and nothing re-armed setup mode until a reboot — **the device was stranded out
  of setup mode**. The app reached this state live today.

### `device-google-steelhead` r46 → **r47**

- `depends=` **+nexusq-btagent**; `nexusq.preset` **enables** it.
- **`/etc/xdg/nexusq/autostart/blueman.desktop`** (`Hidden=true`) suppresses
  `blueman-applet` via the existing XDG_CONFIG_DIRS shadow trick (same as
  pipewire/wireplumber). The blueman **package stays** (Petr's call —
  `blueman-manager` on demand). ⚠️ **Starting `blueman-applet` by hand breaks
  pairing again until it exits.**
- post-install sets bluez **`Class = 0x200428`** (Audio/Video major / HiFi Audio
  minor). Live reads **`0x006c0428`** — bluez 5 ORs in its own service bits.

### Companion app — 1.0.0+1 → **1.1.0+2**

- Secure `createRfcommSocketToServiceRecord` + **explicit bond-first**.
- **find-device list overflow fixed** — a `Column` can't scroll → yellow overflow
  stripes with many BT devices.
- **connect-gate ring re-centred** — a non-positioned `Stack` child gets loose
  constraints and parks at `topStart`; fixed with `Positioned.fill`.
- New `companion/app/build-apk.sh`; version shown in UI (`kBuildLabel`).

> ⚠️ **The app is versioned on its OWN INDEPENDENT TRACK — deliberately NOT
> aligned to the device image releases.** An app-only fix must be shippable
> without implying a firmware release, and a firmware release must not force a
> fake app bump. Device compatibility is a **protocol** concern
> (`companion/PROTOCOL.md`), not a version-number one.

### `docker-build.sh`

nexusq-btagent wired into validation, staging, dos2unix and the build phases.

> ⚠️ **Phase ORDER IS LOAD-BEARING.** btagent (**7c3**) must be checksummed +
> built **BEFORE** setupd (**7c4**), which now `depends=` on it. The reverse order
> fails **every clean build** with `nexusq-btagent is missing in checksums`.

---

## 3. Acceptance (v1.9.0-rc4, fresh flash, 2026-07-15) — PASS

Cold boot from a fresh flash:

- setupd armed itself — `setup mode active: discoverable`
- btagent registered as **default agent**; **blueman absent**; Class
  `0x006c0428`; **no bonds**
- App via the **NFC tap path** → bond + **`Trusted`** + **A2DP authorized**
  (`0000110d`) → RFCOMM → **WiFi joined (192.168.20.149)** → `finishSetup` →
  btagent auto-closed the window (`enforcing Pairable=False`)
- **PSK: 0 lines in the journal**
- A2DP live: `bluez_source...a2dp_source s24le 2ch 48000Hz` + PA loopback

Also user-verified: **wrong WiFi password → ring turns red**; **NFC tap goes
straight to pairing** (the BT device list is only the no-NFC fallback).

---

## 4. Honest caveats — OPEN

- **Pairing flakiness — NOT root-caused.** One fresh-flash run needed **2 failed
  attempts** before succeeding (user-reported); the **three subsequent runs
  passed first try (0 failed attempts)**, including the final rc5 acceptance.
  Suspicion only, nothing confirmed: the app's 30 s `ensureBonded` timeout (the
  phone log shows a ~27 s gap before the successful bond) and/or a stale
  phone-side bond — **the stale-bond leg is WEAKENED**, because a run with a
  stale phone bond still succeeded first try. **A repro needs `bluetoothd -d`.**
  **OPEN.**
- **The dev image BAKES Petr's WiFi** (`private/access/wifi.nmconnection` →
  `/etc/NetworkManager/system-connections/wifi.nmconnection`), so a fresh-flashed
  **dev** image self-provisions, `nexusq-setup-needed` correctly reports "not
  needed", and **setup mode never arms**. **THIS is why "čerstvý build vůbec
  nenaběhl" on 2026-07-14 — it was never an onboarding bug.** `PUBLIC_RELEASE=1`
  images do **not** bake it, so real users get onboarding. Today's acceptance
  required manually deleting the baked profile. **Open task:** a
  **`NEXUSQ_NO_WIFI=1` build flag** (skip only the wifi bake, keep ssh keys) —
  promised, **NOT yet written**.
- **The factory WiFi MAC `f8:8f:ca:20:48:e1` is injected NOWHERE.** wlan0 runs
  the chip **OTP MAC** (`14:7d:c5:3a:35:b5`, Murata OUI); the nvram
  `bcmdhd.cal` says `00:90:4c:c5:12:38`; its DHCP lease carries an **empty
  hostname**. **Look leases up by the OTP MAC**; `f8:8f:ca:20:48:e1` is stale.
  BT MAC is fine (DTS `local-bd-address`). `firmware/README.md`'s "pinned at the
  NetworkManager layer" claim is **retired-pending-fix**. **Open task**, separate
  from onboarding.
- **Thermal: 102.8 °C under bounded dual-core load** (diag sweep) — **above the
  documented ~94–99 °C envelope and past the 100 °C passive trip**. Throttling
  engaged correctly and 125 °C critical was never approached, but the documented
  envelope understates the real ceiling. True idle is fine: **72–75 °C**, 52 %
  residency at 350 MHz. **OPEN.**
- **librespot boot race — 5 restarts at boot** (`wlan0 has no IPv4 after 30s`):
  the wrapper hard-binds `--zeroconf-interface`, so it must wait for the WiFi IP.
  **Self-heals once associated.** **OPEN.**
- **`onboard` SIGSEGVs every boot** in its native `osk` module. **NOT** the old
  flash-corruption class — `python3 -S -c ''` is rc 0. **OPEN.**
- **The contactless-payment link is UNPROVEN** — see §8. **OPEN.**

---

## 5. Stock parity (audited 2026-07-15 from `system.raw.img` — userspace, NOT vmlinux)

BT pairing is a **userspace** concern, so the audit target was the stock
`/system`, not the kernel.

| Stock did | Evidence | Our call |
|---|---|---|
| **Never bonded during onboarding** — insecure RFCOMM, zero `createBond` | `HubBroker.odex` | **DIVERGE** — we bond |
| Accepted a **cleartext PSK** | same | **DIVERGE** — encrypted link |
| **Exactly one agent** — BlueZ 4.93 made a 2nd impossible; no `RequestDefaultAgent` existed | BlueZ 4.93 API | our race is a **BlueZ-5-only failure mode** |
| IO cap **DisplayYesNo**, but **never exercised** (setup never bonded) | `libandroid_runtime.so` | **DIVERGE** — `NoInputNoOutput` is strictly better for an input-less Q |
| **NO A2DP at all** — `DisablePlugins = audio,network,input` | stock `main.conf` | ⚠️ **DO NOT COPY** — real + sourced, but a BlueZ-4 key whose `audio` entry would kill the A2DP we want |
| Scanner **ignores CoD**, matches SDP UUIDs | `HubBroker.odex` | Class is **cosmetic** (identity, not discovery) |

**Our bonded setup + `NoInputNoOutput` are DELIBERATE, justified divergences**:
the PSK gets encrypted for free, and the one bond **also serves A2DP** — which
stock never had. The 2026-07-14 framing of insecure RFCOMM as a "workaround to
revisit" was doubly wrong: it was **stock parity**, and we have now moved
**beyond** stock on purpose.

---

## 6. rc5 — FAIL CLOSED on the pairing window (`b2a08af`)

Found by a **diag sweep**, not by the wizard: two fail-**open** decisions, in
opposite directions, both of which turn a transient into a security lie.

### 6.1 `nexusq-setup-needed` — a provisioned device could go pairable (setupd r3 → **r4**)

The condition piped nmcli straight into grep and **threw the exit code away**:

```sh
if nmcli -t -f TYPE connection show 2>/dev/null | grep -q '^802-11-wireless$'
```

So **"nmcli failed / NetworkManager is not up yet" was indistinguishable from
"there is no WiFi profile"** → exit 0 → a fully **provisioned** device arms setup
mode and advertises itself **discoverable + pairable**. The agent
**auto-accepts by design** (nothing attached to this appliance can answer a
prompt), so that transient **hands a passer-by a bond**. It tripped in a window
where NM was demonstrably disturbed.

**Fix:** only a **SUCCESSFUL** nmcli listing no wifi profile means unprovisioned;
anything else assumes provisioned and stays out. The asymmetry is the point —
being wrong that way costs a `startSetupMode` (or the force flag) to re-enter
setup; being wrong the other way leaves **an open pairing window on a live
device**. Verified on the device including a **faked nmcli failure**; +65 lines
of host tests.

### 6.2 `nexusq-btagent.setupd_active()` — the ring could go dark while pairable (btagent r0 → **r1**)

Same class, opposite direction, and it was ours. `systemctl is-active` **has
timed out live under load** (`systemctl is-active failed … timed out after 5
seconds`), and the fallback assumed *"setupd owns the ring"* → **skip our
indicator**. On a still-pairable adapter that is **exactly the lie the ring
exists to prevent**:

> **dark must mean nobody can pair.**

**Fix:** fail to **FALSE** — claim the ring. The cost is near-zero:
`DISCOVERABLE_CMD` is **byte-identical** to setupd's idle spin, so the worst case
is re-sending the blue already showing, plus a wiped theme in a rare error path.
A silently dark ring on a bondable appliance is the worse failure. Unit tests
inverted accordingly (`test_unreadable_systemctl_means_the_ring_is_ours`,
`test_systemctl_timeout_means_the_ring_is_ours`).

**Lesson: when a check gates a security-visible state, decide which way it fails
BEFORE writing it — and never let a pipeline eat the exit code of the command the
decision rests on.**

---

## 7. `startSetupMode` re-provisioning — TESTED, PASSING

This was the **last untested acceptance item** of onboarding step 1. Verified
live over the LAN bridge:

```json
{"ok":true,"result":{"started":true}}
```

→ setupd **active**, force flag **armed**, adapter **discoverable + pairable**,
and **btagent correctly YIELDED the ring to setupd** (no "ring ON" line — the
§6.2 hand-off works in the direction that matters when setupd really is running).

---

## 8. The NFC claim IS the tap — and the payment story (app 1.1.1+5)

**Measured, not reasoned** — and my first attempt at this was **wrong**.

I removed `setPreferredService` on the theory that it bought nothing, since the
platform already routes our AID to us. **That broke the tap**, and the reason is
the interesting part: **routing was never the problem.** The phone sits in
Android 15 **observe mode** and deliberately **does not answer a reader's field
at all**. Measured with the tap failing:

```
NfcService: MSG_RF_FIELD_ACTIVATED        <- the Q's field IS seen
NfcService: MSG_RF_FIELD_DEACTIVATED      <- ...and never answered
(cycling ~150 ms, no APDU ever reaching NqHceService)
```

The platform **drops observe mode for the PREFERRED service** when it declares
`shouldDefaultToObserveMode="false"`, which ours does. **So the claim IS the
tap.**

Measured after the fix:

| state | preferred | observe mode | AID routed |
|---|---|---|---|
| app closed / backgrounded | `null` | `true` | 0 |
| app on the connect screen | ours | `false` | 1 |

Observe mode **returns to `true` when we let go** — the phone is not left in a
payment-hostile state.

**So the claim stays, but scoped:** Dart says when a tap is expected
(`setTapCapture`), and **only the connect screen** — the "waiting to be tapped"
state — asks for it. It is dropped the moment a Q is connected, on dispose, and
on every `onPause`; the HCE component ships `android:enabled="false"`, so a
**closed app has ZERO NFC surface**. Previously **ANY open app claimed NFC
priority, including while just playing music**.

### ⚠️ The payment link is UNPROVEN — record, don't conclude

**Motivation:** the user's contactless payment failed **twice, only ever after a
dev session**. That is a correlation and nothing more:

- The NFC telemetry shows observe mode toggled **only** by `com.android.nfc` and
  `com.google.android.gms` — **never by our uid**.
- It **returns to `true` on its own**.

This is **risk reduction, not a diagnosed fix**, and it must not be written up as
a root cause. **If payment fails again: capture `dumpsys nfc` AT THE MOMENT OF
FAILURE** — after the fact the state has already healed, which is precisely why
this is still open.

---

## 9. Final acceptance (fresh `v1.9.0-rc5` flash) — PASS, shipped as v1.9.0

NFC tap delivered → **bond first try (0 failed attempts)** → RFCOMM → **WiFi
joined** → `finishSetup` → **pairing window auto-closed** → **`NFC: released
preferred`** the moment the device came up. **PSK: 0 log lines.**

This is the build **v1.9.0** is cut from. Read §4 before relying on it.
