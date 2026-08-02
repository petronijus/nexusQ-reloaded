# 2026-08-02 — Full-system OTA (Phase 1) + the glibc-rt package split

Base: v1.11.0 (tagged 2026-07-31); post-v1.11.0 dev line, continuing the same day as
`docs/2026-08-02-device-ota-and-wifi-nogw-heal.md` (the daemon-only OTA milestone).
Commits: `dade0a2` (`feat(build): split the Roon glibc-rt base into its own package`),
`89039dc` (`feat(control): full-system OTA — checkSystemUpdate/installSystemUpdate (r21)`),
`459f811` (`fix(control): system-OTA reboot detection, spinner, green (r23)`),
`f5b12d1`/`3e4ad63`/`d91de3b`/`7b0c5a2`/`59f8e8f` (app 1.10.0 → 1.11.0). OTA repo now
serves `nexusq-control` **r25**, `nexusqd` **r11**, `device-google-steelhead` **r62**.
Companion app **1.11.0** (`versionCode 28`, own track). Reflashed to **v1.11.9**.

## Why: the daemon-only OTA couldn't ship the device config

The prior milestone OTA'd only the four small daemons. The whole-appliance "apt
upgrade" (base musl/systemd/python + our config + daemons) was blocked because
`device-google-steelhead` was **~191 MB** — it baked the unpacked Debian-bookworm
armhf glibc-rt Roon sandbox base (`/opt/glibc-rt`, ~180 MB) — over GitHub Pages' 100 MB
per-file limit, so the config apk could not live in the OTA repo.

## 1. glibc-rt package split (commit `dade0a2`)

Moved `/opt/glibc-rt` out of `device-google-steelhead` into a **new standalone aport
`pmos/nexusq-glibc-rt`** (`pkgver 1.0-r0`, versioned independently — it is a pinned
static base, not tied to the device-config pkgrel). `device-google-steelhead` (now
**r62**) simply `depends=` on it; the base arrives via the dependency and is baked into
the flashed image exactly as before.

- **device-config apk dropped from ~191 MB → 58 KB** — now under the 100 MB OTA limit
  and OTA-shippable.
- `nexusq-glibc-rt` (still ~182 MB) stays **FLASH-ONLY** — deliberately kept out of the
  OTA repo, and not bumped, so an `apk upgrade` never touches it.
- `docker-build.sh` updated to build it as a device dependency: Phase 2 validate,
  Phase 6 copy loop, Phase 7b checksum. It is kept OUT of the `--force` list so its
  180 MB isn't re-unpacked on every build.
- `scripts/publish-ota-repo.sh` now also ships `device-google-steelhead` + its
  `device-google-steelhead-nonfree-firmware` subpackage (both < 100 MB after the split),
  with a **size guard that refuses to publish any apk ≥ 99 MB** so a mistaken big apk
  can never break the push. `nexusq-glibc-rt` and the kernel stay flash-only.
- **Verified on-device** after a reflash to **v1.11.9**: `/opt/glibc-rt` intact and
  owned by `nexusq-glibc-rt` (ld-linux-armhf present, `asound.conf` = `pulse`,
  10000:10000 owners), Roon not regressed, full diag clean.

### ⚠️ The split needs ONE reflash to adopt
A pre-split device cannot OTA `device-google-steelhead` r62 — it would need
`nexusq-glibc-rt` (flash-only) and `apk` would refuse the unsatisfiable dependency.
So the split package layout is established **once, by a reflash** (v1.11.9, done this
session via fastboot-over-ssh — see below). After that, system OTA of the config is
incremental like everything else.

## 2. Full-system OTA — checkSystemUpdate / installSystemUpdate (control r21 → r25)

PROTOCOL **§12b**: the "apt upgrade" of the whole appliance, distinct from the daemon
track (§12a `checkNexusUpdate`/`installNexusUpdate`).

- **`checkSystemUpdate`** — `apk update`, then reports **every upgradable package**
  parsed from `apk version -l '<'`, **MINUS the kernel**, plus the running kernel
  version read-only (`uname -r`). Installs nothing. Returns
  `{packages:[{name,installed,available}], updateAvailable, kernel, repo}`. Unlike the
  daemon check it does **NOT** blink the mute LED — that stays the daemon-"available"
  indicator; the system check only feeds the app's *System* card.
- **`installSystemUpdate`** — `apk upgrade --available` across the system **EXCEPT the
  kernel** (`_KERNEL_PKG = linux-google-steelhead`): no repo the device reads offers a
  newer kernel, and applying a kernel is a boot-partition flash = **Phase 2, not done**.
  Base musl/systemd/python come from the Alpine·pmOS mirrors; our config/daemons from
  the OTA repo. Guarded by the same `_nexus_install_lock` (`Err "busy"` on a concurrent
  install). Returns `{ok, changed, daemons, rebootRecommended, output}`.
- **Reboots when base libc/init churned** — `rebootRecommended` is set when any changed
  package name starts with `_REBOOT_HINTS = (musl, systemd, kmod, eudev, busybox,
  openrc)`; `_finish_system_update` then flashes green and `systemctl reboot`s (staying
  green so the last thing seen is success; the app reconnects when the Q is back).
- **Proven live:** it upgraded **systemd 261.1 → 261.2** + base packages on the
  reference Q.

### r23 — three real bugs found in testing (commit `459f811`)
1. **Reboot detection was silent.** apk-tools writes its `(N/M) Upgrading <name>`
   progress lines to **STDERR**, not stdout, so the old stdout-only parser saw nothing
   and `rebootRecommended` never fired on a systemd/base bump. New **`_apk_changed(r)`
   reads BOTH streams** (`r.stdout + r.stderr`); the daemon-track parser now uses it too.
2. **The determinate bar looked "stuck at ~92 %."** A full-system upgrade is slow and
   of unknown length (downloads + triggers like mkinitfs), so `_OtaProgress`' soft cap
   (92 %) sat there looking frozen. The system install now uses the **INDETERMINATE
   spinner** (`spin 0 153 204 2`, fast blue) which keeps moving the whole time; green
   `set 0 255 0` stops it on success. (The daemon track keeps the determinate bar — its
   upgrade is small and short.)
3. **Green now stays lit through the reboot** — `_finish_system_update` does not flip
   back to the theme before rebooting when `rebootRecommended`.

## 3. App Update-UX — companion 1.10.0 → 1.11.0

- **1.10.0** (`f5b12d1`/`3e4ad63`): a **System** section — full-system update UI
  (kernel version + `apk upgrade --available`, reboot-aware verify).
- **1.10.1** (`d91de3b`): grouped the three update options under one **Update** cluster.
- **1.10.2** (`7b0c5a2`): fixed a false **"Something went wrong"** — the OTA check/install
  RPCs were `silent=false`, so the generic error banner fired on the **expected**
  control-bridge restart during an install. They now run **silent** and success is
  confirmed by **verify-by-recheck**.
- **1.11.0** (`59f8e8f`): **MERGED App + Device into ONE "App update" item.** The phone
  app and the on-device daemons version together as the companion system, so the
  three-way App/Device/System split read as odd. Now a single **"App update available"**
  indicator + one Update button covering whichever side is newer (app only / device only
  / both), with **merged release notes**. **Install order = device daemons first, then
  the phone app** (installing the app restarts the phone, so it goes last, onto an
  already-updated device). The **System** (kernel + all packages) item stays separate.

So the Settings **Update cluster is now TWO items**: **App update** (app + daemons) and
**System** (kernel read-only + every package). Manifest `companion/app-release.json` =
`version 1.11.0` / `versionCode 28`.

## 4. Reflash path — v1.11.9 via fastboot-over-ssh

The v1.11.9 image (control r21 + the split) was built and flashed via
**fastboot-over-ssh** (`systemctl reboot --reboot-argument=bootloader`, kernel patch
0044) — no hands-on. This reflash is the **one-time** requirement to establish the split
package layout (see §1); after it, system OTA is incremental. Images built this session:
**v1.11.5 / v1.11.6 / v1.11.7 / v1.11.8 / v1.11.9**.

## State summary

- OTA repo (gh-pages): `nexusq-control` **r25**, `nexusqd` **r11**,
  `device-google-steelhead` **r62** (+ its firmware subpackage) — all now published
  (device config is OTA-shippable after the split). `nexusq-glibc-rt` and the kernel are
  flash-only.
- Device reflashed to **v1.11.9**; `/opt/glibc-rt` owned by `nexusq-glibc-rt`, Roon OK,
  diag clean.
- App track: **1.11.0** (`versionCode 28`).
- Last public tag: **v1.11.0** (2026-07-31) — the v1.11.x dev line is untagged.
- **Phase 2 (kernel over OTA)** remains out of scope: applying a kernel is a
  boot-partition flash, not an `apk upgrade`.
</content>
</invoke>
