# 2026-07-14 — BT onboarding: honest state AS-IS (does NOT work autonomously yet)

> ## ⛔ SUPERSEDED 2026-07-15 — read `docs/2026-07-15-bt-onboarding-root-caused-blueman-agent-and-bond-first.md` instead
>
> This document is kept **as the record of what was known on 2026-07-14**. Its
> conclusions were overtaken the next day; do not act on it. What changed:
>
> - **§1 "does NOT work autonomously" is NO LONGER TRUE.** Onboarding works from
>   a fresh flash, autonomously, user-accepted (v1.9.0-rc4, 2026-07-15).
> - **§2's hypothesis was RIGHT** — it *was* the dual-agent conflict. Root cause:
>   `blueman-applet`'s **DisplayYesNo** agent forced SSP into **Numeric
>   Comparison**, raising an HDMI Confirm/Deny dialog nothing attached to the Q
>   can click (mgmt `0x0e`), and stole the default agent (`RequestDefaultAgent`
>   is last-writer-wins). A **second, independent** bug: the app let the RFCOMM
>   socket bond on demand (Android's implicit bond collapses → the misleading
>   "incorrect PIN" toast). Fixed by `nexusq-btagent` + app bond-first.
> - **§4 "insecure RFCOMM = a WORKAROUND to REVISIT" is RETIRED and its framing
>   was wrong twice over.** It was in fact **stock parity** (stock never bonded
>   during onboarding and accepted a cleartext PSK); we have now deliberately
>   moved **beyond** stock — `RequireAuthentication=True`, bonded + encrypted, so
>   the PSK never crosses the air in cleartext, and the same bond serves A2DP.
> - **§5's "correct BT firmware" and channel-22 keepers still stand.**
> - The "fresh build wouldn't come up" symptom was **not an onboarding bug at
>   all**: the dev image bakes Petr's WiFi, so it self-provisions and setup mode
>   correctly never arms.

**Status: WORK IN PROGRESS — continues tomorrow.** This is a state record, not a
close-out. The app-driven BT onboarding flow (`docs/2026-07-13-onboarding-step1-implementation.md`)
was carried to a first end-to-end provisioning success this session, but **only
with manual intervention on the device**. It is **NOT** ready, **NOT** tagged, and
**everything is uncommitted** (device sources, companion app, `docker-build.sh`,
firmware blobs). v1.9.0 is **not** ready; the built/flashed artifact is
**v1.9.0-rc3**, unreleased.

Session spans **2026-07-13 evening → 2026-07-14**. Base: v1.8.2 (`1504ef3`,
kernel r43 `#44`, device r40). Reference for the pairing/A2DP evidence used
throughout: `docs/2026-07-09-bluetooth-uart-max-speed-and-crackle-isolation.md`.
Memory: [[nexusq-bt-onboarding-pairing]], [[never-conclude-dead-hardware]].

---

## 1. The honest bottom line

**BT onboarding does NOT work autonomously from a fresh flash.** The one
end-to-end success (device provisioned: hostname `nexus-q`, room `office`, WiFi
joined at **−44 dBm**, `nexusq-setupd` exited cleanly, Prague time) required
**manual intervention on the device**:

1. **killing `blueman`** on the device (its DisplayYesNo agent was competing with
   setupd's agent on HDMI), AND
2. **forgetting a stale phone bond** (Android kept re-pairing a "known" device;
   `blueman` showed an un-completable Confirm/Deny dialog on the HDMI desktop).

That success was **confounded** — both variables changed at once — so even "works
once you forget the bond" is **not cleanly proven**. Treat autonomous fresh-flash
onboarding as UNVERIFIED.

---

## 2. ⚠️ NOT a hardware limitation — the pairing failure is OUR bug

**Correcting a mistake made earlier this session:** the setup-flow pairing failure
was wrongly framed as a **hardware limitation of the BCM4330** (the controller
"can't complete SSP bonding with modern phones"). **That conclusion is WRONG and
was corrected by the user.**

**Evidence it is wrong** — `docs/2026-07-09-bluetooth-uart-max-speed-and-crackle-isolation.md`:
after the kernel **r40 `max-speed=3000000`** BT-UART fix (patch **0040**, shipped
in **v1.8.0**), **BT pairing + A2DP audio WORKED and were user-confirmed**
(*"bluetooth jede, perfektni prace"*). So **SSP bonding works on this exact
BCM4330 controller.** Per the project's standing rule ([[never-conclude-dead-hardware]]:
the HW is known-good, stock-confirmed) the setup-flow pairing failure is **OUR
bring-up/config bug**, to be fixed — not a controller limit.

### Leading hypothesis (to TEST tomorrow, NOT a conclusion)

On 2026-07-09 pairing worked via the **NORMAL path**: there was no `nexusq-setupd`
then, so the phone paired through the standard flow / **`blueman`'s DisplayYesNo
agent**. This session's `nexusq-setupd` introduces its own **`NoInputNoOutput`
auto-accept `Agent1` + `RequestDefaultAgent`** (PROTOCOL §8.6), which **competes
with `blueman`'s agent**. An **HCI trace** on the device showed the incoming bond
being **torn down before any IO-capability event** flowed. The likely bug is our
**setupd agent / pairing configuration** (dual-agent conflict / wrong IO
capability / RequireAuthentication handling), **NOT the controller**.

Candidate directions for tomorrow:
- Make `nexusq-setupd` **own BT exclusively during setup** — stop `blueman`'s
  agent for the window (stock ran **minimal BT** during setup: `DisablePlugins=
  audio,network,input` + a fixed Class `0x200428`).
- **Verify the max-speed r40 fix is present in rc3** (the pairing-critical baud
  sync — a regression here would reproduce the exact 2026-07-09 symptom).
- Re-test **PROPER bonded Just-Works pairing** (this ALSO preserves A2DP — see §3).

---

## 3. BT AUDIO — a bond serves BOTH provisioning and A2DP (first-class requirement)

If setup does **not** create a real BT bond, the phone **cannot stream audio to
the Q over Bluetooth (A2DP)**. A2DP is a **proven, baked capability**
(`docs/2026-07-09`, `phone → BT → PulseAudio bluez_source (s24le/48 kHz) →
TAS5713`, v1.8.0).

The current setup transport is **insecure/unbonded** (§4) — it deliberately
creates **no bond** — which means BT audio would need **separate** pairing after
setup. The right fix is **PROPER bonded pairing in setup**: **one bond serves both
provisioning and A2DP.** Record this as a **first-class requirement** for
tomorrow, not an afterthought.

---

## 4. The insecure RFCOMM decision = a WORKAROUND to REVISIT (not a shipped design)

Because the pairing failure was wrongly attributed to a HW limit, the setup RFCOMM
was set **insecure/unbonded** to get an end-to-end path working:

- **device** (`userspace/nexusq-setupd/nexusq-setupd`): the BlueZ Profile1 registers
  with **`RequireAuthentication=False`** (was `True`).
- **companion app**: the phone uses **`createInsecureRfcommSocketToServiceRecord`**
  (was the secure variant).

This connects **without bonding**. Downsides to record:

- **(a)** the WiFi **PSK crosses the BT link in CLEARTEXT** — the planned
  application-layer **ECDH key agreement is NOT implemented**. A passive BT sniffer
  in range during the setup window could capture the PSK.
- **(b)** no bond → **no BT audio** (§3).

**This is provisional, under revision — NOT a final design.** To be reconsidered
tomorrow in favour of fixing bonded pairing. Only if bonded pairing genuinely
cannot be made to work should this insecure path stand — and then only WITH the
app-layer PSK encryption implemented.

---

## 5. Session changes — KEEPERS vs REVISIT

### KEEPERS (real fixes, independent of the pairing decision)

- **Correct BT firmware.** `firmware/bcm4330.hcd` + `private/firmware/bcm4330.hcd`
  replaced the **WRONG board blob** — *"Proxima BCM4330B1 NoExtLNA"*, md5
  `16db686…` — with the **stock steelhead** *"Google Phantasm BCM4330B1"*: md5
  **`7e5bb859e33142e94052c76fba23b9e6`**, **51813 B**, **build 0749**.
  `firmware-google-steelhead` **r1 → r2**. (Note: the correct firmware did **not
  by itself** fix setup pairing, but it IS the right blob for this device.)
- **RFCOMM channel 22** (was hardcoded **3**). Channel 3 collided with the Headset
  profile → `rfcomm_bind` *"Address in use"* → the server never started. Lesson: a
  BlueZ **server-role ext profile only starts its RFCOMM listener when a `Channel`
  is given** (omitting it publishes the SDP UUID but binds no channel; the app
  resolves the channel via SDP by UUID, so the exact number only has to be free and
  stable — 22 is clear of the Q's audio/PBAP stack on 3,9,10,13–17).
- **BT MAC D-Bus / bluetoothctl fallback.** Mainline 6.x has **no
  `/sys/class/bluetooth/hci0/address`**; the empty MAC broke the NFC tap payload
  (`"bt":""`) and `confirmColor`. `nexusq-setupd` now falls back to BlueZ
  `Adapter1.Address` over D-Bus; `nexusq-nfc-send` falls back to `bluetoothctl show`
  (stdlib-only constraint). `confirmColor` now raises a protocol error
  (`unavailable`) on an unknown MAC instead of crashing.
- **Setup mode stays armed while unprovisioned.** The 600 s inactivity timeout no
  longer leaves setup mode when there is still no WiFi profile — it would have
  stranded the device (nothing re-arms it until a reboot). It stays discoverable
  and keeps spinning; the timeout still fires normally once provisioned.
- **`nexusqd` r10 — `spin R G B [rev_per_s]`** optional rotation speed (float,
  0<s≤20; omitted/≤0 = default 0.75 rev/s), plumbed through `spinner_render`.
  setupd uses it for **LED state feedback**: CONNECTING = slow blue
  (`spin 0 153 204 0.4`), WiFi-joined SUCCESS = fast green (`spin 0 220 60 1.6`),
  join ERROR = slow red (`spin 220 30 30 0.5`, persists until retry).
  **User-confirmed working on device.** `pmos/nexusqd` **r9 → r10**.
- **device `device-google-steelhead` r44 → r46**: `+iw +ethtool +iproute2-minimal
  +tzdata`; **Europe/Prague** timezone (post-install symlinks `/etc/localtime` +
  `/etc/timezone`); `nexusq-nfc-send` MAC fallback.
- **`docker-build.sh`**: `--force` on the `nexusqd` / `nexusq-control` /
  `nexusq-setupd` builds — fixed a **warm-volume STALE-apk trap** that shipped an
  old `nexusq-setupd`; `timezone = Europe/Prague` (pmbootstrap was overriding the
  post-install symlink with GMT).
- **App polish** (all `companion/app`): NFC-tap **dedup guard** (the Q re-emits the
  payload ~8 s → the wizard was restarting); BT permission requested **inside
  `connect()`**; **confirm-color retry**; `find_device_screen` centered + rotating
  glow; **outro de-flicker**; welcome sphere `gaplessPlayback` + precache +
  original-size + centered; **build stamp** (`lib/build_info.dart` via
  `--dart-define BUILD_TAG`, shown on ConnectGate + welcome).

### REVISIT tomorrow

- **`RequireAuthentication=False`** (setupd) + **`createInsecureRfcommSocketToServiceRecord`**
  (app) — the insecure/unbonded workaround (§4).

---

## 6. rc3 build + flash

- **rc3 built + flashed.** Provisioned-boot verified **all-PASS**: **Phantasm**
  firmware loaded, packages `nexusqd r10 / device r46 / firmware r2 / setupd r2`
  (`nexusq-control` unchanged at r9), **Europe/Prague** local time, `iw`/`ethtool`/`ip`
  present, clean `dmesg`, Prague wall-clock correct.

---

## 7. Untested / open acceptance items (for tomorrow)

- Deliberate **wrong-password** path (red LED feedback).
- **NFC tap** in both provisioned states.
- `startSetupMode` **re-provisioning** on an already-provisioned device.
- Final full `nexusq-diag` sweep.
- Clean **autonomous fresh-flash** onboarding (no manual blueman-kill / bond-forget).

---

## 8. Where to continue TOMORROW (priority)

1. **Fix PROPER bonded pairing** — root-cause the setupd agent bug (§2). This also
   **restores BT audio via the same bond** (§3).
2. **Decide blueman / minimal-BT-during-setup** — make setupd own BT exclusively
   for the window (stock: `DisablePlugins=audio,network,input` + Class `0x200428`).
3. **Verify the max-speed r40 fix is present in rc3** (patch 0040 / `max-speed=3000000`).
4. **Clean autonomous fresh-flash acceptance** (no manual intervention).
5. **Only if bonded pairing truly can't be made to work**, fall back to the
   insecure transport (§4) AND implement app-layer **PSK encryption** (ECDH).
6. **Untested acceptance items** (§7).
7. **Commit + tag** (nothing is committed yet; v1.9.0 not ready).
