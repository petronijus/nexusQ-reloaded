# 2026-09-12 — the staircase the ceiling could not reach

Reported as *"USB audio už zase nefunguje, to je strašně unreliable!"*, then,
forty minutes later, *"teď to hraje, ale nehrálo"* and *"narůstá tam latence?"*.
Two questions; the second one turned out to be the one with a bug on our side.

## The silence: the box's, not ours

Prague Q, up 11.8 days, `device-google-steelhead` r96. The USB host on the cable
is the Xiaomi TV box (the RNDIS peer never answers ARP — Android has no host
driver for it, which is consistent).

Every instrument on the chain said the path was fine — gadget `configured` at
high speed, `alsaloop` running `hw:UAC2Gadget → hw:Loopback,0,0`, `usb_in`
loaded and **pinned** to its loopback (the 09-01 fix holding), PulseAudio
without a single error line. So the data itself was read, at the one point
where nothing of ours has touched it yet: the pipe from the silence watcher's
own `arecord` on `hw:Loopback,1,0` (`/proc/<pid>/fd/1`, 64 KB stolen twice).

```
bytes=65536 frames=16384 peak=0 nonzero=0
bytes=65536 frames=16384 peak=0 nonzero=0
```

Exact digital zeros, arriving at exactly 48 kHz (`hw_ptr` on the gadget capture
advanced 48 528 frames in the sampled second). In `u_audio.c` the capture path
is a plain `memcpy(req->buf → dma_area)` with `hw_ptr += req->actual`, so full
packets of zeros in the ALSA ring are full packets of zeros on the wire. A wedged
musb DMA would replay *stale* audio, not silence. The box was sending nothing,
loudly.

The journal gives the day's shape:

| host stream | sound for | then |
|---|---|---|
| 12:01:21 start (after re-enumeration 12:01:09) | 14 s | zeros |
| 12:25 | 17 s | zeros |
| 13:41 | 205 s | zeros, stream closed 13:45:18 |
| 17:12:02 start (after re-enumeration 17:11:57) | 15 s | **37 min of zeros** |
| 17:49:42 (Petr starts something) | 61 s, 17 s, then continuous | — |

Two things fall out. Every host stream start since 09-06 (07:38:05 on the 7th,
12:01:21 and 17:12:02 today) sits 5–12 s after a `serial-getty@ttyGS0` restart,
i.e. a USB re-enumeration: the box opens the stream when it (re)boots or wakes
or the cable is re-seated, never on its own. And between 13:45 and 17:11 it had
the stream *closed*; between 17:12 and 17:49 it had it open and silent. Which of
those windows "nehrálo" refers to decides whether the box had not selected USB
at all or was playing into it muted. That is the box's business either way; it
is recorded here because the next "unreliable" will look identical from the Q.

## The latency: yes, it grows — and r95 bounds the wrong path

Measured while the box was finally playing, `usb_in` running, amp running:

```
17:49:55  Source minimum latency increased to 16.00 ms
17:49:57  Source minimum latency increased to 26.00 ms
17:50:38  Source minimum latency increased to 36.00 ms
17:53:29  Source minimum latency increased to 46.00 ms
18:06:38  Source minimum latency increased to 56.00 ms
18:19:31  Source minimum latency increased to 66.00 ms
18:37:23  Source minimum latency increased to 76.00 ms
```

with the loopback's buffer following (57.9 → 61.1 → 72.3 → 82.7 ms) on top of a
fixed 101 ms sink latency. Effective target ≈ (100 + 76) × 1.1 + 1.5 ≈ 195 ms
against the configured 120, plus the 80 ms alsaloop hop in front of it. The
same staircase is in the journal on 09-02/03 (120 → 145 over two days, 6 steps
on 08-31, 14 on 09-07). It never goes down.

Read against PulseAudio 17.0 (the version on the box):

- **`max_latency_msec`** — the r95 ceiling — is consulted in exactly one place,
  `module-loopback.c: adjust_rates()`, when the module's *own* `underrun_counter`
  exceeds 2 ("Too many underruns, increasing latency"). There is not one such
  line in the journal since the 08-31 boot. The ceiling guards a path this box
  has never taken.
- The staircase is **`alsa-source.c: increase_watermark()`**. A timer-scheduled
  source computes how much room its buffer had when the thread woke; if it woke
  after the room ran out (`overrun`, threshold 0 ms) it raises its *reported
  minimum latency* by 10 ms (`TSCHED_WATERMARK_INC_STEP_USEC`) and announces
  the new range. `module-loopback` receives
  `LOOPBACK_MESSAGE_SOURCE_LATENCY_RANGE_CHANGED`, logs the line above, and
  recomputes `minimum_latency = (min_sink + min_source) × 1.1 + 1.5 ms`, which
  it then uses *instead of* `latency_msec` ("Configured latency of 120.00 ms is
  smaller than minimum latency, using minimum instead"). The code carries its
  own verdict on reversibility: *"the case that the minimum latency changes
  back to a smaller value is not handled because this never happens with the
  current source implementations"*.
- **Not alsaloop.** The aloop playback `trigger_time` (which changes whenever
  alsaloop re-prepares after an XRUN) was sampled at 0.5 s across the whole
  session and did not move at any step. (It *did* move at 17:33:38 and
  17:41:38 while the box was idle — exactly 480 s apart, the `--sync=simple`
  clock drift, ≈ 167 ppm, a glitch per 8 minutes; separate issue, noted.)
- **Not the 5-minute transient units** either (`nexusq-control` r45 still runs a
  `systemd-run … systemd-stdio-bridge --user` every ~5 min: 17:46:04, 17:51:05,
  17:56:07 … against steps at 17:50:38, 17:53:29, 18:06:38 …). Also noted; the
  `--machine` transport r38/r39 retired is evidently not gone.

So the wake-ups are simply late — by more than 16, 26, … 76 ms, on a 2-core
Cortex-A9 idling at 350 MHz with a kworker eating a quarter of cpu0 on the
gadget's 1 kHz interrupt.

## Why they are late: nothing on this image runs real-time

| who | what it asks | what happens |
|---|---|---|
| `alsaloop` | `sched_getparam` + `sched_setscheduler(SCHED_RR)` at start | **musl implements both as `ENOSYS` stubs.** "Scheduler getparam failed." has been in every start since 08-02; the bridge has always been an ordinary task |
| PulseAudio IO threads | `pthread_setschedparam(SCHED_RR\|RESET_ON_FORK, 5)` then rtkit | a probe module (`module-null-sink`, virtual, ignored by switch-on-connect) logged `Failed to acquire real-time scheduling: Not supported`; rtkit answers `No such file or directory`. All six IO threads are `SCHED_OTHER`, nice 0 (`Max nice priority 0`, so `high-priority=yes` failed too) |
| the kernel | — | allows it: util-linux `chrt -f 5` (sched_setattr(2)) inside `user@10000` → `SCHED_FIFO`; `RLIMIT_RTPRIO=50` from the existing drop-in; the cpu cgroup controller is enabled nowhere, so `CONFIG_RT_GROUP_SCHED=y` is inert; the same pthread call from Python as uid 10000 with rlimit 9 succeeds |

Why PA's *own* call fails when the identical one succeeds from Python turned
out to be visible without strace: `strings libpulsecommon-17.0.so` holds
`RealtimeKit worked.` and `Failed to acquire real-time scheduling: %s` but not
one of `SCHED_RR|SCHED_RESET_ON_FORK worked.` / `Successfully enabled SCHED_RR
scheduling for thread`. Alpine's build compiled the `HAVE_SCHED_H` block of
`pa_thread_make_realtime()` out, so PA never calls `pthread_setschedparam()`
at all and goes straight to its RealtimeKit client — which returns `ENOTSUP`,
the "Not supported" in the probe. PA on this image cannot become real-time on
its own, ever. Something outside it has to do what rtkit would.

## The fix (device r98) — and the regression r97 would have shipped

Three pieces, all on a load-module / launch line, all guarded by
`tests/test_loopback_latency_bounded.sh` (19 checks; each new one seen red
before its change).

1. **`fixed_latency_range=yes`** on `module-alsa-source` for `usb_in` and
   `roon_in` — PulseAudio's own switch for this exact behaviour ("disable
   latency range changes on overrun"). The source still doubles its internal
   wake-up watermark after a miss (it wakes earlier next time); it just no longer
   *reports* a bigger minimum, so `module-loopback` keeps `latency_msec`. A late
   wake-up now costs a dropout instead of a permanent 10 ms.
2. **`alsaloop` under `prlimit --rttime=200000:200000 chrt -f 10`**
   (`NQ_UAC2_RTPRIO`, `NQ_UAC2_RTTIME_US`), probed once against `true` and
   falling back to a plain launch with a warning if RT is not permitted. The
   `RLIMIT_RTTIME` is not optional: a `SCHED_FIFO` alsaloop that wedges into a
   spin — the park logic exists because it does — would own a core; with the
   limit the kernel sends `SIGXCPU` after 200 ms of unbroken RT CPU (rtkit's
   figure for PA) and the supervisor sees an ordinary exit.

3. **`nq-pa-rt`**, because 1 alone made things worse. r97 (1 + 2 only) went
   onto the Prague Q at 18:49 and the journal filled with
   `alsa-source.c: Overrun!` — **23, 18, 7 per minute**, settling around 3.
   With the range fixed, a wake-up later than the source's buffer is a dropout
   instead of a +10 ms, and that buffer is tiny by construction:
   `module-loopback` gives the source `(latency_msec − min_sink) / 2` =
   `(120 − 100) / 2` = **10 ms**, because the amp sink runs `tsched=0` with
   4 × 25 ms fragments (`module-udev-detect tsched=0`) and reports a fixed
   100 ms. Ten milliseconds is less than the 5–18 ms the reader wakes late.
   The reader has to be real-time, and PA cannot make it so — hence a helper
   that does what rtkit would: after each source load, `chrt -r -p 5` on every
   PA thread named `alsa-source-Loo*` (the kernel truncates both loopback
   sources' names to the same 15 characters, so both get it; idempotent, so
   `nexusq-uac2-in` and `roon-nexusq` can each call it). PA's own
   `RLIMIT_RTTIME=200000` already bounds a spinning thread. Live A/B on the
   same stream, same evening: SCHED_OTHER **35 overruns / 84 late wake-ups in
   3 min**; SCHED_RR 5 **0 / 1 in the first minute** (5-minute figures below).

The comment in `nexusq-uac2-in` that blamed the cushion growth on alsaloop's
underruns is corrected; the r95 ceiling and the unpark reset stay — they guard a
real path, just not the one that was climbing.

## Build note

`OTA_PACKAGES_ONLY=1 OTA_PACKAGES=device-google-steelhead` failed under
crossdirect with `cc: fatal error: cannot execute 'cc1': posix_spawnp` while
compiling `nq-healthd.c` (`${CC:-cc}` in `build()`), with **no** concurrent
pmbootstrap on the volume. The pmbootstrap log shows the r95 build hitting the
same wall twice on 09-06 (19:24, 19:26) before a later attempt passed, so the
08-31 verdict ("the toolchain was never broken, it was a concurrent zap") is
true for the kernel and not for this package's direct `cc` call. Built with
`NEXUSQ_NO_CROSS=1`.

## Shipped and measured (Prague Q, r98 installed 19:00:36 by hand from the build volume)

| window | overruns | late wake-ups (>5 ms) | latency steps |
|---|---|---|---|
| r97 (fixed range, SCHED_OTHER), 18:50:15–18:55:15 | **57** | 138 | 0 |
| r97 + source threads `chrt -r 5` by hand, 18:55:15–19:00:44 | 4 | 11 | 0 |
| **r98** (scripts do it themselves), 19:00:36–19:06:06 | **0** | 3 | 0 |

Host streaming throughout (48 624 frames/s on the gadget capture), `usb_in`
RUNNING at its configured 10 ms, loopback buffer at the 120 ms target, alsaloop
`SCHED_FIFO 10` under a 200 ms RTTIME, both `alsa-source-Loo` threads
`SCHED_RR 5` set by `nq-pa-rt` from the service restart, not by hand. Cottage Q
untouched (not reachable from Prague) until it pulls the OTA.

**Released 20:5x the same evening** after 56 minutes of the watch below: 0
latency steps, 1 overrun, 10 late wake-ups, no restart, no fallback.
`publish-ota-repo.sh` → gh-pages `1997b3a` (secrets gate PASS, per-apk
signature `pmos@local-6a42e957`); the Pages repo serves r98.

**Verification watch left running on the Prague Q** (7 days, `nice`):
`/var/tmp/nq-usbaudio-watch.sh` → `/var/tmp/nq-usbaudio-watch.log`, one line a
minute — cumulative `Overrun!` / late-wake-up / latency-step / "Too many
underruns" counts since the r98 install, alsaloop pid + policy (a pid change is
a restart, a policy other than `SCHED_FIFO` is the fallback path), both PA
source-thread policies, `usb_in` state and latency, the loopback buffer, and the
gadget `hw_ptr` (moving = host streaming). PA's log level is at *info* for the
duration so the overrun lines exist; `pacmd set-log-level 2` puts it back. The
first hour of it is what the release was decided on.
