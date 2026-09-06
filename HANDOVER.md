# Cross-machine handover

Steps that were done on ONE machine but have to be done on the others before the
project works there. Delete a section once its steps are done on that OS.

`HANDOFF.md` is the session log — what happened and why. **This file is the todo
list for the other machines.** Matching tasks live in Todoist → **AI-handover**.

---

## Desktop (petronijus-PC) — 2026-09-06 evening: the Prague Q is warm — ✅ repaired the same evening

Diagnosed read-only from the MacBook (`nexusq-diag`, capture
`nq-captures/20260906-160616/` on that machine), repaired on the PC. Full record:
`docs/2026-09-06-the-guard-that-was-asleep-on-paper.md`; CHANGELOG
`[Unreleased]` → "the Roon idle guard believed itself asleep".

**What it was:** not a hot die (67 °C, the idle floor) but the Roon path awake
for 4.75 days with nothing playing — amp powered since Sep 1 21:37, PulseAudio
resampling silence, load ~1.0. The live Roon-loopback module reload for the r92
fix had resumed `roon_in` behind the guard, and `nq-uac2-silence` in producer
mode only ever trusted its own `asleep` flag.

**Done on the PC (2026-09-06 17:00–17:15):**

- Immediate relief: user unit restarted → `roon_in`, the amp sink and the
  tas5713 PCM all idle within 20 s.
- Fix in `pmos/device-google-steelhead/nq-uac2-silence`: reconciles the producer
  PCM against the **capture side of the same aloop cable**
  (`/proc/asound/RoonLoop/pcm1c/sub0/status`, new `NQ_CONSUMER_PCM`, set in
  `nexusq-roon-idle.service`) on every poll, both directions, after 1 s of
  sustained disagreement. Seen failing first (11 new tests, red on r93; live
  `pactl suspend-source roon_in 0` left the source RUNNING for 15 s with the
  guard silent), then green and undone within 1 s on the device.
- `device-google-steelhead` **r94** built (`OTA_PACKAGES_ONLY=1`), **published**
  (gh-pages `c861ac9`, secrets gate 11/11 clean) and **installed on the Prague Q
  at 17:23** via the app's own path (`apk upgrade --available --ignore
  linux-google-steelhead`); the trigger re-run against the apk-installed guard
  was undone within 2 s. `install-fleet-signing-key.sh --check` clean (the
  standing Todoist task — done); `seed-ota-volume.sh` was NOT a no-op here
  (`seeded=10 kept=1 retired=6`, see the note) — run it before any OTA-only
  publish on a machine that did not build the last release.
- ⏳ **Šumperák Q still on r93** — not reachable from Prague (different network).
  Next time anyone is on the cottage network: the app's *System* update, or
  `apk update && apk upgrade --available --ignore linux-google-steelhead` over
  ssh. Until then its Roon guard has the old hole; a `roon.service` restart
  there would re-arm it correctly but not fix it.
- Not fixed, noticed in the build log: `docker-build.sh` Phase 2's aport listing
  prints `ERROR: failed to source APKBUILD` for all 8 non-device aports
  (subshell `source` under `set -e`, cosmetic — the build itself is fine).

**The rest of that list was worked through the same evening** — record:
`docs/2026-09-06-two-spheres-one-topic-and-a-log-that-cried-wolf.md`.

- ✅ **Home Assistant showed the cottage under Prague's entities** — fixed and
  verified (`nexusq-mqtt` **r5**, published, installed on Prague). It was NOT a
  topic collision on the wire: each box was publishing to its own prefix. The
  flat `<prefix>/health/state` simply names no device, so HA had nothing to
  disambiguate with. Topics are now `<prefix>/<node_id>/…` and the Will lives
  there too; the flat ones stay for the app, marked legacy. Prague's entities
  came back within one publish.
- ✅ **Build log cried wolf** — `docker-build.sh` reported `ERROR: failed to
  source APKBUILD` for 9 of 11 aports on every build. Cause was `set -u`
  (an APKBUILD expands `$srcdir` at top level), not a broken aport. Fixed, and
  a genuinely broken APKBUILD is still reported.
- ⚠️ **systemd-262 journal noise — upstream, not ours.** `systemd-coredump
  --check-requirements` fails because 6.18.48 returns `PIDFD_INFO_COREDUMP` but
  not `PIDFD_INFO_COREDUMP_SIGNAL` (probed directly on the device; the kernel
  source only sets the signal flag when a dump really happened) and Alpine ships
  systemd **262~rc1**, which wants both. The `pids.max` half is
  `CONFIG_CGROUP_PIDS` missing from `steelhead_defconfig` — a one-line change
  worth folding into the next kernel bump, not worth a kernel OTA alone.
  **What IS ours:** `nexusq-control`'s `_systemctl_user()` uses
  `--machine=user@.host`, which opens a PAM session per call and emits the noise
  288×/day. Measured replacement: `setpriv --reuid=10000 --regid=10000
  --clear-groups env XDG_RUNTIME_DIR=… DBUS_SESSION_BUS_ADDRESS=… systemctl
  --user` — identical answers, **zero** noise lines. Queued as **r38**, behind
  the other session's r37 commit; do not land it on top of r37 unpublished.
- USB host streaming silence into the gadget (~30 % of a core, documented cost)
  is now the largest idle consumer. Host-side, not a device fault.

**🚨 Release-tooling gap, hit for real:** `publish-ota-repo.sh` ships the newest
build of every listed package from the shared volume, so publishing
`nexusq-mqtt` r5 also published another session's unapproved `nexusq-control`
r37. Rolled back in minutes (apk parked in
`packages/edge/armv7/.held-unapproved/`, gh-pages `43173cd` back to r36, no
device took it), but a Q that ran `apk update` inside that window then failed
its next upgrade with `HTTP 404` until `apk update` was re-run. Nothing can
currently express "built, not approved" — fix candidates in the dated note.

---

## Open — the USB audio A/B that needs audio actually playing

Device **r95** bounded the delay (the cushion that had grown to 243 ms) and the
Prague Q is at 57 ms after the restart. What is *not* fixed is why the hop
underruns in the first place: `alsaloop --sync=simple` corrects no clock
difference between the async USB gadget and the timer-clocked snd-aloop.

Two corrections exist on this hardware and **neither has been seen working**, so
neither is the default:

| candidate | control | idea |
|---|---|---|
| `captshift` | `UAC2Gadget` → `Capture Pitch 1000000` | the USB async feedback channel: ask the host to adjust |
| `playshift` | `Loopback` → `PCM Rate Shift 100000` (80000..120000) | adjust the virtual card we own |

Probing them without audio proves nothing: alsaloop prints the same "Opened PCM
element Capture Pitch" line under every mode including `simple`, and an
aloop→aloop rig leaves the rate shift at 100000 because both its ends share one
timer.

**To run it** (needs the Xiaomi box actually playing — adb to it is unauthorized
from the desktop, the dialog has to be accepted on the TV):

```sh
systemctl --machine=user@.host --user set-environment NQ_UAC2_SYNC=captshift
systemctl --machine=user@.host --user restart nexusq-uac2-in
# watch the control move off centre while the host streams:
watch -n2 'amixer -c UAC2Gadget cget numid=1 | grep ": values"'
# and whether Buffer Latency stops climbing across a long session
```

Repeat with `playshift` (`amixer -c Loopback cget numid=1`). Whichever holds the
loop steady without the cushion climbing becomes the default in r96; if neither
does, the ceiling stays the answer and that is worth writing down too.

Also still open: the **Roon hop keeps its old uncapped module** until
`roon-nexusq` next starts (it was at 347 ms against 250). Harmless for music —
there is no picture to sync to — so it was left rather than restarting Roon.

## ✅ done 2026-09-06 — app 1.18.1 is out on BOTH tracks, and iOS moved off the MacBook

This section used to hand the iOS half to the MacBook. It is not needed: the
build was cut on the **Proxmox macOS VM 108** instead, and that is now the
normal way.

- **Android**: `app-v1.18.1` + `nexusq-companion-1.18.1.apk`,
  `companion/app-release.json` → 1.18.1 / 52 (live on raw.githubusercontent).
- **iOS**: build **52** uploaded from VM 108, `VALID` in App Store Connect
  (Delivery UUID `ca293ef3-5e84-4d15-995a-bad1cee3c505`), TestFlight group
  "Internal".
- **Bridge**: `nexusq-control` r37 on gh-pages and on the Prague Q, theme
  persistence verified on the box.

**Anyone can cut an iOS build now** — use the `nexusq-ios-release` skill/agent.
It costs Petr his Windows VM for ~10 minutes (they share RAM) and puts it back.
The VM was bootstrapped on 2026-09-06 and keeps its state, so a later run is
just: swap the VMs, pull, build, upload, swap back.

Still not verified by a human, and needing a phone rather than a machine:
Spotify control end to end, and the first run on a real iPhone (52 is the first
TestFlight build that carries the picker).

## Desktop (petronijus-PC) — 2026-08-31: v1.15.0 SHIPPED

Both steps this section used to list are done, so it is trimmed to what is still
live. **v1.15.0 is published** (mainline 6.18 LTS, cross-native build), the
cross-native kernel **booted** on the Prague Q, and the `k618b` perf study came
back clean — no regression, and the earlier "regression" turned out to be the
collector's own ssh polling. Full record:
`docs/2026-08-31-kernel-6.18-lts-and-the-rollback-that-disarmed-itself.md`.

**Still open, and none of it is a blocker for what shipped:**

- **Ethernet after a cold power-cycle is unverified on 6.18.** Patches
  0006/0008/0012 exist for exactly that path and it only proves itself cold, with
  a cable. HDMI, fastboot-over-ssh (0044), USB-host re-probe and USB Audio are
  likewise unexercised.
- **Kernel OTA itself has been running safely in the field** (Petr, 2026-09-01) —
  the trial-slot flow with its health gate is not the shaky part, and nothing here
  should be read as a warning against using it.
  The narrower open item is the **rollback's module-restore path** (`nexusq-kernel-ota`
  r4): it only executes when a trial kernel actually fails and gets rolled back, so
  a run of good OTAs — however long — cannot exercise it. Still unproven rather
  than suspect.
- **The app cannot offer a kernel update.** `checkSystemUpdate` filters the kernel
  out — correctly, since apk must never apply one — so a kernel reaches a device
  only via `nq-kernel-ota` over ssh. A proper fix gives the kernel its own track.
  Rationale and consequence are written into `nexusq-control` at `_KERNEL_PKG`.
- ~~**Šumperák** still trusts a different signing key and cannot OTA at all.~~
  Resolved 2026-09-05 (fleet key installed, r92 + 6.18.48 over the air).

**Two live traps worth keeping in front of anyone touching this:**

- 🚨 **`172.16.42.1` is the Lumia, not the Q.** Both projects share the USB-gadget
  subnet, and `nqctl` auto-mode tries USB *before* WiFi. It also reports the Q
  unreachable when OPNsense is down, because it resolves the WiFi lease through
  it. `hostname` first, always. The Q lives at **192.168.20.246**.
- 🚨 **One build at a time on `nexusq-workdir`, across all sessions.** A second
  build zaps the first one's chroots mid-compile and the victim sees a *fake
  toolchain error*. `docker ps` before starting anything.

## Desktop (petronijus-PC) — the 6.18 bump: lessons worth keeping

⚠️ This section used to read *"the 6.18 kernel rebase is done but UNBUILT"* and
carried a **Resume here** checklist. All of it shipped in **v1.15.0** on
2026-08-31 — the rebase is in git, the kernel is built, booted and published, and
the patch stack is at 6.18.48. The checklist is deleted rather than corrected: a
todo list that describes finished work sends the next session to redo it, and its
`6.12.12` references made the repo look like it was still on the old kernel.

What is kept below is the part that outlives the bump and applies to the **next**
one (the following LTS is due around Nov/Dec 2026). Full record:
`docs/2026-08-31-kernel-6.18-lts-and-the-rollback-that-disarmed-itself.md`;
current state in memory `kernel-618-rebase-result`.

### Found at build time (2026-08-31)

- **Three patches applied with zero fuzz and still did not compile** against 6.18:
  0005 and 0029 (upstream constified the sysfs `bin_attribute` API) and 0007
  (upstream migrated clk from `.round_rate` to `.determine_rate(hw, req)`, and
  git's 3-way merge planted our body into the new signature, where the old
  parameters no longer exist). All three are fixed and compile-verified.
  **A clean `patch` apply says nothing about compiling** — the GNU-patch gate is
  necessary, not sufficient, and it cannot see a 3-way-merge hazard like 0007.

  **Pre-flight before booking the shared build volume**, which catches all of them
  in one pass in ~102 s with no docker and no volume:

  ```sh
  cd ~/nexusq-build/kstack/linux            # the patch stack, branch `steelhead`
  export ARCH=arm CROSS_COMPILE=~/Documents/Dev/nexusQ-reloaded/build/\
  arm-gnu-toolchain-13.3.rel1-x86_64-arm-none-linux-gnueabihf/bin/arm-none-linux-gnueabihf-
  cp ../../../Documents/Dev/nexusQ-reloaded/kernel/configs/steelhead_defconfig .config
  make olddefconfig && make -j"$(nproc)" all
  ```

  ⚠️ **A green build here is NOT proof the shipped kernel is good.** This is
  arm-gnu 13.3 against glibc headers; the kernel actually ships built with Alpine
  gcc 15.2.0 for musl. It is a fast *API-drift* gate, nothing more — the real
  build still has to run, and the device still has to boot it.
- **Only one build may run on this machine at a time**, across all sessions — see
  memory `build-volume-is-single-writer`. A second build zaps the first one's
  chroots mid-compile and the victim sees a *fake toolchain error*
  (`cannot execute cc1: posix_spawn`). `docker ps` before starting anything.
- **`sha512sums` must be trimmed alongside `source=`.** Dropping 0004 and 0032
  from `source=` while leaving their `SKIP` lines aborts abuild with
  "Number of checksums(96 / 2) does not correspond to number of sources(46)".

### A patch worth sending upstream

Mainline's `tas571x_coefficient_info()` **still** sets
`uinfo->value.integer.max = 0xffffffff`, which is `-1` in a 32-bit `long`, so
every biquad coefficient write is clamped. That is our patch 0046. As of 6.18.48
it is unfixed and now also reaches TAS5717/5719 and the newly added TAS5733 on
every 32-bit host. Small, clean, defensible — worth a post to ASoC.

Full state: memory `kernel-618-rebase-result`.

---

## MacBook — 2026-08-30: you can cut releases here now, after one command

The fleet signing key **is installed** (2026-08-31, `scripts/install-fleet-signing-key.sh`;
`pmos@local-6a93112c` retired, `pmos@local-6a42e957` verified byte-identical to
`pmos/ota-signing-key.rsa.pub`). This machine can cut releases — the gates all
work on macOS, see HANDOFF.md → "macOS specifics".

**The volume is seeded (2026-09-05).** The packages that were sitting in
`nexusq-workdir`'s `packages/edge/armv7` had been built with the *old* key
(`device-google-steelhead` r87–r89, `linux-google-steelhead-6.12.12-r52`,
`nexusq-control` r35, `nexusqd` r17, …); `publish-ota-repo.sh` would have
re-signed a fresh index over them and `apk upgrade --available` would have failed
on every Q. `scripts/seed-ota-volume.sh` replaced them with the published
fleet-signed apks (`seeded=11 retired=7`; the old ones are in
`.retired-pmos@local-6a93112c/`, not deleted). An `OTA_PACKAGES_ONLY=1` publish
from here is safe now — and `publish-ota-repo.sh` refuses any foreign-signed apk
by name, so it cannot silently stop being safe.

**Trust reconciled too (2026-09-05, later the same day).** The seed alone was not
enough: the volume *signed* with the fleet key but still *trusted* only the
retired one — pmbootstrap 3 keeps trust in `config_apk_keys/`, filled once at
first init — so the first build died at abuild's index update with `UNTRUSTED
signature`. `install-fleet-signing-key.sh` now reconciles that on every run and
did here: trust installed, 1 key retired, 13 stale apks parked.

**This MacBook IS a release machine now.** `v1.15.2` was cut from here end to
end: full `PUBLIC_RELEASE=1` build in 13.5 min, `verify-rootfs.sh` 29/29 (see
HANDOFF "macOS specifics" for the `--entrypoint bash` form — the older recipe
there was wrong), assets + OTA publish (gh-pages `62e418a`), parity 13/13, both
units upgraded from it the same evening. The only macOS-specific fix it needed
was `544ef09` (the release scripts used bash-4 `mapfile`; macOS ships bash 3.2).

## Any machine that will publish OTA — two checks, once

1. **`scripts/install-fleet-signing-key.sh --check`** — since 2026-09-05 this also
   reconciles *trust* (`config_apk_keys/`), not just the signing key, and parks
   foreign-signed apks. **Desktop: run it once** — expected to be a no-op, but the
   trust dir there has never been checked against the fleet key explicitly.
   (Todoist → AI-handover task exists for this.)
2. **`scripts/seed-ota-volume.sh`** before the first `publish-ota-repo.sh` (and
   after any long gap in building). It reads the published index, downloads and
   signature-checks each apk, and places them in the volume so an OTA-only build
   does not publish stale or foreign-signed packages for everything it did not
   rebuild. Idempotent; on the desktop, which has built everything itself, a
   no-op that says so.

Record: `docs/2026-09-05-six-days-dark-and-the-ota-that-renamed-the-cottage.md` §3.

---

## Šumperák Q — ✅ done 2026-09-05

This section used to say *"cannot OTA at all, needs someone on site"*. Someone was
on site: the fleet key is in its `/etc/apk/keys`, it is on **v1.15.2** (device
r93, kernel-ota r5, kernel 6.18.48-r0, upgraded over the air at 19:16 CEST) with
its own identity restored, on DHCP as `nexus-q-sumperak.local`. Nothing left to do
on the other machines for it.
