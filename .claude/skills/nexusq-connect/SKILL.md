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

The agent owns: checking fastboot/adb state, then probing **eth-direct**
(RESOLVED 2026-07-04, first-class again: host has the persistent
`eth-direct-host` profile on `enp7s0`, the device bakes an `eth-direct` static
profile 10.42.0.2/24 — `autoconnect=no` by design, so if ssh fails over the
cable but another path works, `nmcli c up eth-direct` on the device, then
`ssh root@10.42.0.2`; device eth0's hw MAC is random per boot — no MAC EEPROM),
**USB gadget** (RNDIS `172.16.42.1` — re-discover the `enx*` iface whose MAC/name
changes each reboot, mark it unmanaged, assign `172.16.42.2`; plus the `/dev/ttyACM*`
serial console as a fallback), and **WiFi** (stable FINAL IP **`192.168.20.195`**
since the 2026-07-03 batch-2b/`#29` factory-MAC flash — try it directly; else
look the lease up in OPNsense
via the `opnsense-api` helper, matching hostname `steelhead` or the MAC per the
flashed image: the **factory `f8:8f:ca:20:48:e1` on `#29`+** (NM-pinned,
verified on air), the chip's OTP `14:7d:c5:3a:35:b5` on the interim `#27`
(lease `.175`); on the older v1.6.5 image the lease MAC is
randomized per boot and the IP wanders, hostname-match only). It
verifies the winner with a real `ssh` probe and returns the single best connect
command + fallbacks. It does NOT change anything on the device (the one allowed
exception: activating the baked `eth-direct` profile).

When it reports back, relay the connect command to the user (and use it yourself
for any follow-up shell work). See [[nexusq-device-access]], [[nexusq-usb-gadget-rename]],
[[nexusq-apk-over-usb-nat]], [[flaky-connection-broken-ipv6]].
