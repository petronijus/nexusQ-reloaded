# 2026-07-15 — BT onboarding ROOT-CAUSED + FIXED: blueman's agent hijacked SSP, and the app bonded on demand

**Status: onboarding WORKS from a fresh flash, autonomously, user-accepted.**
Built + flashed as **v1.9.0-rc4**. This **supersedes**
`docs/2026-07-14-bt-onboarding-state-as-is.md` ("does NOT work autonomously"),
which is kept as the record of what was known then — its §2 hypothesis was
right, its §4 "insecure RFCOMM workaround to revisit" is now **retired**.

Base: v1.8.2 (`1504ef3`, kernel r43 `#44`). **v1.9.0 is NOT tagged yet**;
everything below is uncommitted. Pairing/A2DP evidence reference:
`docs/2026-07-09-bluetooth-uart-max-speed-and-crackle-isolation.md`.

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

- **Pairing needed 2 failed attempts before succeeding** on the fresh-flash run
  (user-reported). **NOT root-caused.** Suspicion only: the app's 30 s
  `ensureBonded` timeout (the phone log shows a ~27 s gap before the successful
  bond) and/or a stale phone-side bond. **OPEN.**
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
  hostname**. BT MAC is fine (DTS `local-bd-address`). **Open task**, separate
  from onboarding.
- **v1.9.0 is NOT tagged.** Everything uncommitted.

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
