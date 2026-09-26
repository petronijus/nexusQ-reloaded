# 2026-09-26 — idle audit: five pollers, half the work

Cottage Q (Šumperák), kernel 6.18.48-r17, first night with the deep C-states on
by default. Captures: `nq-captures/sumperak-soak-20260926/`.

## 1. The night (r109, 00:47–08:15, one boot, nothing touched)

Two cumulative-counter snapshots, taken with a small read-only script
(cpuidle usage/time, cpufreq `time_in_state`, `/proc/stat`, `/proc/interrupts`,
`pm_debug/count`, diskstats, per-process utime+stime), and their delta:

| | cottage r109 | Prague 2026-09-24 soak |
|---|---|---|
| no hang / reset / new pstore | yes | yes |
| C3 share of idle, CPU0 / CPU1 | 89.6 % / 92.7 % | 86 % |
| C2 share | 2.3 % | 2 % |
| C3 entries per CPU | 153/s, 5.5 ms each | — |
| 350 MHz residency | 99.82 % | — |
| busy (of 2 cores) | 2.1 % | — |
| die temperature, median / max | 40.3 / 46.8 °C | 48.9 °C median |
| WiFi watchdog | 330 checks, 0 loss, 0 repairs | 81 checks, 0 repairs |
| eMMC writes | 6.2 KB/s ≈ 510 MiB/day | — |
| MemAvailable, minimum | 849 MiB, swap untouched | — |

The temperatures do not compare: different rooms, different ambient.

## 2. Where the idle work went — measure it passively

The method is the one §4h of the sleep doc settled on: trace
`power:cpu_idle` + `sched:sched_switch` (+ irq, ipi, timer, workqueue events)
for 60 s and attribute each idle exit to the first handler and the first task
after it. Nothing is stopped, so nothing churns.

Three things the snapshot delta alone would have got wrong:

- **Short-lived processes are invisible in per-process deltas.** Every fork
  is a new PID that exists in neither snapshot. Summing the trace's
  `sched_switch` run time by task name found 465 ms per minute in processes
  that live for milliseconds — `wc`, `iw`, `grep`, `awk`, `ip`, `ping`, `cut`
  — almost all spawned by the WiFi watchdog. That is 0.78 % of a core, as much
  as the largest long-lived consumer, and appeared nowhere in the delta.
- **A burst pattern tells you the cause.** Grouping each task's runs into
  bursts showed `systemd-oomd` at 10 ms every 1.25 s,
  `nq-healthd` at 6 ms every 5 s plus 157 ms every 30 s, and `nexusq-btagent`
  at 61 ms every 10 s. Each period pointed straight at a line of code.
- **IPI callsites say who sends them.** On 6.18 `ipi:ipi_send_cpu` carries the
  callsite and callback. `generic_exec_single` from the idle task (150/s) is
  the coupled-cpuidle poke; `irq_work_queue` → `dbs_irq_work` (46/s) is the
  conservative governor's 20 ms sampling. Both are costs of mechanisms we
  want, not bugs.

## 3. The five fixes (device r110/r111, btagent r6, control r49, shairport-sync 5.1-r100)

| consumer | before | cause | fix |
|---|---|---|---|
| systemd-oomd | 0.81 % | PSI polling every 1.25 s | off: preset + enable links removed + systemd's ManagedOOM drop-ins shadowed with `/dev/null` |
| WiFi watchdog + children | ~0.9 % | ~15 forks per 30 s check, `wc -l` over the whole log | shell-side parsing, one `iw`, uptime by builtin, line counter |
| nq-healthd | 0.63 % | whole kmsg ring re-read every 30 s | incremental read, trimmed to the oldest record in the ring |
| nexusq-btagent | 0.62 % | an introspecting BlueZ proxy per property read | `introspect=False` + explicit signatures |
| shairport `alsa_buf_mon` | 0.47 %, 91 exits/s | `usleep(10000)` loop on a flag that never changes | patched to block on a condition variable |

Details, tests and caveats for each are in CHANGELOG [Unreleased]. Two traps
worth remembering:

- **Disabling oomd did not disable it.** After r110's `disable --now` it was
  back after the reboot, `WantedBy=user@0.service user@10000.service`. systemd
  ships `10-oomd-defaults.conf` drop-ins (`ManagedOOMMemoryPressure=kill`) for
  `user@.service`, `-.slice` and `system.slice`, and PID 1 turns any
  `ManagedOOM*=` setting into `Wants=/After=systemd-oomd.service`. A same-named
  drop-in in `/etc/systemd/system/<unit>.d/` pointing at `/dev/null` switches
  the vendor one off (r111). Verified on the device: an upgrade from a state
  with oomd enabled and running leaves it inactive, and it stays inactive
  across a reboot.
- **`introspect=False` needs signatures.** Without introspection dbus-python
  guesses argument types. `Properties.Set(…, dbus.Boolean)` goes out as `ssb`,
  and bluetoothd answers `UnknownMethod` (reproduced on the device before the
  fix shipped). A str object path goes out as `s`, not `o`.

## 4. After (r111, same 60 s trace, idle, 15 min after boot)

| | r109 | r111 |
|---|---|---|
| idle exits/s | 721 | **353** |
| all tasks, % of one core | 4.71 | **2.21** |
| systemd-oomd | 0.81 | 0 |
| nq-healthd | 0.63 | 0.13 |
| python3 (btagent + control + mqtt) | 0.72 | 0.25 |
| alsa_buf_mon | 0.47 | 0.007 |
| watchdog children (wc/grep/awk/ip/cut) | 0.35 | ~0 |

Function-call IPIs from idle fell with everything else (150 → 77/s), which
fits them being coupled-idle pokes: fewer wakeups, fewer rendezvous.

Functional checks on r111: the BT agent registers as default and enforces
`Pairable=False`, AirPlay is advertised and `alsa_buf_mon` exists but sleeps,
the watchdog logs `ok` with loss 0 and −45 dBm, and `dmesg_err` tracked a full
recount through +2 matches, a ring wrap (7 → 0) and a match after the wrap.

The 30 min snapshot window after the trace is **not** an idle measurement:
Spotify played during it (librespot and PulseAudio ~9–10 % each, die 56 °C).

## 5. Open

- **librespot's audio cache is unbounded**: 2.0 GB on the cottage Q, and
  eMMC writes ~64 KB/s while playing. Cap it (`--cache-size-limit`) or drop the
  audio cache — a design call.
- **Governor sampling** (20 ms) is now the largest idle wakeup source we
  control; lengthening it waits for a listening test (08-16 note, item 4).
- **`psimon`** ~4/s: PID 1, the user managers and journald hold PSI triggers
  (sd-event pressure watches), so `CONFIG_PSI` still has users; whether they
  are worth its cost is not measured yet.
- The five packages above are **built, not published**. The cottage Q runs
  them from local apks. Prague gets them with the next OTA publish.
