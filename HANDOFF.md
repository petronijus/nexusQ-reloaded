# Nexus Q PostmarketOS Port -- Agent Handoff Document

## Project Goal

Boot PostmarketOS (mainline Linux 6.12 LTS) on the Google Nexus Q ("steelhead"), an OMAP4460-based media streamer from 2012.

## Session 2026-07-01 (latest): v1.6.5 shipped — LED keepalive + breathing themes + 5 visualisations + app-mute LED + librespot softvol fix + companion-over-WiFi

A batch of device-side fixes and companion features on the v1.6.3 image — released as a
single **v1.6.5**. (An interim **v1.6.4** was built + flashed internally to test the LED
keepalive but **never published**; it was folded into v1.6.5 along with the other items.
The 1.6.3 → 1.6.5 gap is intentional.) `boot.img` is **byte-identical** to
v1.6.2/v1.6.3 (kernel unchanged; md5 `36a3dec2c4a493710dffa18c4d796236`), so an
already-current device only needs the userdata reflash. Final pkgrels: `nexusqd` **r5**,
`nexusq-control` **r4**, `device-google-steelhead` **r17**. The companion APK is rebuilt +
reinstalled separately (not part of the device image). Full detail:
`docs/2026-07-01-led-ring-avr-starvation-keepalive.md` +
`docs/2026-07-01-librespot-softvol-bootstrap-and-breathe-scenes.md`.

- **librespot crash-loops on a fresh boot — FIXED (`device-google-steelhead` pkgrel 17).**
  The ALSA `NexusQ` **softvol** control (`asound.conf`) does not exist until the
  `nexusq_soft` PCM is first opened, and it is recreated empty each boot, but librespot
  opens its ALSA mixer control **before** the sink → exits `Could not find Alsa mixer
  control` and `Restart=on-failure` respawns it into the same state forever (a reboot never
  helps). Fix: `librespot.service` gained
  `ExecStartPre=-/bin/sh -c 'timeout 5 aplay -q -D nexusq_soft -f cd -d 1 /dev/zero'`, which
  opens `nexusq_soft` once (1 s silence) to create the control before librespot's mixer
  opens. Also fixes companion **volume** (the bridge's `amixer NexusQ set` needs that
  control to exist).
- **Color themes are now a BREATHING OVERRIDE, not a solid fill (`nexusqd` pkgrel 5,
  `nexusq-control` pkgrel 4).** New `nexusqd` control command **`breathe R G B`**
  (`CTL_BREATHE`, control.c/.h) drives the **compositor manual layer (priority 8)** via a
  new `breathe` flag (`struct manual_ctx`): `manual_render` pulses the ring in the theme hue
  with the **same throb envelope as the idle screensaver** (`screensaver_throb`,
  `A = 0.1 + 0.35*(1 - throb)`) but at priority 8 it is **always visible** — over the music
  visualizer and over a blanked/idle screensaver. This was the fix for "pick a color, ring
  stays dark". _(The earlier screensaver-retint approach — a `br/bg/bb` base color +
  `screensaver_set_color` — was **REVERTED**: it was invisible once the screensaver blanked
  or while music played. `screensaver.c/.h` no longer carry those.)_ A companion color theme
  maps (in the bridge) to **just** `breathe R G B` (no `auto`). Hues: blue (`#0099CC`) /
  warm (`#FF5A0A`) / cool (`#00C88C`) / rose (`#FF285A`) / smoke (`#6E7387`) / off;
  `spectrum`/`trackinfo` dropped.
- **5 music visualisations selectable from the app (`nexusq-control` pkgrel 4 + companion
  app).** `nexusqd` already had `scene 0..4` (waveform/waveformsolid/circles/pointmorph/
  starfield); the bridge gained `setScene`/`listScenes` (maps a name → `auto` + `scene N`)
  + a `scene` field in `getState`, and the Flutter app gained a separate **VISUALIZATION**
  picker (models.dart `kVisualizations`, device_controller.dart `setScene`, home_screen.dart
  section, mock_client.dart). A color theme (breathing override, priority 8) and a
  visualisation (music-reactive effect, priority 7) are now two **independent** controls.
- **App-mute now lights the device mute LED (`nexusqd` pkgrel 5, `nexusq-control`
  pkgrel 4).** New `nexusqd` command **`muted 0|1`** (`CTL_SETMUTED`) sets the mute state
  and calls the same `apply_mute_led()` (dim-teal `#001E28`/`#006B8E` AVR mute LED) the
  hardware mute key drives. The bridge's `setVolume`/`adjustVolume`/`setMuted`/`toggleMute`
  path now also sends `muted 0|1`, so a companion mute has a device-side ring indicator.
- **LED ring goes dark after long idle — root-caused + fixed (AVR keepalive, `nexusqd`
  pkgrel 5; the keepalive landed at r3, later rels add `breathe`/`muted`).** The
  `steelhead-avr` MCU firmware (fw `0x00`) **starves**: it stops lighting
  the ring if the host sends no frame *commit* for too long (a host-frame watchdog). The
  kernel driver `frame_write` (`kernel/drivers/leds-steelhead-avr.c`, sysfs
  `/sys/bus/i2c/devices/1-0020/frame`) sends `SET_RANGE` + `COMMIT` on **every** write, but
  `nexusqd` only wrote a frame when it **changed** (a `memcmp(pk, lastpk)` gate). The idle
  screensaver locks to a **static** frame at `SS_LOCK_S=300 s` (`ledAlpha` constant `0.1`,
  breathing stops) and blanks at `SS_BLANK_S=600 s` → frame stops changing → `memcmp`
  identical → no more commits → AVR starves → ring dark until `nexusqd` restarts
  (~20 h to manifest). **Not** HW (a direct sysfs write lights the ring), **not** a
  commit-mode issue (both `AVR_COMMIT_IMMEDIATE=0` and `AVR_COMMIT_INTERPOLATE=1` display
  fine at 1 write / 4 s), **not** a regression. Fix: re-commit the current frame every
  `AVR_KEEPALIVE_S=1.0 s` even when unchanged (`last_avr_push` var + `|| now-last_avr_push
  >= AVR_KEEPALIVE_S` in the write-gate). Zero cost during animation; idle adds ~1 cheap
  96-byte-payload i2c frame write/s. **Caveat:** mechanically deployed + running, but the
  "never wedges again" proof needs an **overnight idle soak** (the wedge took ~20 h).
- **Companion bridge reachable over WiFi** — new nftables drop-in
  `pmos/device-google-steelhead/55_nexusq-control.nft` opens **TCP 45015 on `wlan*`**
  (mDNS discovery reuses the UDP 5353 rule in `60_spotify.nft`). Previously the bridge was
  only reachable over the USB-gadget net; it had been live-patched but not baked.
  `device-google-steelhead` pkgrel 17.
- **Verified live** (clean flash of the internal v1.6.4 keepalive build): boots;
  `nexusqd 0.1.0-r3` (correct musl binary), `device-google-steelhead 1.0-r16` at that point;
  the bridge answers `getState` (returns the "Nexus Q" state) over WiFi on 45015; WiFi
  rejoined (`192.168.20.x`). The released **v1.6.5** ships `nexusqd 0.1.0-r5` +
  `nexusq-control 0.1.0-r4` + `device-google-steelhead 1.0-r17` with the other items above;
  the softvol/breathe/scene/mute-LED work is verified in the build (device flash-verification
  of those was still pending when this was written).

### Known limitation — deferred to v1.6.6: app/hardware/desktop/Spotify volume+mute are not unified
The companion volume + mute act on the ALSA **`NexusQ` softvol** (the Spotify/librespot
stream) and now the **mute LED** (via `nexusqd muted 0|1`), but do **not** mirror to the
**LXQt desktop taskbar** volume/mute icon. The physical mute/volume keys emit
`KEY_MUTE` / `KEY_VOLUME*` input events that the **desktop** catches (→ taskbar + desktop
audio) and `nexusqd` reads (→ mute LED); the **app** path goes straight to the softvol, so
the app and the desktop can **diverge**. Unifying app + hardware + desktop + Spotify onto
one canonical volume/mute control is a focused **v1.6.6** task — investigate whether the
desktop drives ALSA `Master` vs PulseAudio/PipeWire, and whether emitting `uinput` KEY
events or driving the canonical control is the cleaner approach. **Not done — do not claim
it is.**

---

## Session 2026-07-01: v1.6.3 shipped — companion app + nexusq-control LAN bridge

A **companion app** and its on-device **`nexusq-control` LAN bridge** now ship and are
**verified working on hardware** — released **v1.6.3** (CHANGELOG dated 2026-06-30; the
device-side build, flash and live verification, which surfaced + fixed the boot-ordering
cycle below, were done 2026-07-01). Branch `feat/companion-app` is **merged to main**
(`1844d98`). This **resolves the "HANDOVER 2026-06-30 → Linux: build the companion-bridge
image"** below. Full detail in `CHANGELOG.md` ([1.6.3]),
`docs/2026-06-30-companion-app-RE.md`, `companion/PROTOCOL.md`, and the boot-enablement
finding in `docs/2026-07-01-companion-bridge-boot-enablement.md`.

- **`nexusq-control`** — new noarch aport (`pmos/nexusq-control`, daemon
  `userspace/nexusq-control/`, pure Python3 stdlib). TCP **45015**, mDNS
  **`_nexusq._tcp`**, line-delimited JSON v1 protocol. Fans out to: ALSA softvol
  (volume), `nexusqd` `/run/nexusqd.sock` (LED theme/brightness), a `librespot
  --onevent` hook (now-playing). Methods: getState, setVolume/adjustVolume/setMuted/
  toggleMute, setTheme/listThemes/**setBrightness**, getPlayState, getDeviceInfo.
- **Software master volume** — `asound.conf` `nexusq_soft` softvol (control `NexusQ`)
  over the v1.6.2 tee; `librespot.service` now `--device nexusq_soft --mixer alsa
  --alsa-mixer-control NexusQ --onevent /usr/bin/nexusq-onevent` → one volume knob
  shared by Spotify-Connect + the companion, and the visualizer still tracks the output.
- **`nexusqd brightness <0-255>`** — new control command + software ring-brightness
  scalar (`nexusqd` pkgrel 2).
- **Companion app** (`companion/app`) — cross-platform **Flutter** remote (sphere UI,
  animated LED ring, mDNS auto-discovery; volume + LED theme/brightness + now-playing).
  Built on the phone, **not** in the device image.
- **The enablement fix (3 layers tried; the 3rd stuck) + the boot-cycle fix.** On a clean
  flash the image build kept stripping the unit's enable symlink:
  1. the aport's **`/usr/lib` vendor wants** → wiped by the build's `systemctl preset-all`;
  2. a **bare `/etc` wants symlink** (pkgrel 14) → wiped by postmarketOS's `disable *`
     catch-all;
  3. a **systemd preset `95-nexusq.preset`** (pkgrel 15) → **stuck** (preset-all enables it).
  But then it was *enabled yet never auto-started*: the unit's
  `After=network-online.target nexusqd.service sound.target` formed a boot ordering cycle
  (`nexusq-control` → `nexusqd` → `multi-user.target` → `nexusq-control`); systemd breaks
  cycles by **deleting a start job** and dropped `nexusq-control`. (Manual `systemctl
  start` took a different path, which masked the bug.) **Fix (r2):** the bridge degrades
  gracefully (binds `0.0.0.0`, lazy-reconnects to the sockets), so nexusqd/librespot are
  soft `Wants` only and the unit needs **no `After=`** — removed it. `nexusq-control`
  aport pkgrel 2, `device-google-steelhead` pkgrel 15.
- **Verified live** (clean v1.6.3 flash): `nexusq-control` auto-starts (`active`, no
  cycle), answers every protocol method, volume works (the `nexusq_soft` softvol over the
  tee), the LED visualizer still reacts to playback, `systemctl is-system-running` =
  running. **Transport (play/pause/next) is `unavailable` in v1 by design** (librespot has
  no local transport API).

---

## Session 2026-06-30: v1.6.2 shipped — LED music visualizer wired up (audio tee + snd-aloop)

The **LED music visualizer now reacts to Spotify playback** — released **v1.6.2**,
verified live on the device. v1.6.1 routed librespot straight to the TAS5713 speaker,
so nexusqd's snd-aloop audio tap got nothing and the ring stayed idle while music
played. Full detail in `CHANGELOG.md` ([1.6.2]).

- **Audio TEE feeds the visualizer.** The `nexusq` ALSA PCM (`asound.conf`) is now a
  tee (`type multi` + `type route`) that duplicates librespot's 48 kHz stereo to BOTH
  the TAS5713 speaker AND the snd-aloop loopback (`hw:Loopback,0`). nexusqd's existing
  `arecord` tap on `hw:Loopback,1` (48 kHz) drives the FFT/beat visualizer while the
  speaker plays. The **speaker is the timing master**; the loopback slave is `plughw`
  so it adapts to the cable rate and **never blocks playback** — the tee opens
  regardless of which side grabs the loopback first.
- **snd-aloop auto-loaded.** New `/etc/modules-load.d/snd-aloop.conf` loads the
  loopback (`CONFIG_SND_ALOOP=m`); without it the `Loopback` card doesn't exist and
  the tap can't open. `device-google-steelhead` pkgrel 12.
- **Verified live:** the LED ring pulses/animates to the music; no ALSA/xrun errors,
  no failed units, nexusqd/librespot `NRestarts=0`. This closes the long-standing
  "Spotify-driven visualizer blocked by WiFi + the snd-aloop B11 gap" item from
  `docs/2026-06-20-session-handoff.md`: WiFi works on 5 GHz, librespot ships,
  snd-aloop auto-loads, and the audio is teed to the loopback.

---

## HANDOVER 2026-06-30 → Linux (petronijus-PC): build the companion-bridge image  ✅ RESOLVED 2026-07-01

> **DONE — built, flashed and verified live; shipped as v1.6.3** (see the 2026-07-01
> session above). Branch `feat/companion-app` is **now merged to main** (`1844d98`).
> The build surfaced + fixed the boot-ordering cycle (unit `After=` deleted its start job)
> and the enablement-symlink stripping (resolved via the `95-nexusq.preset` systemd preset).
> Kept below as the original handover record.

Companion app + its device-side bridge are done on branch **`feat/companion-app`** (pushed,
14 commits, ~~NOT merged to main~~ **now merged — `1844d98`**). The **device-side build must be
done on Linux** (the dockerized pmbootstrap pipeline). The Flutter app itself runs on the phone
and is built separately — it is NOT in the device image.

**What this branch adds to the device image (all needs to land in the build):**
- `pmos/nexusq-control/` — new noarch aport: the `nexusq-control` LAN bridge (port 45015, mDNS
  `_nexusq._tcp`) + `nexusq-onevent` hook + systemd unit. (`userspace/nexusq-control/`.)
- `userspace/nexusqd/` — new **`brightness <0-255>`** control command + software ring-brightness
  scalar (control.h/control.c/nexusqd.c).
- `pmos/device-google-steelhead/` — `APKBUILD` now `depends nexusq-control`; **`asound.conf`**
  adds the `nexusq_soft` softvol PCM + `NexusQ` control; **`librespot.service`** now uses
  `--device nexusq_soft --mixer alsa --alsa-mixer-control NexusQ --onevent /usr/bin/nexusq-onevent`.
- `docker-build.sh` — Phase 2 validates the aport, Phase 6 stages `nexusq-control` into
  `$PMAPORTS/main/nexusq-control`, Phase 7c2 builds it (noarch).

**Build steps (on petronijus-PC / Ubuntu):**
1. `cd ~/Documents/Dev/nexusQ-reloaded && git fetch && git checkout feat/companion-app && git pull`
   (or merge the branch to main first, your call — building the branch directly is fine).
2. Ensure the **private overlay** is present (non-redistributable BT/WiFi firmware blobs):
   `private/` must hold `firmware/bcm4330.hcd` + `firmware/bcmdhd.cal` (clone
   `nexusQ-reloaded-private` into `private/`, see `private/README.md`). Run
   `scripts/setup-firmware.sh` if the build expects staged blobs.
3. Build the full image via the dockerized pipeline (`docker-build.sh`, or the **nexusq-build**
   skill). Watch for the two new build lines: `Installed: nexusq-control (...)` (Phase 6) and
   `nexusq-control build exit code: 0` (Phase 7c2). The build should also still build `nexusqd`.
4. **Flash** boot.img + rootfs in fastboot (INSTALL.md).

**Verify on the device after flash** (full checklist: `docs/2026-06-30-companion-hardware-bringup.md`):
```sh
systemctl status nexusqd nexusq-control librespot
amixer -c NexusQSpeaker scontrols | grep -i nexusq    # softvol control 'NexusQ' exists
ss -ltnp | grep 45015                                  # bridge listening
```
Then on the phone: `adb install -r companion/app/build/app/outputs/flutter-apk/app-debug.apk`
(non-mock build, auto-discovers via mDNS) — or `flutter run --dart-define=NEXUSQ_HOST=<ip>`.

**Confirm against real values** (likely needs a tweak once on hardware): the softvol control
name/card (defaults `NexusQ`/`NexusQSpeaker` — override via `NEXUSQ_MIXER_CTRL`/`NEXUSQ_MIXER_CARD`
in the unit), and the librespot `--onevent` env field names in `nexusq-onevent` (NAME/ARTISTS/
ALBUM/COVERS/VOLUME) against the installed librespot version. Transport (play/pause/next) is
`unavailable` in v1 by design.

Refs: `companion/PROTOCOL.md`, `docs/2026-06-30-companion-app-RE.md`,
`docs/2026-06-30-companion-design-language.md`, `docs/2026-06-30-companion-hardware-bringup.md`.

---

## Session 2026-06-29 (late): v1.6.1 shipped — TAS5713 2× bug FIXED + Spotify Connect BAKED IN

Both the audio bug and the live Spotify Connect install from the earlier 2026-06-29
entry below are now **resolved and in the build** — released **v1.6.1**, verified on a
**fresh flash**. Full detail in `docs/2026-06-29-spotify-connect-and-tas5713-2x-speed.md`.

- **TAS5713 2× speed bug FIXED — kernel patch 0022** (`linux-google-steelhead`
  pkgrel 25). Root cause was the `simple-audio-card`↔`omap-mcbsp` master-mode gap: the
  generic card sets only `mclk-fs` and never `snd_soc_dai_set_clkdiv()`, so McBSP2 left
  `CLKGDV=0` (bit clock = the undivided 24.576 MHz fclk) and sized the frame as
  `in_freq/rate = 256` BCLK → **FSYNC = 96 kHz = 2× too fast**. Patch 0022 derives
  `CLKGDV` from the real `mcbsp->fclk` + a minimal `wlen*channels` I2S frame,
  reproducing the factory registers (CLKGDV=15, BCLK 1.536 MHz, 32-BCLK frame, FSYNC
  48 kHz). **Verified on hardware:** 60 s of audio now plays in **60.00 s** (1.000×; was
  ~30 s / 0.50×). The "B7 TAS5713 MCLK 16 vs 12.288 MHz" lead from the entry below was a
  **red herring** — mainline `tas571x` has no `.set_sysclk`, so MCLK never gates FSYNC.
  Cross-checked vs `reverse-eng/vmlinux.bin` (stock-parity audit).
- **Spotify Connect (librespot) BAKED INTO THE BUILD** — `device-google-steelhead`
  pkgrel 11 now `depends librespot` (Alpine edge/testing **0.8.0**, libmdns zeroconf)
  and ships: the enabled `/etc/systemd/system/librespot.service` (`librespot --name
  "Nexus Q" --device nexusq …`), `/etc/asound.conf` (the **`nexusq`** PCM = `plug` →
  `hw:CARD=NexusQSpeaker,0` forced to **48000 Hz** — addressed by **NAME** because the
  TAS5713/HDMI cards race for card 0/1 across boots), and `/etc/nftables.d/60_spotify.nft`
  (`wlan*` UDP 5353 + TCP 37879). Discovery + auth + streaming verified over 5 GHz WiFi
  at correct pitch (44.1 k Spotify resampled to the clean 48 k). All of it now **survives
  a flash**. (The device-side install + nftables/`--ap-port 443` rationale are in the
  entry below.)

## Session 2026-06-29: Spotify Connect streams; TAS5713 plays 2× too fast (NEW bug) → both RESOLVED in v1.6.1 (see above)

Full detail in `docs/2026-06-29-spotify-connect-and-tas5713-2x-speed.md`. Both
results below are on the v1.6.0 image and were open when written; **both are now
shipped in v1.6.1 — see the session above.**

- **Spotify Connect (librespot) installed + streaming VERIFIED** — `apk add
  librespot` (Alpine edge/testing, **0.8.0-r0**, **libmdns-only** zeroconf backend so
  it coexists with `avahi-daemon` on UDP 5353 via `SO_REUSEPORT`). Unit
  `/etc/systemd/system/librespot.service`: `librespot --name "Nexus Q" --backend alsa
  --device plughw:1,0 --bitrate 320 --format S16 --initial-volume 60 --ap-port 443
  --zeroconf-port 37879 --cache /var/cache/librespot`. nftables drop-in
  `/etc/nftables.d/60_spotify.nft` opens `wlan*` UDP 5353 (mDNS) + TCP 37879
  (zeroconf HTTP). `--ap-port 443` dodges VLAN20 blocking librespot's default AP port
  4070. Phone sees "Nexus Q", authenticates, tracks load + play over 5 GHz WiFi.
  **NOT baked into the build** (a flash wipes it) — bake-in deferred until the audio
  bug below is fixed.
- **NEW HARDWARE BUG — TAS5713 plays EXACTLY 2× too fast.** First real timing test of
  the speaker path (was "software-verified, listening test pending"): 10.0 s of
  `S16_LE` stereo silence to `hw:1,0` (card 1 `NexusQ-Speaker` = McBSP2 → TAS5713)
  plays in **5.00 s** = **0.50× = 2× too fast** at 48000 Hz, 2× at all rates. So
  librespot/Spotify tracks end in half real time and the player **auto-skips ~40 s
  in** (the "plays ~40 s then skips" symptom — **not** a librespot crash). Root cause:
  **McBSP2/ABE SRG emits FSYNC (LRCLK) at 2× the requested rate** — a kernel/DTS clock
  bug in the **B7 TAS5713-MCLK family** (`docs/2026-06-19-boot-warnings-followup.md`
  §B7). `func_mcbsp2_gfclk` reads 24.576 MHz (=512×48k, correct), so the ×2 is
  **downstream** (SRG divider / I2S frame width / TAS5713 MCLK 16 vs 12.288 MHz). A
  stock-parity audit vs `reverse-eng/vmlinux.bin` (the factory kernel that drove this
  amp correctly) + the precise kernel fix are **IN PROGRESS** — open, newly
  root-caused; fix + verification to follow.
- **WiFi join after a fresh flash documented** (SSID `Svatovitske-Internety-5g`,
  5 GHz/vlan20, PSK in 1Password — never in-repo) in `.claude/agents/nexusq-connect.md`
  + the `nexusq-wifi-join` memory. 5 GHz ~26–30 Mbit/s carries the Spotify stream;
  2.4 GHz still has the BT-coexist bulk stall.

## Session 2026-06-28: zram + userns + power health; ARMv7 python crash FIXED (flash bug; gold dropped) → v1.6.0

Full detail in `docs/2026-06-28-session-findings.md`. Diag capture
`nq-captures/20260628-124159/` (verdict CRIT — dark-but-responsive LED ring + the
then-failed python unit, **not** a true hang).

- **zram swap fixed** — `CONFIG_ZRAM=m` + `deviceinfo_zram_swap_algo="lzo-rle"`
  (the kernel module only has the lzo backend; the service's default zstd failed
  `Invalid argument`). Live: `/dev/zram0` lzo-rle 1.4 G `[SWAP]`. linux pkgrel 23→24.
- **`CONFIG_USER_NS=y`** — `max_user_namespaces=7716`, `unshare --user` works.
- **SMP re-confirmed** — `nproc=2`, `cpu/online=0-1`. Corrects any stale "CPU1 not
  brought up / SMP groundwork" framing; SMP is done (v1.2.0).
- **CPU power/thermal health confirmed** — 350/700/920/1200 MHz, reaches 1.2 GHz,
  VDD_MPU tracks OPP exactly, abb_mpu FBB@Nitro 1375 mV, governor `conservative`,
  idle ~70 °C / peak 95 °C (no throttle). `CONFIG_CPU_FREQ_STAT` is off (no
  `time_in_state`) — a diagnostic gap.
- **CORRECTION (idle freq):** the v1.5.0 CHANGELOG "idle settles at 350 MHz" is
  wrong on hardware — idle hovers **~920 MHz** (nexusqd LED polling keeps the clock
  up), dipping to 350 only briefly.
- **CORRECTION (GCC):** the **current shipping kernel is built with GCC 15.2.0**
  (`/proc/version`: `cc (Alpine 15.2.0) 15.2.0`) and boots fine. The old
  "13.3.Rel1 only / GCC 15 silently does not boot" finding below (2026-06-10)
  applied to the early hand-cross-compiled build and is **superseded** for the
  pmbootstrap path.
- **FIXED — armv7 python3-3.14.5 SIGSEGV: the on-device crash was a FLASH bug, not a
  build bug.** Alpine's `python3-3.14.5-r2` SIGSEGVed deterministically
  (`python3 -S -c ''` → rc 139 in `Py_Initialize`), crashing
  onboard/blueman/sleep-inhibitor and `gdb` (it links libpython). The **single root
  cause** was the `raw2simg.py` `DONT_CARE` deployment bug (next bullet): a re-flash over
  non-erased eMMC left stale garbage in libpython's should-be-zero `.PyRuntime` /
  `.data.rel.ro`, landing on `interp->types.builtins.num_initialized` (read back
  `0xf0012b00`), so `_PyStaticType_InitBuiltin` derefs a wild address → SIGSEGV. v1.6.0
  ships a local `pmos/python3/` override (same 3.14.5, **r5**, **default linker / bfd**)
  so its higher pkgrel supersedes Alpine's `-r2`; it drops `--with-lto` +
  `--enable-optimizations` and the `!gettext-dev` token, keeps stock `-O2`.
  **The session HYPOTHESISED a build-time qemu-user mmap-corruption and tried a
  gold-linker workaround (`-fuse-ld=gold -Wl,--no-mmap-output-file`, `binutils-gold`) —
  both INVESTIGATED then DROPPED as unnecessary:** the build was never reproducibly
  corrupt — 6 independent default-linker builds were all integrity-gate-clean, and a bfd
  build (gold-note absent, libpython md5 `79a0d4ace1358bb2d94c8a4d72479da9`) flashed via
  the corrected all-RAW `raw2simg` ran `python3 -S -c ''` rc 0 on the real device. (The
  earlier "byte-identical `.text`, opposite outcome" / "two r4 builds" coin-flip evidence
  was almost certainly a post-flash device pull misread as build corruption.) The
  deterministic build-integrity gate `scripts/verify-libpython-clean.py` (long non-zero
  runs in those zero-regions; clean ≤52 B, corrupt ≥22000 B, threshold 256) is **kept as
  a cheap safety net** — Phase-7d gate+retry (rebuild ≤4×, pkgrel-exact apk selection) +
  a Phase-10 **ship gate** on the installed rootfs libpython — catching zero-region
  corruption from any source, **not** as "the gold fix". **DISPROVEN (do not re-tread):**
  LTO/PGO; LDREXD misalignment (faulting addr 8-byte aligned but **UNMAPPED** → SIGSEGV
  not SIGBUS); gnu2/TLSDESC; optimization level; and the qemu-build / gold theory above.
  A clean build is necessary-but-not-sufficient — the flash must also be **byte-exact**;
  always validate `python3 -S -c ''` **on the device**.
- **FIXED — the DEPLOYMENT (flash) bug that corrupted python on-device → v1.6.0.** The
  gate-CLEAN rootfs SIGSEGVed `python3` (rc 139) on-device: the build was clean, the
  **flash** was not — `raw2simg.py` emitted all-zero blocks as `DONT_CARE`, which
  fastboot SKIPS, correct only on a pre-erased partition; the Nexus Q's U-Boot does
  **not** erase `userdata`, so each skipped block kept STALE eMMC data from the prior
  flash, corrupting libpython's `.PyRuntime`/`.data.rel.ro` zero-regions. Forensics:
  on-device libpython differed from the (clean) image in **exactly 47** 4 KiB blocks,
  **all** image-zero→device-garbage (`.PyRuntime longest_run 30652`); `scp`-ing the
  clean image libpython over the device's → `python3 -S -c ''` rc 0 instantly (proof:
  flash, not build). **Fix:** `raw2simg.py` now writes **every** block as RAW (no
  `DONT_CARE`) → byte-exact flash regardless of prior eMMC content (sparse ≈ raw size).
  Verified by de-sparse round-trip (md5 matches raw) **and** on hardware: a **fresh
  flash, no live-patch** (no `.flashcorrupt` backup) of a default-linker (bfd) build
  gives `libpython3.14.so.1.0` md5 `79a0d4ace1358bb2d94c8a4d72479da9`,
  `SYSPY_OK 3.14.5 … [GCC 15.2.0]`, `SYS_PY_RC=0`. **The all-RAW flash fix → shipped
  v1.6.0**, the first release with a working system python from a clean flash. Lesson:
  integrity-verify what the **device** runs, not just the artifact (do NOT use DONT_CARE
  on a non-erasing target).
- The currently-flashed image is now **v1.6.0** (bfd r5 python + all-RAW flash).
  `device-google-steelhead` pkgrel 6→10 **removed**
  the `sleep-inhibitor.service` `/dev/null` mask and added `gdb` + `python3-dbg`. WiFi
  creds added live are wiped by reflash — to persist they need a **private overlay**
  (PSK is a secret), not the public repo.
- **Ethernet still down** (v1.4.0 cpufreq boot-timing regression, unchanged).

## Session 2026-06-23: device hardening — AVR keys, HDMI desktop, WiFi; ethernet still open

Released **v1.2.0**. Built on the dual-core SMP win. Full detail in
`docs/2026-06-23-session-findings.md`; ethernet next steps in
`docs/2026-06-23-ethernet-continuation.md`.

- **AVR rotary volume + mute keys FIXED** (patch 0011) — the keys were dead
  because the AVR holds INT low while its KEY_FIFO is non-empty and the driver
  uses an `EDGE_FALLING` irq: stale FIFO entries at probe meant the line was
  already low → no edge → the irq never fired → FIFO never drained (latent driver
  bug; intermittent). Drain the FIFO in probe to release INT. Proven by reading
  the KEY_FIFO directly over i²c (the AVR was detecting keys the whole time) and
  by the IRQ count going 0→118 once drained. The LED ring (nexusqd) now responds
  to the dome again.
- **HDMI desktop visible** — DDC pads to `PIN_INPUT` (EDID reads) + hdmi4 bridge
  `.mode_valid` cap at 75 MHz (patch 0010) so wlroots picks a DSS-displayable
  1280×720 instead of the blank native 1440×900.
- **WiFi latency** fixed via NM `wifi.powersave = 2` drop-in.
- **Ethernet LAN9500A — still intermittent.** stock-parity-auditor REFUTED the
  board-level timing/power-cycle hypothesis (stock uses identical udelay(2), no
  power-cycle, no retry) and found one real divergence: stock's **1 ms ULPI
  pre-reset settle** (added, commit `3b06c41`) — but it is **not** sufficient; a
  cold boot still shows PORTSC CCS=0 / no enumeration. **Prime open suspect:**
  `UHH_HOSTCONFIG` not holding `0x11c` across `usbhs_runtime_resume`. Next: a
  kernel-side diag build dumping `UHH_HOSTCONFIG` + USB3320 ULPI identity (userspace
  `/dev/mem` faults on the clock-gated USBHS). See the continuation doc.

### Process reminders reinforced this session
- **Verify every hypothesis against stock before building.** The user's "does
  stock confirm this?" caught a wrong ethernet fix mid-flight (a board-level
  power-cycle that stock does not do) before it was flashed.
- **Nothing is "benign/cosmetic."** Every half-working subsystem gets root-caused.
- **sha-verify the on-device boot image before `dd`** (a slow-WiFi scp once
  silently transferred a 0-byte file); flash via fastboot or the USB gadget.
- Test ethernet only by **cold power-cycle** over **multiple boots** — warm
  `fastboot reboot` is not representative and one good boot is luck.

## Session 2026-06-22: SECOND CPU CORE WORKS ✅ — dual-core SMP

The OMAP4460 HS second Cortex-A9 is online and stable on mainline 6.12.
`CONFIG_SMP=y` had silently deadlocked the boot for the life of the port; root
cause found by disassembling the stock kernel (`reverse-eng/vmlinux.bin`):

- **Missing SEV in `omap4_smp_prepare_cpus`** — stock issues `dsb;sev` after
  writing AUX_CORE_BOOT_1 to kick CPU1 out of ROM WFE; mainline omits it → CPU1
  never starts → `__cpu_up` hangs before any console. Fix: **patch 0009**
  (`dsb_sev()` at end of prepare).
- **CPU1 cpuidle panic** once online (`Attempted to kill the idle task`, on
  `swapper/1`). Fix: **`cpuidle.off=1`** (stock ships `cpuidle44xx.disallow_smp_idle`).

Secure SMC service IDs already matched stock byte-for-byte; `omap_type()=HS`.
defconfig: `CONFIG_SMP=y`, `NR_CPUS=2`, `HOTPLUG_CPU=y`, `KERNEL_LZMA` (SMP+gzip
busted the ~6.6 MB U-Boot ceiling; LZMA → ~5.1 MB); DTS `cpu@1` restored.

**Validated** (cold boot, `boot-smp-dualcore.img`): `nproc=2`, online/possible=0-1,
`taint=0`, 0 module-ABI errors, `SMP: Total of 2 processors activated`, CPU1 up at
`[0.25s]`, both cores load under stress, ~59 °C; audio/LED-ring/wifi/BT/USB up.
Dual-core also cured the single-core-saturation network flakiness.

Build: `scripts/build-kernel-boot.sh` (fast kernel-only docker build). Branch
`feat/smp-cpu1-bringup` (`510f8ab` breakthrough+debug, `8d4df5d` clean dual-core).
Also fixed a repo-integrity bug: patch 0008 (ethernet) applied with `git apply`
but FAILED under GNU `patch` (abuild) — regenerated clean.

**Full writeup: `docs/SMP-second-core.md`.** Open items (cpuidle proper, eth
LAN9500A enumeration reliability, wifi BCM4330 power-save, making SMP the default
after multi-cold-boot reliability validation) tracked in
`docs/2026-06-22-smp-session-findings.md`.

## Session 2026-06-22 (late): ETHERNET FIXED ✅ — kernel #8, released v1.1.0

The on-board **SMSC LAN9500A USB-ethernet works.** This retires the multi-month
"ethernet is dead hardware" verdict, which was wrong: the stock Android 3.0 kernel
enumerates the same chip on this unit, so the bug was always in our mainline port.

**Two kernel patches, both required:**
- `0006-usb-ehci-omap-steelhead-keep-ethernet-port-alive-ulp` — vendor steelhead
  host-init in `ehci-omap` done *before* `usb_add_hcd()`: LAN9500A power-on-reset
  sequence (auxclk3 38.4 MHz, NENABLE/NRESET gpios), `INSNREG01` burst thresholds
  = 0x80, a ULPI Function-Control soft reset of the USB3320, plus
  `usb_disable_autosuspend()` on the root hub so the idle port is not clock-gated.
- `0008-mfd-omap-usb-host-steelhead-UHH-HOSTCONFIG-connect` — in `omap_usbhs_init`,
  program `UHH_HOSTCONFIG` to the vendor's **0x11c**: set `P1_CONNECT_STATUS`
  (bit 8) so EHCI latches the port-1 connect, and leave `APP_START_CLK` (bit 31)
  **clear** so the UHH does not auto clock-gate. Measured mainline default was
  **0x1c** (the "ethernet-stockinit" handover's APP_START_CLK guess was wrong).

**Discovery note:** kernel **#7** (patch 0006 alone) already enumerated `eth0` —
the `docs/2026-06-22-HANDOVER-ethernet-stockinit.md` "#4–#7 all failed, eth0 absent"
conclusion was a mis-test. #8 adds the UHH_HOSTCONFIG change as the *more-correct*
root-cause form (matches the vendor exactly, no autosuspend reliance) and is the
released kernel.

**Verified on hardware (#8):** `eth0` (`0424:9e00` → `smsc95xx`) at 100 Mbps/Full,
bidirectional ping 0% loss (~0.69 ms avg), **zero** rx/tx/CRC/frame/over errors and
zero collisions after ~660 MB transferred. Throughput TX ~60 / RX ~28 Mbps —
USB2 + single-core OMAP4 bound (device ~64% idle during RX), not a link fault.

**Access over ethernet (now preferred over the renaming USB gadget):** the Nexus
RJ45 is cabled directly to `petronijus-PC` NIC `enp7s0` (Intel I225-V, 100M). Device
`eth0` has a persistent NetworkManager profile **`eth-direct`** (`ipv4.method
manual`, `10.42.0.2/24`, never-default, autoconnect, bound to ifname not MAC since
smsc95xx has no EEPROM MAC) → survives reboot and stopped the earlier NM-DHCP-timeout
link flap. PC side: `enp7s0` = `10.42.0.1/24`, set NM-unmanaged so the IP sticks.
`ssh root@10.42.0.2`.

Artifacts: `#7` backup `output/p9-backup-7-working.img` (sha c0dd95d1); released
`#8` boot image `output/boot-eth-8.img` (sha 8c7b4f75, 6496 KB, under the ~6.5 MB
U-Boot ceiling). The released boot image is #8 *with* a one-time diagnostic
`UHH_HOSTCONFIG` boot log; source patch 0008 in the v1.1.0 tag omits that logging
(functionally identical). Build gotcha fixed: `docker-build.sh` Phase 7a now also
chowns `$WORK/cache_ccache_armv7` to uid 12345.

## Session 2026-06-22: TAS5713 amp clock fixed, single-core taint cleared; ethernet still dead

Built and flashed kernel **#4** (`6.12.12`), verified live over the USB gadget
(WiFi is unstable — flash/diagnostics go over `172.16.42.1`).

- **TAS5713 amplifier MCLK fixed** (kernel patch 0007). OMAP4 composite-clock
  `round_rate`/`set_rate` were `-EINVAL` stubs; delegated to
  `ti_clk_divider_ops`. On HW: `dpll_per_m3x2_ck` = 61.44 MHz, `auxclk1_ck` =
  12.288 MHz (256×48 kHz), ALSA `card 0 NexusQ-Speaker` registers, no clock
  error. (Actual audio playback through speakers not yet tested.)
- **Single-core taint cleared.** DTS now `/delete-node/ cpu@1` (matches
  `CONFIG_SMP=n`). `/proc/sys/kernel/tainted` = 0 (was 512), no DT cpu-cap WARN.
- `CONFIG_SRAM=y`; new helper scripts `regen-dts-patch.sh`,
  `extract-and-repack.sh`; device password moved to gitignored `.nexus_pw`.
- **Ethernet (LAN9500A) STILL DEAD.** #4 kernel: EHCI port powered, ULPI PHY
  (USB3320, VID 0x4:0x24) responds, `PORTSC=00001000` (PP set, CCS clear) — no
  enumeration, no `eth0`, EHCI bus 002 has only the root hub. This is the next
  thing to investigate/fix. Backup of the pre-#4 boot partition:
  `output/p9-backup-pre-clockfix-b7.img`.

## Session 2026-06-10: Userspace boots, WiFi works, ethernet is dead HW

### Status: postmarketOS (systemd) boots, SSH over USB gadget, WiFi functional

### Root causes found today (in order of discovery)
1. **U-Boot kernel-size ceiling (~6.5-7 MB)** when loading from the boot
   partition: 6.45 MB zImage+DTB boots, 7.3 MB does not. This was the hidden
   variable behind "Finding 2" (identical-config rebuilds not booting) --
   embedded initramfs pushed the image over the limit.
2. **Ubuntu GCC 15.2 kernels do NOT boot** (black screen). Only the Arm GNU
   Toolchain 13.3.Rel1 (same as original builds) produces booting kernels.
   Toolchain lives in `build/arm-gnu-toolchain-13.3.rel1-*/bin`,
   prefix `arm-none-linux-gnueabihf-`.
3. **Feb rootfs flash silently failed**: 511 MB sparse image exceeds the
   U-Boot fastboot download buffer (~150 MB). Flash userdata with
   `fastboot -S 100M flash userdata <img>` -- works reliably (6 chunks).
4. **Rootfs is pmOS systemd variant** (/sbin/init -> ../lib/systemd/systemd).
   /etc/inittab and /etc/init.d are decoys. Emergency mode was caused by an
   fstab entry for a /boot partition UUID that only existed in the build VM;
   line removed. Root account unlocked (password 147147, same as user).
5. **Ethernet (LAN9500A) is dead hardware.** Verified at register/pad level:
   pinmux applied, GPIO pads toggle (DATAIN readback), 38.4 MHz PHY refclk
   running, ULPI PHY (SMSC USB3320, id 0x0424/0x0007) responds via the EHCI
   ULPI viewport (INSNREG05 @ 0x4A064CA4), EHCI port powered -- but PORTSC
   CCS never asserts. gpio_1 (ethernet NENABLE) is physically clamped low
   (drive-high reads back 0). DTS ethernet fixes applied anyway (38.4 MHz
   clock per board-steelhead-usbhost.c, NENABLE polarity, gpio_wk1 pad 0x042
   in wkup domain, fref_clk3_out mux) -- correct for a healthy unit.
6. **WiFi (BCM4330) works.** Chain of fixes:
   - kernel patch 0004: twl-core registers the clk mfd cell for TWL6030
     (mainline only did TWL6032; register bases 0x8C/0x8F are identical)
   - DTS: pwrseq clocks = <&twl 1> (clk32kaudio, per board-steelhead-wifi.c)
   - DTS: WLAN_EN (gpio_43) only in pwrseq (was double-claimed by the vmmc
     regulator -> EBUSY); vmmc is a plain always-on 3.3 V fixed regulator
     (3.3 V matters: SDIO OCR negotiation fails at 1.8 V "no support for
     card's volts")
   - nvram: **original bcmdhd.cal recovered from the old Android system
     partition (mmcblk0p11, still intact!)** -> /lib/firmware/brcm/
     brcmfmac4330-sdio.txt. Generic Prowise nvram does NOT work (dongle
     timeout -110). Also recovered bcm4330.hcd (Bluetooth patchram).
     Both backed up in `firmware/` in this repo.

### Access to the running device
- USB gadget RNDIS via micro-USB: device 172.16.42.1, host 172.16.42.2/24
  (NetworkManager profile "nexusq" on this PC; iface name changes each boot
  -- random MAC -- fix with `nmcli con mod nexusq connection.interface-name <enx...>`)
- SSH as root (password 147147, petronijus' ed25519 key authorized)
- Gadget+sshd is started by /usr/local/bin/nexus-diag.sh (systemd unit
  nexus-diag.service), which also dumps diagnostics to /dev/tty1 and
  /var/log/nexus-diag.log
- **Boot images can be written from the running system**:
  `dd if=boot.img of=/dev/mmcblk0p9 bs=1M conv=fsync` -- no fastboot needed
- **`systemctl reboot` over SSH works cleanly** (~90 s to gadget back up).
  The old "software reboot re-enters fastboot" note applied to panic-reboots
  and `fastboot reboot`, NOT to a clean systemd reboot.
- pstore/ramoops configured in cmdline (last 1 MB of RAM, mem=1008M) --
  survives warm reboots only

### Current images
- boot: `output/boot-wifi-v5.img` (GCC 13.3, gzip, no initramfs,
  root=/dev/mmcblk0p13 + ramoops in cmdline, DTS with all fixes)
- rootfs: `output/work-rootfs.img` (raw) / `work-rootfs-sparse.img` (flash)
  -- modules for this exact kernel installed, fstab fixed, sshd fixed
  (UsePAM drop-in removed), root unlocked, host keys baked in
- mini mkbootimg replacement: `make-bootimg.py` (or reuse a proven header)

### Known issues / next steps
1. **Intermittent boot failure** (~1 in 3 boots: black screen, retry helps).
   Unexplained. Candidates: U-Boot flakiness, DRAM init, kernel race.
   pstore won't help across cold cycles. Consider UART2/3 serial console.
2. WiFi: NetworkManager connection profile not yet configured (needs SSID
   + password). brcmfmac autoloads on boot; firmware+nvram persist in rootfs.
3. Bluetooth: bcm4330.hcd recovered; hci_bcm + UART2 wiring in DTS untested.
4. SMP still disabled (single core) -- original U-Boot CPU1 issue.
5. Audio (TWL6040/TAS5713), NFC, LEDs untested.
6. APKBUILD sha512sums need refresh (0004 patch added with SKIP).

## Current Status: KERNEL BOOTS (HDMI output confirmed)

**Milestone achieved 2026-02-27:** The kernel boots, HDMI output works (framebuffer console with Tux logo), eMMC is fully detected with all partitions, and the kernel panics with "Unable to mount root fs" -- which is expected since no rootfs is configured yet.

### What Was Wrong (Root Cause)

**`CONFIG_SMP=y`** was the sole root cause of boot failure. The U-Boot 2011.09 bootloader leaves CPU1 (second Cortex-A9 core) in an undefined state. The mainline kernel's OMAP4 SMP startup code hangs trying to bring it online -- no panic, no output, silent deadlock. **Fix: `CONFIG_SMP` disabled.**

### Required Config for Boot (all must be set)

| Option | Value | Why |
|--------|-------|-----|
| `CONFIG_SMP` | `n` | U-Boot leaves CPU1 in bad state; SMP startup hangs |
| `CONFIG_ARM_ATAG_DTB_COMPAT` | `y` | **REQUIRED** -- kernel does NOT boot without it; U-Boot passes ATAGs that the kernel needs for proper initialization |
| `CONFIG_ARM_APPENDED_DTB` | `y` | DTB appended to zImage (standard for this platform) |
| `CONFIG_CMDLINE_FORCE` | `y` | U-Boot's cmdline is unreliable; compiled-in cmdline only |
| `CONFIG_INITRAMFS_SOURCE` | `"mini-initramfs.cpio"` | Initramfs MUST be embedded in kernel (see below) |

### Boot Method

- **Reliable: `fastboot flash boot` + normal power-on** -- Flash to the 8 MB boot partition, then power-cycle without holding mute sensor. U-Boot loads from partition and boots reliably.
- **Unreliable: `fastboot boot` (RAM boot)** -- Intermittent on this U-Boot. Works sometimes, fails silently other times. Avoid for testing.

### Initramfs Strategy: MUST Be Embedded in Kernel

**U-Boot does NOT load the ramdisk from the boot partition** during normal boot. The boot.img ramdisk section is ignored. Therefore:
- External ramdisk in boot.img: **DOES NOT WORK** (U-Boot ignores it)
- DTB initrd-start/end: **DOES NOT WORK** (U-Boot doesn't load ramdisk to RAM)
- `CONFIG_INITRAMFS_SOURCE`: **WORKS** (initramfs compiled into zImage)

A minimal initramfs (busybox + USB gadget setup, 549 KB compressed) is embedded in the kernel via `CONFIG_INITRAMFS_SOURCE="mini-initramfs.cpio"`. Total boot image: 6.7 MB, fits in 8 MB partition.

The full pmOS initramfs (8.4 MB) is too large to embed. Solution: use the minimal initramfs for initial boot, mount full rootfs from userdata partition.

## Boot Image Variants Tested
| Image | Size | Description | Result |
|-------|------|-------------|--------|
| `boot.img` | 13.5 MB | Full pmos initramfs, SMP=y | No output (SMP bug) |
| `boot-diag.img` | 5.9 MB | Minimal diag initramfs, SMP=y | No output (SMP bug) |
| `boot-builtin.img` | 8.8 MB | Full initramfs, built-in drivers, SMP=y | No output (SMP bug) |
| `boot-noramdisk.img` | 5.0 MB | Kernel+DTB only, SMP=y | No output (SMP bug) |
| `boot-test-nosmp-noatag.img` | 6.2 MB | SMP=n, ATAG=n, no ramdisk | Boots (HDMI+kernel panic) |
| `boot-atag-initramfs.img` | 6.7 MB | SMP=n, ATAG=y, external ramdisk | Boots (panic: ramdisk not found) |
| `boot-atag-embedded.img` | 6.7 MB | SMP=n, ATAG=y, embedded initramfs | **Testing...** |
| Various rebuild tests | 6.2 MB | SMP=n, ATAG=n, no ramdisk | No output (ATAG required) |

### Kernel Configuration Changes (Current State)
These drivers were changed from `=m` (module) to `=y` (built-in) in `kernel/configs/steelhead_defconfig`:
- `CONFIG_DRM=y`, `CONFIG_DRM_OMAP=y` (HDMI display)
- `CONFIG_DRM_PANEL_SIMPLE=y`, `CONFIG_DRM_DISPLAY_CONNECTOR=y`
- `CONFIG_DRM_SIMPLE_BRIDGE=y`, `CONFIG_DRM_TI_TFP410=y`, `CONFIG_DRM_TI_TPD12S015=y`
- `CONFIG_USB=y`, `CONFIG_USB_EHCI_HCD=y` (USB host)
- `CONFIG_USB_MUSB_HDRC=y`, `CONFIG_USB_MUSB_OMAP2PLUS=y` (USB OTG)
- `CONFIG_NOP_USB_XCEIV=y`, `CONFIG_OMAP_USB2=y`, `CONFIG_TWL6030_USB=y` (USB PHY)
- `CONFIG_USB_GADGET=y`, `CONFIG_USB_CONFIGFS=y` (USB gadget/RNDIS)
- `CONFIG_USB_USBNET=y`, `CONFIG_USB_NET_SMSC95XX=y` (Ethernet)
- `CONFIG_FRAMEBUFFER_CONSOLE=y`, `CONFIG_FB=y` (framebuffer console)

### Other Fixes Applied
- `deviceinfo_dtb` changed from `"ti/omap/omap4-steelhead"` to `"omap4-steelhead"` (kernel installs DTBs flat, not under `ti/omap/`)
- `deviceinfo_append_dtb="true"` added (appends DTB to zImage)
- `CONFIG_ARM_APPENDED_DTB=y` in defconfig (DTB concatenated after zImage)
- `CONFIG_ARM_ATAG_DTB_COMPAT=y` in defconfig (REQUIRED for boot, see Investigation Log)
- Rootfs flashes to `userdata` partition (13 GB) since `system` is only 1 GB
- Custom `raw2simg.py` for sparse image conversion. U-Boot supports only RAW +
  DONT_CARE chunks (no FILL/CRC32), but as of 2026-06-28 we emit **all-RAW** (no
  DONT_CARE): U-Boot does NOT erase userdata, so a skipped DONT_CARE block keeps stale
  eMMC data → corrupts the flash (it re-broke libpython; see the 2026-06-28 session).

## Investigation Log & Key Findings

### Finding 1: SMP Is the Only Boot Blocker
`CONFIG_SMP=y` causes a silent deadlock during OMAP4 SMP startup. All other early boot failures were caused by SMP, not by other config options. With SMP disabled, the kernel boots reliably.

### Finding 2: ATAG_DTB_COMPAT Is REQUIRED (Corrected)
Earlier testing incorrectly concluded that `CONFIG_ARM_ATAG_DTB_COMPAT=y` caused crashes. This was wrong -- ATAG_DTB_COMPAT was always disabled alongside SMP, so the real culprit (SMP) was masked. When we later rebuilt with ATAG_DTB_COMPAT=y and SMP=n, the kernel booted fine (6.12.12 #2).

**With ATAG_DTB_COMPAT=n, kernel rebuilds do NOT boot.** The original working binary was a fluke or compiled under slightly different conditions. Multiple clean rebuilds with ATAG_DTB_COMPAT=n (identical config, verified via extract-ikconfig, only 43 bytes of timestamp differences) all failed to boot.

### Finding 3: U-Boot Ignores Boot.img Ramdisk on Partition Boot
U-Boot 2011.09 on the Nexus Q does NOT load the ramdisk section of the Android boot.img when booting from the boot partition. Only the kernel is loaded and executed. This means:
- External ramdisk in boot.img is useless for partition boot
- The initramfs must be embedded in the kernel via `CONFIG_INITRAMFS_SOURCE`
- CyanogenMod worked because it used `fastboot boot` (RAM boot) which DOES load the ramdisk, or because its U-Boot had ramdisk loading patched in

### Finding 4: Boot Method Reliability
- `fastboot flash boot` + cold power-cycle (unplug/replug): **RELIABLE**
- `fastboot boot` (RAM boot): **UNRELIABLE** (intermittent)
- `fastboot reboot`: **UNRELIABLE** (often re-enters fastboot instead of booting)
- Software reboot (panic=XX): Re-enters fastboot

### What Was NOT the Problem
- LZMA compression (GZIP kept for compatibility)
- `CONFIG_OMAP_RESET_CLOCKS` (disabled as precaution)
- `CONFIG_POWER_AVS_OMAP` (disabled as precaution)
- The device tree (omap4-steelhead.dts is correct)
- The boot image format (mkbootimg header v0, correct addresses)
- `CONFIG_ARM_ATAG_DTB_COMPAT` (was falsely suspected)

## Immediate Next Steps

### 1. Verify Embedded Initramfs Boot (IN PROGRESS)
`boot-atag-embedded.img` (6.7 MB) has the kernel with embedded mini-initramfs and ATAG_DTB_COMPAT=y. Currently being tested.

### 2. Get USB Networking / Telnet Access
The mini-initramfs sets up:
- USB gadget RNDIS on micro-USB (host IP 172.16.42.1, client 172.16.42.2)
- Telnet on 172.16.42.1:23
- Tries to mount rootfs from /dev/mmcblk0p13 (userdata)
- Falls back to interactive shell on HDMI console

### 3. Flash Full Rootfs to Userdata
Once we have shell access:
- Flash the full pmOS rootfs to userdata partition (mmcblk0p13)
- Or create a minimal rootfs with networking, then expand later

### 4. Re-enable SMP (Future)
Investigate proper OMAP4460 SMP startup with this U-Boot. May need:
- Custom SMP startup code that handles the undefined CPU1 state
- A secondary CPU holding pen implementation
- Patching the kernel's OMAP4 SMP code to reset CPU1 before bringing it online

## How to Reproduce a Working Boot

```bash
# 1. Build kernel (from /tmp/linux-6.12.12)
export ARCH=arm CROSS_COMPILE=/path/to/arm-none-linux-gnueabihf-
# Ensure .config has: SMP=n, ATAG_DTB_COMPAT=y, INITRAMFS_SOURCE="mini-initramfs.cpio"
make -j$(nproc) zImage dtbs

# 2. Create boot image (kernel + appended DTB, no external ramdisk)
cat arch/arm/boot/zImage arch/arm/boot/dts/ti/omap/omap4-steelhead.dtb > zImage-dtb
# Use Python mkbootimg script (see output/ directory) with:
#   base=0x80000000, kernel_offset=0x8000, ramdisk_size=0, pagesize=2048

# 3. Flash
fastboot flash boot output/boot-atag-embedded.img

# 4. Cold power-cycle (UNPLUG power, wait 5s, replug WITHOUT mute sensor)
# Do NOT use 'fastboot reboot' -- it re-enters fastboot
```

## Device Information

### Partition Layout
```
environment    97 KB    raw
crypto         16 KB    raw
xloader       384 KB    raw
bootloader    512 KB    raw     *** NEVER FLASH ***
device_info   512 KB    raw
bootloader2   512 KB    raw
misc          512 KB    raw
recovery        8 MB    boot
boot            8 MB    boot    (can fit <=8 MB images)
efs             8 MB    ext4
system          1 GB    ext4    (too small for rootfs)
cache         512 MB    ext4
userdata     13.17 GB   ext4    (rootfs target)
```

### Fastboot Mode
- Enter: Cover mute LED sensor during power-on -> solid red LED
- The device is **unbrickable** as long as bootloader is never overwritten
- Serial: `AW1S12241020`
- Bootloader: `steelheadB4H0J` (U-Boot 2011.09-rc1, Apr 2012)

### U-Boot Quirks
- Only supports sparse image chunk types `RAW` and `DONT_CARE` (not `CRC32` or `FILL`).
  NB: U-Boot does **not** pre-erase the partition, so `DONT_CARE` (which fastboot skips)
  leaves stale eMMC data behind — `raw2simg.py` therefore emits **all-RAW**, byte-exact
  (see the 2026-06-28 session: DONT_CARE re-corrupted libpython on re-flash).
- `fastboot boot` accepts images up to ~150 MB (download buffer)
- `fastboot flash boot` limited to 8 MB partition
- USB connection can be flaky -- always power-cycle between flash operations

## Build System

### Docker Build (Windows Host)
```bash
# Build Docker image
docker build -t nexusq-builder .

# Full build (clean)
docker volume rm nexusq-workdir nexusq-output 2>/dev/null
docker run --rm --privileged \
    -v "${PWD}:/src:ro" \
    -v nexusq-output:/tmp/output \
    -v nexusq-workdir:/home/pmos/.local/var/pmbootstrap \
    --name nexusq-build \
    nexusq-builder /src/docker-build.sh

# Extract output
docker run --rm -v nexusq-output:/data -v "${PWD}/output:/out" \
    alpine:3.21 sh -c 'cp /data/*.img /out/'
```

### Build Volumes
- `nexusq-workdir` -- pmbootstrap work directory (kernel build cache, chroots)
- `nexusq-output` -- Output images (boot.img, rootfs)

### Current Build Artifacts in Docker Volume
The `nexusq-workdir` volume contains a **completed kernel build** with the built-in driver defconfig. Key paths inside:
```
chroot_rootfs_google-steelhead/boot/vmlinuz          (5.1 MB, kernel 6.12.12)
chroot_rootfs_google-steelhead/boot/dtbs/omap4-steelhead.dtb  (94 KB)
chroot_rootfs_google-steelhead/boot/config            (kernel config)
chroot_rootfs_google-steelhead/lib/modules/6.12.12/   (150 modules)
```

The `mkinitfs` step failed because `deviceinfo_dtb` had the wrong path (`ti/omap/omap4-steelhead` vs `omap4-steelhead`). This has been fixed in `pmos/device-google-steelhead/deviceinfo`. A clean rebuild should work.

### Manual Image Export
If `mkinitfs` fails in the chroot (QEMU binfmt issues), use `manual-export.sh` which:
1. Fixes DTB path in chroot deviceinfo
2. Builds initramfs manually (copies busybox + modules)
3. Creates boot.img with mkbootimg
4. Creates rootfs ext4 image from chroot

## File Inventory

### Core Configuration
| File | Purpose |
|------|---------|
| `kernel/configs/steelhead_defconfig` | Kernel config (MODIFIED: key drivers =y) |
| `kernel/dts/omap4-steelhead.dts` | Device tree source (579 lines) |
| `kernel/patches/0001-*.patch` | TAS5713 audio amp driver |
| `kernel/patches/0002-*.patch` | TAS5713 DT binding |
| `kernel/patches/0003-*.patch` | Steelhead DTS added to kernel tree |
| `pmos/device-google-steelhead/deviceinfo` | Device config (MODIFIED: DTB path fixed) |
| `pmos/device-google-steelhead/modules-initfs` | Initramfs modules list |
| `pmos/device-google-steelhead/APKBUILD` | Device package recipe |
| `pmos/linux-google-steelhead/APKBUILD` | Kernel package recipe |
| `pmos/firmware-google-steelhead/APKBUILD` | Firmware package recipe |

### Build Scripts
| File | Purpose |
|------|---------|
| `Dockerfile` | Alpine-based build container |
| `docker-build.sh` | Main build orchestrator (10 phases) |
| `build-and-flash.sh` | Top-level build + flash script |
| `manual-export.sh` | Manual image export when mkinitfs fails |
| `raw2simg.py` | Convert raw image to Android sparse format |

### Diagnostic Scripts
| File | Purpose |
|------|---------|
| `build-diag-boot2.sh` | Build minimal diagnostic boot image |
| `build-noramdisk.sh` | Build kernel-only boot image (no initramfs) |
| `fix-dtb.sh` | Manually append DTB to kernel |
| `verify-dtb.sh` | Validate DTB structure |
| `verify-kernel.sh` | Validate kernel binary |
| `inspect-initramfs.sh` | Extract and inspect initramfs contents |
| `inspect-initramfs-detail.sh` | Detailed initramfs inspection |
| `inspect-stage2.sh` | Inspect pmos init stage 2 |
| `regen-initramfs-fixed.sh` | Rebuild initramfs with correct module paths |

### Output Images
| File | Size | Description |
|------|------|-------------|
| `output/boot-atag-embedded.img` | 6.7 MB | **CURRENT** -- SMP=n, ATAG=y, embedded initramfs |
| `output/boot-test-nosmp-noatag.img` | 6.2 MB | Milestone: first boot (SMP=n, ATAG=n, no ramdisk) |
| `output/boot-atag-initramfs.img` | 6.7 MB | SMP=n, ATAG=y, external ramdisk (boots, no initramfs) |
| `output/boot.img` | 13.5 MB | Original full image (SMP=y, no boot) |
| `output/google-steelhead.img` | 720 MB | Rootfs (raw ext4) |
| `output/google-steelhead-sparse.img` | 530 MB | Rootfs (sparse, for flashing) |
| `output/milestone-kernel-boot-2026-02-27.png` | -- | Screenshot of first kernel boot |

## Ubuntu Transition Notes

If continuing on Ubuntu (instead of Windows):
1. USB/fastboot should work natively (`sudo apt install android-tools-adb android-tools-fastboot`)
2. Docker build should be faster (no QEMU overhead for Windows Docker)
3. Can also build natively with pmbootstrap if Alpine chroot works
4. Serial UART debugging is easier with USB-to-serial adapters on Linux
5. The rootfs (`google-steelhead-sparse.img`) is already flashed to the device's userdata partition -- only boot.img needs reflashing after kernel rebuilds
6. Consider using `pmbootstrap` natively on Ubuntu instead of Docker for faster iteration
