# USB audio dozes while the host sends silence (2026-09-30)

Kernel patch **0059** (`usb: gadget: u_audio: doze a capture stream of pure
silence`), linux-google-steelhead **6.18.48-r18**, enabled by
`nexusq-usb-gadget.sh` in device **r121**.

## The cost it removes

The second overnight soak (2026-09-29, CHANGELOG under r120) had the Android
TV box as the USB audio host. The TV keeps the UAC2 stream open while nothing
plays and sends a packet of zeros every millisecond:

- `/proc/interrupts`: the two musb lines at 1001/s each, around the clock;
- C3 13-15 % of idle, against 72.6 % in the first soak, whose host (omarchy,
  PipeWire) let the stream idle;
- `nexusq-uac2-in` 3.87 % of a core against 3.17 %.

C3's target residency on steelhead is 1100 µs
(`docs/2026-09-20-sleep-states-design.md`); a wakeup every 1000 µs rules it
out.

## Why the interval cannot be lengthened

Closed on 2026-08-26 (PLAN.md Step 6), with bInterval 5 (2 ms) collapsing the
stream to ~3000 of 48 000 frames/s, then blamed on musb. Root-caused on
2026-09-29: the host. Linux `snd-usb-audio` accepts a high-speed data interval
of bInterval 1-4 only (`snd_usb_parse_datainterval()`, sound/usb/helper.c,
returns 0 otherwise), sizes each packet for 125 µs, 6 frames, and the gadget
carries one packet per 2 ms: 500 × 6 = 3000. The `Data packet interval: 125 us`
the host printed in August is that fallback (sound/usb/proc.c). Every Linux or
Android host sets the same 1 ms floor; upstream f_uac2 caps the interval at 4
for this reason.

## The mechanism

Isochronous OUT has no handshake: the host sends whether or not the device
takes the packet. musb raises an endpoint interrupt only when a packet lands in
the FIFO ("An interrupt is generated whenever a packet is received", MUSBMHDRC
programmer's guide 24.1.2.2). With the FIFO full, the next packet is dropped
and OverRun is set (24.1.2.3), no interrupt. `musb_g_rx()` with no request
queued returns and leaves the packet in the FIFO. So a gadget that stops
queueing requests stops being interrupted, and the host cannot tell.

`u_audio`, while the capture stream carries exact zeros:

1. counts the run of silence; after `doze_idle_ms` it holds back each request
   as it completes instead of re-queueing it, and holds back the feedback
   request (the host's feedback reads get a zero-length packet, which
   `snd-usb-audio` ignores: `actual_length < 3 -> return`, keeping the last
   rate);
2. starts a soft hrtimer. Every `doze_probe_ms` it writes into the ALSA
   capture ring the frames of silence due since the last tick, at the stream's
   rate with the sub-frame remainder carried, and queues the held-back
   requests once;
3. a probe that comes back all zeros is held back again; the first one with
   sound wakes the stream: it is delivered, and every request and the feedback
   go back into circulation.

The synthesized zeros matter as much as the dozing. `nexusq-uac2-in` reads a
gadget capture whose `hw_ptr` stops as a host that has gone away while holding
the stream open, and alsaloop spins on such an input (the 2026-08-29 wedge,
28 h at 1.2 GHz). With the ring kept moving, nothing above the kernel sees a
difference, and nothing there had to change.

`u_audio_stop_capture()` runs from `set_alt`, in interrupt context, so it must
not wait for the timer with `hrtimer_cancel()`: a tick running as a softirq on
the same CPU would never finish. The tick queues each probe with interrupts off
and a flag set, which the stop waits on (only ever from another CPU); the stop
marks the stream as stopping and the tick then ends itself. `g_audio_cleanup()`
cancels the timer for real, from process context.

Both parameters are module parameters (`/sys/module/u_audio/parameters`),
writable at run time. The kernel's default is off. `nexusq-usb-gadget.sh` sets
5000 and 50 right after it loads `usb_f_uac2`, if the kernel has them; a
modprobe.d option would make an older kernel log "unknown parameter" at every
boot.

## Measured

Prague Q, TV as host, 2026-09-29/30. For the experiment the patch's first
version was built as r17, so its `u_audio.ko` carries the running kernel's
vermagic (the build reproduced r17 exactly: `usb_f_uac2.ko` byte-identical to
the unit's), and loaded into the running kernel with `insmod`; the module on
disk was left alone, so a reboot returns the stock one. 30 s windows:

| | musb interrupts/s | C1 / C2 / C3 of idle | capture frames/s |
|---|---|---|---|
| stock u_audio | 2004 | 85.4 / 1.5 / 13.1 % | 48 144 |
| patched, `doze_idle_ms=0` | 2008 | 83.7 / 1.8 / 14.6 % | 48 271 |
| doze, 20 ms probe | 251 | 54.4 / 3.9 / 41.6 % | 48 192 |
| doze, 50 ms probe | 101 | 40.9 / 2.7 / 56.5 % | 48 239 |

Petr played sound on the TV twice with the 50 ms probe. `nq-uac2-silence`
logged `audio returned` both times (00:26:35, 00:26:58), he heard nothing
wrong, and after `silent` at 00:27:43 the stream was dozing again: 101/s,
C3 58.3 %. No kernel message on that path.

## Review, and what has not run yet

The fleet-safety review of that first version found no blocker, and five
things the patch now does differently: the stop frees the held-back requests
itself (musb logged "request not queued" for each when a host closed a dozing
stream); the doze state is reset only after the endpoint is enabled (a
repeated SET_INTERFACE of a running alt setting stranded every request); the
stop does nothing in a configuration without capture (its timer is never set
up); the request that starts a doze is held back only after its data is
copied out; and `doze_idle_ms=0` wakes a dozing stream.

Not exercised on a unit yet, each to be checked with dmesg: the fixed version
itself; a host that plays zeros for more than 5 s and then closes the stream
(a Linux host with PipeWire does exactly that); the cable pulled while dozing;
the gadget unbound and rebound while the timer is armed.

The remaining C1 share comes from the rest of the idle path (alsaloop and
`nq-uac2-silence` on the aloop, PulseAudio, the other daemons); the first
soak's 72.6 % C3 had no USB stream at all.

## What it costs

At most one probe period (50 ms) of the start of a sound after at least 5 s of
silence. The probe interval is a run-time knob if that ever matters.

## Tests

- `tests/test_u_audio_doze.py` extracts `u_audio_doze.h` from the patch and
  runs `tests/u_audio_doze_test.c` against it: doze only after the full idle
  run, never when off, any sound restarts the run, silent probes keep it asleep,
  a probe with sound wakes it, and the synthesized frames add up to the rate
  exactly under uneven ticks. Five mutations were each seen failing.
- The patch is `checkpatch --strict`-clean apart from the host-test typedefs,
  builds without warnings at `W=1`, and the series 0001-0059 applies with GNU
  patch on a pristine 6.18.48.
