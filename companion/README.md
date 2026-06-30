# companion/ — modern Nexus Q companion app (WIP)

A new, modern companion app for the **postmarketOS / `nexusqd`** Nexus Q. The original Google
"Nexus Q" Android app (`com.google.android.setupwarlock`) is dead — its entire setup/control flow
depended on Google's Android@Home cloud, which was decommissioned in 2013, so it can no longer even
finish pairing a device.

This app replaces it for a Q we now fully control on the local network.

## Status

**Design phase — nothing implemented yet.** The original app has been reverse-engineered; the full
feature catalog, the three local wire protocols (discovery / pairing / control RPC), and a
keep/modernize/drop/add triage live in [`../docs/2026-06-30-companion-app-RE.md`](../docs/2026-06-30-companion-app-RE.md).

Decompiled originals (non-redistributable Google code) are kept out of this public repo, under
`private/nexusq-original/companion/` (gitignored).

## Scope (to be confirmed)

The worthwhile, reimplementable control surface distilled from the RE (see the triage):
LED theme + brightness, master volume/mute, output routing (HDMI/analog/S-PDIF), fixed-volume
line-out, A/V sync delay, now-playing, device/health info — talking to `nexusqd` over the LAN.

Open decisions (platform, v1 scope, device-side control protocol, discovery, pairing/auth) are
listed at the end of the RE doc.
