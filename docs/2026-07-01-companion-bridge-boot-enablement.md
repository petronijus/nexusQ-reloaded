# Session findings — 2026-07-01

Building + flashing the **v1.6.3 companion-bridge image** on Linux (resolving the
2026-06-30 Linux build handover) surfaced two non-obvious, device-specific reasons the
`nexusq-control` LAN bridge **was installed but not running on a clean flash** — both now
fixed and **hardware-verified**. The build/code itself was correct; this was entirely a
**boot-enablement** problem (a systemd-on-this-image-build gotcha), worth recording so the
next service we add doesn't re-derive it.

Context: `nexusq-control` (TCP 45015, mDNS `_nexusq._tcp`) is the device side of the
companion app — see `companion/PROTOCOL.md`, `docs/2026-06-30-companion-app-RE.md`,
`docs/2026-06-30-companion-hardware-bringup.md`.

## Finding 1 — the enable symlink kept being stripped (3 layers; only the 3rd stuck)

A normal `systemctl enable` writes a `*.wants/` symlink. On this postmarketOS image build,
that symlink was wiped twice before the bridge stayed enabled:

1. **`/usr/lib/.../multi-user.target.wants/` (aport vendor wants)** — the image build runs
   `systemctl preset-all`, which re-derives every unit's enable state from *preset policy*
   and **removed** the un-presetted vendor wants.
2. **bare `/etc/.../multi-user.target.wants/` symlink** (force-installed by the aport,
   pkgrel 14, commit `3685fc0`) — wiped by postmarketOS's **`disable *` catch-all** preset
   (pmOS ships a `90-…preset` that disables everything not explicitly presetted).
3. **a systemd preset `95-nexusq.preset`** shipped by the device package (pkgrel 15, commit
   `6495815`) → **stuck.** `preset-all` honours it (95 sorts after pmOS's 90 `disable *`),
   so `nexusq-control.service` is enabled durably across the image build.

**Lesson:** on this image, durable boot-enablement of a new unit needs a **systemd preset**
drop-in, *not* an `enable` symlink (vendor or `/etc`) — `preset-all` + pmOS `disable *`
will strip the symlink.

## Finding 2 — enabled, yet never auto-started: a boot ordering cycle deleted its start job

With the preset in place the unit was enabled, but on a clean v1.6.3 boot it was still
`inactive`. The journal showed why:

```
multi-user.target: Found ordering cycle: nexusq-control after nexusqd after
  multi-user.target - after nexusq-control
Job nexusq-control.service/start deleted to break ordering cycle
```

Root cause: the unit carried `After=network-online.target nexusqd.service sound.target`
(+ `Wants=network-online.target`). Once pulled into the boot transaction it formed a cycle
— `nexusq-control` → `nexusqd` → `multi-user.target` → `nexusq-control` — and **systemd
breaks an ordering cycle by deleting a start job**, picking `nexusq-control`'s. So it was
correctly enabled but silently never started. A manual `systemctl start nexusq-control`
took a *different* (non-boot-transaction) path with no cycle, succeeded, and **masked** the
bug during earlier interactive testing.

**Fix (commit `2e45cd0`, aport pkgrel 2):** the bridge already **degrades gracefully** — it
binds `0.0.0.0` immediately and lazily (re)connects to `/run/nexusqd.sock`, the librespot
hook socket, and the ALSA control — so `nexusqd`/`librespot` are **soft `Wants` only** and
the unit needs **no `After=`** ordering at all. Removed
`After=network-online.target nexusqd.service sound.target` and
`Wants=network-online.target`.

**Lesson:** never give a unit that is pulled into the boot transaction an `After=` on
something that (transitively) orders *after the same target* the unit is wanted by — systemd
will resolve the resulting cycle by **deleting a start job**, and it may pick yours, with no
failure surfaced except a single `journalctl` line. If a service can start without ordering
(degrade gracefully), prefer soft `Wants` + no `After=`.

## Outcome — verified live (clean v1.6.3 flash)

- `nexusq-control` **auto-starts** (`active (running)`, no ordering cycle in the journal),
  `systemctl is-system-running` = `running`.
- The bridge **answers every v1 protocol method** (getState, setVolume/adjustVolume/
  setMuted/toggleMute, setTheme/listThemes/setBrightness, getPlayState, getDeviceInfo).
- **Volume works** through the `nexusq_soft` ALSA softvol (control `NexusQ`) layered on the
  v1.6.2 tee — the same knob `librespot` uses, so Spotify-Connect and companion volume stay
  in lockstep.
- The **LED music visualizer still tracks playback** (the tee → snd-aloop path is intact).
- **Transport (play/pause/next) is `unavailable` in v1 by design** — librespot is a
  Spotify-Connect receiver with no local transport API.

Package state shipped: `device-google-steelhead` pkgrel 15, `nexusq-control` aport pkgrel 2,
`nexusqd` pkgrel 2 (the new `brightness <0-255>` command). Released as **v1.6.3**
(`CHANGELOG.md` [1.6.3]); branch `feat/companion-app` merged to main (`1844d98`).
</content>
</invoke>
