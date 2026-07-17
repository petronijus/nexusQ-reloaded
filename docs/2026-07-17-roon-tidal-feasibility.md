# 2026-07-17 — Roon Bridge & Tidal Connect: integration feasibility

Investigation of the two hard step-3 services (the phase spec flagged both as
"glibc binaries on musl Alpine → gcompat or container, to be designed"). This is
the design. Evidence is from live tests on the device + current web research; the
verdict is **feasible for Roon, conditional for Tidal, with one shared prerequisite
and one shared blocker (now solved).**

> **UPDATE 2026-07-17 — Roon PROVEN on-device, end to end.** The "single unproven
> step" below (does Roon's Mono run in a real glibc chroot vs. segfaulting under
> gcompat?) was validated live. On the running v1.10.1 device: grew the rootfs with
> `resize2fs` (2.0 GB → 12.7 GB, 9.8 GB free), staged a Debian bookworm armhf glibc
> rootfs at `/opt/glibc-rt`, ran the official `RoonBridge_linuxarmv7hf` under
> `bwrap --bind /opt/glibc-rt /`. Results:
> - `mono-sgen --version` → **"Mono JIT compiler version 6.10.0.104", exit 0**
>   (under gcompat it segfaulted). Arch `armel,vfp+hard`.
> - Roon's own `check.sh` → **STATUS: SUCCESS** — Binary Compatibility **OK**
>   (was FAILED under gcompat) + ALSA Libraries **OK** (after
>   `apt-get install libasound2 libasound2-plugins` inside the rootfs).
> - `start.sh` actually launched: `Initializing → Starting RoonBridgeHelper →
>   RAATServer Running`. Mono ran Roon's real daemon + audio server in the chroot.
> The only open detail is audio-device plumbing (`opendir` misses because `/dev/snd`
> + `/proc/asound` weren't bound; production routes through the PA `pulse` plugin) —
> an implementation detail, not a feasibility question. **Roon is a build task now,
> not a research question.** The first-boot `resize2fs` is already baked (device
> pkg r51: `nexusq-resize-rootfs` + `.service` + `95-nexusq.preset` enable).

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

**~~Single unproven step~~ — PROVEN 2026-07-17 (see the UPDATE at the top):** Roon's
`mono-sgen` runs inside the glibc chroot (v6.10.0.104, exit 0), `check.sh` →
SUCCESS, and `start.sh` brings RAATServer up. No blocker remains before build.

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

## Decisions (2026-07-17)

1. **Roon**: GO — build the glibc-chroot + Roon Bridge. Live-proven feasible
   (above); this is the clean, official candidate.
2. **Tidal**: DEFERRED — grey-area extracted binary + Debian-9 glibc. Revisit as a
   follow-up once the Roon glibc-chroot pattern is shipped (Tidal reuses it).
3. **Disk**: DONE — first-boot `resize2fs` baked (device pkg r51).

## Roon build plan (progress)

Decisions made 2026-07-17: bake a **pinned tarball** for the glibc base; RoonBridge
**fetched first-run + self-updates**; Roon is an **on-demand, default-OFF** user
service (resource policy — the companion app will later toggle services per-user).

1. ~~First-boot resize~~ — **DONE** (device r51).
2. **Glibc base baked** — **DONE** (device r52). The proven `/opt/glibc-rt` base
   (Debian bookworm armhf + `libasound2` + `libasound2-plugins`, minus the app and
   apt caches) was captured as `nexusq-glibc-rt-bookworm-armhf.tar.xz` (125 MB xz,
   sha512 pinned in the APKBUILD) and is unpacked into `/opt/glibc-rt` at build
   time. **Hosting: a GitHub release asset** on this repo, tag
   `glibc-rt-bookworm-armhf-1` (a build asset, NOT a device release). ⚠️ The upload
   itself is the one open action — the automated release-create was permission-
   blocked; Petr uploads it (command in the handoff), then the build can fetch it.
3. **RoonBridge app** — fetched on first Roon start by `roon-nexusq` (lazy, only if
   the user turns Roon on) into a uid-10000-owned dir so both the fetch and Roon's
   own self-updater can write. We never pin/manage the app version.
4. **Audio** — **DONE**: `roon-asound.conf` in the rootfs defaults ALSA to `pulse`;
   the wrapper binds the uid-10000 PA socket + `XDG_RUNTIME_DIR`/`PULSE_SERVER`.
   `/dev/snd` is deliberately NOT bound (pulse-only path, so Roon can't grab hw and
   fight PA). Output/volume stay in PA. The harmless `opendir` device-scan warnings
   remain; revisit only if RAATServer needs a bound `/proc/asound`.
5. **systemd USER unit** — **DONE**: `roon.service` (uid-10000, like
   librespot/shairport), `Restart=on-failure`, **not** auto-enabled (off by
   default; `systemctl --user enable --now roon` to turn on).
6. **Firewall** — **DEFERRED to live validation**: RAAT uses UDP 9003 (discovery) +
   dynamic RAATServer TCP ports. Rather than guess the range, measure the actual
   listening ports with `netstat`/`ss` while the Bridge runs against a real Core,
   then write `62_roon.nft`. (Web lookup of Roon's port list was permission-blocked.)
7. **Validate against a real Roon Core** (needs Petr's Roon account) — pair the
   bridge, play a track, confirm it appears as a PA input and audio comes out; then
   finalize step 6.

## Companion-app service toggles (next feature, Petr's request 2026-07-17)

Petr wants per-service enable/disable from the app: one user runs only Spotify,
another only Roon, another Roon+AirPlay — nothing runs unless turned on (resource
policy). Design: `nexusq-control` gains `listServices` / `setService(name, on)`
(start/stop the uid-10000 user units + persist enabled-state); the app shows a
toggle per service (Spotify/librespot, AirPlay/shairport, Roon, HDMI desktop).
Roon is already built to drop in (default-off user unit). librespot/shairport stay
as-is for now and get folded under the same toggle in that dedicated feature (no
midnight refactor of working services).

## Sources
- Roon Linux install / platform + glibc note — https://help.roonlabs.com/portal/en/kb/articles/linux-install
- Alpine `gcompat` — https://pkgs.alpinelinux.org/package/edge/main/armhf/gcompat
- Alpine "Running glibc programs" — https://wiki.alpinelinux.org/wiki/Running_glibc_programs
- Tidal Connect extracted-binary docker (ifi/BluOS) — https://github.com/seniorgod/ifi-tidal-release , https://github.com/TonyTromp/tidal-connect-docker
