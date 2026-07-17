# 2026-07-17 — Roon Bridge live bring-up: validated end-to-end against a real Core

Follow-on to `docs/2026-07-17-roon-tidal-feasibility.md` (the design + packaging).
This is the record of the LIVE validation against Petr's ROCK Core (Proxmox VM,
`192.168.20.105`) — every fault in the chain root-caused with log/packet evidence,
then baked as **device r54** (`51b2f7d`). Outcome: **all three streaming inputs
play — Spotify (librespot), AirPlay (shairport-sync, user-tested), Roon (glibc/bwrap
sandbox)**.

Starting point: the **v1.10.2-dev-r53** image was flashed (first-boot resize proved
itself: `/` grew 2.0 → 12.7 GB); Roon was then debugged live over ssh and each fix
hand-applied, then ported into the package (r54). The r54 build's file content is
identical to what the device now runs ([[bake-successes-into-build]]).

## The debugging chain (in the order it was hit)

1. **bwrap wouldn't even start — `/tmp` missing from the glibc base.** The
   `nexusq-glibc-rt-bookworm-armhf` tarball excludes `/tmp` (and the apt dirs), and
   **unprivileged bwrap cannot create mountpoints in a root-owned `/`** — the
   mountpoint must pre-exist. Fix: APKBUILD `package()` recreates `/tmp` (1777) +
   the apt dirs in the unpacked base.
2. **`Can't mkdir /run/user/10000`** — the baked `/run` in the base is root-owned,
   so bwrap couldn't create the bind target for `XDG_RUNTIME_DIR`. Fix:
   `--tmpfs /run` BEFORE the XRT bind — a fresh tmpfs belongs to the userns user,
   so bwrap creates the target itself.
3. **Bridge ran but was INVISIBLE to the Core — no SOOD announce.** RoonBridge's
   log: `[ipaddresses] SKIPPED wlan0: not up` for EVERY interface. Mono's
   `NetworkInterface` reads iface state from **`/sys/class/net`**, and the sandbox
   had no `/sys` → every iface enumerates "not up" → RoonBridge skips them all and
   never announces. Fix: `--ro-bind /sys /sys`.
4. **Zone enabled but `DeviceOpenFailed` (EBUSY) on the RoonLoop card.** PA's
   udev-detect auto-loaded `module-alsa-card` on the new second aloop card and held
   its playback substream. Fix: extend the `91-pulseaudio-hdmi-ignore.rules`
   `PULSE_IGNORE` to `KERNELS=="snd_aloop.1"` (same backing-device match idiom —
   never `cardN`, the v1.6.9 lesson).
5. **Firewall — measured packet-by-packet, not guessed** (input policy is
   default-drop; this was the step 6 the feasibility doc deferred to live
   validation). Observed against the real Core → `62_roon.nft`:
   - **udp 9003** — SOOD discovery (Core queries + unicast probes).
   - **tcp 9100-9200** — RAATServer's jsonserver (observed **9200**; 9100-9200 is
     Roon's documented range).
   - **tcp 32768-60999** — each enabled zone gets a dynamic RAAT device port
     (observed **38717**/**42117**) + a dynamic `audio_port_tcp` (observed
     **37933**). Blocked → the Roon UI **hangs at "Enabling"** (Core SYN-retries
     into the drop).
   - **udp 32768-60999** — the zone's dynamic clock-sync port (observed **36787**).
     Blocked → the zone enables but every track **"skips"** — audio can't start
     without clock sync.
   The dynamic ranges are Linux's ephemeral-port span; RAAT offers no way to pin
   them. WiFi-ingress only, like every other service drop-in.
6. **Choppy playback — two independent causes:**
   - **RAAT's audio threads got no SCHED_FIFO**: its `sched_setscheduler` was
     failing inside the sandbox because `user@10000.service` had no RTPRIO limit.
     Fix: `user@10000.service.d/rtprio.conf` (`LimitRTPRIO=50`).
   - **Core-side Device Setup → Buffer Size** — RAAT's default 40 ms buffer is too
     tight for this chain; Petr raised it in the Roon UI. **User action, stored on
     the Core** (persists across our reflashes — nothing to bake).
   Plus a loopback latency cushion on the PA side (see the architecture note
   below): `module-loopback latency_msec=250` — the value proven smooth live, so
   the baked wrapper (r55) uses it, not the initial 100 ms.

## The shipped audio architecture (differs from the feasibility plan)

The feasibility plan's step 4 ("ALSA default = pulse inside the chroot, bind the PA
socket") turned out NOT to be how RAAT works: **Roon does not speak PulseAudio**,
and with zero ALSA devices visible RAATServer answers `enumerate_devices` with `[]`
— the Core shows no output at all. Shipped design instead:

- **A dedicated second `snd-aloop` card, `RoonLoop`** — Roon's private playback
  device. `snd-aloop-options.conf` pins the indices (`index=0,7`) so the platform
  cards can't shift (ALSA card index is probe-order dependent — v1.6.9 lesson).
- **The sandbox dev-binds ONLY the RoonLoop nodes** (`controlC7`, `pcmC7D0p`,
  `/dev/snd/timer`) — the real cards (TAS5713/SPDIF/HDMI) have no nodes inside, so
  Roon can never grab hw and fight PA.
- **The wrapper loads `module-alsa-source` on `hw:RoonLoop,1,0` @ 48 kHz s16le**
  (source `roon_in`) — loading the capture side FIRST holds the loopback pair at
  48 kHz, so RAAT reads the capability and converts itself — plus
  **`module-loopback`** from `roon_in` to the **default sink**, so Roon follows the
  app's output switch like every other input.
- **`--unshare-uts --hostname`** from the onboarding name (`/etc/nexusq/
  device.json`, sanitized to hostname-safe) — the Core lists **"Nexus-Q"**, not the
  OS hostname "steelhead".

## Known issues / cosmetics (carried in CHANGELOG)

- **Two "Loopback PCM" devices in the Roon UI** — RAAT enumerates the RoonLoop
  card at control level and can't hide `DEV=1`. Cosmetic: **enable the one that
  works** (`DEV=1` fails fast by design if picked — no silent wrong-device state).
- **PA-restart stale-volume artifact** — restarting PA mid-session restored a stale
  device volume (**−51.6 dB**) once. Live-session artifact only; not reproduced
  from a clean boot.
- **AirPlay now-playing metadata** (MPRIS on the session bus) — still open.
- **Tidal stays deferred** (grey-area extracted vendor binary — feasibility doc).

## Current device state (as left 2026-07-17)

- Image: **v1.10.2-dev-r53** flashed; **r54 fixes hand-applied live** — identical
  content to the r54 build. **v1.11.0-rc1 build in progress.**
- Roon enabled via
  `systemctl --machine=user@.host --user enable --now roon.service` (root form for
  the uid-10000 user manager — the v1.8.2 lesson). Default remains OFF in the
  image.
- RoonBridge lives at `/opt/glibc-rt/opt/RoonBridge` (lazy-fetched on first start,
  uid-10000-owned, **self-updates** — only the glibc base is baked).

## Next

**Companion-app per-service toggles** (agreed next feature): `nexusq-control`
gains `listServices` / `setService(name, on)`; the app shows a toggle per service
(Spotify/AirPlay/Roon/desktop). Design sketch in the feasibility doc.
