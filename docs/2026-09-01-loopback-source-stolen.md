# 2026-09-01 — the input that was playing to nobody

Reported as four words: *"ted mi nefunguje audio"*. One bug, and every instrument
on the box said the path was fine.

## The symptom, and why it was so quiet

USB audio produced nothing from the amp while:

- `nexusq-uac2-in.service` read **`active`**
- `alsaloop` was running (`hw:UAC2Gadget → hw:Loopback,0,0`)
- the gadget's `Capture Rate` control read **48000** — the host *was* streaming
- the service had logged **"host started streaming at 48000 Hz — USB audio live again"**
- the silence watcher was logging `audio returned -> source resumed`, i.e. it was
  seeing **non-silent PCM arrive**
- `dmesg` had no audio error at all

Everything true, and no sound.

## The chain

PulseAudio's stock config loads **`module-switch-on-connect`**. It makes each
newly appeared source the default **and moves existing source-outputs onto it**.

The Q has two loopback inputs, each loaded by its own service:

| module | loaded by | reads |
|---|---|---|
| `module-loopback source=usb_in` | `nexusq-uac2-in` | the UAC2 gadget via snd-aloop |
| `module-loopback source=roon_in` | `roon-nexusq` | RoonBridge via its own snd-aloop card |

Whichever came up **last** won. `roon_in` appearing dragged the USB loopback onto
it, so the amp played Roon's silent loop while the USB host streamed into a source
nobody read. Mirror-symmetric: starting USB audio stole Roon exactly the same way.

The live evidence, before the fix:

```
Module #27  Argument: source=usb_in latency_msec=120     <- loaded to read usb_in
Source Output #0   Owner Module: 27   Source: 4          <- actually reading roon_in
Source #3 usb_in    Source #4 roon_in
Default Source: roon_in
```

The module's **load argument and its actual binding disagreed**. That is the whole
bug, visible in one `pactl` call — once you know to compare those two.

## Why the existing supervisor could not catch it

`ensure_modules()` in `nexusq-uac2-in` exists for the neighbouring failure found
2026-08-27: unloading *any* other `module-alsa-source` (turning Roon off does
exactly that) takes our `module-loopback` with it. It supervises module
**existence** — and here the module never went away. Only its binding changed, and
PulseAudio logs nothing when it moves a stream. So every check passed, forever.

Detecting a move would also cost a second `pactl` fork per tick (~70 ms of CPU
each on this SoC; the first version of that supervisor measured **+4.6 % of a core
at idle**). Pinning is both correct and free.

## The fix

`source_dont_move=true` on both loopbacks. **Only the capture side.** The
sink-input stays movable on purpose — looping into the default sink is what makes
an input follow the output the app selects.

Seen failing and seen holding, on the device:

1. **Forced move** — `pactl move-source-output <id> roon_in` → `Failure: Invalid
   argument`, exit 1, stream still on `usb_in`.
2. **The original trigger** — unload + reload the `roon_in` source (what turning
   Roon off and on does): `Default Source` flips to `roon_in` as before, and the
   USB loopback **stays on `usb_in`**. That is the exact moment it used to be
   dragged away.

`tests/test_loopback_source_pinned.sh` pins the invariant. It asserts the flag is
on the `load-module` **command**, not merely somewhere in the file — both files
explain it in a comment, and a test satisfied by prose would pass on a file that
had lost the code. Seen failing with the flag deleted.

## Two things that were not the cause

- **The box being on HDMI.** `audio-out status` said `mode=hdmi`, and
  `/data/adb/audio-out/mode` was written at 20:05:17 — the same minute the Q logged
  the stream closing. That was Petr switching away *because* the Q was silent: the
  consequence, not the cause.
- **The amp volume.** It read 6 % / **−73 dB**, which looks like an answer. It is
  per-source and restores when a source goes live: with USB audio running it was
  **−33 dB**, an ordinary listening level. A volume read on a *parked* path is not
  what plays.

## Method note

The one command that would have gone straight to it, from the top:

```sh
pactl list source-outputs | grep -E 'Source Output #|Owner Module:|Source:'
pactl list modules | grep -A2 module-loopback     # compare Argument: to the above
```

When a PulseAudio path is silent but healthy, **check bindings, not just that the
modules are loaded.**

Also worth recording: reading GPIO 16 on the TV box with `gpioget` during
diagnosis was a mistake — `xiaomi-tvbox-twilight/README.md` (line 599) warns it
switches the line to an input, which is why the role is detected from the presence
of the external controller's root hub (`fe350000`) instead. No harm done here, but
the box's role must be read with `audio-out status`, never from the GPIO.
