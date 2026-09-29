# nexusQ-reloaded — instructions for coding agents

Mainline Linux and postmarketOS on the Google Nexus Q (steelhead, OMAP4460):
a 6.18 LTS kernel with our patches, a systemd rootfs with the device daemons
(LED ring, LAN control bridge, Bluetooth and WiFi setup, MQTT telemetry,
AirPlay/Spotify/Roon playback), an OTA apk repo that updates the units in the
field, and a Flutter companion app. This file is for every coding agent
(Claude Code, Cursor, Codex, …); humans start at `README.md`.

Read `HANDOVER.md` (open work, per machine and per unit) before starting,
`INSTALL.md` before anything that flashes, `companion/PROTOCOL.md` before
touching the app ↔ daemon protocol, and the dated `docs/` note on a subsystem
before changing it — they hold the measurements the code was built on.

## Hard rules

- **Never write the `bootloader` or `xloader` partition** — by `fastboot` or
  any other means. They are the only way to brick a unit; everything else
  reflashes from the release artifacts.
- **Check which host you are on.** The first command on any remote host is
  `hostname`, and it must name the unit (or machine) the task is about. A
  reachable IP proves nothing: addresses have moved between devices.
- **A fix is done when it is in the build.** A change that works live over ssh
  goes into its APKBUILD / `docker-build.sh` in the same session, with a
  `pkgrel` bump; a reflash or OTA wipes anything else. A new file is in
  `source=`, staged by `docker-build.sh` if it lives outside the aport, and
  installed in `package()`; a new package is in `pmos/ota-packages.list`.
- **Stock is the ground truth for hardware.** Before building a kernel, DTS or
  driver fix from a hypothesis, check what the stock Android kernel does
  (`reverse-eng/`, the stock-parity-auditor agent). The hardware is known
  good: an unresponsive chip is our bring-up bug, never "dead hardware".
- **Fix root causes; never mask.** Every boot error and warning on the Q is
  ours to fix. Disabling or masking a unit is a last resort, stated as such.
- **Respect the device.** It has two Cortex-A9 cores: wrap any load you put on
  it in `timeout` and `nice`, never an unbounded loop. Its speakers are driven
  by a 25 W amplifier and someone may be listening: check `pactl list
  sink-inputs` before touching the audio path, and never play test tones.
  Never pair with or connect to Bluetooth/WiFi devices that are not ours.
- **One image build at a time.** The pmbootstrap work volume is single-writer
  (`docker ps` first), and `docker-build.sh` runs only inside the builder
  container (the README has the command).
- **A test must be seen failing** before it counts — revert the fix and watch
  it go red. Host and qemu passes are not device passes.
- All code, comments, docs, logs, commit messages and UI strings are in
  English. Commits carry `petronijus@bastla.com` only.
- Secrets live in 1Password and in the gitignored `private/` overlay (WiFi
  PSK, MQTT login, ssh keys, signing keys); never commit, print or log them.
  Public release images are built with `PUBLIC_RELEASE=1` and pass
  `scripts/release-preflight-no-secrets.sh`.
- Commit or push only when asked.

## Commands

`just` is the entry point for checks; `just` alone lists every recipe.

| Command | What it does |
|---|---|
| `just setup` | install Python 3.14 for the tests, the git hooks, blame's ignore list, the app's packages; run the doctor |
| `just doctor` | check this machine against the pinned toolchain, print every fix |
| `just check` | fast lane (~25 s): formatting and linters, analyzer, Python, C, Dart and host shell tests |
| `just ci` | full gate: `check`, the docker shell suites, the ALSA integration test, the Android build (and iOS on macOS) |
| `just fmt` | format everything (`tools/dev/format.sh`) |
| `just test-py` / `test-c` / `test-dart` / `test-sh` / `test-sh-docker` | one lane |

The image build, flashing and the device side have their own tooling:
`docker-build.sh` in the builder container (full image),
`scripts/build-kernel-boot.sh` (kernel only), `INSTALL.md` (flashing),
`scripts/package-release.sh` (a release: image assets, OTA repo, parity gate),
`scripts/diag/` and `scripts/device-nexus-diag.sh` (on-device diagnostics),
`companion/app/build-apk.sh` (the app for a phone).

There is no hosted CI. `just ci` is the CI, run on the Linux desktop or the
MacBook. A change is done when `just ci` is green — and, when it reaches the
device, when it has been built, flashed or OTA-upgraded and the full
diagnostic sweep (including CPU frequency and VDD_MPU against the OPP) is
clean.

## Layout

```
kernel/        defconfig, DTS and the patch series over mainline (the DTS ships via a patch)
pmos/          the aports: device-google-steelhead, linux-google-steelhead, firmware, one per daemon;
               ota-packages.list (what the OTA repo carries) and the fleet signing key (public half)
userspace/     the daemons: nexusqd (LED ring, C), nq-healthd (C), nexusq-control, -mqtt,
               -btagent, -setupd (Python), nexusq-alsa-vol (ALSA plugin), -kernel-ota, -rootfs-ab (shell)
companion/app/ Flutter companion app (Android + iOS); PROTOCOL.md next to it
scripts/       build, release, flashing and diagnostic helpers; scripts/diag/ the on-device diag tooling
tests/         repo-level tripwires (aport source lists, copies that must stay identical)
reverse-eng/   ground truth extracted from the stock firmware (gitignored, not redistributable)
private/       the personal overlay: access, stock firmware blobs (gitignored, its own repo)
tools/dev/     formatter, shell test runner, commit-msg check, toolchain doctor
docs/          the dated engineering record, one note per finding
```

## Conventions

- Conventional Commits (`type(scope): summary`, ≤ 72 characters), enforced by
  the commit-msg hook. Scopes are the subsystems: `kernel`, `dts`, `device`,
  `control`, `mqtt`, `setupd`, `btagent`, `nexusqd`, `healthd`, `kernel-ota`,
  `rootfs-ab`, `ota`, `build`, `diag`, `app`, `ios`, `android`, `dev`, `docs`.
  Package revisions go in the body or the summary (`(device r121)`).
- Every package change bumps its `pkgrel`; the CHANGELOG entry names the
  revision. The companion app's `version:` in `pubspec.yaml` is its own
  semver track, independent of the image releases, and is bumped for every
  APK handed to a phone.
- Toolchain pins: Flutter 3.47.5, ktlint 1.8.0, ruff 0.16.9 (in
  `tools/dev/format.sh`), Python 3.14 for the host tests (the device's).
  `just doctor` checks them.
- Formatting is automatic (pre-commit hook, and every agent write): ruff for
  Python (`ruff.toml`, 120 columns, target py39 because host tools meet older
  interpreters), `dart format` (tall style), ktlint (`.editorconfig`,
  android_studio), shellcheck for shell (`.shellcheckrc`). C and Swift are
  written by hand in the surrounding style.
- Shell on the device is busybox `sh`: POSIX plus what ash adds. Python on the
  device is Alpine's 3.14 with the packaged modules only; no pip.
- Tests: Python `unittest` (no pytest; the daemons are loaded with
  `SourceFileLoader`), C tests per Makefile, shell suites under `*/tests/`
  (`# needs: docker` in the header puts one in the docker lane), Dart
  `flutter test`.
- Dates are absolute (`2026-09-29`), Europe/Prague.

Details, per-OS setup and troubleshooting: `docs/development.md`.
