# 2026-07-17 — Roon Bridge & Tidal Connect: integration feasibility

Investigation of the two hard step-3 services (the phase spec flagged both as
"glibc binaries on musl Alpine → gcompat or container, to be designed"). This is
the design. Evidence is from live tests on the device + current web research; the
verdict is **feasible for Roon, conditional for Tidal, with one shared prerequisite
and one shared blocker (now solved).**

> **UPDATE 2 (2026-07-17 late) — SHIPPED. Roon VALIDATED END-TO-END against Petr's
> real ROCK Core and every fix baked as device r54** (`51b2f7d`; packaging r52,
> build gates r53). All build-plan steps below are DONE except the companion-app
> service-toggle feature (future). The firewall is no longer deferred —
> **`62_roon.nft` is measured and baked** (udp 9003 SOOD, tcp 9100-9200 jsonserver,
> tcp+udp 32768-60999 dynamic zone/clock ports, all observed live). The audio step
> shipped DIFFERENTLY than planned (Roon does not speak PulseAudio — see the note
> at plan step 4). Full live-debugging record + evidence:
> **`docs/2026-07-17-roon-bring-up.md`**.

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
   `glibc-rt-bookworm-armhf-1` (a build asset, NOT a device release). ~~⚠️ The upload
   itself is the one open action~~ — **CLOSED (r53)**: the asset is live and the
   download + sha512 pin were verified against it; the r53 build fetched it.
   ⚠️ r53 build gates learned baking it: `makedepends=+xz` (abuild's tar shells out
   to the xz binary), `options=+!fhs +!tracedeps` (foreign-libc tree under /opt;
   abuild's ELF tracer chokes on `ld-linux-armhf.so.3`), suid/sgid stripped from
   the Debian base, and the base tarball ships NO `/tmp` — `package()` recreates it
   (1777) because **unprivileged bwrap cannot create mountpoints in a root-owned
   `/`** (hit live, r54).
3. **RoonBridge app** — fetched on first Roon start by `roon-nexusq` (lazy, only if
   the user turns Roon on) into a uid-10000-owned dir so both the fetch and Roon's
   own self-updater can write. We never pin/manage the app version.
4. **Audio** — **DONE, but SHIPPED DIFFERENTLY (r54)**: the pulse-only plan here
   (ALSA default = `pulse`, no `/dev/snd` bound) turned out not to work — **Roon
   does not speak PulseAudio**, and with zero ALSA devices RAATServer answers
   `enumerate_devices` with `[]` (the Core shows no output). Shipped design: a
   dedicated second `snd-aloop` card **`RoonLoop`** (index pinned 7,
   `snd-aloop-options.conf`), the sandbox dev-binds ONLY its nodes (so Roon can
   never grab TAS5713 hw), and the wrapper loads `module-alsa-source`
   (`hw:RoonLoop,1,0` @48 kHz, holds the pair so RAAT converts) + `module-loopback`
   to the default sink — Roon follows the app's output switch like every input.
   `roon-asound.conf` (default = pulse) still ships but is not the RAAT path.
   Details: `docs/2026-07-17-roon-bring-up.md`.
5. **systemd USER unit** — **DONE**: `roon.service` (uid-10000, like
   librespot/shairport), `Restart=on-failure`, **not** auto-enabled (off by
   default; `systemctl --user enable --now roon` to turn on).
6. **Firewall** — **DONE (r54, measured — no longer deferred)**: `62_roon.nft`,
   every port observed live against the real Core: udp 9003 (SOOD), tcp 9100-9200
   (jsonserver, observed 9200), tcp 32768-60999 (dynamic zone device ports 38717/
   42117 + audio_port_tcp 37933), udp 32768-60999 (clock sync, observed 36787 —
   blocked clock = tracks "skip"; blocked device port = UI hangs at "Enabling").
7. **Validate against a real Roon Core** — **DONE 2026-07-17**: enabled against
   Petr's ROCK Core (Proxmox VM, 192.168.20.105), tracks play through the app's
   selected output alongside Spotify + AirPlay. Choppiness root-caused (RTPRIO for
   RAAT + Core-side Buffer Size). Full record: `docs/2026-07-17-roon-bring-up.md`.

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
