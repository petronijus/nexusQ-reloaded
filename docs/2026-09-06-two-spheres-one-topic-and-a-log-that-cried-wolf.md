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

**Not shipped in this pass.** The change belongs to `nexusq-control`, whose
source another session is mid-edit on with an r37 apk already built and waiting
for approval; landing it there now would either strand that build or publish it.
It is queued as **r38** behind that commit.

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
