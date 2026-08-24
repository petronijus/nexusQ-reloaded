# USB Audio, switched on and idle, costs the whole idle-power programme (2026-08-24)

**Verdict: with "USB Audio" enabled and NOTHING playing, the Q runs at 1200 MHz /
1380 mV 84.65 % of the time and sits at a mean die temperature of 82.9 °C
(peak 95.0 °C). The idle-OPP goal — 90.8 % @ 350 MHz — collapses to 0.58 %.**

**Fixed the same day by one governor knob:** `conservative`'s `down_threshold`
40 → 60 restores **97.33 % @ 350 MHz with USB Audio still live** — 1.07× a
locked-350 floor, better than the shipped USB-off baseline, die 84 → 68 °C, and
no change to how fast a real ramp climbs. Measured, not argued: see *Result*.

This is the measurement PLAN.md's standing goal existed for, run for the first
time with the USB DAC path *enabled*. Every idle-power win from 2026-08-13…16
is erased by leaving this one toggle on.

## Run

| | |
|---|---|
| window | 2026-08-23 18:23 → 2026-08-24 00:33 CEST (**6.17 h**) |
| device | r80 · kernel 6.12.12-r48 · governor `conservative` |
| state | USB Audio **ON** (toggled 18:00), Spotify/AirPlay/Roon **off**, nothing playing, ring blanked (`led_sum=0`) |
| method | `nq-night-usb` sampler, 38 snapshots / 10 min, detached, fetched **once** (per `docs/2026-08-13-idle-opp-residency-measurement.md`) |
| cross-check | Home Assistant history, fully passive (`scripts/diag/ha-opp-window.py --days 1.2`) |

## Numbers

OPP residency, kernel `time_in_state` deltas over the whole run — against the
2026-08-19 baseline (USB Audio off, device r76, 8 h passive HA window):

| OPP | mV | USB Audio ON | baseline OFF |
|---|---|---|---|
| 350 MHz | 1025 | **0.58 %** | **90.8 %** |
| 700 MHz | 1200 | 0.76 % | 9.0 % |
| 920 MHz | 1313 | 14.02 % | 0.15 % |
| 1200 MHz | 1380 | **84.65 %** | **0.04 %** |

- die temperature **mean 82.9 °C, min 75.4, max 90.6** (HA saw a 95.0 °C peak) —
  against **52.7 °C mean** at baseline. **+30 °C for an idle appliance.**
- CPU actually busy: **11.51 % of the 2-core budget** (was ~3.8 %).
- governor transitions **0.073/s** — it is not oscillating, it is *parked*:
  `scaling_min_freq` is a healthy `350000`, so nothing pins the floor; the
  governor genuinely measures load above `down_threshold` forever.

## Attribution (per-cgroup `cpu.stat` deltas)

| cgroup | CPU | note |
|---|---|---|
| `user.slice` | **8.72 % of a core** | almost entirely **PulseAudio** (`ps` TIME 34:10 in 6.95 h ≈ 8.2 %) |
| `nexusqd.service` | **2.14 % of a core** | **13× its 0.165 % r13 idle budget** |
| `nq-healthd` | 0.17 % | normal (post-C-rewrite) |
| `alsaloop` (inside user.slice) | ~0.2 % | the bridge itself is cheap, as designed in r65 |

## Mechanism — three stacked costs, one dominant

1. **`musb-hdrc.0.auto` fires 1006 interrupts/s** (measured over 2 s; `twd`
   adds 296/s). That is the USB gadget's 1 kHz frame cadence, and it runs
   whenever the host is attached and the UAC2 function is composed —
   **independently of whether any audio is actually streaming**. The CPU is
   dragged out of idle every millisecond, so `conservative`'s 20 ms sampling
   window never sees an idle-enough system to step down. This is what parks the
   OPP at 920–1200 MHz, and the 1380 mV rail is where the heat comes from.
2. **PulseAudio resamples silence 24/7.** The sink-input list shows exactly one
   stream — `module-loopback` at **48003 Hz** (not 48000): the loopback is
   permanently rate-matching, i.e. the resampler runs forever on a silent
   stream, and the TAS5713 sink never suspends (`RUNNING`, amp on).
3. **nexusqd never goes idle.** Its r13 adaptive cadence caps the frame deadline
   at 0.25 s "while the tap is open", and the tap is gated on a sink-input
   existing — which the USB loopback guarantees permanently. So the visualizer
   renders forever for a blanked ring. *(This is the same class of bug as the
   `nq_progress` false-CRIT: an r13 assumption invalidated by a new caller.)*

## What to do

**This gets FIXED, not switched off** (Petr, 2026-08-24) — USB Audio is a
shipped feature and "leave it off" is not an answer. The toggle was left ON.

The upstream cause is the host: the Xiaomi box keeps the UAC2 stream open and
pushes **silence 24/7**, so the 1 kHz gadget IRQ cannot be refused while the Q
is enumerated as a DAC. What IS ours is everything that reacts to it.

**Answered by the arm series below: the fix is `down_threshold` 40 → 60**, a
single governor tunable, worth 6.03× → 1.07× and −16 °C, with ramp-up behaviour
unchanged. See *Result* for the mechanism and the numbers. The remaining items
are correctness/efficiency, no longer power:

1. **nexusqd r14** — gate the render tap on SIGNAL, not on a sink-input existing
   (built, undeployed). ~3.9 % of a core at 350 MHz.
2. **PulseAudio: don't resample and don't hold the sink RUNNING on silence.**
   ~20.7 % of a core at 350 MHz plus the amp's own draw. ⚠️ delicate: must not
   clip the start of real audio — this is the path that took r65→r70 to
   stabilise (delay runaway).
3. **Host side, optional.** If the Xiaomi box can be made to close the stream
   when idle (`~/Documents/Dev/xiaomi-tvbox-twilight`), the IRQ storm stops at
   the source — a bonus, never the fix; the device must behave regardless.

## Instrument note — the tooling already existed and was better

This run was taken with a **hand-rolled one-off sampler**, which omitted
`/proc/interrupts` and `/proc/softirqs` — so the actual cause (1006 IRQ/s) and
the fact that **26 % of all burned CPU sits in no cgroup at all** were invisible
until they were chased down in a separate ssh session. `scripts/diag/nq-opp-study2.sh`
already captured all of it. **Reach for the harness; never hand-roll a sampler.**

Fixed here as a result (2026-08-24):

- `nq-opp-study2.sh`: its "playback started — study invalid" guard tested
  `system.slice/<unit>` for `librespot` / `shairport-sync` / `roon` /
  `nexusq-uac2-in`, but **all four are user units** under `user@10000.service`,
  so that path never exists and **the abort could never fire** — a run with
  music playing would have been silently reported as an idle baseline. It now
  checks the user manager's tree too. New `ALLOW_UNITS` env var lets a run
  deliberately profile one of those paths, and stamps it into `run.log`.
- `analyze-opp-snaps.py`: now prints a **relative dynamic-power index**
  (C·V²·f, normalised to a locked-350 floor) — it reproduces PLAN.md's published
  "+16 % baseline" and "1200 MHz costs 6.2×" exactly — and the **share of CPU
  that is in no cgroup**, so the IRQ/kthread blind spot can never hide again.
- `nexusqd` **r14**: the 4 Hz "tap open" floor now yields to the full 1 Hz idle
  stretch once the tap has been raw-silent past `TAP_QUIET_S`. Contained fix,
  worth ~2.1 % of a core — but note it is **13 % of the CPU burn and ~0 % of the
  reason the clock is pinned**, so it is a correctness fix, not the answer.

## Result — one governor knob recovers it (arm series 01:16 → 02:59)

Five arms via the harness (`OUT=/var/log/nq-night-arms`, 120 s settle + 1200 s
each, `ALLOW_UNITS=nexusq-uac2-in.service`, USB Audio live throughout), asking
how much of the 5× is recoverable by governor policy alone:

| arm | knobs | 350 MHz | 700 | 920 | 1200 | rel. power | die | trans/s |
|---|---|---|---|---|---|---|---|---|
| `base` | sr 20 ms, up 80, **down 40** (production) | 0.00 % | 0.00 | 9.95 | 90.05 | **6.03×** | 84.0 °C | 0.06 |
| `sr100up95` | sr 100 ms, up 95, down 40 | 35.20 % | 28.09 | 15.08 | 21.62 | 3.12× | 68.6 °C | 0.004 |
| **`down60`** | sr 20 ms, up 80, **down 60** | **97.33 %** | 1.74 | 0.38 | 0.55 | **1.07×** | 68.1 °C | 0.26 |
| `powersave` | locked 350 MHz (floor bound) | 100.00 % | — | — | — | 1.00× | 66.5 °C | 0 |
| `base2` | production, repeat | 0.00 % | 0.00 | 9.19 | 90.81 | 6.04× | 77.2 °C ↑ | 0.07 |

**`down_threshold` 40 → 60 recovers 98 % of the loss: 1.07× against a floor of
1.00×, with USB Audio live — better than the shipped USB-off idle baseline
(1.16×). Die 84.0 → 68.1 °C.**

- `base2` reproduces `base` to 0.2 % (6.04 vs 6.03×), so the knobs restored and
  the measurement is repeatable. `base2`'s cooler 77.2 °C is thermal lag — it
  started from `powersave`'s 66.5 °C and was still climbing at the post-snapshot
  (pre 75.4 → post 77.2).
- The arms are directly comparable: `musb` fired **1000.0 IRQ/s in every arm**
  (the box never stopped streaming), and each cgroup's CPU normalised by mean
  frequency is constant — nexusqd 15.6 / 14.2 / 14.0 / 15.6 MHz·%, user.slice
  82.5 / 94.7 / 75.2 / 71.7 / 81.1. Same workload throughout; only the clock moved.

### Why `down_threshold` is the whole story

`conservative` **holds** the frequency between `down_threshold` and
`up_threshold`. This is the *same* mechanism the 2026-08-16 20 → 40 change fixed,
one band higher: the USB workload — 1 kHz gadget IRQ plus PulseAudio grinding
silence — puts the load of a typical 20 ms window in the **40–60 dead band**, so
at `down=40` the governor had no rule that could ever bring it down, and it stayed
wherever the first load spike put it. At 60 those windows decay, and it walks to
350 MHz and stays: mean visit **9.35 s**, and the 125 excursions to 700 MHz last
**156 ms** each. It is responsive, it just no longer parks.

**Ramp-up is byte-identical to production** — `up_threshold`, `sampling_rate` and
`freq_step` are untouched, so a genuine ramp is still 3 × 20 ms ≈ 60 ms. This is
the decisive advantage over `sr100up95`, which stretches it to ~300 ms.
Transitions rise 0.06 → 0.26/s, which is not oscillation.

### What this rules out

- **`sr100up95` should stay unshipped.** It measured 98.7 % on *plain* idle but
  only 35.20 % / 3.12× here, and costs ramp latency. `down60` dominates it on
  every axis; there is no reason to take the listening-test risk for it.
- **PulseAudio's silence-resampling is NOT what pinned the clock.** `down60`
  reached 97.33 % @ 350 MHz with PA still resampling at 48003 Hz and the sink
  still `RUNNING`. So the attended "unload the PA loopback" experiment is
  **off the critical path as a power fix** — it stays a CPU-efficiency and
  correctness item, not a prerequisite.
- **350 MHz sustains the USB audio path with room to spare.** `powersave` held
  the stream for 20 min at 100 % / 350 MHz and 20.4 % busy — roughly 4× headroom.
  So `down60`'s 1.07× is within 7 % of the best physically available.

### Still worth fixing, now on efficiency grounds only

At 350 MHz the same silence costs **user.slice 20.7 % and nexusqd 3.9 % of one
core** (the percentages rise as the clock falls; the *work* is unchanged). That
is a quarter of a core burned on nothing. It no longer costs much power, but
nexusqd **r14** (built, undeployed) and the PulseAudio suspend-on-idle work
remain correct fixes.

### Shipping gate

`down_threshold=60` is applied live on the device (2026-08-24 10:20) and is one
`echo` from reverting; a reboot restores the shipped 40. Before it goes into
`nexusq-cpufreq-tune` permanently it needs **Petr's listening test**: the knob
only governs the *descent*, so the exposure is the ramp production already ships
with USB Audio off — but no measurement can substitute for hearing whether the
clock descends mid-track.

## Follow-up — is ~20 % of a core for silence *correct*? No. (2026-08-24, měřeno)

Petr asked whether audio processing genuinely costs that much, or whether the
number is a measurement artefact. It is neither an artefact nor proportionate.

**The attribution was thin and is now solid.** The 8.72 % "user.slice ≈
PulseAudio" in *Attribution* above came from `ps` TIME, not from a cgroup —
`analyze-opp-snaps.py` prints `system.slice` children but only the *aggregate*
for `user.slice`, so PA was never actually isolated. It is now, per-thread,
against the live daemon (pid 620, up since boot — no restart loop; the extra
`pulseaudio` pids seen mid-investigation were client autospawns caused by
running `pactl` as root, "Denied access … invalid authentication data"):

| thread | % of one core @ 350 MHz | what it is |
|---|---|---|
| `alsa-sink-40124` | **17.80 %** | writes to the amp |
| `alsa-source-Loo` | 4.47 % | reads snd-aloop |
| `pulseaudio` (main) | 3.67 % | almost entirely nexusqd's IPC |
| `alsaloop` (separate proc) | **0.63 %** | the actual USB→aloop bridge |

**The damning comparison is inside our own stack.** `alsaloop` moves the *same*
48 kHz stereo stream one hop for **23 cycles/sample**. PulseAudio's sink thread
costs **664 cycles/sample** — measured directly: 317 000 cycles per wakeup,
**200 wakeups/s** where the 25 ms period (1200 frames, `default-fragments=4` ×
`25 ms`) needs 40. **~30× the cost of a plain ALSA bridge for the same job.**
So "audio processing is just expensive" is false; the ALSA path proves the work
itself is nearly free.

### Where the cost actually comes from — the chain changed

The path is no longer r65's direct bridge. It is now:

```
USB gadget → alsaloop → snd-aloop → PulseAudio (module-loopback) → TAS5713
```

The PulseAudio hop was added to regain mixing and the LED visualiser (the
snd-aloop plan in PLAN.md). r65's `alsaloop → amp` cost 0.63 % of a core; the
PA hop costs ~25 %. **That is the price of the feature, and it is being paid
24/7 in total silence** — because `module-loopback` is never corked, so the
loaded `module-suspend-on-idle` can never suspend the sink and the amp never
powers down. Nothing is broken; nothing ever stops.

### LED tap — clean A/B (nexusqd stopped, `arecord` killed by pid)

| | tap on | tap off | cost |
|---|---|---|---|
| `alsa-sink` | 17.80 | 16.44 | 1.36 |
| `alsa-source-Loo` | 4.28 | 3.80 | 0.48 |
| `pulseaudio` main | 3.44 | **0.04** | **3.40** |
| total | 25.52 | 20.28 | **5.24 %** |

The tap costs **5.2 % of a core, and two thirds of that is socket chatter with
PA, not audio data**. `nexusqd` **r14** (built, undeployed) already gates the
render tap on silence.

### `tsched=0` is NOT the bug — do not "fix" it

200 wakeups/s where 40 would do looks exactly like interrupt-mode overhead, and
`module-udev-detect tsched=0` is forced by
`device-google-steelhead.trigger`. **It is deliberate**: timer-based scheduling
"was the biggest cause of the periodic playback crackle on this OMAP4". Flipping
it back is a listening-test change, not a free optimisation. Recorded here so
the next person does not re-derive it as a leftover — it is not.

### What to do, in order

1. **Stop computing silence at all.** Detect that the UAC2 stream is digital
   silence and cork or tear down the loopback, so `module-suspend-on-idle`
   suspends the sink *and* the amp powers down. Worth ~20 % of a core plus the
   amp's own draw — and it is the only fix that addresses the user's actual
   objection, which is that the work happens at all.
2. **Deploy nexusqd r14** — −5.2 %, already built.
3. **Leave `tsched=0`, `resample-method=auto`, the 48 kHz pinning alone** unless
   a listening test backs the change. `avoid-resampling` is moot: both ends are
   already 48 kHz; module-loopback resamples to track *drift*, not rate.

### Latency creep is back (slower, not dead)

`journalctl -t pulseaudio` over the 2026-08-23 window:

```
18:05  module-loopback.c: Source minimum latency increased to 16.00 ms
18:13  module-loopback.c: Source minimum latency increased to 26.00 ms
22:12  module-loopback.c: Source minimum latency increased to 36.00 ms
```

Same shape as the 2026-08-08 runaway that r65 was built to kill — 16 → 36 ms
over four hours instead of minutes to *minutes* of delay, so the alsaloop
bridge is holding the bulk of it, but the PA hop reintroduced a slow version of
the original fault. Also logged once: `Cannot set requested sink latency of
40.00 ms, adjusting to 100.00 ms`. **Open — watch it over a multi-day window
before deciding whether it plateaus.**

## Talking to PulseAudio from root — the recipe, and the way I broke it

`pactl` as root against the user's PA fails in three different ways, and one of
the wrong attempts **took USB Audio down for several minutes** on 2026-08-24.
Recorded so it is not rediscovered the hard way.

**The only correct recipe** (it is what `nexusqd`'s `arecord` child already uses —
read `/proc/<pid>/environ` of a working client if in doubt):

```sh
export PULSE_SERVER=unix:/run/user/10000/pulse/native
export PULSE_COOKIE=/home/user/.config/pulse/cookie   # uid 10000 is `user`
pactl info
```

Setting `PULSE_SERVER` explicitly is the important half: it stops libpulse from
trying to create/validate `$XDG_RUNTIME_DIR/pulse`, which is where every failure
below comes from.

- ⚠️ **There are two home directories** — `/home/user` (uid 10000, the real one)
  and `/home/nexusq`. Taking the first cookie `ls` returns gives
  `Connection failure: Access denied`.
- `XDG_RUNTIME_DIR=… pactl` as root → *"not owned by us (uid 0), but by uid
  10000"*.
- `su -s /bin/sh nexusq` → *"user does not exist"*; the account is **`user`**.
- `setpriv --reuid=10000` and `systemd-run --machine=user@.host --user` both
  still fail if the runtime dir ownership is wrong (below).

**What I broke:** after several root-side `pactl` / `pulseaudio --dump-conf`
invocations, `/run/user/10000/pulse` was left **`root:root` 700**. PulseAudio
runs as uid 10000, so from that moment **no new client could connect** — and
`nexusq-uac2-in`, which runs as `user` and calls `pactl` to load its two modules,
sat in its "wait for PA" loop forever. The service reported `active` while
`alsaloop` was not running and neither module was loaded: **USB Audio was down and
looked healthy.** Fix:

```sh
chown 10000:10000 /run/user/10000/pulse
systemctl --user --machine=user@.host restart nexusq-uac2-in.service
```

Verified restored: `alsaloop` running, `module-alsa-source` + `module-loopback`
both loaded, sink-input unmuted at 100 %, not corked.

**Two rules out of this:**
1. **Never run `pactl` or the `pulseaudio` binary as root without `PULSE_SERVER`.**
2. **`systemctl is-active` is not a health check for `nexusq-uac2-in`** — the
   script is long-running and stays `active` while stuck waiting for PA. Check
   `alsaloop` + both modules + the sink-input instead.

### `module-loopback` has no `resample_method`

Attempting `pactl load-module module-loopback … resample_method=speex-fixed-1`
fails with *"Module initialization failed"* and leaves the loopback **unloaded** —
that is how USB Audio went down. The resampler is chosen **daemon-globally**
(`resample-method` in `daemon.conf`), so any resampler A/B costs a full PA
restart, not a module reload.

### …and the `speex-fixed-1` A/B would have been a regression anyway

`libspeexdsp` on this device is a **float build** — the hot loop runs
`vmla.f32`/`vmul.f32` on scalar `s`-registers; a FIXED_POINT build would use
integer `smull`/`smlal`. PA's `speex-fixed-N` calls
`speex_resampler_process_int`, which in a float build converts int16→float
**internally and scalar**, instead of letting `libpulsecommon`'s NEON `pa_sconv`
do it. It moves work out of vectorised code into scalar code. Dropped without
testing on the device — proving a negative was not worth three PA restarts.

**Which leaves exactly one fix for the resampler: rebuild `speexdsp` with NEON.**

## Incidental findings

- **`10.42.0.2` is NOT the Nexus Q right now.** It pings and accepts ssh, but
  answers as `nokia-rm875` with `10.42.0.2/24` on a `usb0` interface — another
  USB-gadget device is squatting the eth-direct address. Anything scp'd there
  goes to the wrong box. The Q's `eth-direct` profile and that device now
  collide on the same /24; untangle before trusting eth-direct again.
- The device rebooted at 17:41 on 08-23 (HA entities went `unavailable` 17:40 →
  `off` 17:42, uptime reset). Cause not established; noted for the record.
- The Q's clock was correct throughout (device time == HA time), so the RTC/NTP
  problem from the DFS-channel outage is not currently in play.
