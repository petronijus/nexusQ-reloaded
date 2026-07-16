# 2026-07-17 — Roon Bridge & Tidal Connect: integration feasibility

Investigation of the two hard step-3 services (the phase spec flagged both as
"glibc binaries on musl Alpine → gcompat or container, to be designed"). This is
the design. Evidence is from live tests on the device + current web research; the
verdict is **feasible for Roon, conditional for Tidal, with one shared prerequisite
and one shared blocker (now solved).**

## TL;DR

| | Roon Bridge | Tidal Connect |
|---|---|---|
| Official armv7 binary | ✅ yes (`RoonBridge_linuxarmv7hf`) | ❌ none — only an **extracted vendor binary** (ifi/BluOS), grey-area |
| Runtime | bundled **Mono** (.NET), glibc | glibc, needs **Debian 9 (stretch)**-era glibc |
| gcompat (musl glibc shim) | ❌ **mono-sgen SEGFAULTS** (tested live) | ❌ (same class; not separately tested) |
| Real glibc userland (chroot/bwrap) | ✅ the viable path | ✅ the viable path (Debian-9 rootfs) |
| Arch fit (armv7) | ✅ | ✅ |
| Legality | clean (official redistributable) | **grey area** (extracted proprietary binary) |
| **Verdict** | **FEASIBLE** via a glibc chroot | **POSSIBLE but fragile + grey-area**; recommend deferring |

## What was measured on the device (2026-07-17)

- **gcompat does NOT run Roon.** Installed `gcompat 1.1.0-r4`, downloaded the
  official `RoonBridge_linuxarmv7hf.tar.bz2`, extracted it. Roon's own `check.sh`
  → `Binary Compatibility FAILED`, `ALSA Libraries FAILED`. The bundled Mono
  runtime (`RoonMono/bin/mono-sgen`, an ELF armv7 glibc binary needing
  `/lib/ld-linux-armhf.so.3`) **segfaults immediately** under gcompat. This
  matches Roon's own warning that gcompat "gets most glibc binaries to run, but
  some will not" and is "unreliable for production." Mono is one of the ones it
  can't run.
- **The device CAN host a real glibc userland.** `bubblewrap` (0.11.2),
  `proot` (5.4.0) and `chroot` are all available in Alpine armv7 — so a glibc
  rootfs can run under a lightweight sandbox WITHOUT a full container runtime
  (there is no Docker on the device, and OMAP4 single-core wouldn't want one).
- **RAM is fine:** 980 MB total, ~720 MB free.
- **The disk blocker — and it is trivially solved.** `/` (`mmcblk0p13`) reported
  only **86 MB free of 2.0 GB** — nowhere near enough for a glibc rootfs. BUT the
  partition is actually **14.1 GB** on a **15.8 GB** eMMC; the flashed 2.1 GB
  rootfs image's ext4 was never grown to fill it. **`resize2fs /dev/mmcblk0p13`
  reclaims ~12 GB.** This should be a baked first-boot resize regardless of
  Roon/Tidal — 86 MB free is dangerously low for any apk op.

## The shared architecture (recommended)

Both services need a glibc userland; build ONE and host both:

```
/opt/glibc-rt/                      a minimal armv7 glibc (Debian bookworm/bullseye) rootfs
  ├── Roon Bridge (official tarball, its bundled Mono runs against this glibc)
  └── Tidal Connect (extracted binary; needs an OLDER glibc → its own Debian-9 root)

bwrap --bind /opt/glibc-rt / --dev /dev --proc /proc \
      --bind /run/user/10000 /run/user/10000  (PulseAudio socket)  <app>
```

- **PulseAudio**: both are just more PA INPUTS, like librespot/shairport. Bind the
  uid-10000 PA socket into the sandbox; the app's ALSA `pulse` plugin (or PA
  client libs inside the glibc root) routes to the same hub. OUTPUT/volume stay in
  PA and follow the app's default-sink choice — consistent with every other input.
- **mDNS/discovery**: Roon uses RAAT (its own discovery, needs the RAATServer
  ports); Tidal advertises via avahi/Bonjour. Firewall drop-ins as for AirPlay.
- **systemd USER units** in the uid-10000 session, same pattern as librespot.

## Roon Bridge — FEASIBLE, the concrete plan

1. Bake the first-boot `resize2fs` (prerequisite; do it regardless).
2. Stage a minimal armv7 glibc rootfs (Debian bullseye/bookworm, ~60–120 MB) at
   `/opt/glibc-rt` — via `debootstrap`-produced tarball baked into the image, or
   fetched first-boot. Needs `libasound2` + the PA ALSA plugin inside it.
3. Ship the official RoonBridge tarball; run its `start.sh` under
   `bwrap --bind /opt/glibc-rt /`.
4. Route audio to PA (ALSA `pulse` device inside the glibc root, PA socket bound
   in).
5. USER unit + firewall for the RAAT ports.

**Single unproven step to validate FIRST in implementation:** does Roon's
`mono-sgen` actually run inside the glibc chroot (vs. segfaulting under gcompat)?
Everything downstream depends on it. Cheap to test once the rootfs is staged.

## Tidal Connect — POSSIBLE, but recommend deferring

- **No official binary.** The only route is the community `tidal_connect_application`
  extracted from ifi/BluOS firmware (see the `*/ifi-tidal-release` and
  `tidal-connect-docker` repos). It is a **proprietary vendor binary** — a legal
  grey area to redistribute; at most Petr provides it himself.
- It **requires Debian 9 (stretch)** glibc — "does not work on newer OS versions"
  — so it needs its OWN old glibc root, separate from Roon's.
- It is **normally run as a Docker container** (Debian-9 base); we'd reproduce
  that as a bwrap sandbox over a Debian-9 armv7 rootfs.
- armv7 arch matches (the ifi binaries are armv7/armhf).

**Recommendation:** ship AirPlay + Roon first; treat Tidal as a follow-up gated on
(a) Petr wanting it enough to accept a grey-area extracted binary, and (b) the
Roon glibc-chroot infrastructure already proving the pattern (Tidal reuses it with
an older rootfs).

## Open questions for Petr

1. **Roon**: proceed to build the glibc-chroot + Roon Bridge? (It is the clean,
   official one — the strong candidate.)
2. **Tidal**: acceptable to run an extracted vendor binary, or drop it? Do you
   have a Roon account / Tidal HiFi to test against?
3. **Disk**: bake the first-boot `resize2fs` now (independently useful), yes?

## Sources
- Roon Linux install / platform + glibc note — https://help.roonlabs.com/portal/en/kb/articles/linux-install
- Alpine `gcompat` — https://pkgs.alpinelinux.org/package/edge/main/armhf/gcompat
- Alpine "Running glibc programs" — https://wiki.alpinelinux.org/wiki/Running_glibc_programs
- Tidal Connect extracted-binary docker (ifi/BluOS) — https://github.com/seniorgod/ifi-tidal-release , https://github.com/TonyTromp/tidal-connect-docker
