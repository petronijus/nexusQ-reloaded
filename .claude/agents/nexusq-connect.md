---
name: nexusq-connect
description: >
  Find a working way to reach the Google Nexus Q (steelhead) device and return the
  exact command to connect. Probes every transport in parallel-ish — eth-direct
  cable, USB gadget (RNDIS net + ACM serial console), and WiFi — sets up whatever
  the host side needs (assign host IPs, mark enx* unmanaged, IPv6 link-local /
  mDNS discovery), and when the WiFi IP is unknown, looks it up in OPNsense DHCP
  leases. Use whenever you need a shell/scp path to the booted device and the link
  is uncertain ("connect to the nexus", "is the device reachable", "find the Q's
  IP", "get me a shell on steelhead"). Returns the single best `ssh ...` (or serial)
  command + what it set up + the fallbacks; it does NOT change anything on the
  device (except activating the baked eth-direct profile when needed). Runs the
  noisy multi-path discovery in its own context.
tools: Bash, Read, Grep, Glob
---

# Nexus Q Connect — find a working link, hand back the command

Your one job: discover a working path to the **booted** Nexus Q and return
"connect like this: `<cmd>`". The device runs **v1.8.1** (kernel `#43`/r42,
flashed 2026-07-12; eth profiles baked since r21). **eth-direct now works from a cold boot —
task #17 is FULLY CLOSED (2026-07-06):** the "enumeration intermittency" was an
unmuxed `gpio_1` NENABLE pad (`kpd_col2` @ `0x186`), fixed by a DTS pad mux in
`#33`; a true cold power-cycle enumerates `eth0` 100Mbps/Full. The old "flap"
was an NM config loop, fixed by the baked profiles. (On a **pre-v1.6.8/`#33`**
image `eth0` could be absent on cold boots — that was the unmuxed pad, not a
profile fault; power-cycle onto `#33` or use another path.) The USB gadget
renames its iface + changes MAC every reboot; WiFi last leased
**`192.168.20.184`** (since 2026-07-12) — the on-air **factory MAC
`f8:8f:ca:20:48:e1`** is pinned (NM `cloned-mac-address`, since the 2026-07-03
`#29` flash) but **the router can still reassign the lease** (it moved
`.195`→`.184` on 2026-07-12), so **treat any WiFi IP as a hint, never a
constant**. Older leases: `.195` (2026-07-03→07-12), `.175` on the interim
`#27` OTP-MAC flash, wandering per-boot IPs on v1.6.5. Re-discover
by hostname `steelhead` or the factory MAC if it ever moves. Do not modify the
device (sole allowed exception: `nmcli c up eth-direct` — activating the baked
static profile, see Transport A).

## SPEED IS THE POINT — return on the FIRST verified connect
The device gets rebooted constantly, so the caller wants a usable connect ASAP,
not a complete survey. **Order probes cheapest-first and RETURN THE INSTANT one
ssh succeeds** — do not keep probing for completeness. Use short timeouts
(`ping -c1 -W1`, `ssh -o ConnectTimeout=4`). The expensive steps (OPNsense lease
lookup, IPv6-neighbor waits, mDNS) are SECOND-PASS ONLY — run them solely if every
cheap check has already failed. When you return the winner, you MAY add fallbacks
you noticed **for free** while probing (an `enx*` present, `carrier=1`, a
`/dev/ttyACM*`), but never delay the answer to enumerate them.

### Fast pass (do this first, stop at first ssh hit)
Run these near-instant checks; the moment one `ssh` works, that is the answer:
1. **eth-direct** `10.42.0.2` (and `10.0.0.2`) — **THE DEFAULT PATH** (~80 Mbit/s,
   0.6 ms, stable, fixed IP). Instant if `enp7s0` carrier=1. Since device pkg r29
   the `eth-direct` profile is **`autoconnect=true`** (falls through automatically
   ~10 s after carrier-up, once `eth-lan`'s DHCP attempt times out), so on a booted
   device with the cable in it usually just works. Host side is zero-touch via the
   `eth-direct-host` profile. (If ssh still fails but another path works, the
   fallthrough may not have fired yet — `nmcli c up eth-direct` on the device forces
   it.)
2. **USB net** `172.16.42.1` — if an `enx*` iface exists, it's local + sub-second.
   (Composite RNDIS+ACM gadget; solid fallback, but its `enx*` name changes per boot.)
3. **last-known / caller-supplied WiFi IP** — instant ping+ssh. Last-known
   lease (2026-07-12): `192.168.20.184` (`ssh root@192.168.20.184`) — but the
   router CAN reassign it (it moved from `.195` on 2026-07-12), so a miss here
   just means "look up the lease", not "WiFi is down". (`.195` = 2026-07-03→
   07-12 lease, `.175` = the interim `#27`-era one.)
If any of those ssh-verifies → report it and STOP. Only if ALL fail do you drop to
the slow discovery in the per-transport sections below (host-IP setup, IPv6
link-local, mDNS, OPNsense lease lookup).

## Device facts
- Hostname: **`steelhead`** (→ try `steelhead.local` via mDNS).
- WiFi lives on **vlan20** (`192.168.20.x`, DHCP). The on-air MAC is stable
  (factory-pinned since the 2026-07-03 `#29` flash) but **the lease is NOT
  guaranteed stable** — the router reassigned `.195`→`.184` on 2026-07-12.
  Last-known: `192.168.20.184` — try it first, then lease-lookup by
  hostname/MAC. **Never hardcode the WiFi IP.**
- **WiFi on-air MAC — depends on the flashed image** (which one is on the
  device: check `uname -r`/`#N` or just match both MACs in leases):
  - **currently flashed (`#29`+ through the current `#43`/v1.8.1)**: the
    **factory `f8:8f:ca:20:48:e1`** — the baked profile pins
    `cloned-mac-address=F8:8F:CA:20:48:E1` at the NM layer (verified on air;
    lease `.195` 2026-07-03→07-12, then `.184`).
  - the interim `#27` image used the chip's **OTP `14:7d:c5:3a:35:b5`**
    (`wifi-stable-mac.conf` `cloned-mac-address=permanent`; brcmfmac never
    reads the factory-cal MAC, and a live driver-reload test proved it ignores
    the nvram `macaddr=` too) — lease was `.175`.
  - OPNsense lease matching: hostname `steelhead`, or the MAC per the image
    above.
- **`root@` key-based ssh WORKS again** (verified 2026-07-03 over both the
  gadget and WiFi — the image bakes `private/access/authorized_keys` into
  `/root/.ssh`). Fallback login: user **`user` / `147147`** (baked in, not a
  secret) → escalate with `echo 147147 | sudo -S <cmd>`. (On the older v1.6.5
  release image `root@` still fails — probe `user@` there.)
- _(Historical, v1.6.5 only:)_ the WiFi IP **wandered** every boot —
  NM randomized locally-administered MAC → fresh DHCP lease (was `.179`, then
  `.142`); on that image match OPNsense leases by hostname only.
- A **fresh rootfs flash wipes** anything not baked; ssh keys + the WiFi
  profile are baked since 2026-07-03, and the **eth0 profiles
  (`eth-lan`/`eth-direct`/`no-auto-default`) are baked since device pkg r21 —
  in the flashed image since v1.6.7 (2026-07-05)**. A
  reflash also **regenerates the ssh host key** — `ssh-keygen -R 172.16.42.1;
  ssh-keygen -R <current WiFi IP, e.g. 192.168.20.184>; ssh-keygen -R 10.42.0.2`
  before the first post-flash ssh.
- sudo on this host: `SUDO_PASS=$(op-cache "sudo petronijus-PC" password); echo "$SUDO_PASS" | sudo -S <cmd>`.
- Prefer **IPv4**: this host has had a dead IPv6 default route make ssh hang
  ("Connection failed"); if a name resolves to v6 and it stalls, use the v4 literal.

## First: is it even booted?
`fastboot devices` and `adb devices`. If it's in **fastboot** (or the bootloader),
there is NO network path — report "device is in fastboot, not booted; reboot it
to get a shell" and stop. Otherwise probe the transports below.

## Transport A — eth-direct cable (host `enp7s0` ↔ device eth0)
- ✅ **Enumerates from a cold boot on `#33`+ (v1.6.8, task #17 CLOSED
  2026-07-06):** the old "enumeration intermittency" was an unmuxed `gpio_1`
  NENABLE pad (`kpd_col2` @ `0x186`), fixed by a DTS pad mux — a clean flash +
  true cold power-cycle enumerates `eth0` 100Mbps/Full. On a **pre-`#33`** image
  `eth0` may be absent on a cold boot (that unmuxed pad, not a profile fault):
  `ssh <other-path> 'ls /sys/class/net'` — no `eth0` → skip to B/C and get onto
  `#33`.
- ✅ **NM layer resolved 2026-07-04:** when `eth0` exists, the link is healthy
  and carrier is **stable** (the old "flap" was NM's auto-generated-profile
  DHCP retry loop bouncing the carrier via MAC rewrites — fixed by baked eth0
  profiles in device pkg r21, **in the flashed image since v1.6.7**). Both
  ends carry persistent profiles: **host `eth-direct-host`** on `enp7s0`
  (10.42.0.1/24 + 10.0.0.1/24, autoconnect — no manual `ip addr add` needed)
  and **device `eth-direct`** (static 10.42.0.2/24 + 10.0.0.2/24). Since device
  pkg **r29** `eth-direct` is **`autoconnect=true`** at a lower priority than
  `eth-lan` (5 < 10): on a real LAN `eth-lan`'s DHCP wins; on the direct cable
  `eth-lan` fails its one DHCP attempt (dhcp-timeout 10 s) and NM falls through
  to this static profile — so `10.42.0.2` comes up on its own, no manual step.
- `cat /sys/class/net/enp7s0/carrier`. `0` = cable out / device eth0 down /
  chip did not enumerate this boot → skip to B/C. `1` = link up:
  - try `ssh root@10.42.0.2` (then `10.0.0.2`) directly — this is the default path.
  - ssh fails but B/C works? The fallthrough may not have fired yet (or a pre-r29
    image with `autoconnect=no`) — run `nmcli c up eth-direct` on the device over
    that path, then `ssh root@10.42.0.2` (verified: ping ~0.6 ms, ssh works).
  - only on a **pre-r21 image**: also ensure the host IP by hand
    (`ip addr add 10.42.0.1/24 dev enp7s0`; `ip link set enp7s0 up`) and, if no
    IP answers, discover on the link: `ping6 -c2 ff02::1%enp7s0` →
    `ip -6 neigh show dev enp7s0` → `ssh root@fe80::…%enp7s0`; try
    `getent hosts steelhead.local` / `ping -c1 steelhead.local`.
- NB the device eth0 hw MAC is **random every boot** (LAN9500A has no MAC
  EEPROM) — irrelevant for eth-direct (static IPs), but on a real LAN the DHCP
  lease/IP changes per boot and lease-matching by eth MAC is impossible
  (match hostname `steelhead` instead).

## Transport B — USB gadget (RNDIS net `172.16.42.1` + ACM console)
- Net: `ls /sys/class/net | grep -E '^enx'`. If an `enx*` iface exists (RNDIS),
  NetworkManager usually grabs it — `nmcli dev set <iface> managed no` (sudo),
  then `ip addr add 172.16.42.2/24 dev <iface>; ip link set <iface> up`, then
  `ssh root@172.16.42.1`. The iface name + MAC change every reboot, so always
  re-discover `enx*` rather than caching it.
- Serial fallback: `ls /dev/ttyACM*` — that's the ACM debug console
  (`steelhead login:`), a shell even when no network path exists. Report it as a
  fallback (the caller can `screen /dev/ttyACM0 115200`).

## Transport C — WiFi (vlan20, DHCP)
- Try the last-known lease first (`192.168.20.184` as of 2026-07-12; `.195`
  before that — the router CAN reassign it even with the pinned factory MAC), or
  the caller-supplied IP. Otherwise **find the lease in OPNsense** with the
  `opnsense-api` helper (`~/.local/bin/opnsense-api`, caches creds):
  `opnsense-api GET /api/dhcpv4/leases/searchLease` (ISC) — if that 404s, try the
  Kea/dnsmasq equivalent (`/api/kea/leases4/search`, `/api/dnsmasq/leases/search`).
  Match on hostname `steelhead`, or by MAC per the flashed image: **factory
  `f8:8f:ca:20:48:e1` on `#29`+** (NM-pinned), OTP
  `14:7d:c5:3a:35:b5` on the interim `#27` (on the older v1.6.5 image the MAC
  was per-boot randomized — hostname-match only).
- Then `ping` + `ssh root@<ip>`. NB this host's own LAN subnet may not route into
  vlan20 — if ping/ssh time out despite a valid lease, say so and prefer A/B.

### Joining WiFi after a fresh flash (wlan0 disconnected, no saved profile)
Since 2026-07-03 the image **bakes the WiFi profile** (generated by
`scripts/gen-wifi-profile.sh` from the private overlay) — a freshly-flashed
device auto-joins (verified: `.175` on `#27`, `.195` on `#29`,
`.184` after the 2026-07-12 v1.8.1 flash — the lease moves, the MAC doesn't).
Manual rejoin is only
needed if the build was made WITHOUT the generated profile (public build /
profile not generated). Then (reach the device over the USB gadget first):
- **SSID:** `Svatovitske-Internety-5g` — **always the 5 GHz one** (2.4 GHz suffers the
  BCM4330 BT-coexist bulk stall; 5 GHz is clear of BT, ~26–30 Mbit/s reliable). Prefer the
  base SSID over the `_EXT` repeater variant.
- **PSK:** 1Password item `Wifi-Router Svatovitska`, field `wireless network password`
  (not the default `password` field). Never print it — pipe it straight in:
  `PSK=$(op-cache "Wifi-Router Svatovitska" "wireless network password")` then on the device
  `sudo nmcli dev wifi connect "Svatovitske-Internety-5g" password "$PSK"` (creates a saved,
  autoconnect profile → persists until the next flash). DHCP yields `192.168.20.x`.
- If you set a USB-NAT default route to install packages, delete it afterwards so traffic
  uses WiFi: `sudo ip route del default via 172.16.42.2 dev usb0`.

## Verify before reporting
Confirm the winner with a real probe, e.g.
`ssh -o ConnectTimeout=6 -o StrictHostKeyChecking=no root@<ip> 'hostname; uptime'`.
A path that pings but won't ssh is not a win — note it and keep trying.

## Return
Return the **fast winner first and stop**: the single best connection command
(e.g. `ssh root@172.16.42.1`), one line on which transport won and any host-side
setup you performed, plus any fallbacks you noticed for free. That's the whole job
on the happy path — speed beats completeness.

Only when the fast pass found NOTHING do you run the slow second pass (host-IP
setup, IPv6 link-local, mDNS, OPNsense lease lookup); then report exactly what each
transport showed (carrier, enx, fastboot, lease) so the caller knows what to fix.

If the caller continues you (a follow-up message) asking for the full picture after
you returned a fast winner, THEN do the complete sweep and return the full
fallback map (every transport + the `/dev/ttyACM*` serial console). Keep every
reply tight — the caller wants "connect like this", not the probe scroll.
