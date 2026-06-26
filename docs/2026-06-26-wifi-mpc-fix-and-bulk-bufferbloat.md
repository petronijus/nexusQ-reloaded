# WiFi (BCM4330 / brcmfmac) — mpc fix shipped, bulk still broken (2026-06-26)

## TL;DR

- **Stock proves it's our software.** Same firmware (`5.90.195.114`) + byte-identical
  nvram (`bcmdhd.cal`) + same chip + same AP as the stock Android image, which works
  with the vendor `bcmdhd` driver. Our mainline uses `brcmfmac`. So every WiFi defect
  is a brcmfmac driver/config gap, not hardware/firmware/RF/environment.
- **SHIPPED + committed (`44e32d8`): `mpc=0`.** Fixes the *small-packet* reliability —
  packet loss 30 % → 0 %, idle latency 270–530 ms → 4–59 ms.
- **STILL BROKEN: bulk throughput.** A sustained transfer collapses: ~2 Mbit/s, stalls,
  and the latency *under load* explodes to **3–4 seconds** with 50 % loss
  (catastrophic bufferbloat). An `iperf3` TCP session over WiFi can't even sustain.

## Fix #1 — mpc (Minimum Power Consumption) — DONE

`brcmf_c_preinit_dcmds()` forces the firmware `mpc` iovar to 1, so the firmware powers
the radio **down when idle**. The per-scan re-enable (`brcmf_scan_config_mpc`) only runs
for chips with the `NEED_MPC` quirk (BCM4329 only); on our BCM4330, with P2P disabled,
`mpc` stays 1 forever → the radio sleeps and every traffic resume costs 270–530 ms +
~30 % loss. Stock `bcmdhd` sets `mpc=0`.

- **Kernel patch `0021-brcmfmac-mpc-module-param.patch`**: exposes `mpc` as a brcmfmac
  module parameter (default 1, behaviour unchanged upstream).
- **`device-google-steelhead/brcmfmac-mpc-off.conf`**: `options brcmfmac mpc=0`
  (the Nexus Q is mains-powered and never wants the radio to sleep).
- HW-validated: loss 30 %→0 %, idle latency 270–530 ms→4–59 ms. Persistent (patched
  `.ko` + conf in rootfs). Committed `44e32d8`.

## The bulk problem — NOT yet fixed

Rigorous test (2026-06-26): 30 MB transfer = ~2 Mbit/s + stalls; `ping` under a
sustained `dd|ssh` load = **3057–3895 ms RTT, 50 % loss**. The TX path floods and TCP
collapses.

### `iw` evidence (measured over the eth transport, see below)
```
Connected to <AP-2.4G>, freq 2437 (ch6), signal -32 dBm (strong)
tx bitrate: 54.0 MBit/s     # 802.11g, OK
rx bitrate:  1.0 MBit/s     # <-- DOWNLOAD stuck at the lowest 802.11b rate!
HT: Capabilities 0x1020, HT20, RX HT20 SGI, MCS 0-7   # device IS 802.11n-capable...
                                                      # ...but the link negotiated NON-HT
tx failed: 0
```
So two distinct problems sit under the "bulk" symptom:
1. **RX rate stuck at 1 Mbit/s** — the device receives (downloads) at the basic rate.
   (Confirm whether this is real per-frame or a beacon artefact via rx-bitrate during a
   live bulk — the iperf run to confirm this was still pending.)
2. **No 802.11n / A-MPDU** — the link is legacy g/b although the chip advertises HT.

### Tried, did NOT fix the bulk
- `roamoff=1` (bcmdhd parity — disable firmware roaming/periodic scans). One 100 KB scp
  passed once, but 30 MB still stalls → inconclusive. Kept as a likely-good parity knob.
- `fcmode=2` (EXPLICIT_CREDIT flow control). brcmfmac default is `FCMODE_NONE` (no
  credit-based throttling → the host floods the firmware queue → bufferbloat); bcmdhd
  uses `dhd_txflowcontrol`. But the param has perm 0 (unreadable) and the BCM4330
  firmware may not support the `bdcv2 tlv` (→ forced FCMODE_NONE). Bulk still stalled →
  likely no effect. Needs the perm fixed to verify.

### NOT the cause (ruled out)
- SDIO: `sg_support=TRUE` (omap_hsmmc `max_segs=64`), 50 MHz / 4-bit HS = optimal,
  txglom path fine. The clm_blob/txcap "-2 missing" warnings are benign (BCM4330 carries
  them in fw+nvram; regdomain already reads CZ).

## The eth transport (testing unblock — reusable)

The flaky WiFi can't push tools (scp lands empty); the `/dev/ttyACM0` serial console
corrupts file transfers (canonical-mode mangling). The reliable path is the on-board
**eth0** (LAN9500A), a direct cable to this host:

```
# host (petronijus-PC): the cable is on enp7s0 (carrier=1, no IP)
sudo ip addr add 10.42.0.1/24 dev enp7s0 && sudo ip link set enp7s0 up
ssh root@10.42.0.2          # device eth-direct profile: 10.42.0.2 + 10.0.0.2
# -> 0.8 ms RTT, 0 % loss. iw + iperf3 pushed over this; iperf3 server on the device.
```
NB eth0 is intermittent on cpufreq builds (task #17) — it came up this boot. When up,
it is the transport to use for all WiFi measurement (run iperf over WiFi to
`<lan-ip>`, control the device over eth `10.42.0.2`).

## Next steps (the rigorous bulk follow-up)

1. **Confirm the RX-1-Mbit/s** with rx-bitrate sampled *during* a live iperf download.
2. **Why no 802.11n** — does brcmfmac associate without HT here? AP HT support on ch6,
   the firmware HT iovars, the assoc request.
3. **Bufferbloat** — host `txqueuelen` / `fq_codel` on wlan0 + the firmware credit flow
   control (`fcmode`, once the param perm is fixed so it's verifiable).
4. **Delivery** — fold `mpc=0 roamoff=1` (+ a verified `fcmode`) into the device conf and
   add `iw`/`iperf3` to the device-package depends so the rootfs ships them; then measure
   over eth without the manual tool-push dance.

Device conf currently (experimental, only `mpc=0` is committed):
`options brcmfmac mpc=0 roamoff=1 fcmode=2`

## Update (later 2026-06-26): eth re-verified fast; WiFi WORKS on 5 GHz

**eth is NOT slow** (re-verified, the "small eth download?" question). `dd|ssh` =
80 Mbit/s both directions (4 runs, consistent); raw `nc` (no ssh) = ~106 Mbit/s —
i.e. at the 100 Mbit/s LAN9500A line rate (the 80 is just ssh-AES overhead). So the
system (CPU/ssh/stack) is fine; the bulk problem is **WiFi-specific**.

**Decisive band test — WiFi on 5 GHz WORKS.** Connected to `<AP-5G>`
(ch52, 5260 MHz, -48 dBm):
- `tx 65 MBit/s` = HT MCS7 → **802.11n IS negotiated**. The device is HT-capable; the
  2.4 GHz AP `<AP-2.4G>` is **g-only** (its beacon carries no HT IE — the
  scan shows only ESS/Privacy/RadioMeasure).
- 30 MB DOWN = 9 s (**26 Mbit/s**); 30 MB UP = 8 s (**30 Mbit/s**) — both complete, no stall.
- rx bitrate during the download holds ~65 MBit/s (**no collapse**, vs 18→1 on 2.4 GHz).
- ping under load: 0 % loss, 2/35/256 ms (vs the 3–4 s + 50 % loss on 2.4 GHz).

So the device's WiFi is **FUNCTIONAL** (~26-30 Mbit/s reliable on 5 GHz). The 2.4 GHz
collapse is explained by two 2.4-GHz-specific factors:
1. The 2.4 GHz AP is **g-only** (no HT/A-MPDU) → legacy rates, fragile under load.
2. **BT coexistence** — the BCM4330 is a WiFi+BT combo sharing one **2.4 GHz** antenna
   (nvram `btc_params*`; `bluetoothd` is running). BT arbitrates 2.4 GHz airtime; the
   5 GHz WiFi is on a different band so it is *clear of BT*. **CONFIRMED** the
   device-side cause: disabling BT on 2.4 GHz (`systemctl stop bluetooth` +
   `hciconfig hci0 down`) takes the 15 MB download from **2 Mbit/s (stall, rx 18→1
   collapse) to 9 Mbit/s**, and the rx bitrate **holds at 54 MBit/s** (no collapse).
   So BT coexistence — BT sharing the 2.4 GHz antenna and stealing airtime — is the
   confirmed 2.4-GHz bulk killer (this is "our software", per the always-software
   rule). The residual 9 Mbit/s is the congested g-only 2.4 GHz AP's own limit.

   **Fix direction:** reduce BT airtime — mask `bluetooth.service` if BT is unused on
   the Nexus Q, or tune the coex (`btc_params` for WiFi priority, vs how bcmdhd sets
   them) — or simply use 5 GHz (clear of BT). NB rfkill is unavailable on the device
   (`/dev/rfkill` missing, CONFIG_RFKILL); disable BT via systemd + hciconfig.

**Practical outcome:** mpc=0 (committed) + **use 5 GHz** (`<AP-5G>`)
= a usable WiFi (~26-30 Mbit/s, reliable, HT). The 2.4 GHz throughput is a secondary
follow-up (BT-coex tuning vs bcmdhd `btc_params`; the g-only-AP is the AP's own limit).
Device is now on the 5 GHz SSID (IP <lan-ip>).
