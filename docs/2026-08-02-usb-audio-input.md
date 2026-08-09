# 2026-08-02 — USB Audio input: the Nexus Q as a toggleable USB DAC

Base: v1.11.0 (tagged 2026-07-31). Ships as post-v1.11.0 dev work — device runs
dev build **v1.11.3** (untagged). HEAD `0565977`
(`feat(audio): USB Audio input — the Q as a toggleable USB DAC (UAC2 gadget)`).
Packages: `linux` **r46** (`#47`), `device-google-steelhead` **r60**,
`nexusq-control` **r16**, companion app **1.7.0+16**.

> **⚠️ SUPERSEDED (audio path only) — as of 2026-08-09 / `device-google-steelhead`
> r65 (commit `2dccd3a`), the PulseAudio `module-alsa-source` + `module-loopback`
> bridge described below was replaced by a DIRECT `alsaloop -C hw:UAC2Gadget
> -P hw:NexusQSpeaker --sync=simple` bridge (no PulseAudio in the audio path).** This
> fixed the multi-minute playback delay AND the idle CPU/heat burn that the PA design
> developed (recorded in `docs/2026-08-08-usb-audio-playback-delay-and-ota-publish.md`).
> Consequence: **USB audio is now EXCLUSIVE** — it suspends PA's tas5713 sink (no
> simultaneous mixing with Spotify/AirPlay/Roon), and `nq-vol` drives the TAS5713
> hardware mixer while it's on. Everything else in this note (kernel `uac2.0` gadget,
> the app toggle, the "no audio input" analysis) still stands.

## The problem: the Q has no audio INPUT

Petr wanted to feed external audio into the Q's amp. It has none of the obvious
inputs — **every port on the sphere is an OUTPUT**:

- **Optical / SPDIF** — the DTS runs **McASP0 in DIT (transmit) mode** → the
  `spdif-dit` codec. DIT is TX-only; there is no S/PDIF receiver (no `spdif-dir`,
  no McASP RX serializer wired). The TOSLINK jack is an optical **out**.
- **HDMI** — the OMAP4 display subsystem (DSS) drives HDMI **out** through the
  TPD12S015A level-shifter/ESD companion, which is an HDMI **source** part. There
  is no HDMI sink / audio-return path in the silicon or the board.
- **Line/analog** — the TWL6040 headset codec pad is unpopulated/unused (stock
  never drove it); the only analog path is the TAS5713 Class-D amp → banana jacks,
  an output.

Confirmed against the DTS, TI documentation for the OMAP4 DSS + TPD12S015A, and a
Nexus Q teardown. **Feeding a TV's optical/HDMI into the Q is impossible without a
hardware receiver-chip mod.** The only no-solder, no-Bluetooth digital audio in is
**USB** — the micro-USB service port already runs a configfs composite gadget
(RNDIS + ACM), so a UAC2 audio function can join it.

## The implementation

- **Kernel r46:** defconfig gains `CONFIG_USB_CONFIGFS_F_UAC2=y` (module
  `usb_f_uac2`). No new patch — a defconfig-only bump, so the boot.img stays 44
  patches / well under 8 MB.
- **Gadget (device r60, `nexusq-usb-gadget.sh`):** adds a `uac2.0` function to the
  single composite config with

  ```
  c_chmask=3   c_srate=48000   c_ssize=2   p_chmask=0
  ```

  `c_*` is the **capture** direction (host → gadget). The Q is a **USB speaker**:
  the host plays, the Q receives. On the device this surfaces as an ALSA **capture**
  PCM on the `UAC2Gadget` card (`pcm0c`). `p_chmask=0` = **no** gadget→host mic.
  ⚠️ Measured on-device: setting `p_chmask` instead makes the Q enumerate as a
  **microphone**, not a speaker — `c_chmask` is the correct knob. If
  `CONFIG_USB_CONFIGFS_F_UAC2` is missing the gadget still comes up as rndis+acm.
- **Loopback (`nexusq-uac2-in` + `.service`):** a long-running user service
  (`KillMode=mixed`) that loads a PulseAudio `module-alsa-source` on the
  `UAC2Gadget` capture + a `module-loopback` into the **default** PA sink (TAS5713),
  so the host audio **mixes with Spotify / AirPlay / Roon** like any input. It
  unloads its PA modules in a **SIGTERM trap**. Default-OFF (no `wants` symlink,
  same as Roon).
- **App toggle (control r16, app 1.7.0+16):** a **4th per-service switch**
  "USB Audio" (`Icons.usb`) next to Spotify / AirPlay / Roon. `nexusq-control`
  `SERVICES` gained `{"id":"usbaudio","unit":"nexusq-uac2-in.service"}`.

## The `disable` vs `mask` lesson (control r16)

`set_service` OFF used to `mask --now` every unit. `mask --now` symlinks the unit to
`/dev/null` **before** stopping it, which drops the unit's `KillMode` / `ExecStop` —
so systemd tears the process down without honouring its stop logic. For a service
that owns **external state that outlives its own process** — `nexusq-uac2-in` loads
PA loopback modules that keep running in the PulseAudio daemon — masking **leaked the
loopback**: the modules stayed loaded after the service was "off".

Fix: `set_service` OFF now `disable --now`s the **default-OFF** units (roon,
usbaudio) — which keeps the unit file intact so its **SIGTERM trap runs** and unloads
the modules — and only `mask --now`s the **vendor-default-ON** units
(spotify/airplay), via a new `vendor_on` flag in `SERVICES`. (Masking is still wanted
there so a vendor-on unit stays off across boots.)

## Verification (clean v1.11.3 dev flash)

- Toggle **ON** → `nexusq-uac2-in` active, the `UAC2Gadget` capture card present, the
  host's audio arrives, **TAS5713 sink RUNNING**.
- Toggle **OFF** → the service stops via its trap, its PA loopback modules
  **unload cleanly (0 modules)** — no leak.

End-to-end confirmed: host plays over USB → sound out the Q's amp, and it mixes with
a simultaneous Spotify stream.

## Housekeeping fix

`nexusq-usb-gadget.sh` had a stale code comment naming the loopback helper
`nexusq-uac2-route`; the shipped binary/service is `nexusq-uac2-in` — comment
corrected.

---

## WiFi 5 GHz TX degradation — RESOLVED (evidence 2026-08-01)

At v1.11.0 a WiFi known-issue was left **open**: on long uptimes the BCM4330 5 GHz
link would stay associated at −48 dBm with good RX but **70-100 % TX packet loss**,
worsening over a session and not cleared by a reboot; it was hypothesised as
environmental / AP-side on ch36.

It is **resolved by `brcmfmac roamoff=1`** (device r56) — the same in-firmware
background-*roam*-scan failure as the `brcmf_escan_timeout` wedge; pinning the Q to
its single AP (it never roams) cures both. The new **`nexusq-wifi-watchdog`**
(device r57) — gateway-ping every 30 s, auto-bounce `wlan0` after 3 failures, health
logged to `/var/log/nq-health/wifi-watchdog.jsonl` — recorded a **29 h continuous
clean run (2026-08-01)**: no TX-dead wedge, no heal bounces triggered. The earlier
"environmental / open" verdict is retired. eth-direct (`10.42.0.2`) stays the fastest
path for bulk transfers.
