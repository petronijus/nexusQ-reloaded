# Nexus Q LED Ring — Modern Driver + Faithful Behavior (Design)

**Date:** 2026-06-19
**Status:** Approved design, pending spec review → implementation plan
**Device:** Google Nexus Q ("steelhead"), postmarketOS on mainline Linux 6.12.12

## Goal

Drive the Nexus Q's 32-LED ring (+ 1 mute LED) on mainline Linux with **modern,
idiomatic code** while reproducing the **original Nexus Q behavior as closely as
possible** — pixel-perfect on the LED ring.

**In scope:** the 32-LED ring + mute LED only.
**Out of scope:** HDMI / on-screen visualization, GPU rendering. No display output
of any kind — only the ring.

## Background / what we know (verified)

- The 32 RGB ring LEDs + 1 mute LED sit behind the **steelhead-AVR** MCU at i2c
  bus 1, address `0x20` (`/dev/i2c-1`). DT node `avr@20`, compatible
  `google,steelhead-avr`, already present in `kernel/dts/omap4-steelhead.dts`
  (reset = gpio2-16, INT = gpio2-17). No mainline driver binds today.
- AVR register protocol (from AOSP `drivers/misc/steelhead_avr_regs.h`,
  confirmed live 2026-06-19 — see memory `led-ring-avr-protocol`):
  `0x02` LED_MODE (0x02=HOST), `0x03` SET_ALL, `0x04` SET_RANGE,
  `0x05` COMMIT (0x00 immediate / 0x01 interpolate), `0x06` SET_MUTE,
  `0x07` GET_COUNT, `0x08` HW_TYPE (0x01=SPHERE), `0x09` HW_REV, `0x0A` FW_VER,
  `0x00` KEY_EVENT_FIFO (mute/volume buttons), `0x01` MUTE_THRESHOLD.
  AVR reports HW_TYPE=SPHERE, count=32. Boot/power-up animations live in AVR
  firmware (modes 0x00/0x03) and run autonomously — reproduced "for free".
- The OMAP4 PowerVR SGX540 has **no mainline GPU driver** (software rendering
  only). This is irrelevant for the ring: only 32 output values per frame are
  needed, which is trivial on CPU. The original's GPU dependence was for the
  HDMI scene, which we drop.

### Original architecture (recovered from the tungsten-ian67k factory image)

- A central **LED service** (`TungstenLEDService.apk`, `com.google.tungsten.LedService`,
  AIDL `ILedService`: `setLed`, `setLedRange`, `setLeds`, `setMuteLed`, `setMode`,
  `commitLEDValues(CommitMode)`) owned `/dev/leds`; clients requested LED states.
  → validates our **userspace daemon** design.
- The **visualizer** (`Visualizer.apk`, `com.google.android.tungsten.visualizer`)
  used Android's `android.media.audiofx.Visualizer` (audio FFT/waveform tap on the
  output mix) feeding a node-graph renderer: nodes `Waveform`, `WaveformSolid`,
  `Circles`, `StarField`, `ParticleScreensaver` (idle), `PointMorph`, `BlurEffect`,
  `FadeTransition`, `TrackInfoOverlayEffect`. Shaders are small GLSL `_f`/`_v`
  files; 3D models (`pointmorph_model_*`) have `_led` mapping variants; the ring
  had dedicated LED render paths (`particle_screensaver_mute_*`).
- **Themes** ("color schemes") are plain JSON in `HubBroker.apk` `res/raw/theme_*`,
  using the Android Holo palette:
  | theme | led | mode | colors |
  |-------|-----|------|--------|
  | blue | 1 | 1 | `#33B5E5` |
  | cool | 1 | 1 | `#99CC00 #669900 #0099CC #33B5E5` |
  | warm | 1 | 1 | `#CC0000 #FF4444 #FF8800 #FFBB33` |
  | smoke | 1 | 1 | `#070707 #222222 #111111` |
  | spectrum | 1 | 1 | `#AA66CC #FF4444 #CC0000 #FF8800 #FFBB33 #99CC00 #669900 #0099cc #33b5e5` |
  | trackinfo | 1 | 2 | (same 9 as spectrum) |
  | off | 0 | 1 | `#000000` |
  (`mode` 1=visualizer, 2=trackinfo overlay; `display` ignored — no HDMI.)

### Original assets (proprietary — NOT committed)

Google's themes, GLSL shaders, models, and textures are proprietary, like the
BCM firmware blobs removed from the public repo. They are staged in the
gitignored private overlay at `private/nexusq-original/` (`themes/`,
`visualizer/`, plus `Visualizer.apk` / `HubBroker.apk` for reference) and are
**extracted from the official Google factory image** at build time, not
redistributed. A `scripts/setup-leds-assets.sh` (analogous to
`setup-firmware.sh`) will extract them:
factory image `https://dl.google.com/dl/android/aosp/tungsten-ian67k-factory-d766e5f1.zip`
→ unzip → `simg2img` `system.img` → extract `app/Visualizer.apk` +
`app/HubBroker.apk` (the ext4 image opens directly in 7-Zip) → pull
`res/raw/theme_*` and `res/raw/*` shaders/models.

## Architecture

Three cleanly separated layers, mirroring the original (AVR firmware + kernel
driver + host service):

1. **AVR firmware** — on-chip, unchanged. Provides boot/power-up animations.
2. **Kernel driver** `drivers/leds/leds-steelhead-avr.c` — mechanism: talk to the
   AVR, expose LEDs + buttons.
3. **Userspace daemon** `nexusqd` — policy: all animations and behavior.

## Component 1 — Kernel driver (`leds-steelhead-avr`)

New file `drivers/leds/leds-steelhead-avr.c` + Kconfig (`CONFIG_LEDS_STEELHEAD_AVR`)
+ Makefile, shipped as kernel patch `0005-*`. i2c driver matching
`of_device_id` compatible `google,steelhead-avr`. Fully `devm_`-based.

**Probe:** `devm_gpiod_get(reset)` + reset pulse → wait for AVR boot; read
FW/HW/rev/count (validate count==32); set MODE=HOST; allocate shadow framebuffer
(33×RGB); register the three interfaces below; `devm_request_threaded_irq` on the
INT gpio (FALLING, ONESHOT).

Three userspace interfaces over **one mutex-protected shadow framebuffer**:

1. **Multicolor LED class** — 32 ring + 1 mute as `led_classdev_mc` (3 sub-LEDs
   each). Names `/sys/class/leds/steelhead:rgb:ring-0…31`, `steelhead:rgb:mute`.
   `brightness_set_blocking` writes one LED into the shadow buffer then
   `SET_RANGE`+`COMMIT`. Idiomatic per-LED control + integration/triggers.
2. **Frame channel** — efficient batch path for the daemon:
   - binary sysfs `frame` — write 96 B (32×RGB) overwrites the whole ring
   - `commit_mode` — 0 immediate / 1 interpolate (AVR COMMIT)
   - `mute` — RGB for the mute LED
   - one frame write → one `SET_RANGE`(0x04) + `COMMIT`(0x05)
3. **input_dev** — IRQ thread drains the FIFO (reg 0x00), decodes down/up +
   keycode → `input_report_key` → `KEY_MUTE`/`KEY_VOLUMEUP`/`KEY_VOLUMEDOWN`.

**Resilience:** i2c retry (5 attempts). On `KEY_EVENT_RESET` (0xFE) in the FIFO,
re-assert HOST mode and reload the shadow framebuffer (as the original did).

## Component 2 — Userspace daemon (`nexusqd`)

Written in **C** (long-running ~30–60 fps loop on a single 1 GHz Cortex-A9; no GC,
low overhead; shader ports are C anyway).

Structure:
- **output:** opens the kernel `frame` / `commit_mode` / `mute` sysfs
- **compositor:** priority layering → one frame → write. Layers low→high:
  1. idle/ambient (ParticleScreensaver node), 2. visualizer (when audio playing),
  3. volume overlay (transient on VOLUME key, ~2 s fade), 4. status animations.
  Mute LED (index 0) is independent and always reflects mute state.
- **input:** reads `/dev/input/eventX` for the AVR keys
- **audio:** captures the output mix (see visualizer) → FFT → visualizer
- **themes:** loads the original `theme_*.json` palettes verbatim
- **control:** Unix-domain-socket API mirroring `ILedService`
  (`setTheme`, `setAll`, `setRange`, `setMode`, `setMute`, `commit`, `notify`)
- **`nexusled` CLI:** mirrors the original `avrlights [start] [count] [color…]`
  (index 0 = mute, 1.. = ring); talks to the daemon socket, or writes sysfs
  directly when the daemon is not running; plus `nexusled theme <name>` / `off`.
- **systemd:** `nexusqd.service`, starts at boot, sets idle glow.

## Component 3 — Visualizer (pixel-perfect ring)

1. **Audio tap:** capture the output mix, matching the original (Android
   `Visualizer` tapped the mix). Primary: a **PipeWire/PulseAudio monitor source**;
   fallback: **ALSA `snd-aloop`**. *The device's audio stack must be confirmed
   during implementation.*
2. **Analysis:** replicate **Android `Visualizer` semantics** (mono 8-bit downmix,
   fixed capture size, its FFT byte layout/scaling) so the ported shaders see the
   same input. Small radix-2 FFT — negligible CPU.
3. **Shader port:** each node's `_f` fragment shader ported to C; evaluate at the
   32 ring sample positions; for neighbor-dependent effects (blur/particles/
   starfield) render a small CPU buffer then sample 32 points. The exact 32-LED
   sample geometry comes from the `*_led` model/mapping files. Node graph + theme
   palette select what runs.

## Component 4 — Behaviors & assets

| Behavior | Fidelity |
|----------|----------|
| Themes / palettes | pixel-perfect (extracted JSON, used verbatim) |
| Visualizer nodes, idle ParticleScreensaver, mute screensaver | pixel-perfect (ported shaders) |
| Boot / power-up | original (AVR firmware) |
| Volume overlay | **must be pixel-perfect — reverse-engineer exact rendering during implementation** (HubBroker/Music2/system) |
| Mute LED color + behavior | **must be pixel-perfect — reverse-engineer during implementation** |
| Status animations (reset red→blue, wipe purple) | behavior-faithful from documentation; reset/wipe in recovery are AVR/firmware (outside the daemon) |

Default active theme persists across reboots.

## Build & flash strategy

Driver built as a **module** so most iteration avoids reflashing the kernel:
1. One kernel rebuild (Docker, GCC 13.3) to enable `CONFIG_LEDS_STEELHEAD_AVR=m`
   and `CONFIG_LEDS_CLASS_MULTICOLOR=m`; flash `boot.img`.
2. Then each driver change = rebuild only the `.ko` in-tree → `scp` →
   `rmmod`/`modprobe`. No further reflash, no boot risk.
3. Flash from the running system: `dd if=boot.img of=/dev/mmcblk0p9 bs=1M
   conv=fsync` + `systemctl reboot`. Keep known-good `boot-wifi-v5.img` as
   fallback (flaky boot ~1/3 → power-cycle / fastboot the old image). Bootloader
   never touched → unbrickable.

Daemon/CLI: pure userspace, iterate freely (scp + restart). Packaged for
postmarketOS/Alpine (armv7, musl) with theme JSONs; assets staged via
`setup-leds-assets.sh`.

## Testing & verification

- **Driver:** module binds; `/sys/class/leds/steelhead:rgb:*` + frame channel +
  input device appear; single-LED echo; frame-channel write + commit modes;
  `evtest` shows the keys; AVR-reset state restore; i2c retry under load.
- **Pixel-perfect (core) — golden test vs the original shaders:** a host test
  harness runs the original GLSL shader (desktop GL / reference evaluator) and our
  C port on identical synthetic audio/FFT input and diffs the 32 RGB values
  frame-by-frame (tolerance ±1 LSB), per node and per theme. Written first (TDD);
  the shader port is implemented against it. Themes verified by asserting palette
  equality. FFT verified against the Android format with a known tone.
- **Observability:** daemon dumps 32-LED frames to a file; an offline simulator
  renders frames to a PNG strip / terminal so animations are tuned without
  hardware.
- **On-device acceptance:** visual/video check of idle, theme switch, volume
  overlay, mute, and the visualizer reacting to music.

## Open items to resolve during implementation

1. Reverse-engineer the **exact volume-ring rendering** and **mute LED color/
   behavior** for pixel-perfect fidelity (not yet sourced).
2. Confirm the device's **audio stack** (PipeWire/Pulse vs bare ALSA) for the tap.
3. Confirm the original **default theme** and update cadence (`utils/Clock` FPS).
4. Obtain a **reference capture** of the original ring for acceptance, if possible.
