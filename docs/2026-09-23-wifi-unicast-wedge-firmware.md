# 2026-09-23 — WiFi: the firmware that stopped listening

For weeks the Q kept dropping off WiFi. Home Assistant showed it offline, Spotify
skipped, and `nexusq-wifi-watchdog` bounced the link many times a day. Every
other device on the same AP was fine. The cause was the WiFi firmware.
The linux-firmware blob we shipped (5.90.195.114, January 2013) stops delivering
unicast frames to the host every few minutes. Stock Android's own firmware
(5.90.125.0, February 2012) runs under the same brcmfmac driver without a single
failure. `firmware-google-steelhead` **r3** ships the stock firmware.

## 1. What a "wedge" actually is

The Q stays associated with a good signal (−47 dBm) and keeps its IP. Pings to the
gateway fail, and after a while DHCP renewal fails too. Three measurements
during an episode (kernel 6.18.48-r16, C2/C3 disabled):

- **The Q still transmits.** On the PC, `tcpdump -i enp2s0f1 ether src
  f8:8f:ca:20:48:e1` showed the Q's ARP requests and its DHCP REQUEST arriving
  on the wired side of the AP.
- **The Q receives broadcast and multicast, but no unicast.** An AF_PACKET
  counter on `wlan0` split received frames by destination. In 12 s it counted
  0 unicast frames to the Q, 7 broadcast and 39 multicast. `arping` to the
  gateway got 0 replies.
- **A full disconnect/connect restores the link, but only for a few minutes.**

So the TX path is fine and unicast RX is broken. DHCP then fails as a
consequence, because the offers and ACKs come back unicast.

`iw` shows `rx bitrate 6.0 MBit/s` in every episode. That is not a symptom in
itself: brcmfmac reports the rate of the last frame received of any kind, and
during a wedge that is always a broadcast at the 5 GHz basic rate.

## 2. Two hypotheses, one ruled out

1. **The AP thinks the Q is asleep** and buffers its unicast (a power-save state
   desync).
2. **A-MPDU / BlockAck receive state desyncs**, so the firmware holds or drops
   aggregated frames.

A probe service ran on the device. At each detected wedge it pinged the gateway
five times, toggled `iw dev wlan0 set power_save on` then `off` (which makes the
firmware tell the AP it is awake), and pinged five times again. In two real
episodes the result was **0/5 before and 0/5 after**, so hypothesis 1 is out.
(A third trigger was a false alarm, 4/5 before and 3/5 after.)

For hypothesis 2 the brcmfmac source settles one detail. With the default
`fcmode=0` on SDIO, `brcmf_fws_attach()` returns at "FWS queueing will be
avoided" before it ever sets `ampdu_hostreorder`. Any reordering therefore
happens inside the firmware, so a reorder bug would be a firmware bug. That
made the firmware itself the next suspect.

## 3. Stock never ran this firmware

The stock factory image (`tungsten-ian67k`, `system.img`) contains:

| File | What | md5 |
|---|---|---|
| `/vendor/firmware/fw_bcmdhd.bin` | stock WiFi firmware, `4330b2-roml/sdio-ag-pool-ccx-btamp-p2p-idsup-idauth-proptxstatus-pno-aoe-toe-pktfilter-keepalive`, **5.90.125.0**, 2012-02-19 | `658765a665299744947e99e1f1986d19` |
| `/etc/wifi/bcmdhd.cal` | NVRAM | `f222187eb4c97e47b0f173a270001563` (**identical** to what we ship) |
| `/vendor/firmware/bcm4330.hcd` | BT patchram | `7e5bb859e33142e94052c76fba23b9e6` (identical to what we ship) |

We were shipping linux-firmware's `4330b2-roml/sdio-ag-p2p-idsup-idauth-pno`
**5.90.195.114**. The NVRAM and the BT patchram already matched stock; the WiFi
firmware was the only one of the three that did not. The June WiFi note stated
that stock ran the "same firmware (5.90.195.114)". That came from a stock-kernel
RAM boot which never mounts `/system`, while stock `bcmdhd` loads
`/system/vendor/firmware/fw_bcmdhd.bin`. The stock driver was running on *our*
blob. That one test kept the firmware off the suspect list for three months.

The old notes claimed that brcmfmac "cannot use" a bcmdhd firmware image. That
was never tested, and it is wrong. On the BCM4330 both drivers speak BCDC over
SDIO, and brcmfmac loaded the stock image on the first try:

```
brcmf_c_preinit_dcmds: Firmware: BCM4330/4 wl0: Feb 14 2012 09:51:59 version 5.90.125 (TOB)
```

The stock kernel had `bcmdhd` built in (the `dhd_*` symbols are in
`reverse-eng/vmlinux.bin`). It contains no `wlfc`/`proptxstatus` strings, so
stock ran without host flow control, which is exactly what brcmfmac's
`fcmode=0` does.

## 4. The A/B

The switch was made live: point the board symlink
`brcmfmac4330-sdio.google,steelhead.bin` at the stock image, then unbind and
rebind `mmc4:0001:{1,2}` from `brcmfmac`. Pings were counted by the on-device
trace, one every 5 s, and by `nexusq-wifi-watchdog`, one check every 30 s.

| Firmware | Window | Result |
|---|---|---|
| linux-firmware 5.90.195.114 | 28 min before the switch | **73 %** of gateway pings failed (248/341) |
| linux-firmware 5.90.195.114 | previous boot, 2.7 h | watchdog: 79 bad checks, 98 checks with loss, repeated heals |
| stock 5.90.125.0 | 20 min right after the switch | PC → Q: **1200/1200** pings; Q → gateway: 0 failed of 243 |
| stock 5.90.125.0 (from the r3 package, after a reboot) | 5.8 h | watchdog: **64 ok, 0 bad, 0 with loss, no heal** |

The repeated `brcmf_escan_timeout: timer expired` messages stopped with the
switch too. There were 17 in the 2 h 15 min before it and none since.

## 5. The price: lower bulk throughput

The stock firmware is slower, measured back to back the same evening with the
same method as in 2026-07-07: 40 MB over ssh, `chacha20-poly1305`.

| Firmware | PC → Q (the Q receives) | Q → PC (the Q transmits) |
|---|---|---|
| linux-firmware 5.90.195.114 (fresh association, before it wedges) | 18–20 Mbit/s | 28–30 Mbit/s |
| stock 5.90.125.0 | 13–16 Mbit/s | 13–14 Mbit/s |

It is not SDIO packet glomming. brcmfmac enables host TX glomming only if the
firmware accepts `bus:rxglom`. Asked directly (an nl80211 vendor DCMD
`GET_VAR`), **both** firmwares answer −52 (unsupported). Stock's aggregation
settings look ordinary too: `ampdu`=1, `ampdu_ba_wsize`=64,
`ampdu_rx_factor`=1, `ampdu_density`=6, `amsdu`=0, `nmode`=1. The difference
lives inside the firmware's rate control or aggregation. That is also where the
newer firmware's unicast RX breaks, so the extra speed and the wedge may well
come from the same change.

For this appliance the trade is easy. Spotify needs 320 kbit/s, AirPlay about
1.4 Mbit/s, and Roon's RAAT at the Q's 48 kHz about 2.3 Mbit/s. 13 Mbit/s is
several times what any of them needs. A link that does not drop is what matters.

## 6. What changed

- **`firmware-google-steelhead` r3** ships the stock `fw_bcmdhd.bin` as
  `brcmfmac4330-sdio.bin`. The board-named symlinks are unchanged.
- **`docker-build.sh`** has no linux-firmware download fallback any more, since a
  fetched blob would bring the wedge back without anyone noticing. It stages
  all three blobs from `./firmware/` and checks each against the md5 of the
  one correct steelhead copy. A missing or wrong blob is a hard error.
- **`scripts/setup-firmware.sh`** stages and verifies the same three blobs from
  the private overlay. When the overlay is absent, it prints the `debugfs dump`
  commands that pull them out of the stock `system.img`.
- The private overlay holds `firmware/fw_bcmdhd.bin`.
- **`nexusq-wifi-watchdog` stays, but no repair is quiet any more** (device
  r107, nexusq-mqtt r7). The heals were built for this wedge, so a repair from
  now on is a failure worth knowing about. The watchdog counts each heal and
  reconnect in `/run/nexusq/wifi-watchdog.json`, and nexusq-mqtt publishes it
  to Home Assistant as a "WiFi repairs" counter, a "Last WiFi repair"
  timestamp and a "WiFi link" problem sensor (ON for 24 h after a repair). The
  heal itself is kept because it also rescues a different failure, a
  NetworkManager stuck in DHCP (the `nogw` case, 2026-08-02), that no firmware
  fixes.

## 7. Tools worth keeping

Reading a firmware iovar from a running system, with no debug build needed. This
is `BRCMF_VNDR_CMDS_DCMD`: OUI `0x001018`, subcmd 1, header
`{cmd=262 GET_VAR, len, offset=20, set=0, hdrlen=20}`, followed by the
NUL-terminated name and room for the answer.

```sh
# payload for "mpc": cmd 262, len 8, offset 20, set 0, hdrlen 20, "mpc\0" + 4 bytes
iw dev wlan0 vendor recv 0x001018 0x1 0x06 0x01 0x00 0x00 0x08 0x00 0x00 0x00 \
   0x14 0x00 0x00 0x00 0x00 0x00 0x00 0x00 0x14 0x00 0x00 0x00 \
   0x6d 0x70 0x63 0x00 0x00 0x00 0x00 0x00
# -> vendor response: 0c 00 02 00 | 00 00 00 00   (nla len 12, type DATA, mpc = 0)
```

The answer is the first four bytes after the 4-byte nla header. −52 means the
firmware does not know the iovar.
