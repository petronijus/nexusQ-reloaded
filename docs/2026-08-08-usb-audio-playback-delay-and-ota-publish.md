# 2026-08-08 — USB Audio (UAC2 DAC) develops a multi-minute playback delay + OTA publish

Base: v1.11.0 (tagged 2026-07-31); post-1.11.0 dev. Two things recorded here:
a new **on-device finding** (USB-Audio-in latency runaway) and the **2026-08-08 OTA
publish** (nexusqd r12 + device-google-steelhead r63).

---

## 1. FINDING — USB Audio input drifts ~3 minutes late over a long session

### Symptom (measured on-device, not guessed)
Audio fed into the Q over USB from a **Xiaomi Mi TV Box** (the UAC2 gadget capture,
`nexusq-uac2-in`) plays out the TAS5713 amp correctly, but after a **long session**
it comes out **~3 minutes late**. Not present in a short window; the lag crawls up
over hours.

### Root cause — PulseAudio's latency-based rate controller is fed a bogus latency
The bridge is `module-alsa-source` on the async UAC2 gadget capture
(`hw:UAC2Gadget`, `pcm0c`) → `module-loopback` → default sink (TAS5713).

- `module-alsa-source` on this **async** capture reports a **bogus,
  monotonically-growing source latency** ≈ **uptime** (measured ~64 s of reported
  latency at 64 s uptime; **5134 s** seen after a long run) instead of the real
  ~millisecond buffer.
- `module-loopback`'s adaptive resampler is **latency-driven**: it trims the sample
  rate to hold a target end-to-end latency. Fed an ever-growing bogus latency, it
  drives the resampler to the **±1 % rail (48480 Hz)** and lets the `memblockq`
  backlog grow — to **minutes** — which is exactly the audible delay.

### Ruled OUT (each measured, not assumed)
- **Clock mismatch between the two cards** — effective capture rate measured
  **48004.79 fps over a clean 30 s = +100 ppm**. Normal. The two cards being
  independently clocked is real but tiny; it is NOT what produces a 3-minute lag.
- **The ALSA capture buffer** — `delay`/`avail` ~144 frames = **~3 ms**;
  `buffer_size` 16384 **never fills**. The capture side is healthy.
- **`tsched=0`** — tested live: with timer-scheduling off, the reported source
  latency **still grew** (25 s → 33 s), so `tsched=0` does **NOT** fix the runaway.
  (It WOULD help the *related* idle-CPU busy-poll below, just not the delay.)

### Not reproducible in a short window
After any service restart the path is **healthy** — ~**134 ms** total, resampler
neutral (~48002 Hz). The fault only emerges after **hours**; a spot-check right
after `systemctl --user restart nexusq-uac2-in` will look fine.

### Related defect — idle CPU + thermal cost while nothing plays
The same broken loopback **busy-polls a STALLED capture**: when the Xiaomi source is
paused, `hw_ptr` is frozen but the PCM state stays **RUNNING**, so the loopback keeps
polling → steady **nice-CPU** and ~**+5 °C** even with no audio (die **78 °C** with
`nexusq-uac2-in` running vs **73 °C** stopped). Device thermals are otherwise fine
(73–78 °C die; critical ~98–99 °C), so this is a waste, not a hazard. `tsched=0`
would blunt this busy-poll (but, per above, not the delay).

#### Deeper root cause (measured 2026-08-08) — the loopback never lets the sink suspend
`module-suspend-on-idle` **IS loaded**, but the `module-loopback` **sink-input is
never corked** (`Corked: no`): the loopback feeds the TAS5713 sink **continuously**
(silence when the source is idle/stalled), so suspend-on-idle can **NEVER** suspend
the sink. That keeps the **TAS5713 DAC + the audio clock + the DMA + the
speex-float resampler powered and running 24/7** — that is what burns the steady CPU
and the +5 °C in silence. On top of it, `module-alsa-source` **timer-polls** the
async UAC2 gadget capture (`Flags: LATENCY` / `tsched`).

Numbers, so the next session doesn't re-derive them:
- Stopping `nexusq-uac2-in` drops nice-CPU to **~0** and die temp **78 → 73 °C**.
- During **active** streaming + the nexusqd LED music visualizer's `arecord -D pulse`
  capture, the CPU sits pinned at **1.2 GHz** and **~91–94 °C** — **not yet
  thermally throttling** (`scaling_max_freq` still 1200; the trip is higher; overall
  thermals still within range, critical ~98–99 °C).
- The `arecord` is **legitimate** (nexusqd's LED music visualizer reading the sink),
  **not a leak** — don't flag it as a runaway.

**Fix ties to the SAME bridge redesign** as the delay above: `alsaloop
--sync=samplerate`, **or** making the loopback **cork-on-silence** so the sink can
actually suspend when nothing is playing. Record both under the one USB-audio
redesign follow-up.

### Likely fix — NOT yet implemented (needs hours-long validation)
Redesign the bridge away from PulseAudio's broken latency smoother. Candidate:
`alsaloop --sync=samplerate` — **closed-loop sample-rate tracking** between the two
independently-clocked cards (UAC2 capture ↔ TAS5713 playback), which corrects for the
real +100 ppm without trusting a fabricated latency figure — while still routing
through PulseAudio so USB audio keeps **mixing with Spotify / AirPlay / Roon**.
Must be validated over **hours**, since the fault only shows over hours.

Path to touch: `pmos/device-google-steelhead/nexusq-uac2-in` (+ `.service`). The
source device is documented in `~/Documents/Dev/xiaomi-tvbox-twilight`
(adb `192.168.20.169:5555`; switch its USB port to host mode with
`gpioset -t 0 -c 0 16=0`).

---

## 2. OTA published 2026-08-08

`scripts/publish-ota-repo.sh` pushed to `gh-pages`
(`https://petronijus.github.io/nexusQ-reloaded/nexusq`):

- **`nexusqd` 0.1.0-r12** — front-panel volume **ring applied headless** via
  `nq-vol` (turning the physical dome ring changes volume with no desktop/app in the
  loop). **Confirmed working on-device by Petr — the ring changes volume.**
- **`device-google-steelhead` 1.0-r63** (+ its `firmware-google-steelhead` r63
  subpackage) — **desktop OFF by default**: `default.target` → `multi-user.target`
  symlink (was `graphical.target`, which auto-started the HDMI desktop), and the
  **duplicated labwc audio keybinds** dropped.
- Unchanged in the index: `nexusq-control` **r25**, `nexusq-btagent` **r4**,
  `nexusq-setupd` **r4**.

### Build defect this fixed — local main `024d928` (committed + pushed)
The committed r63 APKBUILD ("desktop off by default", commit `9a9bb16`) did
`ln -sf … default.target` as the **first** thing to touch
`$pkgdir/etc/systemd/system`, but nothing had created that directory yet (later
blocks `install -dm755` it, but they run **after**) — so a clean pipeline build of
r63 **failed**: `ln: … default.target: No such file or directory`. The committed r63
**never actually built through docker-build**. Fix: `install -dm755` the dir before
the symlink.

Same commit added an **`OTA_PACKAGES_ONLY=1`** gate to `docker-build.sh`: a targeted
**two-package** build (`nexusqd` + `device-google-steelhead`, both `--force`) that
reuses all the load-bearing setup verbatim (aports staging, abuild-as-root, config,
REPODEST ownership, checksums) then exports **just the two signed apks** to the
work-volume repo for `publish-ota-repo.sh` — **no full rootfs / boot.img**. Pure
addition; the full-pipeline path is unchanged.

> `024d928` is **committed and pushed to `main`** (2026-08-08, 024d928).

### Companion finding — System OTA reports "system update failed"
The same session found the **System** update track (`installSystemUpdate`) reporting
**"system update failed"** — a `postmarketos-mkinitfs` / `boot-deploy` pending
trigger that fails because `/boot` is empty on this ramdisk-less device (the packages
still install; it's cosmetic + blocks a clean apk state). Full record:
`docs/2026-08-08-system-ota-mkinitfs-trigger-failure.md`.
