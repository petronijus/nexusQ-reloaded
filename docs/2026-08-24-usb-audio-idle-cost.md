# USB Audio, switched on and idle, costs the whole idle-power programme (2026-08-24)

**Verdict: with "USB Audio" enabled and NOTHING playing, the Q runs at 1200 MHz /
1380 mV 84.65 % of the time and sits at a mean die temperature of 82.9 °C
(peak 95.0 °C). The idle-OPP goal — 90.8 % @ 350 MHz — collapses to 0.58 %.**

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
pushes **silence 24/7** (the aloop playback pointer advances continuously with
nothing playing), so the 1 kHz gadget IRQ is not something the device can refuse
while it is enumerated as a DAC. What IS ours is everything that reacts to that
silence. Fixes, in the order they should be attempted:

1. **Stop burning CPU on silence — our two consumers, ~10.9 % of a core between
   them.** This is first not only for its own sake: the governor parks high
   because it *measures load*, so removing the load may let the OPP fall on its
   own and fix the 1380 mV term for free.
   - **nexusqd: gate the render tap on SIGNAL, not on a sink-input existing.**
     r13's adaptive cadence caps the deadline at 0.25 s "while the tap is open",
     and the USB loopback holds a sink-input open forever ⇒ the visualizer
     renders 20 fps for a blanked ring. Worth ~2.1 % of a core.
   - **PulseAudio: don't resample and don't hold the sink RUNNING on silence.**
     The `module-loopback` sink-input sits at 48003 Hz (permanent rate-matching)
     and `NexusQSpeaker` `pcm0p` has been `RUNNING` since boot, so
     `module-suspend-on-idle` can never sleep the amp. Worth ~8.2 % of a core
     plus the amp's own draw. ⚠️ delicate: must not clip the start of real
     audio — this is the path that took r65→r70 to stabilise (delay runaway).
2. **Re-measure the OPP after (1).** If it descends, done. If it stays parked,
   the 1 kHz wakeups alone are holding it and the next lever is the governor.
3. **Governor, if still needed.** `sampling_rate=100 ms` + `up_threshold=95`
   measured 98.7 % @ 350 MHz on plain idle
   (`docs/2026-08-16-idle-700mhz-deep-analysis.md`, known-but-unshipped). This
   workload — very many very short wakeups — is exactly what it was designed
   for. Needs Petr's listening test first (it stretches a genuine ramp
   ~60 ms → ~300 ms), and with USB audio in the path that test matters more.
4. **Host side, optional.** If the Xiaomi box can be made to close the stream
   when idle (`~/Documents/Dev/xiaomi-tvbox-twilight`), the IRQ storm stops at
   the source — but the device must behave well regardless, so this is a bonus,
   never the fix.

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

## Armed overnight (2026-08-24 01:16 → ~03:21)

Governor arm series via the harness (`OUT=/var/log/nq-night-arms`, 120 s settle +
1200 s each, `ALLOW_UNITS=nexusq-uac2-in.service`): `base` → `sr100up95` →
`down60` → `powersave` (locked 350 MHz = the floor bound) → `base2` (restoration
+ repeatability control). It measures **how much of the 5× is recoverable by
governor policy alone**, given the IRQ storm cannot be refused while the box
streams. Removing the *software* load is deliberately NOT in this series — it
needs unloading the PA loopback, and a mid-arm crash would leave the audio path
broken unattended; do that one attended.

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
