# 2026-07-07 (evening) — Audio outputs: SPDIF bring-up, the McBSP2 pinmux fix that finally drove the speaker, and the PA-centric multi-input system (v1.6.15)

> ✅ **IMPLEMENTED + BAKED — v1.6.15 (built 2026-07-07; final clean-flash
> acceptance still PENDING).** The kernel SPDIF/McBSP2 work below was built +
> flashed as the v1.6.13 test build (kernel `pkgrel=36` / r36, `rc2` probe fix
> folded in). The PA-centric routing redesign that was originally *decided* here
> is now **implemented and baked into the image** — see the "IMPLEMENTED" section
> at the end. Package delta: `device-google-steelhead` **r31**, `nexusq-control`
> **r6**, `nexusqd` **r7**, `linux` **r36**. Versioning is tag-only; v1.6.13 was a
> test build, v1.6.15 is the milestone that ships this.

This is the richest single record of the 2026-07-07 audio-outputs work — the
lower half (from "Decision") records the plan as first decided; the final
"IMPLEMENTED" section records what actually shipped + what was verified live.
Companion to the two earlier 2026-07-07 notes (desktop-audio PA fix, WiFi/ethernet).

---

## Built + flashed: v1.6.13 (kernel r36)

Two changes landed in the DTS (patch `0003` regenerated) + defconfig; no C driver
work.

### 1. SPDIF (optical TOSLINK) bring-up
Mainline `davinci-mcasp` already supports `ti,omap4-mcasp-audio` + DIT/IEC958, so
this is pure DT + Kconfig.

- **defconfig** (`kernel/configs/steelhead_defconfig`):
  `CONFIG_SND_SOC_DAVINCI_MCASP=m` + `CONFIG_SND_SOC_SPDIF=m`.
- **DTS** (`kernel/dts/omap4-steelhead.dts`):
  - `&mcasp0` enabled (`status = "okay"`; the node itself lives in
    `omap4-l4-abe.dtsi`).
  - new `mcasp_spdif_pins` = `OMAP4_IOPAD(0x0f8, PIN_OUTPUT | MUX_MODE2)`
    (`abe_mcbsp2_dr` → `abe_mcasp_axr`, serializer AXR0 out). Mirrors stock
    `board-steelhead.c`: `omap_mux_init_signal("abe_mcbsp2_dr.abe_mcasp_axr", 0)`
    → padconf `0x0f8 = 0x0002`. That ball is McBSP2's data-RECEIVE line, unused by
    the TX-only speaker link, so it is free to become the McASP output.
  - new `sound_spdif` simple-audio-card (name `NexusQ-SPDIF`): `mcasp0` DIT DAI ↔
    `spdif_dit` codec (`compatible = "linux,spdif-dit"`). In DIT mode the McASP
    generates its own IEC958 framing; the card just binds the DIT DAI to the DIT
    codec (stock parity: stock's "Steelhead SPDIF Card" = omap-mcasp-dai ↔
    dit-hifi, ABE L3 IRQ disabled — no ABE DSP firmware needed).

### 2. McBSP2 pinmux FIX — and the MAJOR finding
`mcbsp2_pins` was muxing pads `0x110 / 0x114 / 0x116`. **Those are the
`abe_dmic_*` balls, NOT McBSP2.** With the wrong mux, the real McBSP2 I2S balls
(`0x0f6` clkx / `0x0fa` dx / `0x0fc` fsx) sat in **`safe_mode`**, so the TAS5713
amp received **no clock, no data, no frame**.

**→ The banana-terminal speaker was SILENT for the entire project.** `aplay`
returned `rc=0` (the ALSA/PCM/softvol pipeline was healthy end-to-end in software)
but nothing was ever driven onto the physical amp. **This recontextualizes every
prior "TAS5713 audio works" claim as software-pipeline-only.**

Fix: mux the stock McBSP2 pads at `MUX_MODE0` (McBSP2 is bit/frame master → all
OUTPUT):

```
OMAP4_IOPAD(0x0f6, PIN_OUTPUT | MUX_MODE0)  /* abe_mcbsp2_clkx */
OMAP4_IOPAD(0x0fa, PIN_OUTPUT | MUX_MODE0)  /* abe_mcbsp2_dx   */
OMAP4_IOPAD(0x0fc, PIN_OUTPUT | MUX_MODE0)  /* abe_mcbsp2_fsx  */
```

Confirmed against `reverse-eng/stock-omap-mux-full.txt` **and** a live `pinctrl`
read. **After the fix the speaker actually plays — user confirmed audible sound.**

---

## SPDIF probe fix → rc2 (built, NOT yet flashed)

On the flashed v1.6.13 the SPDIF card **failed to probe**:

```
davinci_mcasp 40128000.mcasp: ASoC: error at snd_soc_dai_set_fmt -22
```

Cause: `simple-audio-card` passed a DAI fmt with the **FORMAT field = 0**, so
`davinci_mcasp_set_dai_fmt()` fell through to `default:` → `-EINVAL` (-22).

Fix (kernel-only rebuild `rc2`): give `sound_spdif` a valid format and make the
McASP the bit + frame master (DIT drives its own TX clock from the ABE McASP fck;
`spdif-dit` is a dummy sink, no external codec clock):

```
simple-audio-card,format = "i2s";
simple-audio-card,bitclock-master = <&spdif_cpu>;
simple-audio-card,frame-master   = <&spdif_cpu>;
```

- Artifact: `output/nexusq-boot-v1.6.13-spdif-rc2.img` — **boot.img only**.
- Kernel `pkgrel` deliberately kept at **36** so module vermagic still matches the
  already-flashed rootfs modules (kernel-only swap).
- **DTB verified. rc2 is built but NOT yet flashed.**

---

## Speaker CRACKLE — first theory (now superseded), still an open polish item

Once audible, playback crackles / micro-drops.

- **NOT a clock issue.** `auxclk1` = 12.288 MHz (TAS5713 MCLK) and `abe_24m_fclk`
  = 24.576 MHz (McBSP2 BCLK) are coherent — same ABE DPLL root.
- **NOT caused by the mcbsp2 fix.**
- **First theory (was: `asound.conf` `type multi`).** The chain
  `nexusq_soft` → `nexusq_tee` → `nexusq_both` (`type multi`) fanned the stream in
  lockstep to BOTH the TAS5713 (real hardware clock) and the snd-aloop Loopback
  tap (an `arecord` for the LED visualizer) — two asynchronous clock domains in one
  `type multi`, so tap jitter back-pressured the speaker.
- **Status as of v1.6.15 (was type-multi, now moot):** the `type multi` is GONE —
  the tap moved to a PA monitor source (which cannot back-pressure the sink) and PA
  is the single writer to the speaker. So the type-multi explanation no longer
  applies. The crackle is deferred as a polish item: **re-diagnose from measurement
  with the speaker safe-disconnected**, and check whether pinning PA to 48 kHz
  (`50-nexusq-48k.conf`) already reduced it.

---

## Decision: PA-centric redesign (per user requirement, 2026-07-07)

User clarified: outputs must **NOT** all play at once — he wants to **select** the
active output (TAS5713 / HDMI / SPDIF) from the **companion app**. Decided
architecture (implementation is a follow-up; none of this is baked yet):

- Each output = a selectable **PulseAudio sink**: TAS5713 exists today; SPDIF
  appears once rc2 is flashed; HDMI = **un-ignore** the
  `91-pulseaudio-hdmi-ignore.rules` rule when wanted.
- **Output selection = `pactl set-default-sink`**, driven by the companion app →
  bridge.
- **Remove the `asound.conf` `type multi`.** The companion metering tap becomes a
  **PA monitor source** (`parec` on `<sink>.monitor` — never back-pressures the
  sink) instead of the arecord-loopback. **This also fixes the crackle.**
- **Volume → `pactl set-sink-volume`** (was `amixer` on the "NexusQ" softvol).
- **librespot 0.8.0 has NO pulseaudio backend** (rodio / alsa / pipe / subprocess
  only). Route it to PA via the **ALSA `pulse` plugin**: `--backend alsa --device
  pulse` (`alsa-plugins-pulse` + `libasound_module_pcm_pulse.so` are present).
  - **Wrinkle:** librespot is a **root** system service, but PulseAudio runs in the
    **uid-10000** user session. Decision: **run librespot as `user`** so it shares
    the PA session.
- **`nexusq-control`** (442-line python bridge) needs rework: volume via `pactl`,
  tap via PA monitor, plus a new **output-select** command. The companion app
  gains an output-selector UI (follow-up).

---

## HDMI audio (recorded earlier today, unchanged)

The HDMI card is the **real `omap-hdmi-audio`** (not a stub). PCM open returns
`-EINVAL` only because the attached display is a **Philips 190C DVI monitor**
(128-byte EDID, no CEA extension → no audio block). Very likely works on an
audio-capable HDMI sink (TV / AVR) with no code change — **UNTESTED**.

---

---

## IMPLEMENTED — the PA-centric audio system (v1.6.15, built 2026-07-07)

All of the plan above is now baked. Each capability was confirmed live during
bring-up; the only remaining gate is the final clean-flash acceptance sweep.

### librespot as a PA input (VERIFIED end-to-end)
- `librespot.service` moved to a systemd **USER** unit (`/usr/lib/systemd/user/`,
  enabled via a `default.target.wants/` symlink — same mechanism as
  `pulseaudio.service`, no linger under autologin) so it runs in the uid-10000
  session and shares its PulseAudio.
- New wrapper `/usr/bin/librespot-nexusq`: `--backend alsa --device pulse` (0.8.0
  has no native PA backend → the ALSA `pulse` plugin), `--ap-port 443`,
  `--disable-credential-cache`, and **`--zeroconf-interface <wlan0 IP>`** resolved
  at start. Why the interface pin: 0.8.0 here is built with ONLY the libmdns
  zeroconf backend (`--zeroconf-backend avahi` errors "Valid values: libmdns"), and
  libmdns advertises on every interface → it announced the **usb0 gadget IP
  (172.16.42.1)**, unreachable from a WiFi phone. The wrapper waits for wlan0's
  IPv4 and pins libmdns to it.
- avahi additionally constrained to wlan0 (`allow-interfaces=wlan0`) — the
  post-install patches `avahi-daemon.conf` in place (avahi has no drop-in dir),
  idempotently, because avahi-daemon also answered `steelhead.local` on every iface.
- **VERIFIED:** Spotify Connect discoverable + connectable + plays into PA (shows
  as a sink-input on the default sink).

### Output selection (VERIFIED end-to-end)
- `nexusq-control` gained `listOutputs` / `setOutput` (+ `outputChanged`). Known
  sinks map to a stable id + Czech label by substring: `tas5713`→`speaker`
  ("Reproduktor"), `spdif`→`spdif` ("Optický výstup"), `hdmi`→`hdmi` ("HDMI").
- `setOutput` = `pactl set-default-sink` (new streams) **+** `move-sink-input` for
  every current sink-input (a playing stream follows — input-agnostic) + a class-D
  amp **Speaker** on/off safety toggle (amp on only when `speaker` is active) +
  `set-default-source <sink>.monitor` so the LED tap follows the output.
- Volume/mute reworked `amixer`→`pactl` (`set-sink-volume`/`set-sink-mute` on the
  active sink). The bridge runs as root and reaches the user-session PA via
  `PULSE_SERVER`/`PULSE_COOKIE` (env `NEXUSQ_PULSE_SERVER`/`NEXUSQ_PULSE_COOKIE`,
  defaults `unix:/run/user/10000/pulse/native` + `/home/user/.config/pulse/cookie`).
- Flutter companion app gained an OUTPUT selector (Holo-dark segmented control).
- **VERIFIED:** app switch → device default sink changes + amp Speaker toggles.

### SPDIF pinned to 48 kHz (VERIFIED)
- `/etc/pulse/daemon.conf.d/50-nexusq-48k.conf`: `default-sample-rate = 48000`,
  `alternate-sample-rate = 48000`, `avoid-resampling = false`. PA runs every sink
  at 48 kHz and resamples 44.1 kHz sources (Spotify). At 44.1 kHz the McASP DIT
  logged "Sample-rate is off by 88435 PPM" (== 48000/44100) → detuned optical out;
  the McBSP2→TAS5713 link is built around an exact 48 kHz FSYNC (patch 0022 CLKGDV).
- **VERIFIED:** both PA sinks report 48000 Hz on a fresh boot.

### LED music-visualizer: PA-monitor tap + AGC (VERIFIED live)
- The visualizer tap moved off the (removed) snd-aloop loopback to a **PA monitor
  source**: nexusqd runs `arecord -D pulse` (captures PA's default SOURCE, which the
  bridge keeps pointed at the active sink's `.monitor` — follows output selection).
  `nexusqd.service` gets `PULSE_SERVER`/`PULSE_COOKIE` so the root daemon reaches the
  uid-10000 PA; no start ordering vs PA (audio.c respawns on EOF until PA is up).
- **AGC** (nexusqd r7, `audiocap.c` / `audiocap.h`): the monitor is post-volume, so
  raw level scales with listening volume (~0.01–0.03 mean-abs at normal vs ~0.1–0.2
  full-scale). Normalize to `AGC_TARGET 0.15` (fast attack, `AGC_RELEASE 0.95` EMA
  ~1.5 s slow release, `AGC_NOISE_FLOOR 0.001` gate, `AGC_MAX_GAIN 50`) so the LED
  reacts to the music regardless of volume — matching the old pre-volume loopback tap.
- **VERIFIED live:** steady `audio DETECTED vol=0.150` (== AGC_TARGET), no flicker.
  The pre-AGC symptom was the visualizer flickering ↔ breathing at low volume.

### Multi-input roadmap (future — architecture already supports it)
Output selection + the LED monitor tap work for ANY PA input, so each future input
is just another PA client into the same hub: **Bluetooth-A2DP** (bluez +
pulseaudio-bluez, both present), **Tidal** (unofficial Linux daemon), **casting**
(AirPlay via shairport-sync). No further routing work needed.

### Files (v1.6.15)
- Kernel (v1.6.13 / r36): `kernel/dts/omap4-steelhead.dts` (`mcbsp2_pins` fix
  0x0f6/0x0fa/0x0fc MUX_MODE0, `mcasp_spdif_pins`, `sound_spdif` incl. rc2
  format/master, `&mcasp0`/`&mcbsp2` enable), regenerated
  `kernel/patches/0003-ARM-dts-omap4-add-steelhead.patch`,
  `kernel/configs/steelhead_defconfig` (`SND_SOC_DAVINCI_MCASP=m`,
  `SND_SOC_SPDIF=m`).
- Device (r31): new `pmos/device-google-steelhead/librespot-nexusq` (wrapper),
  new `50-nexusq-48k.conf`, `librespot.service` (now a USER unit),
  `pulseaudio.service`, `nexusq.preset` (librespot note), `.post-install` (avahi
  wlan0 pin), `APKBUILD` (source/sha512sums/pkgrel).
- Bridge (nexusq-control r6): `userspace/nexusq-control/nexusq-control` (Pulse class,
  listOutputs/setOutput, pactl volume/mute, monitor source), `README.md`.
- LED daemon (nexusqd r7): `userspace/nexusqd/src/audiocap.c` + `include/audiocap.h`
  (AGC), `nexusqd.service` (PULSE_SERVER/PULSE_COOKIE).
- Companion: `companion/PROTOCOL.md` (§ Audio output), app `models.dart`,
  `home_screen.dart`, `device_controller.dart`, `mock_client.dart`.

### Deferred polish (NOT in v1.6.15 — need care/hardware)
1. **Volume gain-cap** — TAS5713 amp is very hot (app ~8% ≈ deafening); the bridge
   sends plain linear pactl % for now. Cap the Master/Speaker gain so 0–100 maps to
   a usable SPL range; needs calibration with the user at a safe volume / reconnected
   speaker.
2. **Boot default output** — should be the speaker; PA picked spdif/sink0 on boot in
   testing. Ensure the speaker sink is the boot default and not muted.
3. **Speaker crackle** — see the crackle section above (type-multi theory now moot;
   re-diagnose from measurement, speaker safe-disconnected).

### Gotcha for the next debugger
`ss` is **NOT installed** on the device (busybox/Alpine minimal) — it caused a long
misdiagnosis of "no listener". Use **`netstat`** (`netstat -tlnp` / `netstat -ln`)
to check listening sockets on the Nexus Q.
