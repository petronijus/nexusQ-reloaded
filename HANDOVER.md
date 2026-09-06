# Cross-machine handover

Steps that were done on ONE machine but have to be done on the others before the
project works there. Delete a section once its steps are done on that OS.

`HANDOFF.md` is the session log — what happened and why. **This file is the todo
list for the other machines.** Matching tasks live in Todoist → **AI-handover**.

---

## Desktop (petronijus-PC) — 2026-09-06 evening: the Prague Q is warm — Roon idle guard stuck awake

Written on the MacBook from a **read-only** diagnostic (`nexusq-diag`, capture
`nq-captures/20260906-160616/`). Nothing on the device was changed; Petr picks
this up on the PC. The box is `steelhead.local` / **192.168.20.246**, device r93,
kernel 6.18.48-r0, up since Aug 31 23:14.

### What is wrong (verdict)

The die is **not** hot — 67 °C average over the last 16 h, board sensor 49 °C,
zero throttling this boot, exactly the idle floor documented for this hardware.
The enclosure is warm because **the Roon path has been "awake" for 4.75 days
with nothing playing**: the TAS5713 amplifier has been powered the whole time
and PulseAudio has been resampling silence around the clock. Load average sits
at ~1.0 all night instead of the healthy 0.1–0.2.

| symptom | evidence |
|---|---|
| `roon_in` source **RUNNING** while the producer is closed | `pactl list sources` vs `/proc/asound/RoonLoop/pcm0p/sub0/status = closed` |
| amp sink never idles | sink-input #4 "Loopback from RoonBridge" `Corked: no`; `alsa_output.platform-sound-tas5713` RUNNING, TAS5713 PCM open since uptime 80541 s = **Sep 1 21:37:01** |
| amp physically on | `gpio-12 pdn out hi` (active-low → not powered down), Speaker Switch on, PVDD consumers active; sink at −33 dB so nothing audible |
| CPU burned in silence | pulseaudio ~21 % of a core (10 % of it in libspeexdsp resampling a 48003 Hz silent loopback), nexusqd's `arecord` tap ~7 % (its gate counts uncorked sink-inputs) |
| guard asleep on paper | `nexusq-roon-idle.service` (user unit, `NQ_WATCH_MODE=producer`) logged `producer idle -> source suspended` once at **Aug 31 23:15:45** and nothing since |

**Trigger:** Sep 1 21:37 is the moment the Roon loopback module was reloaded
live from a root ssh session on `192.168.20.150` (the r92 `source_dont_move` fix,
see `docs/2026-09-01-loopback-source-stolen.md`). Reloading the module resumed
`roon_in` from outside the guard. The guard never saw the producer open, so it
never re-issued the suspend, and it has trusted its own `asleep` flag ever since.

### The bug, precisely

`pmos/device-google-steelhead/nq-uac2-silence`, `Watcher.run_producer()`
(~line 338): while `self.asleep` is true the loop only reacts to the producer PCM
*opening*. It never checks whether the PA source it believes suspended is
actually suspended. Any external resume — a module reload, `pactl
suspend-source roon_in 0`, `nexusq-control setOutput` re-routing, a PA restart
that loses the suspend — leaves the source running forever. The USB path
(`NQ_WATCH_MODE=silence`) does not have this hole, because there the reader
itself notices audio; the producer mode reads nothing.

### Steps on the PC

1. **Immediate relief, on the device** (either line; the amp should idle within
   ~a minute and the load drop to ~0.2 — check with `uptime` and
   `cat /sys/class/thermal/thermal_zone0/temp` after ten minutes):
   ```
   ssh root@steelhead.local "systemctl --machine=user@.host --user restart nexusq-roon-idle.service"
   # or: ssh root@steelhead.local "su - user -c 'pactl suspend-source roon_in 1'"
   ```
   Then confirm `pactl list sources short` shows `roon_in … SUSPENDED` and
   `/proc/asound/card2/pcm0p/sub0/status` (tas5713) reads `closed`.
2. **Fix the guard properly** (no workaround, no restart timer): in
   `run_producer()`, while asleep, verify the real source state on every poll
   (or every Nth poll) — the `_cli` PA socket it already holds can answer
   `list-sources` (look for `state: RUNNING`/`IDLE` on `roon_in`), or subscribe to
   PA source events — and re-assert `suspend(True)` whenever the source is found
   running with the producer closed. Log it as its own event (`source resumed
   behind our back -> re-suspended`) so the next occurrence is visible. Consider
   the same self-check on the wake path (`suspend(False)` failing silently).
3. Bump `device-google-steelhead` pkgrel (r94), build + OTA-publish from the PC
   (`scripts/install-fleet-signing-key.sh --check` first — the standing Todoist
   task), upgrade both units, CHANGELOG entry, and a dated `docs/2026-09-06-…`
   note (the diag report text is in the capture dir).
4. **Verify it holds:** reproduce the trigger on purpose — `pactl suspend-source
   roon_in 0` while Roon is idle — and watch the guard put it back to sleep.

### Also seen, lower priority

- **USB host streams silence into the UAC2 gadget** — `musb_irq_work` ~1 kHz ≈
  30 % of a core, `alsaloop` running, `Capture Rate = 48000` held by the host
  since Sep 1 22:27. Known and documented cost
  (`docs/2026-08-24-usb-audio-idle-cost.md`), not a fault; the USB guard itself
  works (last `silent -> source suspended` Sep 4 23:32). Still the largest single
  consumer once the Roon leak is fixed.
- **Journal noise after systemd 262** (Sep 5 upgrade): every login and every
  5-minute `nexusq-control` poll (`systemctl --machine=user@.host --user`,
  `userspace/nexusq-control/nexusq-control` ~line 520) emits
  `systemd-coredumpd.service: Skipped due to 'exec-condition'` / `Dependency
  failed for Kernel Core Pattern Register` / `Failed to read pids.max`.
  `coredumpctl` is empty — nothing crashes; `systemd-coredump
  --check-requirements` fails on this image. Packaging-side; a PAM session and a
  transient unit every 303 s is also worth trimming.
- **HA telemetry shows the wrong unit.** `sensor.nexus_q_*` in Home Assistant
  went unavailable Sep 3 12:29 and since **Sep 5 17:44** carries a box with
  uptime <1 d and a 47–59 °C die — that is the cottage Q, not Prague (5.7 d,
  67 °C). Prague's `nexusq-mqtt` is alive (`node nexusq_f88fca2048e1`, connected
  since boot). Either the cottage OTA of Sep 5 publishes into the same HA device
  (prefix / node_id collision — see memory "Two Nexus Q on MQTT" and
  `userspace/nexusq-mqtt/nexusq-mqtt` discovery config) or Prague's discovery
  broke in HA on Sep 3. Until sorted, `ha-opp-window.py` reads the cottage.
- `vdd_mismatch` warns: 12 in 5.7 days, isolated singletons ~10 h apart — the
  documented sampling race, not a power fault.

### Untouched and healthy, for the record

nexusqd + LED ring alive (watchdog fine, 0 restarts), WiFi −22 dBm on 5 GHz with
no heals since Sep 1, BT up, VDD_MPU tracks the OPP exactly, `time_in_state`
87 % at 350 MHz / 0.4 % at 1.2 GHz, dmesg clean, pstore empty, no cooling-device
activity ever.

---

## Desktop (petronijus-PC) — 2026-09-06: pick up the companion app (1.18.1 unreleased)

Written on the MacBook at the end of the 2026-09-05/06 session; Petr continues on
the PC. Everything is on `main` (`fe6d56a`), nothing is stashed or local-only.

### Where things stand

| track | state |
|---|---|
| device image | **v1.15.2** released (device r93, kernel-ota r5, kernel 6.18.48-r0); both Qs on it + `nexusq-control` **r36** (OTA-only, 2026-09-05 evening) |
| companion app | **1.18.0+51 released on both tracks** (`app-v1.18.0` + `app-release.json`; TestFlight build 51). **1.18.1 is UNRELEASED**: two fixes committed after it, see below |
| cottage Q | back online since 2026-09-05, DHCP + `nexus-q-sumperak.local`, identity restored, on the same software as Prague |

### 1.18.1 — what is in `main` and not yet shipped

1. **Updates survive leaving Settings** (`lib/update/update_coordinator.dart`,
   commit `bfe0bc6`): the flows are owned per client, Settings only renders them,
   the home app bar spins while anything is in flight.
2. **Several Nexus Qs → the first screen lists them and you pick** (commit
   `fe6d56a`): `discoverNexusQAll` (Android multicast_dns / iOS Bonjour
   `discoverAll`), the connect gate lists devices as they resolve, one auto-joins,
   several wait for a tap, "Switch Nexus Q" in the home app bar.

Both: `flutter analyze` clean, **122/122 tests**, Android + iOS build. CHANGELOG
`[Unreleased]` already carries both entries under "app 1.18.1, unreleased".

### To release 1.18.1 from the PC

1. `git pull`; in `companion/app`: `flutter pub get` (four new packages since
   1.17.3: `url_launcher`, `app_links`, `http`, `crypto`).
2. Bump `pubspec.yaml` to `version: 1.18.1+52`, commit.
3. **Android** (works on the PC): `./build-apk.sh --release` — it reads the Spotify
   client ID from 1Password item **"Spotify API key"**, field `client ID`
   (`op` signed in; otherwise the build says "not configured" and Spotify control
   is off in that build — do not ship that). Then `gh release create app-v1.18.1`
   with `nexusq-companion-1.18.1.apk`, bump `companion/app-release.json`
   (`version`, `versionCode` 52, `notes`, `apkUrl`), commit + push.
4. **iOS — NOT possible on the PC.** Rule since 2026-09-05: an app release is both
   tracks. `companion/app/release-ios.sh` needs the MacBook (distribution
   identity + profile are in its keychain; see HANDOFF "iOS / TestFlight") or the
   Proxmox macOS VM 108 after a signing bootstrap there (KP's `ios-release-vm`
   skill describes the VM dance; it shares RAM with the Windows VM). If you ship
   Android from the PC, **write the iOS half into this file as an open MacBook
   step** rather than calling 1.18.1 released.
5. CHANGELOG: rename the two "app 1.18.1, unreleased" headings to released.

### Not yet verified by a human — do these first when a phone is at hand

- **Spotify control end to end** (1.18.0): play Spotify to a Q → Settings →
  *Spotify account* → Connect (browser → back into the app via
  `nexusq://spotify-callback`) → pause from the phone. Petr's Spotify developer
  app has the redirect URI; development mode admits only allow-listed users;
  control needs Premium. Errors surface as SnackBars — report the exact text.
- **The first real-iPhone run** (TestFlight build 51): Keychain access group,
  Bonjour discovery, and now the Spotify redirect on iOS are simulator-verified
  only.
- The picker with two live Qs on one LAN has been exercised only by the widget
  tests; the cottage and Prague units are on different networks.

### Still open in the device software (unchanged, for the record)

- AirPlay / Roon transport: the bridge has no backend, `transport = none`;
  shairport-sync 5.1 on the Q is built with metadata + MPRIS (the intended
  AirPlay route). See `docs/2026-09-05-six-days-dark-…` open list.
- The `status=127` after an in-place systemd upgrade: worked around in control
  r36 (`daemon-reexec` first), cause not explained.
- 122 WiFi heals/day after a runtime MAC change on the cottage unit: hypothesis,
  no controlled test yet; do not change a Q's MAC without a reboot.
- Todoist task for this machine: `scripts/install-fleet-signing-key.sh --check`
  (expected no-op).

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
