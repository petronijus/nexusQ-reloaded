# NFC tap-to-send — reverse-HCE (Q → phone), the pn544 RATS fix

**2026-07-08 · VERIFIED end-to-end on device · ships in v1.7.0**
(kernel `linux` **r37** patch 0037 · `device-google-steelhead` **r33** · Flutter
companion app native HCE)

The Nexus Q now hands a phone a short text over NFC when you tap the dome; the
companion app shows it as a SnackBar. This note captures **why the obvious
approaches are impossible on this 2011 chip**, the reverse-HCE design that does
work, the one kernel change that unlocked it, and the durable usage gotchas.

## 1. The problem: a bare tap can't read this Q like a sticker

Two hard constraints kill the naive "tap a phone, it reads the Q":

- **The PN544 (2011) cannot be a passive tag / host-card-emulate.** Its
  card-emulation RF path routes only to a hardware **Secure Element over SWP** —
  which this device does not even have. Host Card Emulation (HCE — emulate a card
  in app software, no SE) only arrived with the **next chip generation (PN547) +
  Android 4.4**. So the Q cannot present itself as an NFC tag/card to a phone.
- **Android Beam (NFC P2P push) was removed in Android 14.** The old "bump two
  phones to push" transport that a PN544 *can* do is gone from modern phones.

Passive NFC stickers were explicitly rejected (not the product intent). So the
data has to flow **Q → phone** with the Q as the active side.

## 2. The design that works: reverse-HCE

Invert the usual roles:

- The **phone runs a HostApduService (HCE)** — still fully supported on modern
  Android. It registers a custom **AID `F0010203040506`** (category `other`, not a
  payment AID) and answers APDUs in software.
- The **Nexus Q is the ISO-DEP reader.** It polls for an ISO 14443-A target (the
  phone presenting a card), activates it to ISO-DEP (layer 4), SELECTs our AID, and
  pushes a payload APDU carrying the UTF-8 text. The phone's `processCommandApdu`
  receives it.

Requires the companion app **installed and foreground** (preferred-HCE routing).

### Wire protocol (both ends implement exactly this)
1. `SELECT` by AID: `00 A4 04 00 07 F0 01 02 03 04 05 06 00` → phone answers
   `90 00` iff the AID matches.
2. Payload: `80 10 00 00 <Lc> <Lc UTF-8 bytes>` → phone extracts the text,
   forwards it to the UI, answers `90 00`.
3. Anything else → `6A82` (not found) / `6D00` (unsupported INS).

## 3. THE kernel fix — pn544 RATS-activate all ISO-DEP targets (patch 0037)

This was the missing piece. `pn544_hci_ready()` disables the reader firmware's ISO
14443-4 auto-activation (`PN544_RF_READER_A_AUTO_ACTIVATION = 0x00`), so **layer-4
activation is the driver's job**: it must send an explicit **RATS** via
`CONTINUE_ACTIVATION` before a `WR_XCHG_DATA` I-block can reach an ISO-DEP target.

`pn544_hci_complete_target_discovered()` did that **only for Mifare DESFire**
(`sens_res == 0x4403`), per its own TODO. An **Android HCE phone advertises
ATQA 0x0004 / SAK 0x20** — never matched — so the reader transceived against a
still-**layer-3** target and the firmware answered **`ANY_E_NOK`**. Observable
symptom: the phone entered card emulation (wakelock fired) but **never received
the SELECT APDU** (`processCommandApdu` was never called).

Fix (`drivers/nfc/pn544/pn544.c`): trigger `CONTINUE_ACTIVATION` for **any** target
that advertises ISO 14443-4 (SAK bit 5 set — `target->sel_res & 0x20`), keeping the
DESFire ATQA match as belt-and-suspenders:

```c
if ((target->sel_res & 0x20) ||   /* ISO 14443-4 / ISO-DEP */
    target->sens_res == 0x4403)   /* Type 4 Mifare DESFire */
    r = nfc_hci_send_cmd(hdev, NFC_HCI_RF_READER_A_GATE,
          PN544_RF_READER_A_CMD_CONTINUE_ACTIVATION, NULL, 0, NULL);
```

The chip already implements reader-side ISO-DEP (DESFire works through this exact
path); it only needed to be told to activate layer 4 for the phone.

## 4. Device side — `nexusq-nfc-send` + `nexusq-nfc.service` (device r33)

`/usr/bin/nexusq-nfc-send` is a **pure-Python reverse-HCE reader daemon** (a
working **prototype** — a C rewrite is possible future polish):

- Generic-netlink to the kernel `nfc` genl family for device-up / start-poll /
  target discovery on **`nfc0`**, then a **`PF_NFC` / `SOCK_SEQPACKET` /
  `NFC_SOCKPROTO_RAW`** socket (`net/nfc/rawsock.c`) for the APDU exchange.
- Custom **AID `F0010203040506`**; `SELECT` then the `80 10 …` payload APDU.
- Sends **once per tap**: after a confirmed `90 00` it disarms and does not re-send
  while the same phone stays in the field; re-arms only once the field is empty
  long enough (a cooldown guards a momentary drop-and-reacquire).
- First-APDU tolerance: Android binds the HCE service on demand, so the first APDU
  can be slow — the reader spaces retries and uses a 5 s recv timeout.

`nexusq-nfc.service` runs it with `NQ_NFC_LOOP=1` + `NQ_NFC_MESSAGE=Ahoj z Nexus Q!`,
`Restart=always`, and low priority (`Nice=10`, `IOSchedulingClass=idle` — continuous
polling is low priority next to audio on this OMAP4). Enabled via `nexusq.preset`.

**neard is NOT installed** on the image — this daemon owns the kernel NFC device
directly (raw netlink + ISO-DEP socket). During dev, when neard had been
live-installed, `systemctl stop neard` was needed first (it otherwise owns the
netlink device); the shipped image has no neard, so no stop is needed.

## 5. Companion app (Flutter) side

- **`NqHceService`** (Kotlin `HostApduService`) — AID `F0010203040506`, defensive
  bounds-checked APDU parser (a truncated/malformed APDU yields a clean status word
  instead of an exception that would drop the whole transaction).
- **`apduservice.xml`** — `requireDeviceUnlock="false"`, `requireDeviceScreenOn="false"`,
  and **`android:shouldDefaultToObserveMode="false"` — CRUCIAL on Android 15**,
  which otherwise defaults HCE to **observe mode** and never answers APDUs.
- **`HceBridge`** — process-local hand-off from the service (which runs outside the
  Flutter engine) to Dart. Persists the last message with **`.commit()` — NOT
  `apply()`**: a HostApduService can be killed the instant the transaction ends,
  before an async `apply()` flushes to disk, which **lost the message**. Buffers
  messages that arrive before a Flutter sink is listening and drains on attach.
- **`MainActivity`** — EventChannel `nexusq/hce/messages` (stream) + MethodChannel
  `nexusq/hce` (`getLastMessage` resume fallback, `isNfcAvailable`), and
  `CardEmulation.setPreferredService` on **resume** (released on pause) so routing
  is unambiguous and no app-chooser appears.
- **`HceListener`** (Dart) — shows a Holo-dark SnackBar; listens both to the live
  stream (foreground) and `takeLast` on resume/cold-start so no tap is lost.
- NFC is optional: `uses-feature android.hardware.nfc.hce required="false"` and
  every NFC access is guarded — the app still installs on phones without NFC.

**VERIFIED end-to-end on device (full trail):**
`NqHceService: received text` → `HceBridge: post: persisted (sink=true)` →
`flutter: [HCE] show (messenger=true)` → user saw the SnackBar.

## 6. Usage gotchas (durable)

- **Tap AND HOLD steady ~5–10 s.** RATS NOKs if the phone moves mid-activation.
- **The companion app must be foreground** (preferred-HCE routing) with the
  **screen on**.
- Reader dev/test only: `systemctl stop neard` if neard was live-installed (the
  shipped image has none).

## 7. Deferred / future

- **Payload is a static greeting** (`NQ_NFC_MESSAGE`). Next step: send the device's
  **connection info** (IP / mDNS) so the app could auto-connect — the original
  "tap to onboard" intent — but that needs app-side parsing + mDNS re-discovery
  (also still owed to the app-reconnect path).
- **Q-side reader is a Python prototype** — a C daemon would be cleaner for the
  shipped image.
- **Continuous NFC polling keeps the RF field active** (minor power/thermal on this
  thin-headroom OMAP4); revisit if it matters.

## 8. Files

- `kernel/patches/0037-nfc-pn544-rats-activate-iso-dep-targets-steelhead.patch`
- `pmos/device-google-steelhead/nexusq-nfc-send`, `nexusq-nfc.service`,
  `nexusq.preset` (+ `APKBUILD` r33)
- `pmos/linux-google-steelhead/APKBUILD` (r37, source + SKIP for 0037)
- companion `android/app/src/main/kotlin/org/nexusq/nexusq_companion/`
  `NqHceService.kt`, `HceBridge.kt`, `MainActivity.kt`; `res/xml/apduservice.xml`;
  `res/values/strings.xml`; `AndroidManifest.xml`; `lib/nfc/hce_channel.dart`,
  `lib/nfc/hce_listener.dart`; `lib/main.dart`
- reader reference copy: `userspace/nfc-experiments/nq-nfc-send.py`
