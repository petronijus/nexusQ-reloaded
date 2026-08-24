# The hardware EQ wrote 0xFF into the amp — an upstream 32-bit bug, fixed by patch 0046 (2026-08-24)

**Verdict: every write through the `CH1/CH2 - Biquad n` ALSA controls put
`0xFFFFFFFF` into the TAS5713's coefficient RAM, whatever value was asked for.
Confirmed on the I2C wire, not inferred.**

**✅ FIXED the same day — kernel patch 0046, shipped as r50 and verified on the
wire and by frequency response. See *Resolution* at the end.**

## What was deployed first

Step 1 of the plan went through cleanly and is not in question:

| | |
|---|---|
| kernel **6.12.12-r49** | staged via `nq-kernel-ota stage-latest`, trial-booted, **auto-promoted at boot** (`healthy after 0s — promoting`), package DB reconciled |
| `device-google-steelhead` **r81** | `perf` in the image; `nexusq-cpufreq-tune` logged `down_threshold 20 -> 60` **at boot**, which is the whole point of r81 |
| 14 biquad controls | present: `CH1/CH2 - Biquad 0..6` |
| `getEq` | `{"bass_db": 0.0, "treble_db": 0.0, "supported": true}` |

Then verifying the write path found the defect.

## The bug

`amixer cget` on any biquad control reports:

```
; type=INTEGER,access=rw------,values=5,min=0,max=-1,step=0
```

**`max=-1`.** Mainline's `tas571x_coefficient_info()` sets
`uinfo->value.integer.max` to `0xffffffff`. ALSA carries control bounds in a
`long`, which is **32-bit on armv7**, so that value becomes **−1**. Every write is
then clamped to "max" and reaches the driver as `0xFFFFFFFF`.

This is an **upstream bug that cannot manifest on 64-bit** (where `long` holds
0xffffffff fine). Nothing about it is visible from userspace except the odd `max`.

### Proof on the wire

`ftrace` `i2c:i2c_write`, amp at `i2c-3` address `0x1b`, register `0x29` =
`CH1 - Biquad 0`:

```
# asked for 8388608,0,0,0,0   (unity: b0 = 0x00800000)
amixer: i2c_write: i2c-3 a=01b l=21 [29-ff-ff-ff-ff-ff-ff-ff-ff-ff-ff-ff-ff-ff-ff-ff-ff-ff-ff-ff-ff]

# asked for 1000,2000,3000,4000,5000
amixer: i2c_write: i2c-3 a=01b l=21 [29-ff-ff-ff-ff-ff-ff-ff-ff-ff-ff-ff-ff-ff-ff-ff-ff-ff-ff-ff-ff]
```

Twenty bytes of `0xFF` both times. **The requested value is irrelevant.**

### Read-back is fine — do not chase it

`amixer cget` returning `67108863` is not a second bug: that is `0x3FFFFFF`, the
26-bit mask of the `0xFFFFFFFF` that was actually written. Reads report the chip
honestly. Two false trails cost time here and are recorded so nobody repeats them:

1. *"Writes are fine, reads are broken."* Wrong — the wire says otherwise.
2. *"The write corrupted the read path."* Wrong — see below.

## The amp keeps its coefficients across a warm reboot

The very first read of the session (before anything was written) gave
`8388608,0,0,0,0` — real unity. After the bad writes, every read gave `0x3FFFFFF`
**including immediately after two full `systemctl reboot`s**.

`systemctl reboot` does not power-cycle the TAS5713, so **its register state
survives**. Garbage written into the DSP stays there until it is overwritten or
the chip actually loses power. `eq_restore_thread` is not the culprit — it returns
early on a flat stored config and never touched ALSA.

## Recovery — `i2cset -f` is the escape hatch

The ALSA path cannot write a correct value, so go under it. `i2cdetect` shows
`UU` at `0x1b` (claimed by the driver), hence `-f`:

```sh
# unity = b0 0x00800000, b1 b2 a1 a2 = 0; 20 bytes, 3.23 fixed point, big-endian
for r in 0x29 0x2a 0x2b 0x2c 0x2d 0x2e 0x2f 0x30 0x31 0x32 0x33 0x34 0x35 0x36; do
  i2cset -y -f 3 0x1b $r 0x00 0x80 0x00 0x00 \
      0x00 0x00 0x00 0x00  0x00 0x00 0x00 0x00 \
      0x00 0x00 0x00 0x00  0x00 0x00 0x00 0x00 i
done
```

`0x29`–`0x2F` are CH1 BQ0–6, `0x30`–`0x36` CH2 BQ0–6. Verified afterwards:
**14/14 read `8388608,0,0,0,0`**. Mode `i` (I2C block write) is required — SMBus
block (`s`) would prepend a length byte and corrupt the register.

## State left behind

- **All 14 biquads at unity, verified by read-back.** The amp is flat and safe.
- `/etc/nexusq/eq.json` reset to `{"bass_db": 0.0, "treble_db": 0.0}` — it had been
  left at `3.0` by a test, which `eq_restore_thread` **would have re-applied at the
  next boot**, putting the garbage straight back.
- `nexusq-control` **r31** stays deployed — *(with r50 it now writes correct
  coefficients; on r49 and earlier any `setEq` re-broke the amp)*.

## What had to happen before the EQ could be used — all ✅ done, see *Resolution*

1. ✅ Fix the control bounds — **patch 0046**, kernel **r50**.
2. ✅ Re-verify **on the wire**, not by read-back.
3. ✅ Then the sliders, at ≤1–2 % volume — now unblocked.

## Resolution — kernel patch 0046, `linux-google-steelhead` r50 ✅

`tas571x_coefficient_info()` now advertises a bound that fits a 32-bit `long`:

```c
/* 3.23 fixed point: 26 significant bits, unity = 0x00800000 */
#define TAS571X_COEFFICIENT_MAX	0x3ffffff
...
	uinfo->value.integer.max = TAS571X_COEFFICIENT_MAX;
```

Kept as its own patch rather than folded into 0045 — it is an upstream bug, not
part of exposing the controls, and 64-bit builds never see it, which is presumably
how it survived upstream. Written by generating the hunk with `diff` after a
hand-written one was rejected as malformed, and verified to apply with GNU
`patch --fuzz=0` on the real series (0001 → 0038 → 0045 → 0046).

Deployed the same way as r49: published → `stage-latest` → `try` → **auto-promoted
unattended**. `amixer cget` now reports `min=0,max=67108863` instead of `max=-1`.

### Acceptance test 1 — the wire

```
# asked for 8388608,0,0,0,0 (unity)
[29-00-80-00-00-00-00-00-00-00-00-00-00-00-00-00-00-00-00-00-00]

# asked for 1000,2000,3000,4000,5000
[29-00-00-03-e8-00-00-07-d0-00-00-0b-b8-00-00-0f-a0-00-00-13-88]
     0x3e8=1000  0x7d0=2000  0xbb8=3000  0xfa0=4000  0x1388=5000
```

Every value lands exactly, and read-back returns what was written.

### Acceptance test 2 — the actual frequency response

Coefficients read back **off the amp**, decoded from 3.23 two's complement, and
evaluated as a transfer function:

| | bass +3 | bass −6 / treble +6 | flat |
|---|---|---|---|
| 20 Hz | **+3.00 dB** | −5.99 dB | 0.00 |
| 100 Hz | +1.50 dB | −3.00 dB | 0.00 |
| 1 kHz | 0.00 | 0.00 | 0.00 |
| 8 kHz | 0.00 | +3.00 dB | 0.00 |
| 16 kHz | 0.00 | +5.92 dB | 0.00 |

Half the gain exactly at the design frequency (100 Hz / 8 kHz) is the textbook
shelf midpoint; the two bands are independent; flat is true unity. `bass +3`
decodes to `+1.0016, −1.9830, +0.9816, +1.9830, −0.9832`.

⚠️ **Read those raw values through the two's complement.** A naive
`raw / 8388608` prints `b1` as `+6.0170` and `a2` as `+7.0168` and looks like
garbage — they are −1.983 and −0.983. That misreading cost a few minutes here.

### State

All 14 biquads at unity, `/etc/nexusq/eq.json` flat, kernel r50 with `apk` in
agreement, `device` r81, `down_threshold=60`. **The EQ is ready for a low-volume
listening test**, and app **1.14.0+35** is unblocked pending Petr's approval.

## Incidental

- `nq-kernel-ota`'s health-gated auto-promote worked end to end unattended:
  `trial boot marker found` → `healthy after 0s — promoting` → `promoted and
  disarmed` → package DB reconciled to r49. The A/B kernel path is proven again.
- The protocol pushes `eqChanged` **events on the same socket as replies**, so a
  naive client that does one `readline()` per request desynchronises and reads an
  event as its answer. Match on `id`.
- `getServices` is not a method — the services API is named differently; check
  `companion/PROTOCOL.md` §11 before scripting against it.
