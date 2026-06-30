# Session Handoff — 2026-06-20 (Plan 3b music visualizer + WiFi finding)

## ✅ LED ring — feature-complete
Plan 1 (kernel driver), Plan 2 (daemon), Plan 2b (volume/mute, mute LED verified BLUE
#001E28/#006B8E — the "red" was the retired Task-6 placeholder), Plan 3 (idle breathing
screensaver), and **Plan 3b (music-reactive visualizer)** are all done, committed and pushed.

Plan 3b: reverse-engineered the factory `Visualizer.apk` (pulled the tungsten-ian67k factory
image → `debugfs` extract → baksmali deodex → jadx) and ported the audio path + all 5 scenes
pixel-perfect to C: `audiocap` (waveform/getVolume/real-FFT/BeatProcessor+Comb), `themecolor`,
`jrandom`, `ledcfg`, and `fx_{waveform,waveformsolid,circles,pointmorph,starfield}`, wired via
`music.{c,h}` into `nexusqd.c` (priority-7 music layer, childAlpha fade vs the screensaver).
RE docs: `docs/2026-06-19-particle-screensaver-RE.md`, `docs/2026-06-19-music-effects-RE.md`.
**Verified live**: playing a track into the ALSA loopback drives the ring; all 5 scenes
confirmed by hand (`nexusled scene 0-4`). 15/15 host tests, 0 warnings (host + cross ARM 13.3).

### What's left for the lights (when wanted)
> **→ RESOLVED in v1.6.2 (2026-06-30):** the Spotify-driven visualizer is live — WiFi works on
> 5 GHz, librespot ships, snd-aloop auto-loads, and the `nexusq` PCM tees the audio to the
> loopback so nexusqd's tap drives the ring. See `CHANGELOG.md` ([1.6.2]).
- **Spotify-driven visualizer** — librespot is installed (below) but streaming is blocked by the
  WiFi issue (below). Once WiFi is fixed, Spotify audio → loopback → the effects react with no
  extra work.
- **Scene auto-cycling** — the original rotated scenes via `FadeTransition` (NOT ported; we have
  manual `nexusled scene N`). Add timed cycling + a fade if desired.
- **musl apk** — the daemon currently runs as a **static** `/usr/bin/nexusqd` (deployed over USB).
  Build the real musl `nexusqd-*.apk` via `docker-build.sh` (Phase 7c) and `apk add` it.
- Out of scope / not needed for LEDs: BlurEffect, TrackInfoOverlay, the HDMI/GL screen render.

## 🎧 librespot (Spotify Connect "Nexus Q") — installed
`apk add librespot` + a systemd unit `/etc/systemd/system/librespot.service`
(`--name "Nexus Q" --backend alsa --device plughw:Loopback,0 --format S16 --ap-port 443
--zeroconf-port 37879`). Discovery + auth WORK (the phone on VLAN20 sees it and authenticates).
Firewall drop-in `/etc/nftables.d/60_spotify.nft` opens UDP 5353 (mDNS) + TCP 37879. `--ap-port
443` works around VLAN20 blocking the default AP port 4070. **Streaming still fails** — audio
content fetch stalls because of the WiFi bulk issue below.

## 🎧 Roon Bridge — DEFERRED until WiFi is fixed
Requested 2026-06-20. Blocked by the same WiFi bulk issue (can't even `apk add` the deps over
WiFi — `gcompat` download timed out). Prep already done: the armv7hf build is downloaded on
the host at `/home/petronijus/nexusq-build/RoonBridge_linuxarmv7hf.tar.bz2` (16 MB, push over
USB). Deps exist in apk: **`gcompat`** (glibc shim — Roon is glibc, device is musl) + **`ffmpeg`**
+ `libstdc++`. Once the device has reliable internet (WiFi fixed, or USB-tether NAT through the
host), `apk add gcompat ffmpeg`, extract RoonBridge, run its `check.sh`/start. Caveat: Roon on
musl-via-gcompat is finicky and may need tweaking; and like Spotify it streams over the network
so it also needs the WiFi fix to actually play.

## ⚠️ WiFi (BCM4330) — NEEDS INVESTIGATION (the "flaky" thing)
**The Nexus Q WiFi can't sustain bulk/throughput**, while small packets are fine. Symptoms:
SSH commands/pings/TLS-auth work, but bulk HTTP/HTTPS hang, scp of the 4 MB daemon corrupts
(md5 mismatch every attempt), large fragmented pings to the LOCAL gateway lose 33–100% with
270–530 ms latency. **Ruled out** (none fixed it): signal (−28…−39 dBm, excellent), channel
(ch1→6), regdomain (`00`→**CZ** via `/etc/modprobe.d/cfg80211-cz.conf`; cut burst loss
100%→~20% but not throughput), power-save off, MTU 1400, device reboot, router reboot. Stuck at
**54 Mb/s (802.11g, no 11n)**; firmware BCM4330 2013 `5.90.195.114`; **`brcmfmac4330-sdio.clm_blob`
missing** (dmesg). → Likely fix is driver/firmware: supply the clm_blob, get 11n/A-MPDU, or newer
firmware/NVRAM. It worked intermittently earlier → marginal, not dead. Memory: `nexusq-wifi-bcm4330-flaky`.

## ✅ Reliable path: USB gadget net (use this for deploys, not WiFi)
Device `usb0` = `172.16.42.1` (RNDIS). When the Nexus Q is plugged into a host via USB, that host
gets an `enx…` iface; `sudo ip addr add 172.16.42.2/24 dev enxXXXX && ip link set enxXXXX up`,
then `ssh root@172.16.42.1` (0.5 ms, 0% loss, clean). Deploy nexusqd and push test media this way.

## Build / deploy quick ref
- Host tests: `cd userspace/nexusqd && make test` (gcc). Cross: `make all CC=<ARM 13.3 gcc>
  CFLAGS="-std=c11 -O2 -Wall -Wextra -Iinclude -static"`. Toolchain at `/home/petronijus/nexusq-build/`.
- Deploy over USB: `ssh root@172.16.42.1 'cat > /usr/bin/nexusqd.new' < nexusqd` → verify md5 →
  `mv … /usr/bin/nexusqd && systemctl restart nexusqd`.
- Test the visualizer with no Spotify: push a WAV over USB, `aplay -D hw:Loopback,0 track.wav`
  (snd-aloop auto-loads via `/etc/modules-load.d/snd-aloop.conf`); the ring reacts.
