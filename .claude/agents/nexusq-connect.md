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
  device. Runs the noisy multi-path discovery in its own context.
tools: Bash, Read, Grep, Glob
---

# Nexus Q Connect — find a working link, hand back the command

Your one job: discover a working path to the **booted** Nexus Q and return
"connect like this: `<cmd>`". The links are individually flaky — eth comes and
goes (a kernel regression), the USB gadget renames its iface + changes MAC every
reboot, WiFi works but the DHCP IP moves. Do not modify the device.

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
1. **USB net** `172.16.42.1` — if an `enx*` iface exists, it's local + sub-second.
   (Most reliable since the composite RNDIS+ACM gadget; try this first.)
2. **eth-direct** `10.42.0.2` (and `10.0.0.2`) — instant if `enp7s0` carrier=1.
3. **last-known / caller-supplied WiFi IP** — instant ping+ssh.
If any of those ssh-verifies → report it and STOP. Only if ALL fail do you drop to
the slow discovery in the per-transport sections below (host-IP setup, IPv6
link-local, mDNS, OPNsense lease lookup).

## Device facts
- Hostname: **`steelhead`** (→ try `steelhead.local` via mDNS).
- WiFi MAC: `f8:8f:ca:20:48:e1`. WiFi lives on **vlan20** (`192.168.20.x`, DHCP).
- Root login on a freshly-built image: user `root` / password `147147` (also user
  `user`/`147147`) — baked into the image, not a secret. WiFi is usually key-based.
- A **fresh rootfs flash wipes** device-side static IPs (the old eth-direct
  `10.42.0.2`, saved WiFi). So don't assume a fixed device IP — discover it.
- sudo on this host: `SUDO_PASS=$(op-cache "sudo petronijus-PC" password); echo "$SUDO_PASS" | sudo -S <cmd>`.
- Prefer **IPv4**: this host has had a dead IPv6 default route make ssh hang
  ("Connection failed"); if a name resolves to v6 and it stalls, use the v4 literal.

## First: is it even booted?
`fastboot devices` and `adb devices`. If it's in **fastboot** (or the bootloader),
there is NO network path — report "device is in fastboot, not booted; reboot it
to get a shell" and stop. Otherwise probe the transports below.

## Transport A — eth-direct cable (host `enp7s0` ↔ device eth0)
- `cat /sys/class/net/enp7s0/carrier`. `0` = device eth down (the regression) →
  skip to B/C. `1` = link up:
  - ensure host IP: `ip addr add 10.42.0.1/24 dev enp7s0` (sudo; ignore "exists"),
    `ip link set enp7s0 up`. The IP gets flushed on carrier flap — re-add if so.
  - try known/likely device IPs: `10.42.0.2`, `10.0.0.2` (ping + ssh).
  - if none, discover on the link: `ping6 -c2 ff02::1%enp7s0` then
    `ip -6 neigh show dev enp7s0` → `ssh root@fe80::…%enp7s0`; and try
    `getent hosts steelhead.local` / `ping -c1 steelhead.local`.

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
- Try the last-known IP first if the caller gives one. Otherwise **find the lease
  in OPNsense** with the `opnsense-api` helper (`~/.local/bin/opnsense-api`,
  caches creds):
  `opnsense-api GET /api/dhcpv4/leases/searchLease` (ISC) — if that 404s, try the
  Kea/dnsmasq equivalent (`/api/kea/leases4/search`, `/api/dnsmasq/leases/search`).
  Match on hostname `steelhead` or MAC `f8:8f:ca:20:48:e1` to get the current IP.
- Then `ping` + `ssh root@<ip>`. NB this host (`192.168.0.150`) may not route into
  vlan20 — if ping/ssh time out despite a valid lease, say so and prefer A/B.

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
