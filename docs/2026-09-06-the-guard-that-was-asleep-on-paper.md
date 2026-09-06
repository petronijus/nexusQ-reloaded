# 2026-09-06 — the guard that was asleep on paper

Reported as *"the Q is warm"*. The MacBook ran a read-only `nexusq-diag`
(capture `nq-captures/20260906-160616/` on that machine) and wrote the handover;
this note records the repair on the desktop the same evening.

## What the box looked like

The die was not hot — 67 °C over 16 h, board 49 °C, zero throttling, exactly the
documented idle floor. But the **enclosure** was warm because the Roon path had
been awake for 4.75 days with nothing playing:

| symptom | evidence |
|---|---|
| `roon_in` RUNNING while its producer is closed | `pactl list sources` vs `/proc/asound/RoonLoop/pcm0p/sub0/status = closed` |
| amp sink never idles | sink-input "Loopback from RoonBridge" uncorked; `alsa_output.platform-sound-tas5713` RUNNING, PCM open since uptime 80541 s = **Sep 1 21:37:01** |
| amp physically on | `gpio-12 pdn out hi` (active-low), Speaker switch on, PVDD consumers active; −33 dB so nothing audible |
| CPU burned in silence | pulseaudio ~21 % of a core (10 % of it in libspeexdsp resampling a 48003 Hz silent loopback), nexusqd's `arecord` tap ~7 % because its gate counts uncorked sink-inputs |
| guard asleep on paper | `nexusq-roon-idle.service` last logged `producer idle -> source suspended` at **Aug 31 23:15:45** and nothing since |

Load average ~1.0 all night instead of 0.1–0.2.

## The trigger

Sep 1 21:37 is the moment the Roon loopback module was reloaded live from a root
ssh session for the r92 `source_dont_move` fix
(`docs/2026-09-01-loopback-source-stolen.md`). Reloading the module resumed
`roon_in` from outside the guard. The guard never saw the producer open, so it
never re-issued the suspend, and it trusted its own `asleep` flag from then on.

## The bug, precisely

`nq-uac2-silence`, `Watcher.run_producer()`: while `self.asleep` the loop only
reacted to the producer PCM *opening*. It never checked whether the PulseAudio
source it believed suspended was actually suspended. Any external resume — a
module reload, `pactl suspend-source roon_in 0`, a `nexusq-control setOutput`
re-route, a PA restart that loses the suspend — left the source running forever.

The USB path (`NQ_WATCH_MODE=silence`) does not have this hole: asleep, its own
`arecord` owns `hw:Loopback,1,0`, so PulseAudio *cannot* reopen the capture side
behind the guard (EBUSY). Producer mode reads nothing, so nothing held the lock.

**Seen failing first**, on the r93 script, with Roon idle and the source asleep:

```
pactl suspend-source roon_in 0
# 1 s later:  roon_in RUNNING, pcm1c "state: RUNNING", tas5713 PCM open
# 15 s later: unchanged, journal of the guard: -- No entries --
```

## Ground truth without asking PulseAudio

snd-aloop wires device 0 of a card to device 1: what Roon writes into
`hw:RoonLoop,0,0` (`pcm0p`) comes out of `hw:RoonLoop,1,0` (`pcm1c`), and that
capture side is what `module-alsa-source` holds open exactly while the source is
not suspended — PA closes the ALSA handle on suspend and reopens it on resume.
Measured on the Q:

| command | `/proc/asound/RoonLoop/pcm1c/sub0/status` (≤1 s later) | `pactl list sources short` |
|---|---|---|
| `suspend-source roon_in 1` | `closed` | SUSPENDED |
| `suspend-source roon_in 0` | `state: RUNNING` / `owner_pid: <pulseaudio>` | RUNNING |

So one /proc read says whether the source is *really* awake: no PulseAudio
round-trip, no parsing of `list-sources`, and — the point — no trust in the
guard's own memory of the last command it sent.

## The fix (device r94)

- `NQ_CONSUMER_PCM` — the other end of the cable. Set explicitly in
  `nexusq-roon-idle.service`; for a hand-run, `other_end()` derives it from
  `NQ_PRODUCER_PCM` (`/pcm0p/` ↔ `/pcm1c/`, purely lexical, anything else
  derives nothing — an unknown consumer must never be guessed).
- `run_producer()` reconciles want (producer) with have (consumer) on **every
  poll**, both directions:
  - asleep, producer closed, capture side open → `suspend(True)` again, logged
    as `source resumed behind our back (producer still closed) -> re-suspended`;
  - awake, producer playing, capture side closed → `suspend(False)` again,
    logged as `producer playing but the source is suspended -> resumed again`.
- `NQ_CONSUMER_CONFIRM` (default 5 polls = 1 s at `NQ_PRODUCER_POLL=0.2`):
  PulseAudio applies suspend/resume asynchronously, so the two files disagree
  for a moment after every command; only a disagreement that survives this many
  consecutive polls is acted on. A blip shorter than that is ignored (tested).
- `consumer_open()` returns `None` when the path is unset or unreadable, and
  `None` triggers nothing — reconciliation is off, not guessing, and the
  startup line says so (`no consumer PCM: an external resume will NOT be undone`).
- `PaCli.send()` now drains the socket before writing. PA answers every command
  with a `>>> ` prompt and nothing ever read it; a socket that is never read
  fills its buffer eventually.

### Proven

- `pmos/device-google-steelhead/tests/test_uac2_silence_producer.py` — 11 tests
  with a fake clock (sleep advances monotonic and plays the outside world per
  poll) and a fake PulseAudio that honours `suspend`. Run against r93 first:
  3 failures (both holes + the resume-then-wake sequence) and 4 errors
  (`other_end` missing). Green after; `test_nfc_payload.py` still green.
- Live, r94 script dropped onto the Prague Q and the user unit restarted:

```
17:11:50 producer idle -> source suspended
17:11:53 source resumed behind our back (producer still closed) -> re-suspended
```

  the second line ~1 s after a deliberate `pactl suspend-source roon_in 0`.
  Guard CPU: 0 %.

## Shipped

`OTA_PACKAGES_ONLY=1 OTA_PACKAGES=device-google-steelhead` on the desktop
(6 min, chroots rebuilt from scratch), `publish-ota-repo.sh` → gh-pages
`c861ac9` (per-apk signature gate + secrets gate 11/11), Pages served r94 within
15 s. Prague Q: `apk update && apk upgrade --available --ignore
linux-google-steelhead` — the app's own path — r93 → r94 at 17:23; the device
package's change re-ran `postmarketos-mkinitfs`/`boot-deploy` (deviceinfo is an
input), which only touches `/boot`, not the running slot (`root=/dev/mmcblk0p13`).
Guard unit restarted from the installed file, trigger repeated, undone in 2 s.
Cottage Q: still r93, not reachable from Prague.

Build-log noise, not fixed: `docker-build.sh` Phase 2's aport listing prints
`ERROR: failed to source APKBUILD` for every non-device aport (a subshell
`source` under `set -e`); cosmetic, the build and the exported apk are fine.

## Immediate relief, before any of that

`systemctl --machine=user@.host --user restart nexusq-roon-idle.service` — within
20 s `roon_in` SUSPENDED, the tas5713 sink SUSPENDED, its PCM `closed`. (The
handover's `journalctl --user-unit … --machine=user@.host` form does not work
as root — "Connecting to a machine as non-root is not supported"; use
`journalctl _SYSTEMD_USER_UNIT=nexusq-roon-idle.service` instead. And `pactl`
needs `PULSE_SERVER=unix:/run/user/10000/pulse/native
PULSE_COOKIE=/home/user/.config/pulse/cookie`, not `su - user`.)

## A release-machine finding on the way

`scripts/seed-ota-volume.sh` on the desktop was **not** the no-op HANDOVER
expected: `seeded=10 kept=1 retired=6`. Six apks in `nexusq-workdir` were signed
with the fleet key but were *not the published bytes* — v1.15.2 was cut on the
MacBook, and the desktop still held its own builds of the same versions. An
OTA-only publish from here would have re-published those. They are in
`.retired-pmos@local-6a42e957/` (nothing deleted). Rule: run the seed before an
OTA-only publish on any machine that did not build the last release, whatever
the machine is.

## Seen in the same diagnosis, not fixed here

- **systemd 262 journal noise** (since the Sep 5 upgrade): every login and every
  5-minute `nexusq-control` poll (`systemctl --machine=user@.host --user`,
  `userspace/nexusq-control/nexusq-control` ~line 520) emits
  `systemd-coredumpd.service: Skipped due to 'exec-condition'` /
  `Dependency failed for Kernel Core Pattern Register` / `Failed to read
  pids.max`. `coredumpctl` is empty — nothing crashes; `systemd-coredump
  --check-requirements` fails on this image. Packaging-side. A PAM session plus a
  transient unit every 303 s is also worth trimming.
- **HA telemetry shows the wrong unit.** `sensor.nexus_q_*` went unavailable
  Sep 3 12:29 and since **Sep 5 17:44** carries a box with uptime <1 d and a
  47–59 °C die — the cottage Q, not Prague (5.7 d, 67 °C). Prague's `nexusq-mqtt`
  is alive (`node nexusq_f88fca2048e1`). Either the cottage OTA of Sep 5
  publishes into the same HA device (prefix / node_id collision — memory "Two
  Nexus Q on MQTT", `userspace/nexusq-mqtt/nexusq-mqtt` discovery config) or
  Prague's discovery broke in HA on Sep 3. Until sorted, `ha-opp-window.py`
  reads the cottage.
- **USB host streams silence into the UAC2 gadget** — `musb_irq_work` ~1 kHz ≈
  30 % of a core, documented (`docs/2026-08-24-usb-audio-idle-cost.md`); the USB
  guard itself works (last `silent -> source suspended` Sep 4 23:32). The largest
  single consumer now that the Roon leak is closed.
- `vdd_mismatch` warns: 12 in 5.7 days, isolated singletons ~10 h apart — the
  documented sampling race, not a power fault.

## Untouched and healthy

nexusqd + LED ring alive (0 restarts), WiFi −22 dBm on 5 GHz with no heals since
Sep 1, BT up, VDD_MPU tracks the OPP exactly, `time_in_state` 87 % at 350 MHz /
0.4 % at 1.2 GHz, dmesg clean, pstore empty, no cooling-device activity ever.
