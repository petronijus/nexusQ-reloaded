# The hardware EQ writes 0xFF into the amp — kernel patch 0045 is broken on 32-bit (2026-08-24)

**Verdict: every write through the `CH1/CH2 - Biquad n` ALSA controls puts
`0xFFFFFFFF` into the TAS5713's coefficient RAM, whatever value was asked for.
The EQ from GitHub issue #2 is DEPLOYED AND UNUSABLE. Confirmed on the I2C wire,
not inferred. The amp was left with garbage coefficients for ~40 minutes and has
been restored to unity.**

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
- `nexusq-control` **r31** stays deployed. Harmless while the stored EQ is flat
  (the restore thread returns early) and while the app that exposes the sliders is
  **unreleased**. Anyone calling `setEq` over the protocol re-breaks the amp.

## What has to happen before the EQ can be used

1. **Fix the control bounds in patch 0045.** It currently just adds
   `BIQUAD_COEFS(...)` entries and inherits mainline's broken
   `tas571x_coefficient_info`. The patch must also give the control a max that
   survives a 32-bit `long` — the coefficients are 3.23 in 26 bits, so
   `0x3FFFFFF` is the honest bound; `0x7FFFFFFF` would also work. Kernel **r50**.
2. **Re-verify on the wire, not by read-back** — the ftrace recipe above is the
   acceptance test. A correct unity write must show
   `[29-00-80-00-00-00-...]`, not `ff`.
3. **Only then** hand Petr the sliders, and only at ≤1–2 % volume.

⛔ **Until 1 and 2 are done the EQ listening test must not happen**, and the app
release (1.14.0+35) stays blocked.

## Incidental

- `nq-kernel-ota`'s health-gated auto-promote worked end to end unattended:
  `trial boot marker found` → `healthy after 0s — promoting` → `promoted and
  disarmed` → package DB reconciled to r49. The A/B kernel path is proven again.
- The protocol pushes `eqChanged` **events on the same socket as replies**, so a
  naive client that does one `readline()` per request desynchronises and reads an
  event as its answer. Match on `id`.
- `getServices` is not a method — the services API is named differently; check
  `companion/PROTOCOL.md` §11 before scripting against it.
