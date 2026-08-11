# 2026-08-11 — Overnight telemetry run: analysis of the first 12 h

The MQTT health telemetry shipped on 2026-08-10 (`b49b536` + `39a6a46`) was left
running overnight. This is the analysis of that run, taken **from the device's own
`nq-healthd` logs** (5 s sampling) rather than from MQTT/HA — finer resolution, and
it needs no broker credentials.

**Window:** boot `2026-08-10 23:32:28` CEST → `2026-08-11 11:30:52` CEST
(**11.97 h uptime**, 7242 samples, median interval 6 s, largest gap 14 s, **zero
gaps > 30 s** — the sampler never missed a beat).

**Headline: the device is rock solid.** Zero service restarts, zero new kernel
errors, no crash dump, no thermal throttling, no memory leak, WiFi flawless.
Three real defects were found, none of them in the device's runtime behaviour —
two are in how the telemetry is *measured/interpreted*, one is a CPU-burning
polling loop that only arms itself after the first NTP sync.

> **🎯 The goal all of this serves** (see PLAN.md "STANDING GOAL"): with every
> streaming service off and nothing playing, the Q should sit at **350 MHz for
> as close to 100 % of the time as possible**, with an absolute minimum above
> it. Baseline to beat: **56.7 % @ 350 MHz** (v1.8.2, 2026-07-13). §4 is why
> that number could not be read off this capture at all, and §5 is a regression
> that was actively working against it.

**Status:** findings 1, 3 and 4 are **fixed in device r68** (source only, not yet
built/OTA-published) — see §10. Finding 2 (the app's `led_stall` rule) is open.

---

## 1. How to reproduce this pull

The device is reachable on WiFi; the baked fallback account works when the host
has no authorized key (this analysis ran from `server-linux`, which does not):

```sh
# password: see `.claude/agents/nexusq-connect.md` "Fallback login"
sshpass -e ssh user@192.168.20.246 'gzip -c /var/log/nq-health/health.jsonl' > health.jsonl.gz
# also: health.jsonl.1 (rotated), events.jsonl, wifi-watchdog.jsonl
```

`health.jsonl` rotates at 4 MiB (`MAXBYTES`); on this run the rotation fired at
08:22, so the night lives in **`health.jsonl.1` + `health.jsonl`** together.
Split the concatenation into boot sessions by watching for `t_mono` decreasing.

⚠️ **Reconstruct wall time from `t_mono`, not from `wall`.** The RTC is unreliable
and the first NTP sync only landed at **08:20:40** — every record before that
carries a `wall` of `2000-01-01T…`. Anchor on the first record whose `wall` is
≥ 2020 and back-compute with `t_mono` (monotonic, immune to the NTP step). Cross-
checked against `uptime`: agrees to the second.

## 2. Stability — clean sweep

| Signal | Result over 11.97 h |
|---|---|
| `nexusqd` restarts | **0** — same PID (498) start to finish |
| `librespot` restarts | **0** (masked all night — intentional, Petr's app toggle) |
| `nq_alive` / `nq_resp` | `1` on **every** one of 7242 samples |
| `nq_state` | 7131 × `S`, 87 × `R`, 24 × `D` — normal |
| `dmesg_err` | constant **5** (pre-existing), **0 new** all night |
| `pstore` | **0** — no crash dump |
| `cool` (thermal throttle) | **0** samples |
| healthd events | 3, all `info`: 1 × `start`, 2 × `led_static` |

## 3. Thermals — flat and cool

min **61.3 °C** · median **65.4 °C** · max **91.8 °C**

The 91.8 °C max is **2 samples at 23:32**, i.e. the boot burst (`load1` peaked at
2.56 there). Steady state is a very flat 63–67 °C band with no throttle events.

Hourly means sit at 65.2–66.7 °C through the night and drop to **63.7 °C** from
09:00 onward — a real but small (~2 °C) reduction, see §4.

## 4. ⚠️ OPP residency — the sampled numbers are not trustworthy

Per-OPP shares computed from the 5 s log disagree badly with the kernel's own
cumulative counter (`/sys/…/cpufreq/stats/time_in_state`, read at 11:42, whole
boot):

| OPP | from `health.jsonl` spot samples | kernel `time_in_state` |
|---|---|---|
| 350 MHz | 20.5 % | **39.1 %** |
| 700 MHz | 39.6 % | 24.0 % |
| 920 MHz | 33.2 % | 16.7 % |
| 1200 MHz | 6.6 % | **20.0 %** |

**Cause — observer effect.** `nq-healthd` is a POSIX shell script that reads
`scaling_cur_freq` (line 149) *from inside its own busy tick*, after having
already forked `dmesg | grep`, `md5sum`, `od`, `awk`. It therefore samples the
frequency the governor picked **in response to healthd itself**, and almost never
observes true idle. The bias is systematic: idle 350 MHz is halved, short 1200 MHz
bursts are under-counted 3×.

**Consequence.** The `freq` field in `health.jsonl` is fine as a liveness signal
but must **not** be used to make power/thermal claims. The authoritative source is
`time_in_state` deltas — which is exactly what **`nexusq-mqtt` r1 already
publishes** (rolling 1 h window, `39a6a46`). The r1 design decision is vindicated;
the raw healthd log is the weaker source, not the stronger one.

This also disposes of an apparent finding: the sampled frequency appears to "ramp"
from 723 MHz (23:40) to 953 MHz (07:00) and then collapse to ~470 MHz after 08:22.
Two candidate explanations were tested and **both failed**:

- *`rotate_if_big` re-reading a growing log* — real but negligible. It does use
  busybox `wc -c < "$LOG"`, which reads the whole file (measured **50 µs** at
  924 kB, **100 µs** at 4.2 MB) instead of `stat -c %s` (**0 µs**). At one call per
  5 s that is ~0.002 % CPU. Worth fixing as hygiene (§7.4), not as a cause.
- *the PAM session churn of §5* — the churn **starts** at 08:22, i.e. exactly when
  the sampled frequency **drops**. Wrong sign.

What is measurable and real is the ~2 °C higher die temperature overnight, so the
device genuinely did slightly more work before 08:22 — but the magnitude of the
"ramp" in the log is an artifact of the sampler and should not be quoted.

## 5. 🐞 PAM/logind session churn — `nq-healthd` spawns `systemctl -M user@` every 5 s

**The single most expensive thing running on the idle device.** `systemd` (pid 1)
is currently the **top CPU consumer at 4.0 %**, ahead of `nexusqd` (1.7 %), with
`dbus-broker` (0.85 %) and `systemd-logind` (0.45 %) alongside.

Caught in the act:

```
systemctl -M user@ --user show -p ActiveState -p MainPID -p NRestarts librespot.service
  ← parent: nq-healthd (subshell)  ← nq-healthd (pid 502)
→ systemd(1) spawns systemd-stdio-bridge --user
→ pam_unix(login:session): session opened for user user(uid=10000) … then closed
```

Rate: **~304 login sessions per 30 min** (one per 5.9 s = healthd's tick), ~600/h.
The session counter had reached **c5330** by 08:20.

**Chain:**

1. `librespot` is **masked** (Petr turned Spotify off via the app) → no MainPID.
2. healthd's cheap process-first path (`/proc/$LS_PID/cmdline`) therefore fails on
   every tick and falls through to `ls_show()`.
3. `ls_show()` is guarded by `[ -d /run/user/10000/systemd ] || return 1`. That
   guard is what kept the night quiet: **0 sessions per 5 min at 00:00, 03:00,
   07:00 and 08:00**.
4. The guard started passing in the **08:00–08:30** window — immediately after the
   first NTP sync at 08:20:40 — and has been firing ever since (verified still
   running at 11:42; `linger` is enabled for both `root` and `user`).

The exact reason the user manager materialised at 08:22 was not pinned down; a
calendar-timer catch-up triggered by the 26-year clock step is the obvious
suspect, but that is a hypothesis, not a measurement.

**Fix direction already exists in-tree:** `nexusq-control` moved off `systemctl`
to an instant `cgroup.procs` read for exactly this class of problem
(`098b50f`, "instant cgroup-based service state"). `nq-healthd` should adopt the
same pattern for `librespot`, or at minimum rate-limit `ls_show()` hard (it only
needs to catch restarts, and a restart always changes MainPID) and back off
sharply while the unit is masked.

## 6. 🐞 `led_stall ≥ 6` false-positives on every idle device

`LED_STALL` is defined in healthd as *consecutive samples where `nexusqd` is up but
the md5 of the driver's committed frame has not changed*. It fingerprints frame
**content**, not commit **events** — and the 1 Hz AVR keepalive re-commits the
*same* frame, so identical content ⇒ counter climbs.

The companion app then does (`health_screen.dart`, `healthProblems()`):

```dart
if (stall is num && stall >= 6) out.add('LED ring frame is stalled');
```

6 samples ≈ 36 s. But the screensaver deliberately freezes the frame after
`SS_LOCK_S = 300 s` and blanks it at `SS_BLANK_S = 600 s`. **Every idle Q therefore
reports "LED ring frame is stalled" permanently, ~10 minutes after the music
stops** — in the app's Health panel and in the HA binary sensor.

The night's data is a textbook trace of exactly that:

| Episode | Window | Duration | Max counter |
|---|---|---|---|
| 1 | 23:37:28 → 23:42:20 | 0.08 h | 50 |
| 2 | **23:42:32 → 11:30:52** | **11.81 h** | **7142** |

Boot 23:32:28 **+ 300 s** = 23:37:28 → episode 1 begins (lock: frame goes static).
Boot **+ 600 s** = 23:42:28 → blank fires, the frame changes once (counter resets),
and from 23:42:32 it never changes again. The frame was non-black for only
**99 of 7242 samples** (23:32:28–23:42:20).

**Fix:** the flag must be qualified by state — suppress it while the screensaver is
locked/blanked (or while `led_sum == 0`), or raise the threshold well past
`SS_BLANK_S`. As written it carries no information about the idle device it is
most often describing.

## 7. LED-ring AVR soak — still not answered, and this telemetry *cannot* answer it

The open follow-up from `docs/2026-07-01-led-ring-avr-starvation-keepalive.md`
("does the 1 Hz keepalive stop the ~20 h wedge?") is **not** closed by this run:

1. **Too short.** 11.97 h of the ~20 h it takes to manifest.
2. **Structurally invisible.** Every signal healthd records is host-side —
   `led_sum`/`led_fp` read the *driver's* frame buffer. The AVR wedge is the MCU
   refusing to *display* a frame the host is still happily committing. With the
   ring blanked to constant black (`led_sum == 0` by design), "dark because
   blanked" and "dark because starved" are indistinguishable in the log.
3. `avr_irq` was **constant at 17** all night — it counts AVR interrupts (touch /
   rotary input), so with nobody touching the device it carries no keepalive signal
   either.

**To actually close it:** leave the Q idle past ~20 h uptime (i.e. past **≈19:30
today**, so *don't reboot it*), then make the frame change — resume audio or push a
scene — and look at the ring. Lights up ⇒ keepalive holds. Stays dark until
`systemctl restart nexusqd` ⇒ the AVR watchdog window is shorter than 1 s in some
state, and `AVR_KEEPALIVE_S` needs raising.

## 8. Memory — no leak

865.6 MB free at start → **852.0 MB** at the end: −13.6 MB over 12 h. But that is
all startup settling; the linear-regression trend is **−0.38 MB/h** and the hourly
means are flat from 03:00 onward:

```
03h 852.0   05h 851.5   07h 851.3   09h 851.6   11h 851.7   (MB free)
```

A leak would keep sloping. This one asymptotes. Clean.

## 9. WiFi — flawless

133 watchdog records over 11.95 h: **131 × `ok`**, `loss = 0` on every check,
`fails = 0`. RSSI **−26 dBm median** (range −26…−31, a 5 dB spread over 12 h —
very stable). The single non-`ok` was `nogw` at **t+32 s**, i.e. during boot before
the gateway was reachable. No watchdog heal, no interface bounce, no lease change.

## 10. Actions

| # | Item | Severity | Status |
|---|---|---|---|
| 1 | `nq-healthd`: replace the `systemctl -M user@` librespot probe with a cgroup read (per `098b50f`), or hard-rate-limit it — §5 | **high** — 4 % CPU 24/7 on an idle device | ✅ **fixed, r68** |
| 2 | App: qualify the `led_stall ≥ 6` rule by screensaver/blank state — §6 | **medium** — permanent false alarm | ⛔ open |
| 3 | Never quote `health.jsonl`'s `freq` for power claims; make residency measurable instead — §4 | **medium** | ✅ **fixed, r68** (`opp_ms`, `opp_trans`) |
| 4 | `rotate_if_big`: `stat` instead of busybox `wc -c` — §4 | low — hygiene | ✅ **fixed, r68** |
| 5 | Keep the Q idle past ~19:30 today to finish the AVR soak — §7 | — | ⏳ running |

### What r68 changed (2026-08-11)

`pmos/device-google-steelhead/nq-healthd`, pkgrel 67 → **68**:

- **cgroup-first unit state.** `nexusqd` and `librespot` are resolved from
  `cgroup.procs` (fork-free `read`, no subshell). systemd is queried only on a
  real (re)start — where `MainPID` then wins over the cgroup's first PID — or
  once per `NQ_UNIT_REFRESH_S` (default 300 s), which keeps `failed` vs
  `inactive` vs masked and `NRestarts` honest. Cost of a *stopped* unit drops
  from one PAM session **per sample** to one per 5 minutes.
- **`opp_ms` + `opp_trans`.** Per-OPP milliseconds and governor transitions for
  the window that just closed, differenced from the kernel's `time_in_state` /
  `total_trans`. Emits `{}` / `-1` on the first sample and on a counter reset
  instead of a poisoned window. `freq` stays, documented as a liveness/vdd-
  bracketing spot read that must not be used for residency.
- **`rotate_if_big` uses `stat`.**
- Header now carries the standing idle goal so the next person reads it before
  touching anything power-related.

**Verified on-device** by A/B-ing r67 against r68 from `/tmp`, into a throwaway
`NQ_LOGDIR`, with a `systemctl` shim on `PATH` that counts invocations:

| 45 s run, 5 s interval (9 samples) | `systemctl` calls |
|---|---|
| **r67** | **10** — 9 × `-M user@ … librespot.service` (one per sample) + 1 × nexusqd |
| **r68** | **2** — one initial refresh per unit |

At the default `NQ_UNIT_REFRESH_S=300` that is one query per 5 min instead of one
per 5 s — **60× fewer**. The periodic path was verified in the other direction
too: with `NQ_UNIT_REFRESH_S=20` over 65 s it fires **exactly 4 times** (t≈0, 20,
40, 60), so a stopped unit's state cannot go stale indefinitely. `nexusqd` needs
only its one initial call because it is *running* — the cached-PID path covers
every later sample, and a restart changes MainPID, which drops into the cgroup
adopt → immediate refresh (the r40 rationale, preserved).

Data side: `ls_active=inactive` and `nq_active=active` correct throughout,
`opp_ms` `{}` on sample 1 then real data summing to the sample window
(e.g. `{"350000":1020,"700000":1930,"920000":1190,"1200000":1230}` = 5.37 s for a
~5.3 s window), `opp_trans` ≈ 4.2/s — matching the independent 2026-07-13
governor study.

⚠️ **Methodology note for whoever repeats this:** counting `pam_unix(login:session)`
lines in the journal is NOT a valid way to measure this from a `user` shell. The
shipped daemon runs as **root**, where `systemctl -M user@` goes through the
stdio-bridge and opens a PAM session; run the same probe as uid 10000 and it does
not, so a user-run instance shows zero sessions whether or not it is churning.
Count `systemctl` invocations (shim) instead — that is the cost being removed.

**Not done here:** no image build, no OTA publish — r68 is source + pkgrel only.

Raw logs and the analysis scripts used for this write-up are not committed; re-pull
per §1.
