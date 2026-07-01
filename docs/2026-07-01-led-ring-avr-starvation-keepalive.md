# 2026-07-01 — LED ring goes dark after long idle: AVR host-frame starvation, fixed with a keepalive

**Shipped in v1.6.5** (`nexusqd` pkgrel 5 — the keepalive itself landed at r3; later rels
add the `breathe` and `muted` commands, see
`docs/2026-07-01-librespot-softvol-bootstrap-and-breathe-scenes.md`).
_(The keepalive was first built + flashed for testing as the internal **v1.6.4** build,
which was never published — it was folded, with the rest of this batch, into the released
**v1.6.5**.)_ A long-standing intermittent bug — the
32-LED ring goes **dark after a long idle / long uptime** (~20 h observed) and stays
dark until `nexusqd` is restarted — is root-caused and fixed. It is **not** a hardware
fault, **not** a regression, and **not** a commit-mode issue. Root cause: the closed
`steelhead-avr` MCU firmware **starves** — it stops lighting the ring if the host sends
no frame *commit* for too long (a host-frame watchdog in the AVR fw, version `0x00`) —
and `nexusqd`'s per-frame `memcmp` gate suppressed all commits once the idle screensaver
locked/blanked to a **static** frame. The fix is a 1 Hz keepalive re-commit.

## Symptom

- Ring lit and animating normally, then after a long idle stretch (**~20 h** on the live
  unit) it goes **fully dark** and does not recover on its own.
- The `nexusqd` control socket (`/run/nexusqd.sock`) still answers — so by the diag
  suite's own rule this reads as benign *idle-off*, not a `nexusqd_hang`. It is neither:
  the daemon is alive and the render loop is running, but the AVR has stopped displaying.
- A `systemctl restart nexusqd` brings the ring straight back.

## The frame path (kernel driver → AVR)

`kernel/drivers/leds-steelhead-avr.c`, sysfs bin attribute `frame`
(`/sys/bus/i2c/devices/1-0020/frame`, `0200`, size `AVR_RING_LEDS*3 = 96`).
`frame_write()` (≈ line 236) does, on **every** write:

1. copy the 96 RGB bytes into `a->ring[]`;
2. `avr_encode_set_range(obuf, …, start=0, a->ring, 32)` → an **`AVR_REG_SET_RANGE`**
   (`0x04`) i2c buffer `[0x04, start=0, count=32, rgb_triples=32, R,G,B × 32]` = 100 bytes
   → `avr_write()` (one i2c transfer);
3. **`avr_commit(a, a->commit_mode)`** → **`AVR_REG_COMMIT`** (`0x05`) + mode (2-byte i2c).

So one `frame` sysfs write = **SET_RANGE(all 32 LEDs) + COMMIT** on the wire, every time.
There is no "changed-pixels-only" path in the driver; the driver faithfully re-sends and
re-commits whatever userspace hands it.

`nexusqd`'s `avr_write_frame()` (`userspace/nexusqd/src/avr.c`) writes `commit_mode`
(`"0"` = `AVR_COMMIT_IMMEDIATE`) then the 96-byte `frame`, i.e. it drives exactly the
SET_RANGE + COMMIT(immediate) path above.

## The gate that starved the AVR (userspace)

`userspace/nexusqd/src/nexusqd.c` render loop — the write-gate was:

```c
if (memcmp(pk, lastpk, sizeof(pk)) != 0) { avr_write_frame(pk, 0); memcpy(lastpk, pk, sizeof(pk)); }
```

i.e. **push to the AVR only when the packed frame changed.** That is correct for a
constantly-animating ring (the frame changes every tick, so a commit lands every tick),
but it goes silent the moment the frame stops changing.

The idle screensaver (`userspace/nexusqd/src/screensaver.c`,
`include/screensaver.h`) makes the frame go static in two stages after audio stops:

- **`SS_LOCK_S = 300.0`** — after 300 s without audio, `screensaver_brightness()` sets
  `lock = 1`, so `ledAlpha` **locks to a constant `0.1`** (the breathing term
  `0.1 + 0.35*(1 - throb)` stops pulsing). The rendered `#0099CC × 0.1` frame is now
  identical every tick.
- **`SS_BLANK_S = 600.0`** — after 600 s the blank timeout forces `ledAlpha = 0.0` → a
  constant black frame.

Either way the packed frame `pk` stops changing → `memcmp(pk, lastpk) == 0` on every
subsequent tick → `avr_write_frame()` is **never called** → the AVR receives **no more
COMMITs**. After enough time without a commit the AVR's host-frame watchdog fires and it
**stops lighting the ring** — dark until the next commit (which only comes on a daemon
restart or the next frame change, e.g. audio resuming).

## Debugging: what it is NOT

- **Not hardware.** A direct sysfs frame write (`nexusled set …`, or writing 96 bytes to
  `/sys/…/1-0020/frame`) lights the ring immediately. The panel/MCU/i2c path is healthy.
- **Not a commit-mode bug.** A/B test with **one write every 4 s**: both
  `commit_mode = 0` (`AVR_COMMIT_IMMEDIATE`) and `commit_mode = 1`
  (`AVR_COMMIT_INTERPOLATE`) display **all colors correctly** — *as long as commits keep
  arriving*. The ring only dies when commits **stop**, independent of the commit type.
- **Not a regression.** Both the `memcmp` gate and the screensaver lock/blank have been in
  place since the daemon's early versions; nothing in a recent release changed them. The
  starvation is a property of the closed AVR firmware (host-frame watchdog, fw `0x00`) that
  only surfaces after a long, uninterrupted static-frame idle — hence "~20 h", not
  seconds, and hence why it went unnoticed.

Net: the AVR needs to be *fed* periodically. When the host feeds it (any cadence tested,
down to 1 write / 4 s), the ring stays lit; when the host goes silent, it starves.

## The fix — a 1 Hz keepalive re-commit

`userspace/nexusqd/src/nexusqd.c`:

```c
#define AVR_KEEPALIVE_S 1.0
…
double last_avr_push = 0.0;   /* last AVR frame commit — drives the keepalive re-push */
…
/* Push on any change, and additionally re-push the unchanged frame every
 * AVR_KEEPALIVE_S so the AVR never starves once the ring goes idle/static. */
if (memcmp(pk, lastpk, sizeof(pk)) != 0 || now - last_avr_push >= AVR_KEEPALIVE_S) {
    avr_write_frame(pk, 0); memcpy(lastpk, pk, sizeof(pk)); last_avr_push = now;
}
```

- During **active animation** this adds nothing: the frame already changes every tick, so
  the `memcmp` branch fires first and `last_avr_push` is refreshed each write.
- Only while the ring is **idle/static** does the keepalive kick in: at most **one extra
  frame commit per second** — a SET_RANGE (100-byte i2c) + COMMIT (2-byte i2c), ~96 RGB
  payload bytes. Negligible i2c/CPU cost, well inside the AVR's watchdog window.

`nexusqd` APKBUILD → **pkgrel 5** (the keepalive landed at r3; later rels add the `breathe`
and `muted` commands — see `docs/2026-07-01-librespot-softvol-bootstrap-and-breathe-scenes.md`).

## Verification (internal v1.6.4 test build, clean flash — folded into the released v1.6.5)

The keepalive was flash-verified on the internal **v1.6.4** build, which ran
**`nexusqd 0.1.0-r3`** (keepalive only) — the released **v1.6.5** ships **`nexusqd 0.1.0-r5`**
(+ `breathe`/`muted`) and `device-google-steelhead 1.0-r17`.

- Boots; **`nexusqd 0.1.0-r3`** runs (correct armv7/musl binary); the render loop is alive
  and the ring lights.
- Companion bridge reachable over WiFi (see the nftables change below):
  `getState` returns the "Nexus Q" state on TCP 45015.
- WiFi rejoined (`192.168.20.x`). `boot.img` is **byte-identical** to v1.6.2/v1.6.3
  (kernel unchanged; md5 `36a3dec2c4a493710dffa18c4d796236`).

**Honest caveat.** The keepalive is **mechanically deployed and running**, but the
"never wedges again" claim is **not yet proven**: the wedge took **~20 h** of idle to
manifest, so a clean confirmation needs an **overnight idle run** with the ring left in
the locked/blank state. Until that soak passes, treat "fixed" as *root-caused + mitigation
deployed*, not *soak-verified*.

## Companion bridge WiFi rule (shipped in the same v1.6.5)

Secondary change baked in this release: a new nftables drop-in
`pmos/device-google-steelhead/55_nexusq-control.nft` opens **TCP 45015 on `wlan*`** so the
companion app reaches the `nexusq-control` bridge over WiFi (mDNS `_nexusq._tcp` discovery
reuses the UDP 5353 rule from `60_spotify.nft`). Previously the bridge was reachable only
over the USB-gadget net; the rule had been live-patched on the device but not baked into
the image. `device-google-steelhead` APKBUILD → **pkgrel 17** (r16 baked this WiFi rule;
r17 adds the librespot softvol bootstrap — see the sibling doc). Verified live: `getState`
answers over WiFi.

_(v1.6.5 also grew three more items — a librespot softvol-bootstrap fix, breathing color
themes and app-selectable visualisations — documented in
`docs/2026-07-01-librespot-softvol-bootstrap-and-breathe-scenes.md`.)_

## Follow-ups

- **Overnight idle soak** to confirm the ring stays lit through the full lock (300 s) →
  blank (600 s) → long-idle window that previously wedged the AVR at ~20 h.
- If a future soak ever shows the ring dark *with* the keepalive running, the next suspect
  is the AVR watchdog window being **shorter than 1 s under some state** — raise the
  keepalive cadence (it is a single `#define AVR_KEEPALIVE_S`).
