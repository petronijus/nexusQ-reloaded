# 2026-09-06 — two spheres, one topic, and a build log that cried wolf

Three of the four items left open by the morning's diagnosis
(`docs/2026-09-06-the-guard-that-was-asleep-on-paper.md`), worked through the
same evening. The fourth — the cottage Q's own upgrade — is blocked on access
and is written up at the end.

## 1. Home Assistant showed the cottage Q under Prague's entities

### What was actually wrong

`sensor.nexus_q_*` belongs to the Prague device. From **08:13 UTC to 16:08 UTC**
it carried the **cottage's** numbers, and Prague's own readings went nowhere.
The proof is arithmetic, not inference:

| entity | 08:13 UTC | 09:10 UTC | 16:08 UTC |
|---|---|---|---|
| `sensor.nexus_q_sumperak_uptime` (cottage) | 55 646, then stops | — | — |
| `sensor.nexus_q_uptime` (Prague) | — | 59 074 | 500 024 |

55 646 s at 08:13 and 59 074 s at 09:10 is one counter, continuing across two
entity sets — one box, appearing under the other's name. Prague had been up
5.8 days (500 000 s), which is the value that returned at 16:08.

### What it was NOT

Not a collision on the wire. Both boxes were publishing to their own prefixes
the whole time, verified live on the broker in a 70 s window:

```
nexusq/health/state            -> uptime 500 114   (Prague)
nexusq-sumperak/health/state   -> uptime  84 323   (the cottage, still counting)
```

So the README's standing advice — *give every additional device its own
`prefix`* — had in fact been followed for the cottage, and it did not save us.
That is the finding worth keeping: **the flat topics name a namespace, not a
device.** `<prefix>/health/state` cannot tell Home Assistant which Q a reading
describes, so when discovery is republished there is nothing to disambiguate
with. And the advice cannot hold anyway: the app provisions `prefix` from one
stored setting, whichever Q you open, so a single tap can undo it.

### The fix (nexusq-mqtt r5)

- Publishes, and points HA discovery at, `<prefix>/<node_id>/health/state` and
  `<prefix>/<node_id>/status`. `node_id` is `nexusq_<factory WiFi MAC>` — the
  string that already keyed the HA device entry and every `unique_id`, so
  nothing new has to be invented or configured.
- The single MQTT Will moves to the per-device status topic. MQTT allows one
  per connection, and with two boxes the flat one could not honestly describe
  either: whichever died marked the shared topic offline.
- The flat topics are still published, marked **legacy** in the README. The
  companion app subscribes to them and the bridge gives it no way to learn a
  node_id — `getStatus` reports no WiFi MAC. Closing that out needs a protocol
  field and an app change; until then the app's health screen with two Qs live
  still shows whichever box published last.
- Two new tests, both seen failing first: the discovery topics are per-device,
  and two node_ids share no state, availability or config topic.

**Verified after shipping:** `sensor.nexus_q_uptime` = 500 024 s at 16:08 UTC,
one publish after the upgrade, and the broker now carries
`nexusq/nexusq_f88fca2048e1/health/state` beside the legacy topic. The cottage
keeps its stale entities until it takes r5 — discovery configs are republished
only on connect.

## 2. The systemd-262 journal noise: upstream, and measured

Every login and every `nexusq-control` poll emits:

```
systemd-coredumpd.service: Failed to read pids.max for control group … (x2)
systemd-coredumpd.service: Skipped due to 'exec-condition'.
systemd-coredump-register.service: Bound to unit systemd-coredumpd.service, but unit isn't active.
Dependency failed for Kernel Core Pattern Register.
```

`coredumpctl` is empty — nothing is crashing. Two separate causes, and neither
is a fault in our code:

**a) `Skipped due to 'exec-condition'`** is systemd-coredumpd's own
`ExecCondition=/usr/lib/systemd/systemd-coredump --check-requirements` failing.
Run by hand it says:

```
ioctl(PIDFD_GET_INFO) does not support PIDFD_INFO_COREDUMP and/or PIDFD_INFO_COREDUMP_SIGNAL.
```

Probed directly on the device (`pidfd_open` + `PIDFD_GET_INFO` across every
struct size the kernel accepts), 6.18.48 returns `mask=0x17`: **`COREDUMP` yes,
`COREDUMP_SIGNAL` no**. That matches the kernel source we build —
`fs/pidfs.c` sets `COREDUMP_SIGNAL` only on the path where a dump actually
happened, and the live-process fallback deliberately does not ("No coredump
actually took place, so no coredump signal"). Alpine edge ships systemd
**262~rc1**, a release candidate that requires both flags. So the unit correctly
skips itself, `systemd-coredump-register` is `BindsTo=` it and correctly fails,
and coredumps on this image simply do not go through the manager. Not ours to
fix; revisit when systemd 262 final or a later kernel lands.

**b) `Failed to read pids.max`** is `CONFIG_CGROUP_PIDS` not being set in
`steelhead_defconfig` — cgroup v2 is mounted with `cpu io memory` and no `pids`
controller, so systemd asks for a file that cannot exist. It logs `ignoring:`
and carries on. Enabling it is a one-line defconfig change, but it needs a
kernel build and a kernel OTA, which is more than a log line is worth on its
own; noted here for the next kernel bump.

### What IS ours: stop triggering it 288 times a day

The noise is emitted per *unit start*, and `nexusq-control` reaches the uid-10000
user manager with `systemctl --machine=user@.host --user`, which opens a PAM
session and a transient unit each time. Measured on the device, three calls:

| form | journal noise lines |
|---|---|
| `systemctl --machine=user@.host --user` | 34 |
| `systemctl --user` as root via the user bus | (refused: *Operation not permitted*) |
| `setpriv --reuid=10000 --regid=10000 --clear-groups env XDG_RUNTIME_DIR=… DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/10000/bus systemctl --user` | **0** |

(The 6 lines that first appeared under the third form were traced to the ssh
login used to run the test, not to the calls.)

The middle row is the one the code's own comment already records — *"the
--machine transport is the ONLY one allowed (the local user bus refuses a root
connection)"*. True, and incomplete: root may **drop to the user** instead of
connecting as root, and `setpriv` does that without PAM, without a session and
without a transient unit. It answers identically (`is-active`, `show -p`,
`list-units`, and `CanStart` says start/stop work too), so it is a drop-in for
`_systemctl_user()`.

**Shipped as r38** once r37 was approved and out. `--init-groups` rather than
the `--clear-groups` used in the measurement above: clearing supplementary
groups drops `audio`, which the units started through this helper (librespot,
roon, shairport-sync) need. Re-measured in the shipped form against a 20 s idle
baseline, one isolated call each — `--machine` **7** noise lines, `setpriv`
**0** — with identical answers from `is-active`, `show -p ActiveState`,
`list-units` and `CanStart`.

### The measurement that corrected the story

The "~5 lines per 20 s baseline" I first recorded here was **my own ssh polling**
— and so, it turns out, was the "noise on every 5-minute `nexusq-control` poll"
in the morning handover. Every login starts a unit, every unit start prints the
noise, so a loop that polls the box to watch for the noise manufactures it. My
first "quiet" window logged a new root session every 30 s: my own wait loop.

Measured properly, seven minutes with nobody logged in and nothing attached:

```
window: 19:05:23 .. 19:12:23   new sessions: 0   coredumpd skips: 1
```

So the box at rest is quiet, and this helper is called on user actions, not on a
timer. What r38 actually buys, three isolated calls each:

| | per call | journal lines (3 calls) |
|---|---|---|
| `--machine=user@.host` | 868–1220 ms | 22 |
| `setpriv` + `--user` | 41–59 ms | 0 |

The ~20× latency is the real win — `setService` waits on this, and the app waits
on `setService`. r38's commit message claiming "~288 sessions a day" was wrong;
**r39** carries that correction in the source comment, with identical behaviour.

Verified end to end through the bridge afterwards: `setService airplay off`
stopped shairport-sync, `on` brought it back, `listServices` correct throughout,
AirPlay left as found.

## 3. The build log that cried wolf

Every build printed, for nine of eleven aports:

```
--- nexusqd ---
  ERROR: failed to source APKBUILD
```

while the build itself was perfectly fine. The cause was **`set -u`**, not a
broken APKBUILD: `docker-build.sh` runs under `set -euo pipefail`, an APKBUILD
legitimately expands abuild-supplied variables at top level (`$srcdir` inside a
`package()` body is enough), and nounset killed the listing subshell before its
first `echo`. The two aports that passed only passed because they happen not to
name one.

Fixed by turning nounset and errexit off inside that subshell only. Verified
both ways: all eleven aports now list their metadata, and a deliberately broken
APKBUILD still reports `ERROR: failed to source APKBUILD (exit 2)`.

## 4. Still blocked: the cottage Q

It is on **device r93 / nexusq-mqtt r4** and cannot be reached from Prague. The
cottage DietPi (`dietpi-sumperak`, Tailscale `100.122.96.6`) refuses this
machine's key, and no credential for it is in 1Password under any obvious name.
Someone on the cottage network — or with that login — needs to run the app's
*System* update or:

```sh
apk update && apk upgrade --available --ignore linux-google-steelhead
```

That brings it to device r94 (the Roon guard fix) and nexusq-mqtt r5, after
which its Home Assistant entities re-register on per-device topics and its
stale readings resolve themselves.

## A release-tooling gap, found the hard way

`publish-ota-repo.sh` takes **the newest build of every package in
`pmos/ota-packages.list`** from the shared `nexusq-workdir` volume. Publishing
nexusq-mqtt r5 therefore also published another session's `nexusq-control` r37,
which was built and deliberately *not* approved for release. Rolled back within
minutes (r37 moved to `packages/edge/armv7/.held-unapproved/`, gh-pages
`43173cd` back to r36); no device installed it, and the peer session verified
that independently.

One consequence outlived the rollback: a Q that ran `apk update` inside that
window cached an index naming r37 and failed its next upgrade with
`HTTP 404: Not Found` until `apk update` was run again. That is what a
mid-flight index change looks like from the device.

The gap itself is unfixed: **the contents of the shared volume are the release
decision**, and nothing can express "built, but not approved". Two candidates,
both cheap: have `publish-ota-repo.sh` skip a `.held-*` directory by name, or
have it take an explicit package list and refuse to ship a version the caller
did not name. It belongs to whoever owns the release scripts.


## 5. What the post-change diagnostic found, including one wrong verdict

A full read-only `nexusq-diag` sweep ran after all three changes were installed
(capture `nq-captures/20260906-184317/`). The fix's effect, from `health.jsonl`
split at the 17:05 guard restart:

| | before (6.40 h) | after (1.62 h) |
|---|---|---|
| die temp, mean | 67.91 °C | **61.24 °C** |
| die temp, min | 65.9 °C | **55.7 °C** |
| `load1`, mean | 1.11 | **0.50** |

Everything else came back healthy: 1.2 GHz reachable, `vdd_mismatch` **0 of
5776** samples (12 this morning), no throttling ever, LED ring alive with 0
restarts, WiFi −22 dBm on 5 GHz with the factory MAC intact, Bluetooth
Phantasm blob loaded with 0 reassembly failures, pstore empty, `time_in_state`
86.6 % at 350 MHz.

### The wrong verdict, and why it was wrong

The sweep flagged the guard's two `source resumed behind our back` lines as
**probable false positives** — reasoning that they are start-adjacent, that
`suspend()` returns True when the command was *delivered* rather than when the
source actually changed, and that PulseAudio's asynchronous close could
therefore keep the consumer reading open past the 1 s confirm window. It
proposed arming the reconcile only after the consumer has been seen `closed`
once.

The reasoning is sound and the conclusion is wrong, which is worth recording
because the evidence that settles it was not available to the sweep: **both
lines are exactly the two moments an operator resumed the source on purpose**
(`pactl suspend-source roon_in 0`, once to prove the fix on the deployed script
at 17:11:52, once again on the apk-installed r94 at 17:24:09). `pactl` leaves no
journal trace, so from the device alone the two look self-inflicted.

The discriminator is in the same journal: the *same* fixed instance
self-suspended twice more at **18:31:20 and 18:31:46**, after real producer
open/close cycles, and emitted **no** warning either time. A false positive
driven by PA's async close would have fired there too.

So the message is accurate and no change is warranted. The property the sweep
identified is real — `suspend()` reports delivery, not effect — and the
theoretical false positive it enables has not been observed in any of the three
fixed-instance self-suspends. Arming the reconcile only after seeing `closed`
would also trade this away for a worse failure: if our own suspend never takes,
the guard would never re-assert it, which is the original bug.

### One thing the fix did not change, and should be looked at

The amplifier **rails stay energized at idle** even with the sink suspended:
`amp_pvdd 5 4` with all four `3-001b-PVDD_A..D` consumers, `gpio-12 (pdn) out hi
ACTIVE LOW`, Speaker switch `[on]` at 0.00 dB (Master −33 dB). That is the same
evidence line this morning's note used for "the amp is physically on". What r94
removed is the *load* — the sink clocked and PulseAudio resampling silence — not
the amp power. Whether the amp should power down when the sink suspends is a
separate question, and not one to answer by experiment on a 25 W amplifier
without thinking about pops first.

### Smaller items from the same sweep

- `dmesg -l err,warn` is no longer empty (7 lines) against the v1.6.10 "clean"
  invariant: 3 `[nq-ab]` slot-marker lines from our own A/B initramfs emitted at
  warn level, `twl_rtc: Power up reset detected`, `hrtimer: interrupt took
  762966 ns`, a systemd `orphaned-….socket` config-changed notice, and
  `perf_duration_warn`. Low severity, but the rule was "empty".
- `nexusq-wifi-watchdog` failed 19× on Sep 5 20:21 with `status=127` (its binary
  missing mid-upgrade), self-resolved a minute later. Current run is spotless:
  1515 `ok`, 0 heals, 0 `nogw` over 139 h.
- `nq-diag-snapshot` reports librespot `inactive` while it is active — the probe
  asks the system manager for a user unit. Cosmetic, in
  `pmos/device-google-steelhead/nq-diag-snapshot`.
