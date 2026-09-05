---
name: nexusq-connect
description: >-
  Find a working way to reach the booted Google Nexus Q (steelhead) and return the
  exact connect command. Probes eth-direct, USB gadget (RNDIS net + ACM serial),
  and WiFi (looking the DHCP IP up in OPNsense when unknown), sets up the host side
  (IPs, enx unmanaged, IPv6 link-local / mDNS), verifies with a real ssh probe, and
  hands back "connect like this". Use when you need a shell/scp on the device and
  the link is uncertain. Trigger phrases: "connect to the nexus", "is the device
  reachable", "find the Q's IP", "get me a shell on steelhead", "ssh into the nexus".
---

# /nexusq-connect

Delegate device discovery to the **`nexusq-connect` subagent** (Agent tool,
`subagent_type: "nexusq-connect"`) so the noisy multi-transport probing stays out
of the main context. Pass any hint the user gave (a last-known IP, "use USB",
"it's on wifi").

The agent owns: checking fastboot/adb state (and, on a **booted v1.11.0+ /
`#46`+** device, it can put it *into* fastboot for a flash via
`systemctl reboot --reboot-argument=bootloader` — patch 0044, no power-cycle;
must be `systemctl`, not busybox `reboot`), then probing **eth-direct**
(**the DEFAULT path** — ~80 Mbit/s, 0.6 ms, stable, fixed IP; measured
2026-07-07 to beat both WiFi ~34 Mbit/s and the USB gadget. NM layer resolved
2026-07-04 and baked since v1.6.7 — flashed 2026-07-05: host has the persistent
`eth-direct-host` profile on `enp7s0`, the device bakes an `eth-direct` static
profile 10.42.0.2/24 — since device pkg **r29 `autoconnect=true`** at lower
priority than `eth-lan` so it falls through automatically ~10 s after
carrier-up; if ssh still fails over the cable but another path works, `nmcli c up
eth-direct` on the device forces it, then `ssh root@10.42.0.2`. ✅ Enumerates from a cold
boot on `#33`+ (v1.6.8, task #17 CLOSED 2026-07-06 — the old "enumeration
intermittency" was an unmuxed `gpio_1` NENABLE pad, fixed by a DTS pad mux); on
a **pre-`#33`** image `eth0` may be absent on a cold boot (that unmuxed pad, not
a profile fault) — `ls /sys/class/net` for `eth0` first, get onto `#33`; device
eth0's hw MAC is random per boot — no MAC EEPROM),
**USB gadget** (RNDIS `172.16.42.1` — re-discover the `enx*` iface whose MAC/name
changes each reboot, mark it unmanaged, assign `172.16.42.2`; plus the `/dev/ttyACM*`
serial console as a fallback), and **WiFi** (last-known lease
**`192.168.20.246`** as of 2026-08-10 — the factory-MAC pin does NOT freeze the
lease; it has moved `.195`→`.184`→`.164`→`.246` (`.246` = a fresh lease after the
2026-08-10 internet outage); try the last-known IP but **never
hardcode it** — else look the lease up in OPNsense
via the `opnsense-api` helper (⚠️ broken from this PC as of 2026-08-10 — no
`opnsense.home.arpa` DNS + 404 on gw `:8443`; re-verify before relying on it),
matching hostname `steelhead` or the MAC per the
flashed image: the **factory `f8:8f:ca:20:48:e1` on v1.10.1+** (`#45`/kernel r44
— DTS-pinned `local-mac-address`, patch 0043, `ethtool -P wlan0` PERMANENT, and
the lease hostname is populated again), the chip's **OTP `14:7d:c5:3a:35:b5` on
`#29`–`#44`** (v1.6.6–v1.10.0 — the NM pin only reached the baked profile, so
on-air was the OTP MAC with an **empty hostname**; found 2026-07-15) and on the
interim `#27` (lease `.175`); on the older v1.6.5 image the lease MAC is
randomized per boot and the IP wanders, hostname-match only). It
verifies the winner with a real `ssh` probe and returns the single best connect
command + fallbacks. It does NOT change anything on the device (the one allowed
exception: activating the baked `eth-direct` profile).
There is a **second unit at the cottage** (`nexus-q-sumperak.local`, WiFi
`f8:8f:ca:05:1f:11`, DHCP on `<cottage-lan>/22` since 2026-08-30 — the old static
`<old-static-ip>` is gone; only reachable from the cottage LAN, not via Tailscale).
Say which unit you mean when there is any doubt.

When it reports back, relay the connect command to the user (and use it yourself
for any follow-up shell work). See [[nexusq-device-access]], [[nexusq-usb-gadget-rename]],
[[nexusq-apk-over-usb-nat]], [[flaky-connection-broken-ipv6]].
