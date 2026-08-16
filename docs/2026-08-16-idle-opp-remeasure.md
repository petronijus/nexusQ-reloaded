# 2026-08-16 — Idle OPP residency re-measured after the 08-13 fixes: **70.7 % @ 350 MHz**

The A/B that `HANDOFF.md → WHERE TO CONTINUE (2026-08-13) item 1` asked for. On
2026-08-13 four OTA fixes went out (nq-healthd **r71** fork diet,
nexusqd **r13** event-driven PA gate + adaptive idle cadence, device **r72**
`nq_progress` window, nexusq-mqtt **r2** LED verdict) and the leftover
`nq-idle-study` sampler was stopped — an estimated ~12 pp of one core of idle
background removed. Nobody touched the Q afterwards, so **79 h of undisturbed
idle** accumulated and the free A/B was simply sitting in the broker.

**Result: 70.69 % @ 350 MHz — +10.2 pp over the 60.5 % baseline, and the hot
1200 MHz/1380 mV OPP has all but disappeared (5.1 % → 0.71 %, −86 %).**

## Result — clean window 2026-08-13 12:00 → 2026-08-16 19:40 CEST (79 h)

| OPP | mV | **2026-08-16** | 2026-08-13 baseline | Δ |
|---|---|---|---|---|
| **350 MHz** | 1025 | **70.69 %** | 60.5 % | **+10.2 pp** |
| 700 MHz | ~1200 | 22.56 % | 24.8 % | −2.2 pp |
| 920 MHz | ~1313 | 6.04 % | 9.5 % | −3.5 pp |
| **1200 MHz** | 1380 | **0.71 %** | 5.1 % | **−4.4 pp (−86 %)** |

Sum 100.01 % (sanity check on the kernel-counter deltas). Spread on the 350 MHz
share over the whole 79 h: median 70.70, **p05 69.60**, min 68.5, max 72.6 —
i.e. the plateau is genuinely flat, the way the 60.5 % one was.

**Die temperature: mean 58.4 °C, min 54.6 °C, max 64.3 °C** (baseline night:
59–61 °C hourly means, min 56.8). The coolest sustained idle recorded so far.

## Measurement conditions — verified from telemetry, not assumed

- **Uptime 2.34 d → 5.84 d across the window: no reboot**, so the r71/r13/r72
  packages under test are exactly the ones that were OTA-installed on 08-13.
- **All streaming services `off` for the entire window** (Spotify Connect,
  AirPlay, Roon, USB audio — HA binary_sensor history; the only state churn is
  an `unavailable → off` blip at 08-16 05:04, an HA/broker reconnect, not the
  device).
- **No observer contamination after 08-13 11:35.** Every contaminated sample in
  the full 3.5 d pull falls inside 08-13 07:41–11:35 — that is the previous
  session's own ssh/OTA/A-B work, and it is visible in all three independent
  signals at once: die > 65 °C (max **82.6 °C**), opp350 < 60 % (min 47.6),
  opp1200 > 3 % (max 16.0). Textbook confirmation of the 2026-07-13 Finding 1
  rule — **judge idle only with no live ssh session**.
- Pipeline unchanged: kernel `time_in_state` → healthd `opp_ms` → `nexusq-mqtt`
  rolling 1 h window → HA MQTT discovery → `sensor.nexus_q_time_at_*_mhz` → HA
  history API. Never healthd's `freq` field (observer-biased ~19 pp).
- Broker cross-check at read time (retained `nexusq/health/state`): `opp350_pct`
  68.5, `temp_c` 59.7, `governor` conservative, all services false — consistent
  with HA.

## Interpretation

- **The "structural" gap was mostly our own observability layer.** On 08-13 the
  residual above 350 MHz was called structural and *findable* — it was: 4.4 pp
  of the 5.1 % at the hottest OPP was nq-healthd's forks, nexusqd's 22
  wakeups/s and the idle-study sampler. Removing them converted almost exactly
  the predicted ~12 pp of core-time into ~10 pp of 350 MHz residency.
- **1200 MHz is now noise-level: 0.71 % ≈ 25 s per hour.** Whatever is left no
  longer pushes the governor to the top OPP in any sustained way; the remaining
  29.3 pp above 350 MHz is dominated by **700 MHz (22.6 %)**.
- That reframes the next lever. Chasing the 1200 MHz residency (old item 5,
  "governor tunables last") has little left to win; the question is now what
  keeps the governor at **700 MHz** for 22.6 % of an idle hour. The named
  suspects from 08-13 survive: `nq-healthd` still at ~2.4 % of a core (item 2, C
  rewrite), **`brcmf` WiFi at ~40 wakeups/s — more than all other sources
  combined** (item 3), and `nexusq-mqtt`'s 30 s `pactl` poll (item 4).
- **`led_stalled` verdict confirmed in the field**: `led_stall` has run up to
  **55 842** on a locked/blanked ring over 5.8 days and `led_stalled` stayed
  `false`, `binary_sensor.nexus_q_led_ring` = `off` (healthy). The r72 + mqtt r2
  pair is doing exactly what it was built for — no false CRIT in 79 h.

## Tooling — `scripts/diag/ha-opp-window.py` (new)

The measurement is now a committed tool instead of an ad-hoc query, because it
has a trap in it:

⚠️ **HA's history endpoint silently truncates a long multi-entity response.** A
single `/api/history/period/<3.5 d ago>?filter_entity_id=<12 entities>` call
returned only the **first 24 h** — no error, no marker, a perfectly well-formed
JSON body that simply stopped at 08-14 07h. Taken at face value it would have
thrown away 2.5 of the 3.5 days, and the truncation happens to land *right
after* the interesting transition, which is exactly how a wrong number becomes
believable. The tool fetches in **6 h chunks** and merges, de-duplicating the
boundary sample each chunk repeats.

```sh
scripts/diag/ha-opp-window.py --days 3.5 --since '2026-08-13 12:00'
```

`--since` is the start of the window you consider clean; the full window is
still reported next to it, and an `outliers` section clusters the contaminated
samples by hour so you can see at a glance that they are your own ssh sessions.
Passive: it reads Home Assistant only, never the device.

## Provenance

- HA history: `sensor.nexus_q_time_at_{350,700,920,1200}_mhz`,
  `sensor.nexus_q_die_temperature`, `sensor.nexus_q_uptime` + the six
  `binary_sensor.nexus_q_*` service/health sensors; window 2026-08-13 07:42 →
  2026-08-16 19:42 CEST; 5 067 clean samples on the 350 MHz sensor.
- Broker spot-check: retained `nexusq/health/state` over `mqtt.home.arpa:1883`.
- Device state at read time: `nexusqd` r13 · `device-google-steelhead` r72 ·
  `nexusq-mqtt` r2 · uptime 5.84 d · governor `conservative` · WiFi −26 dBm.
