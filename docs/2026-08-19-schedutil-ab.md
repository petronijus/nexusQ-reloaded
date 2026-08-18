# 2026-08-19 — schedutil A/B: a negative result, and why residency alone lies

`schedutil` had been the standing "maybe this is the real fix" hypothesis for
idle power ever since the 2026-08-16 analysis found `conservative` ramping on
burst shape. It could not be tested at all back then — it was not compiled in.
Kernel **r48** added it, kernel OTA (phase 2) applied that kernel without a
cable, and this is the measurement.

**Verdict: schedutil is not a win. Stay on `conservative` with our tuning.**

## Method

`scripts/diag/nq-opp-study2.sh`, four 12-minute arms, detached, no ssh session,
idle device (all streaming services off), measured from kernel `time_in_state`
and `trans_table` deltas. Data: `nq-captures/2026-08-18-schedutil-ab/`.

## Result

| arm | 350 MHz | 700 | 920 | 1200 | transitions/s | busy (1 core) | rel. power |
|---|---|---|---|---|---|---|---|
| **conservative** (shipped: 20 ms/80, down 40, ignore_nice 1) | 91.22 % | 8.58 | 0.15 | **0.05** | **1.02** | 4.10 % | **1.157** |
| schedutil (default rate_limit, from the 300 µs transition latency) | **94.75 %** | 2.93 | 0.68 | 1.63 | **15.41** | 3.59 % | 1.158 |
| schedutil, `rate_limit_us=5000` | 93.94 % | 3.26 | 1.22 | 1.58 | 4.37 | 3.00 % | 1.180 |
| schedutil, `rate_limit_us=20000` | 93.86 % | 3.23 | 0.97 | 1.94 | 2.53 | 2.99 % | 1.190 |

Relative power is f·V² normalised to 350 MHz/1025 mV.

## Why the headline number is a trap

**On 350 MHz residency alone, schedutil wins outright: 94.75 % against 91.22 %.**
That is the number the STANDING GOAL is written in, and taking it at face value
would have shipped a change that saves nothing.

The catch is *where the rest of the time goes*. schedutil spends **thirty times
longer at 1200 MHz** (0.05 % → 1.63 %), and 1200 MHz at 1380 mV costs 6.2× what
350 MHz at 1025 mV costs. The two effects cancel almost exactly: **1.157 vs
1.158**.

The mechanism is the difference between the governors. `conservative` climbs one
OPP per sampling tick, so a short burst gets served at 700 MHz and comes back
down. `schedutil` computes the frequency it thinks the utilisation demands and
jumps straight there — its mean stay at 1200 MHz is **2.6 ms**, against 97 ms for
conservative. Lots of very short trips to the most expensive OPP.

`rate_limit_us` does not rescue it: raising it cuts the transition rate hard
(15.4 → 2.5/s) but makes power slightly **worse** (+2.0 %, +2.8 %), because a
longer window means that once it does jump up, it stays up longer.

## What we keep

`conservative` with the shipped tuning, which additionally does ~**20× fewer
transitions** (1.02/s vs 15.41/s) — not free on a board where every OPP change is
a voltage ramp with a 300 µs transition latency.

Recorded so nobody re-opens this hypothesis without new information. The remaining
idle lever is still the one the burst analysis identified: **nq-healthd's ~6 forks
per tick** (the C rewrite), not the governor.
