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

The agent owns: checking fastboot/adb state, then probing **eth-direct** (carrier,
host IP `10.42.0.1`, known device IPs, IPv6 link-local, mDNS `steelhead.local`),
**USB gadget** (RNDIS `172.16.42.1` — re-discover the `enx*` iface whose MAC/name
changes each reboot, mark it unmanaged, assign `172.16.42.2`; plus the `/dev/ttyACM*`
serial console as a fallback), and **WiFi** (look the lease up in OPNsense via the
`opnsense-api` helper, matching hostname `steelhead` / MAC `f8:8f:ca:20:48:e1`). It
verifies the winner with a real `ssh` probe and returns the single best connect
command + fallbacks. It does NOT change anything on the device.

When it reports back, relay the connect command to the user (and use it yourself
for any follow-up shell work). See [[nexusq-device-access]], [[nexusq-usb-gadget-rename]],
[[nexusq-apk-over-usb-nat]], [[flaky-connection-broken-ipv6]].
