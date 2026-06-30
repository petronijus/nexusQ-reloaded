# Session findings — 2026-06-29

Two device-side results on the v1.6.0 image: **Spotify Connect (librespot) is
installed and streaming** over WiFi, and — driving real audio through the speaker
path for the first time — a **new hardware-timing bug surfaced: the TAS5713 plays
exactly 2× too fast.** The TAS5713 path's long-standing "software-verified,
listening test pending" status is now *tested* and **broken**. Neither change is in
the build yet (librespot is a live `apk add`; the audio fix is in progress).

---

## 1. Spotify Connect (librespot) — installed, streaming VERIFIED (device-side only)

Installed live on the v1.6.0 device; **NOT yet baked into the build** — a fresh
flash wipes it. Bake-in (a `pmos/` aport + nftables/systemd staging in the device
package) is the next step **once the audio bug in §2 is fixed** (no point shipping a
player that plays 2× fast).

- **Package:** `apk add librespot` from Alpine **edge/testing**, **librespot
  0.8.0-r0**. This build is compiled with **only the `libmdns` zeroconf backend** —
  no avahi/dns-sd linked in — so it **coexists with `avahi-daemon` on UDP 5353** via
  `SO_REUSEPORT` (both bind the mDNS port; no conflict).
- **systemd unit** `/etc/systemd/system/librespot.service` runs:

  ```
  librespot --name "Nexus Q" --backend alsa --device plughw:1,0 \
            --bitrate 320 --format S16 --initial-volume 60 \
            --ap-port 443 --zeroconf-port 37879 --cache /var/cache/librespot
  ```

  - `--device plughw:1,0` = ALSA card **1 `NexusQ-Speaker`** (McBSP2 → TAS5713) —
    the same path as §2.
  - `--ap-port 443` **works around VLAN20 blocking librespot's default AP port
    4070** (the Spotify access-point connection); 443 is allowed out of vlan20.
  - `--zeroconf-port 37879` pins the zeroconf HTTP control port (default is random)
    so it can be opened in the firewall deterministically.
- **nftables drop-in** `/etc/nftables.d/60_spotify.nft` opens, on `wlan*`:
  - **UDP 5353** — mDNS (zeroconf discovery / advertising "Nexus Q"),
  - **TCP 37879** — the zeroconf HTTP control endpoint (`--zeroconf-port`).
- **VERIFIED WORKING over WiFi (5 GHz):** the phone's Spotify app **sees "Nexus Q"**
  in the device picker, **authenticates** (zeroconf handoff), and **tracks load
  fully** and start playing. Discovery + auth + streaming all confirmed end-to-end.

This realises the long-deferred "audio source = librespot/Spotify Connect 'Nexus Q'"
note in `PLAN.md` §9 (LED music-reactive scenes) and the `firmware`/WiFi-bulk
blocker that gated it — 5 GHz WiFi now carries the stream (see the 2026-06-29 WiFi
join notes in `.claude/agents/nexusq-connect.md`).

---

## 2. NEW HARDWARE BUG — TAS5713 audio plays EXACTLY 2× too fast

This is the **first real listening/timing test of the speaker path.** Every prior
status said "TAS5713 software-verified (`speaker-test` rc 0, card registers),
listening test pending" — now it has been driven with timed audio and is **wrong**.

### 2.1 Measurement (pure timing — no speaker required)

10.0 s of `S16_LE` stereo **silence** written to **`hw:1,0`** (card 1
`NexusQ-Speaker` = McBSP2 → TAS5713) **plays back in 5.00 s**:

- ratio **0.50× = 2× too fast**, sample rate requested **48000 Hz**.
- the **2× holds at all sample rates** tested — it is a fixed factor, not a
  rate-table mismatch.

Because it is a timing ratio, no physical speaker is needed: the ALSA period clock
(driven by the McBSP2 FSYNC/LRCLK) drains the buffer twice as fast as wall-clock.

### 2.2 Consequence — the "Spotify plays ~40 s then skips" symptom

librespot streams a track and tracks its progress by frames played. Because the
hardware consumes frames at 2× rate, **every track reaches its end in half its real
duration**, so **librespot auto-advances to the next track ~40 s in** (≈ half of a
typical ~80 s-in point). The "plays ~40 s then skips to the next song" symptom seen
with Spotify Connect is **exactly this 2× clock bug** — it is **not** a librespot
crash/restart. (NB the diag tooling's `librespot_restart` finding is a *service*
restart; the auto-skip here is normal librespot end-of-track behaviour on a 2×-fast
clock, with the service staying up.)

### 2.3 Root cause (newly root-caused; precise fix IN PROGRESS)

The **McBSP2 / ABE sample-rate generator emits FSYNC (LRCLK) at 2× the requested
rate** — a kernel/DTS clock bug, in the **known "B7 TAS5713 MCLK" family** (see
`docs/2026-06-19-boot-warnings-followup.md` §B7: the `dpll_per_m3x2_ck` /
`auxclk1_ck` 12.288 MHz MCLK path was already flagged as not provably correct).

Narrowing where the ×2 enters:

- **`func_mcbsp2_gfclk` measures 24.576 MHz** on the device (= **512 × 48 kHz**),
  which *looks correct* — so the **fault is downstream of the gfclk**, not in the
  ABE sync-mux feeding it.
- Candidates, in order: the **SRG (sample-rate generator) divider** (off by a factor
  of 2 → FSYNC at 96 kHz framing); the **I2S frame width** (32-bit vs 16-bit slot →
  half the bit-clock periods per frame); or the **TAS5713 MCLK** landing at
  **16 MHz instead of 12.288 MHz** (the B7-family `dpll_per_m3x2`/`auxclk1` rate
  that never provably reached 12.288 MHz — `auxclk1_ck` was last seen at **16 MHz**
  in B7).

### 2.4 Status — OPEN, fix in progress

- A **stock-parity audit** against the factory kernel (`reverse-eng/vmlinux.bin`,
  3.0.8 SMP — the kernel that drove this exact amp correctly) of the McBSP2/ABE
  clock + McBSP frame config is **in progress** (stock-parity-auditor; subject
  "TAS5713 audio clock tree").
- The **precise kernel/DTS fix and its hardware verification will be documented in a
  follow-up pass.** Record here: **newly root-caused, open**; the speaker path is
  **not** usable for music until the FSYNC is at 1× (Spotify will keep skipping).

---

## 3. What this changes in the docs

- TAS5713 status moves from "🟠 software-verified, listening test pending" to
  **"🔴 known 2× speed bug, fix in progress"** everywhere it appears (INSTALL.md
  "What works", PLAN.md §1 + hardware map, README status, CHANGELOG).
- Spotify Connect recorded as a **device-side install, pending bake-in** (CHANGELOG
  `[Unreleased]`, INSTALL.md "What works", README, PLAN §9).
- Diag briefs gain the device fact that a librespot **auto-skip ~40 s in** = the
  TAS5713 2× clock bug, not a player crash.

## 4. Files touched on the device this session (for reference; not in the build)
- `/etc/systemd/system/librespot.service` — the unit in §1.
- `/etc/nftables.d/60_spotify.nft` — wlan UDP 5353 + TCP 37879.
- `/var/cache/librespot/` — librespot cache dir.
- (package: `librespot-0.8.0-r0` from Alpine edge/testing, libmdns backend.)

All of the above are **wiped by the next rootfs flash** — they must be ported into
`pmos/` + `docker-build.sh` to persist, which is deferred until §2 is fixed.

---

## 5. RESOLVED in v1.6.1 (2026-06-29, same day)

Both items above are now **fixed and shipped** — released **v1.6.1**, hardware-verified
from a **clean flash**. (Detail: `CHANGELOG.md` `[1.6.1]`.)

- **§2 TAS5713 2× speed bug — FIXED by kernel patch
  `0022-ASoC-omap-mcbsp-derive-CLKGDV-from-fclk-simple-card.patch`** (`pmos/linux-google-steelhead`
  pkgrel 25). The actual root cause was **not** the B7 MCLK lead in §2.3 — it was the
  `simple-audio-card`↔`omap-mcbsp` **master-mode gap**: the generic card only sets
  `mclk-fs` and never calls `snd_soc_dai_set_clkdiv()`, so `omap-mcbsp` left
  **`CLKGDV = 0`** (bit clock = the *undivided* 24.576 MHz functional clock) and sized
  the frame as `in_freq/rate = 256` BCLK → **FSYNC = 96 kHz for a 48 kHz stream = the
  exact 2×**. The `func_mcbsp2_gfclk` reading 24.576 MHz (=512×48k) was a *correct*
  fclk — the ×2 was the missing divider, as §2.3 suspected ("SRG divider"). The patch
  derives `CLKGDV` from the real `mcbsp->fclk` and uses a minimal `wlen*channels` I2S
  frame when the machine driver supplies no explicit divider, reproducing the **factory
  kernel's registers exactly** (CLKGDV = 15, BCLK 1.536 MHz, 32-BCLK frame, FSYNC
  48 kHz; cross-checked vs `reverse-eng/vmlinux.bin`). **Verified on hardware:** 60 s of
  audio now plays in **60.00 s (ratio 1.000×)** — was ~30 s (0.50×). The "B7 TAS5713
  MCLK 16 vs 12.288 MHz" concern (§2.3) was a **red herring**: the mainline `tas571x`
  codec has no `.set_sysclk`, so MCLK never gates FSYNC.
- **§1 Spotify Connect — BAKED INTO THE BUILD.** `pmos/device-google-steelhead`
  pkgrel 11 now `depends librespot` and ships the enabled `librespot.service`,
  `/etc/asound.conf` (the **`nexusq`** PCM = `plug` → `hw:CARD=NexusQSpeaker,0` forced to
  48000 Hz — audio is addressed by **card NAME** because the TAS5713/HDMI cards race for
  card 0/1 across boots, so the old `plughw:1,0` could have landed on HDMI), and
  `/etc/nftables.d/60_spotify.nft`. librespot now plays via the `nexusq` PCM at correct
  pitch (44.1 k resampled to the clean 48 k). All three files survive a flash. The
  device-side `.service`/`.nft` from §4 are superseded by the in-repo versions under
  `pmos/device-google-steelhead/`.
