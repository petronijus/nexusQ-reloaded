# 2026-07-07 — Desktop audio sink fixed (red-cross tray → PA systemd user unit + deterministic TAS5713 sink)

Diagnosed and fixed live 2026-07-07 on the running device (device pkg **r29→r30**,
verified across a reboot). Companion to
`docs/2026-07-07-wifi-characterization-and-ethernet-default.md`; both ship in
**v1.6.12** (versioning is tag-only; v1.6.11 was a test build that was never
tagged — see that note's version reconciliation).

**Symptom:** after booting, the LXQt/labwc **Wayland** desktop showed a **red-cross
audio tray icon** — no sound sink.

---

## Root cause — two independent layers

### 1. PulseAudio never started
Alpine's `pulseaudio` ships **no systemd user unit**. It relies on the XDG
autostart `/etc/xdg/autostart/pulseaudio.desktop`
(`Exec=start-pulseaudio-x11`, `X-GNOME-HiddenUnderSystemd=true`). In this
**systemd + LXQt/labwc Wayland** session that path never fires:

- systemd's `xdg-desktop-autostart.target` stays **dead** (nothing pulls it in
  the way an X session would),
- the `.desktop` is marked *hidden under systemd* — it defers to a native systemd
  unit that **did not exist**,
- `autospawn=no` (per `50-nexusq-no-autospawn.conf`), so no client spawns it
  on demand either.

→ no PA daemon ever started → `/run/user/10000/pulse/native` missing → every PA
client (the LXQt volume applet, `pactl`) got **"Connection refused"** → red cross.

**NOTE:** this was **NOT** a "PipeWire owns the session" problem — PipeWire was
already correctly suppressed. The gap was purely the missing PA-start mechanism
under Wayland+systemd.

### 2. Wrong default sink
Once PA runs, it auto-loaded `module-alsa-card` for the **snd-aloop Loopback**
card and (being **card index 0 on some boots**) made
`alsa_output.platform-snd_aloop.0.analog-stereo` the **DEFAULT sink**. So desktop
audio would go into the internal loopback plumbing instead of the speaker, and
PA holding the Loopback risks **EBUSY** against the librespot→speaker /
companion-tap chain.

---

## Fix (both verified live, including across a reboot)

### Native `pulseaudio.service` systemd USER unit
Ship `pmos/device-google-steelhead/pulseaudio.service` (new): a plain daemon
`pulseaudio --daemonize=no --log-target=stderr`, `ConditionUser=!root`,
`Restart=on-failure`, enabled for **every** user session via a
`/usr/lib/systemd/user/default.target.wants/pulseaudio.service` symlink.

- **NOT socket-activated.** A systemd `pulseaudio.socket` double-binds the native
  socket that PA's own `default.pa` (`module-native-protocol-unix`) already binds
  → **"bind(): Address in use"**. So plain-daemon, no socket unit.
- `--log-target=journal` is **rejected** by this Alpine PA build; `stderr` is used
  and systemd captures it into the journal.
- `autospawn=no` stays (the unit is the single, deterministic start path).

### Loopback also PULSE_IGNORE'd
Extend `91-pulseaudio-hdmi-ignore.rules` with a second rule that PULSE_IGNOREs the
Loopback card via `KERNELS=="snd_aloop.0"` (platform-name match — the **ALSA card
index is probe-order-unstable**: observed Loopback=card0 with HDMI/tas5713
shuffling around it, same rationale as the existing HDMI rule). Result: PA's
**ONLY** sink is the **TAS5713 speaker** → correct deterministic default. The
Loopback stays pure ALSA plumbing for librespot (`nexusq_soft` in `asound.conf`)
and the companion tap (capture side).

### Verified live (post-reboot)
- PA auto-starts: `systemctl --user is-active pulseaudio` = `active`.
- The **sole** sink is `alsa_output.platform-sound-tas5713.stereo-fallback`, and
  it is the **default** sink.

### Files
- `pmos/device-google-steelhead/pulseaudio.service` — **new** systemd user unit.
- `pmos/device-google-steelhead/91-pulseaudio-hdmi-ignore.rules` — 2nd rule
  (`KERNELS=="snd_aloop.0"`).
- `pmos/device-google-steelhead/APKBUILD` — source + sha512sums + package install
  (`/usr/lib/systemd/user/` + `default.target.wants/` symlink) + pkgrel **29→30**.

---

## Process lesson
Run the **full `nexusq-diag` sweep after every flash + boot**. This red-cross
regression was caught **only because the user noticed the tray icon** — the
post-flash check was too narrow. Post-flash acceptance must sweep the whole
subsystem surface, including **desktop audio (PA running + a real default sink)**,
not just the boot log / failed-units.

---

## HDMI audio — probably works, UNTESTED (2026-07-07)
While here we checked the other desktop output. The HDMI ALSA card is the real
mainline `omap-hdmi-audio` (SND_SOC_OMAP_HDMI, platform dev
`omap-hdmi-audio.1.auto`), not a stub — there is no dummy HDMI dai-link in our
DTS. Its PCM open returns **-EINVAL** only because the attached display is a
**Philips 190C monitor**, a DVI-class sink: its EDID is a 128-byte base block with
**no CEA-861 extension** (hence no audio data block), so the HDMI link runs in DVI
mode with no audio path. That is correct behaviour for that sink, not a port bug.

**Conclusion: HDMI audio out very likely works on an audio-capable HDMI sink (TV /
AV receiver) with no code change — but it is UNTESTED**, as we have no such display
to confirm. To validate later: attach a TV/AVR, then `aplay -D plughw:CARD=HDMI -f
S16_LE -r 48000 -c 2 /dev/zero` should open; if it does, drop the HDMI
`PULSE_IGNORE` (91-pulseaudio-hdmi-ignore.rules) to expose it as a selectable PA
sink. No HDMI bring-up work is pending — only verification when the hardware allows.
