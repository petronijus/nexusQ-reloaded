# 2026-08-13 — The LED "stalled" alarm: a false CRIT the idle diet created, and the false alarm it had been raising all along

Two bugs in the same signal, found and fixed the same day, both shipped by OTA:

1. **`nq_progress` went blind** — a *second-order defect created by `nexusqd`
   r13's own success. It fired **CRIT `led_frozen` on a healthy idle device**,
   twice, on the live Q. Fixed by `device-google-steelhead` **r72**.
2. **`led_stall >= 6` was never a fault condition** — the last open action item
   from `docs/2026-08-11-overnight-telemetry-analysis.md` (§6 / §10 item 2).
   Fixed by `nexusq-mqtt` **r2** publishing a **verdict** instead of a counter,
   plus a companion-app change that is **code-only so far**.

Both live on the device: `nexusqd` r13 · `device-google-steelhead` r72 ·
`nexusq-mqtt` r2.

---

## 1. `nq_progress` — a signal invalidated by an efficiency win (device r71→r72)

### What broke

`nq_progress` was defined as *"did nexusqd's `/proc/pid/stat` tick count change
since the last 5 s sample"*. That was a sound test **while nexusqd burned 4.4 %
of a core** — ≈22 USER_HZ ticks per 5 s sample, so a zero delta really did mean
the daemon had stopped executing.

`nexusqd` r13 (event-driven PA gate + adaptive idle cadence, same day —
`docs/2026-08-13-idle-opp-residency-measurement.md`) dropped idle nexusqd to
**0.165 % of a core ≈ 0.8 ticks per sample**. A zero delta became the **ordinary
reading for a perfectly healthy daemon**.

That alone would have been harmless noise. It wasn't, because of the co-signal:

```sh
# nq-healthd, led_frozen escalation
[ "$nq_resp" = 0 ] || [ "$nq_progress" = 0 ]
```

and because **`LED_STALL` reaching 6 is GUARANTEED on a locked/blanked ring** —
the screensaver freezes the frame at `SS_LOCK_S`=300 s and blanks it at
`SS_BLANK_S`=600 s, while the 1 Hz AVR keepalive re-commits *identical bytes*.
So on any idle Q, `LED_STALL` hits 6 for certain, and the "distress" half of the
co-signal was satisfied by nothing worse than an efficient daemon.

### It was not theoretical — the events log is the evidence

It fired **twice** on the live device in the window between r13 and r72 landing
(`/var/log/nq-health/events.jsonl`):

```json
{"t_mono":214110,"sev":"crit","kind":"led_frozen","msg":"LED frame unchanged for 6 samples with distressed nexusqd (resp=1 progress=0) - ring/AVR/nexusqd hang"}
```

…and again at `t_mono` **214497**. Note `resp=1` in the message itself: the
control socket was answering the whole time. After r72, the same situation
correctly logs **info `led_static` … (resp=1)**.

### The fix (r72)

`pmos/device-google-steelhead/nq-healthd`: progress is measured over a **window**
instead of per sample.

- New state `NQ_LAST_TICK_MOVE` — the `t_mono` at which nexusqd's CPU time last
  advanced.
- New `PROGRESS_STALE_S` (env **`NQ_PROGRESS_STALE_S`**, default **60 s**).
- `nq_progress` is 0 **only** when the tick count has not advanced for that long.
  At r13's idle rate nexusqd accrues a tick roughly every **6 s**, so 60 s of
  silence is **~10× beyond normal** and genuinely means wedged.
- The window **resets** when the unit is not running (`NQ_LAST_TICK_MOVE=-1`), so
  a restart cannot inherit a stale "wedged" verdict.

Threshold rationale, stated so it does not get re-derived: the bound has to sit
far above the daemon's *idle* tick rate, not above its busy rate — the whole
failure was calibrating a liveness test against a load level that a later
optimisation removed.

**Lesson worth keeping:** an efficiency win can *invalidate a monitoring
threshold*. Any health signal derived from "did this process consume CPU in the
last N seconds" must be re-checked whenever the process gets meaningfully
cheaper.

---

## 2. `led_stall >= 6` — the permanent false alarm on every idle Q (mqtt r1→r2)

### What broke

`led_stall` counts **consecutive samples whose frame CONTENT is identical**. The
screensaver makes that happen **by design**, and the AVR keepalive keeps
re-committing the same bytes, so on an idle device the counter climbs without
bound (the 2026-08-11 overnight capture reached **7142** over an 11.81 h episode).

The companion app thresholded the raw counter:

```dart
if (stall is num && stall >= 6) out.add('LED ring frame is stalled');
```

Result: **every idle Q permanently reported "LED ring frame is stalled"**, in the
app's Health panel and in Home Assistant, ~10 minutes after the music stopped.

### The fix — publish the JUDGEMENT, not the counter (`nexusq-mqtt` r2)

New payload field **`led_stalled`** (bool):

```
led_stalled = (led_stall >= LED_STALL_MIN)   # LED_STALL_MIN = 6
              AND (nq_resp falsy OR nq_progress falsy)
```

The qualification is made **on-device**, from **the same distress co-signal
`nq-healthd` itself uses** to choose crit `led_frozen` over info `led_static` — so
the daemon and the telemetry agree **by construction** rather than by two
independently-maintained thresholds. `led_stall` stays in the payload as a
diagnostic number.

New HA discovery entity:

| key | name | class | template |
|---|---|---|---|
| `led` | **LED ring** | `problem`, `entity_category: diagnostic` | `{{ 'OFF' if (not (value_json.led_stalled \| default(false))) else 'ON' }}` |

The `default(false)` matters: an **absent** field reads as **healthy**, rather
than inventing an alarm out of a missing signal (an older device simply says
nothing).

**Live:** `binary_sensor.nexus_q_led_ring = off` in Home Assistant, with the
payload showing `led_stall=17, led_stalled=False`. Daemon test suite **28/28**.

### The companion app (code only — NOT built, NOT released)

`companion/app/lib/screens/health_screen.dart`, `healthProblems()`:

- `led_stall >= 6` → **`s['led_stalled'] == true`**, message **"LED ring is
  stalled"**.
- A device too old to send the field raises **nothing** — silence beats a
  known-false alarm, and a genuinely dead daemon still surfaces via
  `nexusqd_alive`.

`companion/app/test/health_problems_test.dart`: the old assertion replaced, plus
**two new regression tests** —

1. a payload with `led_stall: 9751` **and** `led_stalled: false` must produce an
   **empty** problem list (the idle-screensaver regression, pinned);
2. `led_stalled` fires **only** on a real boolean `true` — not `1`, not `"yes"`,
   not `null`.

**6/6 pass** under `flutter test`.

⚠️ **The app change is NOT in any APK.** No pubspec bump, no build, no GitHub
release, no `companion/app-release.json` bump. The app self-installs on Petr's
phone, so **the release needs his approval**.

---

## 3. Build-infra fallout: OTA package order was load-bearing (`docker-build.sh`)

Shipping r72 hit an old trap and finally fixed it. The `OTA_PACKAGES_ONLY=1` loop
interleaved per package, in the caller's order:

```
checksum A; build A;  checksum B; build B; …
```

When a listed package `depends=` another **listed** package, pmbootstrap resolves
the dep and builds it **from inside the first build** — while that dep's aport
still carries its `sha512sums="SKIP"` placeholder:

```
>>> ERROR: <dep>: <dep> is missing in checksums
```

…and the whole run exits **3**. It bit `nexusq-btagent`→`nexusq-setupd` before
(worked around by "list dependencies first"), and again today with
`device-google-steelhead`→`nexusq-mqtt` (r72 `depends=` the mqtt aport).

**Fix:** a checksum pass over the **entire** `$_ota_list` first, then a separate
build pass. Order-independent — the workaround is retired, and
`.claude/agents/nexusq-build.md` now records the trap as **FIXED**.

---

## Provenance

- Events: `/var/log/nq-health/events.jsonl` on the live device, `t_mono` 214110
  and 214497 (crit `led_frozen`, `resp=1 progress=0`); post-r72 the same state
  logs info `led_static … (resp=1)`.
- MQTT: retained `nexusq/health/state` — `led_stall=17`, `led_stalled=False`;
  Home Assistant `binary_sensor.nexus_q_led_ring = off`.
- Tests: `nexusq-mqtt` pytest **28 passed**; `flutter test` **6 passed**.
- Shipped state on the device: `nexusqd` r13 · `device-google-steelhead` r72 ·
  `nexusq-mqtt` r2 — all built, OTA-published to gh-pages, installed, live-verified.
- Prior record of the false alarm: `docs/2026-08-11-overnight-telemetry-analysis.md`
  §6 (the 11.81 h / max-7142 episode table) and §10 item 2.
