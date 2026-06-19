# Session Handoff — 2026-06-19 (continue on Linux)

Snapshot for resuming on the Linux box. Everything below is pushed to GitHub
(`main` + branch `fix/boot-warnings`; proprietary assets in the private overlay).

## Where things stand

### ✅ Plan 1 — LED ring kernel driver `leds-steelhead-avr` — DONE, merged to `main`
Modern mainline-6.12 i2c driver: 32-LED ring + mute as multicolor LED class, batch
`frame` sysfs channel, mute/volume keys via threaded IRQ, AVR-reset restore.
KUnit 4/4; **fully validated live on the device** (ring color + buttons confirmed
by hand). Built as a module, **persisted on the device**: installed in
`/lib/modules/6.12.12/extra/` + `/etc/modules-load.d/steelhead-led.conf`, auto-loads
at boot (verified across a reboot; clean boot, no failed services).
- Source of truth: `kernel/drivers/{steelhead_avr.h,leds-steelhead-avr.c,leds-steelhead-avr-test.c}`, shipped via `kernel/patches/0005-leds-add-steelhead-avr.patch`, enabled in `kernel/configs/steelhead_defconfig` (=m).
- Spec: `docs/superpowers/specs/2026-06-19-nexusq-led-ring-driver-design.md`; plan: `docs/superpowers/plans/2026-06-19-led-ring-kernel-driver.md`.

### ✅ Plan 2 — `nexusqd` daemon (C + postmarketOS aport) — DONE (2026-06-19, on Linux)
Plan: `docs/superpowers/plans/2026-06-19-nexusqd-daemon.md` (C11, no deps, proper musl aport — no shortcuts). All 8 tasks committed + pushed (`0dfac30`→`5bd98d8`).
- **Tasks 1–5** (`userspace/nexusqd/`): `frame`, `themes` (no-dep JSON), `keys` (evdev decode + node scan), `control` (cmd parser), `avr` (sysfs out) + `compositor` (priority layers). `make test` → 4/4 green, 0 warnings (host + cross).
- **Task 6** `nexusqd.c`: idle layer (`0x00385c`), `/run/nexusqd.sock` control, mute key, **inactive priority-10 reaction-layer seam** (Plan 2b). Cross-built static (ARM 13.3) + smoke-tested live: idle/colors/mute confirmed by hand.
- **Task 7** `nexusled` CLI + `nexusqd.service`: socket path + direct-sysfs fallback, both verified live.
- **Task 8** `pmos/nexusqd/APKBUILD` + `docker-build.sh` staging (Phase 2 validate, Phase 6 stage aport+sources→`main/nexusqd`, Phase 7c build+export apk). Autostart enabled declaratively via the `multi-user.target.wants` symlink. **Autostart-after-reboot verified** on device (static functional install: `active`/`enabled`, PID 416 at boot, idle ring confirmed).
- **Fixes made vs the plan code:** `_POSIX_C_SOURCE 200809L` in `nexusqd.c`/`nexusled.c` (else `clock_gettime` etc. hidden under `-std=c11`); `test_keys.c` offsets via `INPUT_EVENT_SIZE` (plan hardcoded 16 → invalid on 64-bit host); guarded `fgets`/`write` returns (0-warnings).
- **Current device state:** **static** `/usr/bin/{nexusqd,nexusled}` + `/etc/systemd/system/nexusqd.service` (works on musl, no deps). When `docker-build.sh` runs, `apk add nexusqd-*.apk` replaces them with the musl build.
- **NOTE — idle color:** the RE doc says true idle is **`#000F14`**, not the plan default `0x00385c`. This (+ pixel-perfect volume/mute) is deferred to **Plan 2b**, the priority-10 reaction layer seam already wired in Task 6.

### 🛠️ Build env on Linux (this box, `petronijus-PC`)
- ARM GNU Toolchain **13.3.Rel1** installed at `/home/petronijus/nexusq-build/arm-gnu-toolchain-13.3.rel1-x86_64-arm-none-linux-gnueabihf/`. Host gcc 15.2 covers the unit tests.
- `pmbootstrap` NOT installed — the Task 8 apk build runs via the Docker pipeline (`docker-build.sh`), not natively.

### 🎯 Volume/mute/idle behavior — REVERSE-ENGINEERED (exact) — `docs/2026-06-19-volume-mute-RE.md`
Deodexed `TungstenLEDService` (`SystemStatusReceiver`) + `LedController`. Headlines:
- **Volume:** whole ring uniform `#0099CC × brightness`, `brightness = 0.1 + (vol/100)*0.9` (brightness encodes volume, NOT an arc/LED-count). 21-frame ×16 ms decelerate fade-in, static hold +350 ms, overlay times out at 1000 ms → ring `#000F14`.
- **Mute:** mute LED `#001E28` (muted) / `#006B8E` (unmuted); ring drops to `#000F14` (not blanked).
- **Idle:** `mDefaultColor = #000F14`; true idle ring is the Visualizer's `ParticleScreensaver` (Plan 3).
This makes the **reaction layer pixel-perfect and concrete** — implement it as the priority-10 compositor layer seam in Plan 2 Task 6 (or a short Plan 2b). No approximation needed anymore.

### 🩹 Boot-warning fixes — branch `fix/boot-warnings` — PENDING A FLASH-TEST
Commit `8b7f1cd` (DTS): fixed the ABE McBSP2 reparent `-22`, disabled unused ti-sysc
modules (HW RNG `0x48091fe0`, HDQ `0x480b2000`); GPTIMER1 EBUSY left as-is. The
`dpll_per_m3x2` 61.44 MHz MCLK fault is root-caused but **needs a kernel
rebuild + flash + boot check** to confirm (ties to PLAN §1, the TAS5713 audio path).
Details: `docs/2026-06-19-boot-warnings-followup.md` + `.git/sdd/boot-warnings-report.md`.
**Next:** rebuild kernel with this DTS, flash `boot.img`, check `dmesg | grep -iE 'clk:|abe'` and the McBSP2/MCLK rate; then merge or iterate.

## Branches / remotes
- `main` — Plan 1 (merged) + Plan 2 plan + Task 1 + the RE doc. Pushed.
- `fix/boot-warnings` — `main` + the DTS fix (`8b7f1cd`). Pushed.
- Private overlay `private/` (separate repo `nexusQ-reloaded-private`): proprietary LED assets under `private/nexusq-original/` (themes JSON, Visualizer shaders/models, apks). Pushed there — NOT in the public repo.

## Rebuilding the env on Linux (native — easier than the Windows/WSL setup)
The Windows/WSL build tree, ARM toolchain, deodexed smali, and the factory image
live only on the Windows box (temp) — they do NOT transfer, but you don't need
them: the RE conclusions are in the repo doc. To rebuild:
1. `linux-6.12.12` source (`cdn.kernel.org/.../linux-6.12.12.tar.xz`) + Arm GNU Toolchain **13.3.Rel1** (prefix `arm-none-linux-gnueabihf-`). On Linux, native `apt install build-essential flex bison bc libssl-dev libelf-dev` + the toolchain.
2. Kernel/module builds: `scripts/build-led-module.sh` and `scripts/build-clean-modules.sh` (paths are env-overridable: `LINUX_TREE`, `ARM_TCBIN`, `REPO_DRIVERS`, `MODBUILD` — set them for your Linux paths).
3. `nexusqd` host tests: `cd userspace/nexusqd && make test` (just needs host gcc).
4. The full kernel image / aport build is the `docker-build.sh` / pmbootstrap pipeline (on Linux, no QEMU overhead).

## Device
Nexus Q `steelhead`: `root@192.168.20.179` (WiFi, OPNsense VLAN20). SSH key
(petronijus ed25519) installed; fallback password `147147`. The driver auto-loads
at boot; `nexusled` (once Plan 2 ships) or direct sysfs (`/sys/bus/i2c/devices/1-0020/{frame,mute,commit_mode}`) control the ring. See memory `nexus-connection`.

## Gotchas learned this session
- **Subagents share the working tree** — one did `git checkout -b`, which switched the controller's branch and tangled commits. On Linux, prefer git worktrees for parallel agents, or keep agents read-only on git state.
- WSL invoked via PowerShell mangles `$VAR`/`$(...)`/`~` in `wsl bash -lc '...'` — use absolute paths.
- **Verify LED behavior visually on real hardware** — `rc=0` is not proof (this hid the SET_RANGE `rgb_triples` bug and the stale-patch-0005 bug). See memory `always-most-correct-path`.

### ✅ Plan 2b — pixel-perfect volume/mute reaction layer — DONE (2026-06-19)
Implemented in the priority-10 reaction-layer seam. New pure module
`userspace/nexusqd/src/reaction.c` (+ host test `test_reaction.c`) reproducing
`docs/2026-06-19-volume-mute-RE.md` exactly: ring = `#0099CC × (0.1+vol/100·0.9)`,
336 ms DecelerateInterpolator fade-in, 1000 ms overlay then relinquish; mute LED
`#001E28`/`#006B8E`; idle ring `#000F14`. Wired into `nexusqd.c` (volume keys +
`vol N` / `mtoggle` socket cmds; 16 ms tick during the fade). **Verified live**
(fade, brightness levels, mute LED toggle via journal, idle color). `VOL_STEP=2`
— the volume ring is a **rotary encoder** emitting many events/turn (confirmed via
`evtest`). Note: mute shows on the dedicated mute LED, NOT the ring (the ring stays
`#000F14`), per the original.

## Suggested next steps (in order)
1. Run the **Docker pipeline** (`docker-build.sh`) to build the real `nexusqd-*.apk` (musl) and `apk add` it on the device, replacing the static `/usr/bin` binaries.
2. Flash-test `fix/boot-warnings` (audio-clock/MCLK — PLAN §1 gate), then merge.
3. Plan 3 — music visualizer (audio tap + FFT + ported shaders).
