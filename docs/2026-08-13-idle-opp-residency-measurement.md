# 2026-08-13 — First clean idle OPP-residency measurement (STANDING GOAL checkpoint)

The measurement the STANDING GOAL has been waiting for since r68 shipped: a full
night of **true idle** (every service off, nothing playing, no ssh/adb session),
read from the **MQTT `opp*_pct` rolling 1 h window** via Home Assistant history —
i.e. kernel `time_in_state` deltas, never healthd's biased `freq`
(`docs/2026-08-11-overnight-telemetry-analysis.md` §4).

**Result: 60.5 % @ 350 MHz — beats the 56.7 % baseline by +3.8 pp, still
39.5 pp from the ~100 % goal.**

## Measurement conditions (all verified from telemetry, not assumed)

- Device **r70 / v1.12.0**, uptime 2.4 days at read time — no reboot mid-window.
- Services **all off** well before the window: Spotify/AirPlay/Roon off from
  13:32 CEST 08-12, USB audio off from 16:14 CEST 08-12 (HA binary_sensor
  history).
- **No observer contamination:** die temperature fell smoothly 61 → 59 °C over
  the night (min 56.8 °C) — nowhere near the 74–79 °C an open ssh session
  causes. Nothing touched the device; data pulled passively from the broker/HA.
- Pipeline: `nexusq-mqtt` r1 rolling 1 h window → HA MQTT discovery sensors
  (`sensor.nexus_q_time_at_*_mhz`) → HA history API.

## Result — 14 h plateau, hourly means (CEST)

The rolling window is remarkably flat from 19:00 to 09:45 — every hourly mean of
the 350 MHz share sits in **60.0–61.1 %** (single-window max 61.3 %):

| OPP | overnight share | mV |
|---|---|---|
| 350 MHz | **60.5 %** | 1025 |
| 700 MHz | 24.8 % | ~1200 |
| 920 MHz | 9.5 % | ~1313 |
| 1200 MHz | 5.1 % | 1380 |

Die temperature hourly means: 61.5 °C (19h) → 59.0 °C (06h), min 56.8 °C —
the coolest sustained idle recorded so far.

## Interpretation

- **vs baseline 56.7 %** (v1.8.2, 542 s study, 2026-07-13): **+3.8 pp**, and
  this number is far more trustworthy — 14 h of kernel-counter deltas vs a 9 min
  sample. The r68 healthd de-churn (no more per-sample `systemctl` PAM storms)
  is the likely contributor.
- **The gap to the goal is structural, not noise.** At pure idle the CPU still
  spends **39.5 %** of the time above 350 MHz, including a persistent **5.1 % at
  1200 MHz/1380 mV** (~3 min per hour at the hottest OPP). Something periodic
  wakes the governor hard even with every service off.
- The flatness (±0.5 pp over 14 h) means the residual load is a *constant
  background*, not occasional events — which makes it findable with `perf`/
  process accounting.

## ✅ Attribution — done same day, from the device's own logs

Two sources, and they agree: (a) the **`nq-idle-attrib.sh` sampler** the
2026-08-11 session left running as a transient `nq-idle-study.service`
(per-minute per-PID cputicks + ctxt-switch wakeups, `/var/log/nq-idle-study/
attrib.log`, 36 MB, pulled to the host and diffed over the same overnight
window), and (b) a live 60 s **per-cgroup `cpu.stat` delta** (catches the CPU
burned by short-lived forks, which per-PID diffing structurally cannot).

Overnight window (14.0 h, 811 snapshots): time_in_state says 60.4 % @ 350 —
matches HA to 0.1 pp. **Total busy = 18.2 % of one core equivalent**, governor
transitions 3.6/s, and — the headline — **fork rate 13.96/s** (702 759 forks
over the night). **63 % of all busy CPU belongs to short-lived forked children**
invisible to per-PID accounting; the cgroup view assigns it:

| Consumer | % of one core | Wakeups/s | Nature |
|---|---|---|---|
| **nq-healthd** | **~6.3 %** | 11 | ~0.6 % the daemon itself, **~5.7 % its forked children** (dmesg/md5sum/awk per 5 s tick) |
| **nexusqd** | **~4.4 %** | **22** | in-process; 1 Hz AVR keepalive + event loop; `irq/116` i2c thread (0.2 %, 15 wake/s) alongside |
| **nq-idle-study** | **~3.8 %** | — | the leftover sampler itself (2×`awk` per PID per minute). **Stopped 2026-08-13** after the log was pulled |
| systemd (pid 1) | ~1.4 % | 3.5 | post-r68 sane (was 4 %); 5-min PAM refresh + housekeeping |
| nexusq-btagent (python3) | ~0.8 % | 5 | |
| brcmf WiFi kworker | ~0.5 % | **23** | broker keepalive/mDNS/ARP chatter |
| pulseaudio + `pactl` forks | ~0.4 % | 4 | PA running with nothing playing; something forks `pactl` repeatedly (volume reads — 47 s of `pactl` overnight) |
| mqtt + wifi-watchdog + dbus | ~0.8 % | | |

With only WFI available (no C2/C3 — known-blocked), every one of these busy
milliseconds maps directly to OPP residency; ~15–17 % constant background on a
`conservative` governor is exactly a 60/25/10/5 split.

## Next fixes, in impact order

1. ✅ **nq-healthd fork diet — SHIPPED same day as device r71** (see the section
   below). 6.3 % for a health sampler was the single biggest lever.
2. ✅ **nq-idle-study** — stopped (script + logs remain on the device); worth
   ~3.8 pp of headroom immediately. Tomorrow's overnight window is a free A/B.
3. ✅ **nexusqd wakeup audit — SHIPPED same day as `nexusqd` r13** (see the
   second section below). The event loop did tick ~20×/s forever; 4.4 % → 0.165 %,
   22 → 2.9 wakeups/s.
4. ⚠️ **`pactl` forker — mostly resolved by r13, residue quantified.** The bulk
   of it was **nexusqd's own gate poll** (a `pactl list short sink-inputs` every
   1.5 s while the tap was off, ~0.67 forks/s) — now event-driven. What remains,
   measured on-device 2026-08-13: **`nexusq-mqtt`'s 30 s volume/mute poll**, 2
   forks per 30 s ≈ **0.09 % of a core** (≈ the 47 s of `pactl` CPU seen
   overnight). Proposed follow-up (**NOT done**): have `nexusq-mqtt` read volume
   from `nexusq-control`, which already runs a persistent `pactl subscribe`
   bridge, instead of forking `pactl`.
5. **Governor tunables** — after 1–4, check whether 5.1 % @ 1200 MHz collapses
   on its own before touching `conservative` knobs.

> *(Superseded later the same day — see §Post-r71/r13 attribution below. The
> `pactl` residue in item 4 is now only the **4th** target: healthd is #1 again
> at 2.43 %, and `brcmf` WiFi wakeups at ~40/s are #3.)*

## ✅ r71 shipped + verified (same day) — the fork diet

`device-google-steelhead` r70→**r71** (`nq-healthd` only; pkgrel 70→71) — built,
OTA-published to gh-pages, installed on the device via `apk upgrade --available`,
live-verified 2026-08-13. JSONL schema **unchanged** (keys verified identical
against an r70 sample).

What changed (all of it fork elimination or amortization, semantics intact):

- Every sysfs/procfs read is an ash-builtin `read` (`rdv` helper) — no `$(cat)`.
- `/proc/pid/stat` parsed fork-free (`read_stat`; was 2× awk per tick).
- LED frame fingerprint = **one** `od|awk` pass yielding byte sum + a rolling
  hash — `md5sum` dropped (`led_fp` only ever feeds an equality test).
- dmesg ring scan every `NQ_DMESG_EVERY` ticks (default 6 = 30 s); rotation
  `stat()` every 12 ticks; pstore counted by glob (no `ls|wc`);
  loadavg/meminfo/uptime via builtins.
- `systemctl show` output parsed by fork-free `sv()` (no sed/subshell).
- librespot liveness = cgroup membership scan (`cg_scan`); restart detected as
  "cached pid no longer a member while the cgroup is non-empty" (no more
  `grep` on cmdline).
- Inter-sample sleep = fork-free `read -t` on a private fifo fd 9 (probed at
  startup, `sleep` fallback; start event carries `tickfd=0/1`).
- Review catch: `set --` in the AVR-scan/pstore-glob clobbered `sample()`'s
  `$1`, so `--once` is captured up front (`_oncearg`).

**On-device A/B** (60 s each, systemd-run transient units, throwaway
`NQ_LOGDIR`): r70 = **4212 ms** CPU + baseline forks; r71 = **1682 ms** and
**−517 system forks/min** (−43/tick) → **−60 % CPU**. Production unit after the
OTA: **1403 ms / 60 s = 2.3 %** of a core (vs the attributed 6.3–7.0 % on r70);
system-wide fork rate **191 / 60 s = 3.2/s** (was ~14/s including the
now-stopped idle-study sampler).

Together with stopping `nq-idle-study`, **~8 pp of one core** of constant idle
background is gone. Tonight's overnight MQTT window is the free A/B — expect
opp350 well above 60.5 %; re-measure tomorrow morning exactly as in
§Provenance (HA history, **no ssh session overnight**).

## ✅ r13 shipped + verified (same day) — nexusqd's event-driven PA gate + adaptive idle cadence

`nexusqd` r12→**r13** (`pmos/nexusqd/APKBUILD` pkgrel 12→13; sources
`userspace/nexusqd/src/{nexusqd.c,audio.c}` + `include/audio.h`) — built,
OTA-published to gh-pages, installed on the device, live-verified 2026-08-13.
With r71 in, nexusqd was the **top** idle consumer: **~4.4 % of a core, 22
wakeups/s** on a fully idle box (table above).

### The two causes

1. **The PA sink-input gate polled.** While the tap was off, `pactl list short
   sink-inputs` ran every `PA_POLL_S`=1.5 s — ~0.67 forks/s around the clock.
   Worse than the fork cost: every short-lived PA client also woke **every other
   PA subscriber on the box** (notably `nexusq-control`'s own `pactl subscribe`
   bridge) with client-connect events.
2. **The render loop ticked at 20 fps forever** — even with the screensaver
   locked or blanked and the composed frame bit-identical every time (the AVR
   `memcmp` write-gate already suppressed the writes; the *renders* remained).

### What r13 does

- **Event-driven gate.** New `pa_subscribe_open()` (audio.c/audio.h) spawns a
  persistent `pactl subscribe` child; its non-blocking stdout joins the main
  `poll()` set. Lines matching `on sink-input` **and** `'new'`/`'remove'` set
  `pa_check` → re-count. `'change'` events are deliberately ignored (constant
  during playback, and they cannot alter the *count*). A subscription is not a
  stream, so it holds no sink out of suspend.
- **Timed polling demoted to a safety net:** `PA_SAFETY_ON_S`=30 s while
  tapping, `PA_SAFETY_OFF_S`=60 s while idle — but only once the subscriber is
  **proven** (`PA_SUB_PROVEN_S`=2.0 s alive); otherwise it stays at
  `PA_POLL_S`=1.5 s. Dead subscriber (EOF/HUP) → close, respawn every
  `PA_SUB_RESPAWN_S`=10 s.
- **Deviation, accepted and documented:** r12's "while music flows we never
  poll" still holds for the TIMED path, but an EVENT may re-count mid-playback.
  That is bounded by real PA activity rather than by a clock, which is the point.
- **Adaptive idle cadence.** After `IDLE_AFTER_TICKS`=40 bit-identical renders
  **and** an *intent-idle* test, the render deadline stretches to
  `IDLE_FRAME_S`=1.0 s — matching the 1 Hz AVR keepalive, so a locked/blanked
  ring costs one render+write per second. Caps: `IDLE_TAP_FRAME_S`=0.25 s while
  the tap is open (a PAUSED stream still holds its sink-input, so un-pause must
  show without a visible hiccup) and `MUTE_BLINK_S`=0.5 s while the
  update-available blink is live. Keys, any mutating control command
  (`CTL_STATUS` excluded — healthd probes it every 5 s and must not hold cadence
  fast), and a tap off→on transition reset `static_ticks` and force an immediate
  render.

### Adversarial review — 1 CRITICAL + 5 more, all fixed before shipping

This is the valuable part of the change. (5-lens review workflow with refuters;
the verify stage largely died on a model usage limit, so every finding was
**re-verified by hand against the code** before the fix was accepted.)

| Sev | Finding | Fix |
|---|---|---|
| **CRITICAL** | `frame_int` was computed **before** `poll()` but consumed **after** event handling (`next_frame += frame_int`). From idle cadence, a single volume detent/`CTL_VOL` rendered the overlay's fade-in first frame at `eased=0` — with `RX_COLOR_R=0x00` that is **pure black** — then scheduled the next render 1.0 s later, by which time `RX_TIMEOUT_S` had expired. Net: **the ring went black for ~1 s instead of showing the volume flash.** | The whole cadence choice moved to the **END** of the render tick (it decides the NEXT deadline, so it must see post-render state); `tick_base` preserves the non-drifting accumulate + resync. |
| MAJOR | Keying the stretch on **bytes alone** engages mid-animation: near its cosine trough the breathing screensaver quantizes to an identical frame for >40 ticks at low global brightness — the breath would visibly **freeze, then step**. | Added the **INTENT** test: stretch only when there is no overlay, `child_alpha == 0`, no breathe/spin override, and the screensaver is locked (`elapsed_no_audio > SS_LOCK_S`) or blanked. Bytes AND intent must both agree. |
| MAJOR | `pa_poll` kept its 30/60 s safety deadline **after the subscriber died**, so the documented 1.5 s degraded polling never ran — a stream started right after a PA restart left the visualizer dark ~10 s. | Clamp `pa_poll` to `now + PA_POLL_S` in the EOF/HUP path. |
| MAJOR | `fork`+`exec` succeed even when PulseAudio is **down** (the child only EOFs afterwards), so a doomed child armed the long safety horizon. | `PA_SUB_PROVEN_S`=2.0 — the long horizon is earned only by surviving that long. |
| MINOR | The pipe read ends lacked `FD_CLOEXEC`, so the long-lived subscribe child inherited **arecord's** read end — defeating `audio_close()`'s documented SIGPIPE backstop (arecord could survive a raced SIGTERM, capture forever, and pin the sink out of suspend). | `FD_CLOEXEC` on both spawn helpers' read ends. |
| MINOR | pactl's event wrapper `Event '%s' on %s #%u` is **gettext-translated**; a locale leaking into the daemon's environment drops the word "on" and silently kills every match (gate degrades to its safety net, no error anywhere). | `setenv("LC_ALL","C",1)` in the forked children. |

Also: the volume **overlay is excluded from the stretch** — it was reaching 40
static ticks during its 1 s hold, which delayed expiry and the mute-LED hand-back.

### Verification (on device, r13 live)

Acceptance suite, 5 tests, driven **programmatically** off the AVR `frame`
bin_attr — the same bytes healthd fingerprints:

1. Volume overlay from deep idle is on the ring in **~8 ms** (the pre-fix bug
   would have left it black for ~1 s).
2. Screensaver still breathes — `led_sum` 8192 → 1248 over 6 s, i.e. cadence
   **not** stretched while animating.
3. A **silent** sink-input (`paplay /dev/zero`, nothing audible) brings the tap
   up in **~200 ms** via the subscribe path…
4. …and it closes again when the stream ends.
5. Exactly **1** persistent child (`pactl subscribe`), 7 open fds, `NRestarts`
   unchanged.

**Blanked-idle measurement** (waited 548 s for the ring to blank, then a 120 s
window with **no ssh session**):

| Metric | r12 | r13 | Δ |
|---|---|---|---|
| nexusqd CPU | ~4.4 % of a core | **198 ms/120 s = 0.165 %** | **−96 %** |
| nexusqd wakeups | 22/s | **2.9/s** | **−87 %** |
| system-wide forks | — | 2.6/s | |
| die temp | — | 59.2 °C | |

⚠️ **METHOD NOTE — do not compare across screensaver states.** The first attempt
measured 1.6 % and 54 wakeups/s and was **DISCARDED as invalid**: a fresh
`systemctl restart nexusqd` restarts the screensaver, so the ring was
legitimately breathing at 20 fps (`led_sum` ≠ 0). The r12 comparison numbers come
from the **locked + blanked** state, so any A/B must wait out
`SS_LOCK_S`/`SS_BLANK_S` first.

### Cumulative idle picture for 2026-08-13

| Change | Before | After |
|---|---|---|
| nq-healthd (r71) | 6.3 % | 2.3 % |
| `nq-idle-study` sampler (stopped) | 3.8 % | 0 |
| nexusqd (r13) | 4.4 % | 0.165 % |

Roughly **12 pp of one core** of constant idle background removed since this
morning's 60.5 % @ 350 MHz baseline. Tonight's overnight MQTT window is the free
A/B — re-measure tomorrow morning from HA history exactly as in §Provenance,
with **NO ssh session overnight**.

## Post-r71/r13 attribution — the picture after the diet (240 s window, ring blanked)

Re-measured the same day, **after** r71 + r13 + the idle-study stop, over a 240 s
window with the ring blanked:

- **Total busy 8.73 % of one core** (was **18.2 %** overnight), forks **2.59/s**
  (was 13.96/s).

| Consumer (cgroup) | % of one core |
|---|---|
| **nq-healthd** | **2.43 % — new #1** |
| init.scope (pid 1) | 1.69 % ⚠️ |
| nexusq-btagent | 0.90 % |
| sshd | 0.86 % ⚠️ |
| nexusq-mqtt | 0.47 % |
| wifi-watchdog | 0.36 % |
| avahi | 0.30 % |
| dbus-broker | 0.18 % |
| **nexusqd** | **0.14 % — confirms r13** |

Wakeups/s: **brcmf kworker 33.9** · kworker/0:1-events 13.1 · rcu_sched 11.5 ·
irq/116-i2c 10.0 · dbus-broker 7.4 · brcmf_wdog 6.5 · avahi 5.8 · systemd 4.7 ·
btagent 3.3 · nexusqd 3.0 · healthd 2.6.

> ⚠️ **MEASUREMENT CAVEAT — must travel with these numbers.** An ssh poll loop
> (**8 logins inside the window**) inflated `sshd` **and** `init.scope`: every
> login makes pid 1 build and tear down a full PAM session — the exact
> observer effect r68 was written to remove from healthd. So the
> **pid1 / sshd / user.slice figures are NOT trustworthy**; the other daemons'
> figures are. **Real idle busy ≈ 7.7 %.**
>
> Two earlier attempts were **discarded outright**: one wrote its snapshots to
> the void (empty diffs), and its ~400 `awk` forks heated the die **60 → 67 °C**
> — i.e. the sampler again became the load. **Rules for next time:** wait for
> `led_sum == 0` (ring blanked), run the sampler **detached** and fetch its
> output **ONCE** (no polling), and budget **one `awk` fork per snapshot**.

### Next targets, in order (supersedes the list in §Next fixes)

1. **Re-measure the overnight opp350 window from HA history** — no ssh overnight.
2. **`nq-healthd` is the #1 idle consumer again, at 2.43 %.** What remains is its
   **~6 forks/tick** (`date`, `timeout`+`nexusled`, `od`+`awk`, amortized
   `dmesg`). The correct fix is a **C rewrite in the nexusqd mould**: in-process
   socket `connect()` for the liveness probe instead of forking `nexusled`,
   `/dev/kmsg` instead of `dmesg`, in-process hashing instead of `od|awk`.
   **Deliberately NOT started 2026-08-13** — three rewrites of the observability
   layer in one day is unacceptable churn.
3. **WiFi wakeups.** `brcmf` at ~40/s **dominates every other wakeup source
   combined**. Investigate mDNS/avahi chatter + the MQTT keepalive.
4. **`nexusq-mqtt`'s 30 s `pactl` volume poll** (2 forks/30 s ≈ 0.09 %) → take
   volume from `nexusq-control`'s persistent `pactl subscribe` bridge.
5. **Governor tunables LAST.**
6. Commit r71 + r13 + r72 + mqtt r2 + the app change + `docker-build.sh`.

### Device-side leftovers from this study

`/var/log/nq-idle-study/attrib.log` (**36 MB**) and
`/usr/local/bin/nq-idle-attrib.sh` are **still on the device**; the service was
**stopped 2026-08-13** and a local copy of the log was pulled for the analysis
above. Clean them up when the next idle work starts (or keep the script — it is
the only per-PID sampler we have — but never leave it *running*).

## Batch 3, same day — the observability layer told two lies, both fixed

Recorded in full in
**`docs/2026-08-13-led-stall-verdict-and-progress-window.md`**; the short version,
because both are consequences of the work above:

- **`device-google-steelhead` r71→r72 — `nq_progress` measured over a window.**
  A **second-order defect created by r13's own success**: at 0.165 % of a core
  nexusqd accrues ~0.8 USER_HZ ticks per 5 s sample, so `nq_progress=0` became the
  ordinary reading for a healthy daemon — and, co-signalled with the *guaranteed*
  `LED_STALL >= 6` of a locked/blanked ring, fired **CRIT `led_frozen` on a
  healthy idle device**. It really happened, twice, between r13 and r72 landing:
  `{"t_mono":214110,"sev":"crit","kind":"led_frozen","msg":"LED frame unchanged
  for 6 samples with distressed nexusqd (resp=1 progress=0) …"}` (and at 214497).
  Fix: `NQ_LAST_TICK_MOVE` + `PROGRESS_STALE_S` (`NQ_PROGRESS_STALE_S`, default
  60 s) — 0 only when CPU time has stood still for 60 s, ~10× the idle tick
  interval. Post-r72 the same state logs **info `led_static` … (resp=1)**.
- **`nexusq-mqtt` r1→r2 — publish the LED verdict, not the counter.** New boolean
  `led_stalled` (`led_stall >= 6` **AND** nexusqd distressed) + HA
  `binary_sensor` "LED ring"; closes §6/§10-item-2 of
  `docs/2026-08-11-overnight-telemetry-analysis.md`. Companion-app side is
  **code-only** (no APK, no release).
- **`docker-build.sh` — the OTA checksum/build passes are now separate**, so the
  package order in `OTA_PACKAGES` stopped being load-bearing (r72 `depends=`
  `nexusq-mqtt`, which is exactly the shape that used to fail with
  `<dep> is missing in checksums`, exit 3).

## Provenance

- HA history: `sensor.nexus_q_time_at_{350,700,920,1200}_mhz` +
  `sensor.nexus_q_die_temperature`, window 2026-08-12 18:00 → 2026-08-13 09:45
  CEST (~950 points per OPP sensor).
- Broker spot-check (retained `nexusq/health/state`): consistent with HA
  (opp350 60.2–60.3 % at read time).
- Side-note: HA's `led_daemon` / `health_sampler` binary sensors showing `off`
  is **correct** — they are problem-class (inverted) sensors; `off` = healthy.
- Closes Todoist task 6hGMCRq23hPV3RW3 ("Změřit idle OPP residency").
