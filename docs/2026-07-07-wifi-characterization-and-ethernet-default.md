# 2026-07-07 — WiFi characterized (5 GHz healthy, bulk is a HW ceiling) + ethernet is now the default deploy path

All measured live 2026-07-07 on the running **v1.6.10** image (device pkg
`r28`, kernel `6.12.12 #36`). Two outcomes: (1) the long-standing "WiFi is
flaky" framing is **retired** — 5 GHz is healthy and the ~34 Mbit/s bulk cap is
a **hardware ceiling of the 2010-era BCM4330 combo chip**, not a bug; (2) the
**direct-cable ethernet path is now the default** deploy/control transport
(measured fastest + most stable + fixed IP), baked in `device-google-steelhead`
**r29** (built + flashed as v1.6.11 for testing, but never git-tagged; ships in
the next release **v1.6.12** alongside the desktop-audio fix r30 —
`docs/2026-07-07-desktop-audio-pulseaudio-fix.md`). No kernel change; no image
behaviour changed beyond the four NM/diag files below (already applied LIVE on
the device, bake from the next build).

---

## 1. WiFi characterization — 5 GHz is NOT flaky; bulk is a HW ceiling

The "BCM4330 flaky" memory dates to a 2.4 GHz-era BT-coexist bulk stall. Re-run
on 5 GHz today it does not hold — the link is clean and the throughput cap is
intrinsic to the chip.

### 5 GHz link quality (`Svatovitske-Internety-5g`, vlan20)
- Signal **−48 dBm**, `/proc/net/wireless` link quality **62/70**.
- **0** discarded / retry / frag packets.
- Jitter to the vlan20 gateway: **2.6 ms avg / 6 ms max, 0 % loss** over 160
  pings. This is a healthy link, not a flaky one.

### Bulk throughput ≈ 34 Mbit/s is a HARD ceiling (not a bug)
Measured over ssh/chacha20; **dead-consistent across runs**. Ruled out as the
cause, one by one:
- **Not per-flow / not congestion-avoidance:** 2 parallel streams **aggregate to
  ~29 Mbit/s** (LESS than one, contention) — so a single flow is already at the
  chip's limit.
- **Not crypto:** the *same* ssh/chacha20 cipher does **~80 Mbit/s over
  ethernet**, so the Cortex-A9 crypto ceiling is ≈80 Mbit/s and WiFi — not the
  CPU — is the limit.
- **Not power-save:** setting `powersave=2` (off) + reconnect gave **no change**
  (~34 Mbit/s); reverted to default.
- **Not the SDIO bus:** `mmc4` is already at **50 MHz / 4-bit / SD-high-speed**
  (raw ~200 Mbit/s, ample headroom).
- **Root cause:** it is the 2010-era **1×1 802.11n** BCM4330 combo chip on SDIO,
  last firmware **Jan-2013, 5.90.195.114**. Not fixable in software — and it is
  ~100× the appliance's real need (Spotify 320 kbps + LED control).

### 2.4 GHz (tested 2026-07-07): stable, NOT flaky, but strictly worse than 5 GHz
- Both 2.4 GHz variants ran at **0 % loss** — not flaky.
- Main AP `Svatovitske-Internety` broadcasts **802.11g-only (54 Mbit/s cap)** →
  **~14 Mbit/s**, jitter 10.7 / 83.5 ms.
- The chip **does** support 2.4 GHz 802.11n — proven by joining the `_EXT` mesh
  node at **130 Mbit/s 11n negotiated** — but real throughput was still only
  **~13–16 Mbit/s** (repeater backhaul + weaker signal + congested ch6, ~13 APs
  visible), jitter 2.7 / 7.4 / 29 ms.
- So on this chip/environment **2.4 GHz never beats 5 GHz**. BT-coexistence with
  idle BT was minor (blocking the BT radio did not raise throughput).

**Verdict:** use 5 GHz (`Svatovitske-Internety-5g`) for WiFi; it is healthy.
Bulk transfers should use ethernet (below), not because WiFi is broken but
because the BCM4330 caps at ~34 Mbit/s by design.

---

## 2. Ethernet is now the DEFAULT deploy/control path (replaces the USB gadget)

Measured 2026-07-07 on the direct PC↔Nexus cable:
**ethernet ~80 Mbit/s, 0.62 ms, 0 % loss** — beats WiFi (~34) and the USB gadget
(~64 Mbit/s crypto), and unlike the gadget it has a **fixed name/IP** (the
gadget's `enx*` iface renames every reboot and has no host IP until re-added).

- Direct cable: host `eth-direct-host` on `enp7s0` = **10.42.0.1/24** ↔ device
  `eth-direct` = **10.42.0.2/24** (also the secondary 10.0.0.x pair).

### Device config change — automatic fall-through, no manual `nmcli c up`
The direct cable has no DHCP server; previously `eth-direct` was
`autoconnect=false` and you had to `nmcli c up eth-direct` by hand each boot.
Now it comes up on its own via NM autoconnect priority:

- `eth-lan.nmconnection`: `autoconnect-priority` **5→10**, `dhcp-timeout`
  **30→10 s**. NM tries DHCP FIRST on any eth0 carrier.
- `eth-direct.nmconnection`: **`autoconnect=true`** (was `false`),
  `autoconnect-priority=5`, `autoconnect-retries=1`.
- **Behaviour:** on a real LAN, `eth-lan`'s DHCP completes and wins (higher
  priority). On the serverless direct cable, `eth-lan` fails its single DHCP
  attempt (~10 s after carrier-up) and NM falls through to the static
  `eth-direct` → **10.42.0.2 comes up automatically**, no manual step.
  `never-default` on `eth-direct` keeps it from hijacking the route if it ever
  activates on a real LAN; `autoconnect-retries=1` + `cloned-mac-address=permanent`
  keep the old carrier-bounce retry loop from re-arming.

### Tooling / brief updates
- `pmos/device-google-steelhead/APKBUILD`: pkgrel **28→29** (bakes the profile
  changes into the next image; the audio fix later bumped it **29→30**, so the
  shipped v1.6.12 image carries r30).
- `scripts/diag/nqctl`: ethernet (**10.42.0.2**) is now the **first-tried path**
  (order eth → usb → wifi) in `pick_host`/`status`/`--path`. Added `NQ_ETH_HOST`
  and an ssh-agent-independent `SSH_OPTS` (`IdentityAgent=none` +
  `IdentitiesOnly=yes` + `-i $NQ_SSH_KEY`) so it works when the host ssh-agent is
  unavailable / broken instead of falling through to a failing password prompt.
- `.claude/agents/nexusq-connect.md` + `.claude/skills/nexusq-connect/SKILL.md`:
  `eth-direct` is now the **#1 transport** in the fast-pass (USB gadget demoted
  to fallback).

### Caveat
`eth0`'s hw MAC is **random per boot** (the LAN9500A has no MAC EEPROM) and
`cloned-mac-address=permanent` puts that random address on the wire — so on a
**real LAN** the DHCP lease/IP still changes every boot (match by hostname
`steelhead`). The direct-cable path is unaffected (static IP).

The profile edits are applied LIVE on the running v1.6.10 device now; they baked
into the image from the v1.6.11 test build (pkgrel 29) and ship in the v1.6.12
release (pkgrel 30, with the audio fix).
