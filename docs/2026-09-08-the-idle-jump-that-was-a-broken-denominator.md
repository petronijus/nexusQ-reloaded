# The idle jump that was a broken denominator

*2026-09-08. Roon now-playing had just shipped (`nexusq-control` r45,
`nexusq-mqtt` r6) and Petr's standing condition on all three sources is one
sentence: "hlavne aby to nemelo negativni vliv na performance koule, ani to
spotify co jsme ted udelali nesmi mit negativni vliv na performance."*

So the deploy got a performance check, and the check said the Q had gone from
~10 % busy in the morning to **19–20 %** in the evening. That number was wrong,
and the way it was wrong is worth writing down, because the same trap is now on
record twice.

## The A/B that cleared the feature

First the direct question: is the Roon MQTT subscription the cost? The kernel
worker was the top consumer, so it was measured with the subscription on and
off (`systemctl set-environment NQMQTT_ROON=off`, daemon restarted):

```
A: Roon subscription ON  (as shipped)      kworker 780 ticks / 30 s
B: Roon subscription OFF (daemon stopped)  kworker 825 ticks / 30 s
```

Slightly *higher* with the daemon stopped — noise. The subscription is not the
cost. (The override was then cleared with `systemctl unset-environment`;
leaving it would have silently shipped Roon disabled.)

The daemons' own cost, per-task over 60 s, is the same answer from the other
side: `nexusq-mqtt` **5 ticks**, `nexusq-control` **1 tick** — 0.08 % and
0.02 % of a core.

## What is actually burning the CPU

`/proc/interrupts` names it without ambiguity, because a hardware counter has no
denominator to get wrong:

```
141:  30668  Level  musb-hdrc.0.auto
140:  30668  Level  musb-hdrc.0.auto     <- 30 s window: ~1022 IRQ/s, one per USB frame
```

That is the UAC2 gadget, and it feeds `kworker/0:1-events` at **1659 ticks /
60 s ≈ 27 % of a core**. `card4/pcm0c` is `RUNNING` and `/sys/class/udc/*/state`
is `configured`: the Xiaomi box holds the stream open and keeps sending, exactly
as `nq-uac2-silence`'s own docstring says every UAC2 host it has met does.

The silence guard is doing its job — `usb_in` is `SUSPENDED`, so PulseAudio's
share is gone. What it cannot suspend is the kernel's interrupt work, because
the host is still transmitting. This is pre-existing, has nothing to do with the
three now-playing sources, and is the same finding as 2026-08-24's 1006 IRQ/s.

The governor, meanwhile, is healthy: **75.97 % @ 350 MHz, 15.60 % @ 920,
7.92 % @ 700, 0.52 % @ 1200**, 87 transitions/min, die 57 °C. A spot reading of
"1200 MHz" during the sweep was one momentary sample inside an ssh session — the
opposite of the stuck-governor tell, which is a high OPP with a *low* transition
rate.

## The denominator

The "10 % → 20 %" itself never happened. `busy = (total − idle − iowait) /
total` off `/proc/stat` is not a sound percentage on this box. One 60 s
wall-clock window, both cores online, `CLK_TCK`=100, so a real window is 12000
ticks:

| line | ticks advanced | of a real 6000 |
|------|---------------:|---------------:|
| cpu0 | 2704 | 45.1 % |
| cpu1 | 5606 | 93.4 % |

**cpu0's counters advance at about half wall-clock time while the core is
running work.** `kworker/0:1-events` is bound to cpu0 and booked 1659 ticks in
the very same window — more than the 1194 busy ticks `/proc/stat` reported for
both cores combined. cpu0 undercounts its idle and its busy alike; over the
7.4-day uptime it has accumulated 4.2 days of ticks to cpu1's 7.4.

Two consequences:

* **The percentage moves with accounting coverage, not with load.** Constant
  work over a shrinking denominator reads higher. The morning and evening
  figures were never comparable, and an evening went into A/B-testing a deploy
  against a metric artefact.
* **A per-PID tick total may legitimately exceed the reported system busy.**
  That looks like a sampler bug and is not one.

Divide by wall clock (`seconds × 100 × nproc`). Prefer per-task and per-cgroup
accounting, which stayed self-consistent throughout. Read `/proc/interrupts`.
Recorded as rule 7 in the idle-attribution memory, beside rule 4 — "do not
hand-roll a sampler" — which this session promptly did anyway, three times.

## Not a bug: the second silence watcher

Two `nq-uac2-silence` processes are running and one is parented by
`systemd --user`, which read as an orphan from a restart. It is not. Their
environments tell them apart:

```
pid 10326  cgroup …/nexusq-uac2-in.service      (silence mode, usb_in)
pid 15000  cgroup …/nexusq-roon-idle.service    NQ_WATCH_MODE=producer
                                                NQ_UAC2_SOURCE=roon_in
```

Mode comes from `NQ_WATCH_MODE`, not from argv, so both show identical command
lines. Two sources idle differently and each gets its own watcher — by design.
Nothing to clean up.

## Status

Roon still needs a live test: the zone gate opens only when RAAT audio is
actually arriving here (`roon_in` `RUNNING`), so it wants Petr playing Roon *to
the Q*. The safety half has already been seen working — two other zones playing
house-wide while the Q's screen stayed empty.
