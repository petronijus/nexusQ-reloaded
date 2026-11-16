# Cross-machine handover

Steps that were done on ONE machine but have to be done on the others before the
project works there, and what each unit still owes. Delete an item once its step
is done; the history stays in git, `HANDOFF.md` (the session log) and the
CHANGELOG. Engineering work in the tree lives in `PLAN.md`, not here.

Rewritten 2026-11-15: every section before it described finished work (v2.0.0
to v2.1.1, the 6.18 bump, the persist store, the fleet key) and was deleted;
what was still open in them is below.

---

## State of the units — 2026-11-15

| | Prague Q (`steelhead`, 192.168.20.246) | Cottage Q (`nexus-q-sumperak`, cottage LAN only) |
|---|---|---|
| release | v2.1.2 + its first OTA job (2026-11-15 23:00: 254 packages, apk-tools 3.0.9, systemd 262.2) with control r73, mqtt r18, rootfs-ab r7 by hand; device r132; rootfs slot B committed | v2.1.2, upgraded 2026-11-14 from r117 (the upgrade the 600 s timeout cut, then finished by hand) |
| kernel | 6.18.48-r33 | not recorded on 2026-11-14 — read `uname -r`; v2.1.x wants r33 through `nq-kernel-ota` |
| reach | LAN, USB gadget `172.16.43.1`, eth-direct `10.42.0.2` | only from the cottage LAN; the Tailscale hop wants a password not in 1Password |

In the tree and **not released**: `nexusq-control` r69 to r73, `nexusq-mqtt`
r18, `nexusq-rootfs-ab` r7 (on the Prague Q only), `device-google-steelhead`
r133 and `librespot` 0.8.0-r100 (on no unit, unbuilt: rust skew, PLAN)
(CHANGELOG `[Unreleased]`); app 1.27.1, 1.28.0+70 and 1.28.1+71
(the last released app is 1.27.0). The order they take to the units is in
`PLAN.md`: the Prague Q first, never the cottage Q first.

## Prague Q

- [ ] **Not yet checked: AirPlay on shairport-sync 5.5.x.** The next time
      AirPlay is used, confirm from data: a `shairport-sync` sink-input appears,
      no XRUN in dmesg, Now Playing in the app, a volume move lands where
      `airplay_attn_cdb` predicts.
- [ ] Do not read `/proc/tty/driver/*` on a unit: it hung the Prague Q hard
      (RCU stall on CPU0, 2026-10-12) and is not understood yet.

## Cottage Q (needs someone on the cottage LAN)

- [ ] Record its apk state for the OTA install gate:
      `scripts/capture-unit-apk-state.sh root@<its address> nexus-q-sumperak`
      (into the gitignored `private/units/`; the gate then simulates its own
      System update before every publish). Until then only the Prague Q and
      the newest image are checked.
- [ ] Kernel: `uname -r`; if it is older than r33, `nq-kernel-ota stage-latest
      && nq-kernel-ota try` with someone in reach, then read
      `journalctl -u nexusq-kernel-ota-promote` (the first real run of
      kernel-ota's `prune` at promote).
- [ ] Delete Prague's `wifi-svatovitske-internety-5g.nmconnection` and the two
      `.bak` copies of its own profile from the persist store
      (`/var/lib/nexusq/persist/nm-connections/`, via the trash) — once the
      Prague PSK is rotated (Todoist AI-handover, p1) this copy is stale anyway.
- [ ] Home Assistant: the Šumperák section of the "Nexus Q" dashboard has no
      theme / visualisation selects; its mqtt was r10 then. The unit runs v2.1.2
      now, so the entities exist: add them like Prague's.

## Needs a phone at a Q (never run, not testable from a desk)

- [ ] **The one-volume test** (Petr wants to drive it): the Prague Q at
      10-30 %, Petr drives Spotify, the app, the dome and an iPhone over
      AirPlay; watch the sink, the bridge's events and the librespot /
      shairport / `AirPlayVolumeFollow` logs. First question: after the dome
      moves the volume, does the Spotify app show the Q's level on connect, or
      only after the next play (`docs/2026-09-27-one-volume.md`)?
- [ ] AirPlay from an iPhone: the iPhone slider moves the Q; the app's slider
      moved during the session moves the iPhone's after ~1 s (MPRIS SetVolume
      → DACP) and the Q does NOT move on the echo (`airplay: SetVolume failed`
      in `journalctl -u nexusq-control` if not).
- [ ] Spotify **control** end to end (Settings → Spotify account → Connect,
      then pause from the phone; Premium, allow-listed account).
- [ ] iOS: a background refresh (Xcode: Debug → Simulate Background Fetch)
      posts the release notification.

## The companion app in the stores

- [ ] **Google Play** (developer account on Petr's gmail): closed release 69
      was submitted for review 2026-10-11. Once approved, Petr gathers testers
      into "Nexus Q Reloaded testers" and sends the opt-in link; a **closed
      test with 12 testers for 14 days**, then apply for production. Petr
      confirms each submission.
- [ ] **Android developer verification** (Play Console, left menu): register
      the GitHub APK's package name and our signing key, or certified devices
      stop installing the sideloaded app where it applies.
- [ ] **iOS** to the App Store through VM 108 (`nexusq-ios-release`), Petr's call.
- F-Droid is on hold: it refuses the original Google assets; the fdroid flavor
  needs free art first, then an `fdroiddata` merge request (Petr's GitLab).

## Machines

- [ ] **Ubuntu (petronijus-PC) and the MacBook, the first time a Q is on the
      cable** (the gadget is `172.16.43.1` since device r120; `172.16.42.1` is
      the Lumia): `git pull`; on Ubuntu the `nmcli con add` of INSTALL.md §4; on
      macOS give the RNDIS/ECM interface `172.16.43.2/24` (or rely on the Q's
      DHCP); `ssh-keygen -R 172.16.42.1` if that entry was the Q's. Omarchy
      (desktop): done.
- [ ] **Windows:** rerun `scripts/install-gadget-rndis.ps1` elevated (picks the
      adapter by the Q's MAC, assigns `172.16.43.2`). The checks (`just`) are not
      set up there.
- **Any machine that will publish OTA**, once and after a long gap:
  `scripts/install-fleet-signing-key.sh --check` (signing key and trust), then
  `scripts/seed-ota-volume.sh` before the first `publish-ota-repo.sh`. The
  desktop and the MacBook are release machines.

## Decisions and loose ends without a home in PLAN

- [ ] **Runtime hardware watchdog**: not armed on the units
      (`RuntimeWatchdogUSec=0`); a kernel-side GPU hang would not recover.
      Petr's decision.
- [ ] **Prague's NTP**: since device r102 the gateway is out of the fleet-wide
      list; a per-site drop-in needs runtime site detection first (the private
      overlay bakes into the one fleet package). Only costs the WAN-down case.
- [ ] **Release tooling**: `publish-ota-repo.sh` ships the newest build of every
      listed package on the volume; nothing expresses "built, not approved"
      (it published an unapproved control r37 on 2026-09-06, rolled back).
      `docs/2026-09-06-two-spheres-one-topic-and-a-log-that-cried-wolf.md`.
- [ ] **The app cannot offer a kernel update** (`checkSystemUpdate` filters
      it, correctly); a kernel reaches a unit only through `nq-kernel-ota`
      over ssh. Fix: give the kernel its own track (`_KERNEL_PKG` in
      nexusq-control).
- [ ] Unexercised on 6.18: ethernet after a cold power-cycle (patches
      0006/0008/0012), HDMI, fastboot-over-ssh (0044), and kernel-ota's
      rollback module-restore path (runs only when a trial kernel fails).
- [ ] Test nits from `just ci` (no fault): `companion/app/test/eq_card_test.dart:954`
      taps "Reset to flat" at an off-screen offset;
      `pmos/device-google-steelhead/tests/test_uac2_silence_producer.py:190`
      leaves a file open (ResourceWarning).
- [ ] Upstream: mainline `tas571x_coefficient_info()` still sets
      `max = 0xffffffff` (`-1` in a 32-bit long), our patch 0046 — worth a post
      to ASoC; ask Petr before posting.

## For the next kernel LTS bump (due around Nov/Dec 2026)

From the 6.18 bump (`docs/2026-08-31-kernel-6.18-lts-and-the-rollback-that-disarmed-itself.md`):

- A clean `patch` apply says nothing about compiling: 0005, 0029 and 0007
  applied with zero fuzz and did not build against 6.18 (constified sysfs
  `bin_attribute`, clk `.round_rate` → `.determine_rate`, a 3-way merge that
  planted the old body into the new signature). Pre-flight in ~100 s without
  docker or the build volume:

  ```sh
  cd ~/nexusq-build/kstack/linux            # the patch stack, branch `steelhead`
  export ARCH=arm CROSS_COMPILE=~/Documents/Dev/nexusQ-reloaded/build/\
  arm-gnu-toolchain-13.3.rel1-x86_64-arm-none-linux-gnueabihf/bin/arm-none-linux-gnueabihf-
  cp ../../../Documents/Dev/nexusQ-reloaded/kernel/configs/steelhead_defconfig .config
  make olddefconfig && make -j"$(nproc)" all
  ```

  It is an API-drift gate only (arm-gnu 13.3, glibc headers); the shipped
  kernel is Alpine gcc 15.2 for musl and must still build and boot.
- Trim `sha512sums` together with `source=` (abuild aborts on a count mismatch).
- `CONFIG_CGROUP_PIDS` is missing from `steelhead_defconfig` (the systemd
  `pids.max` noise); fold it into the bump.
- One build at a time on the shared volume, across all sessions: `docker ps` first.

## Measuring the USB audio delay

Only with `usb_in` RUNNING (`pactl list short sources`) and
`/proc/asound/card2/pcm0p/sub0/status` RUNNING: a suspended source reports a
large static latency nobody hears, which produced two wrong answers in
September. Shipped configuration measured 56 ms (2026-09-07), near the optimum.
Nothing is open unless the degradation comes back; then measure it while
degraded.
