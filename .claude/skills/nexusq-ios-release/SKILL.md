---
name: nexusq-ios-release
description: >-
  Ship the companion app's iOS half to TestFlight from the Proxmox macOS VM (108),
  so an app release no longer needs the MacBook in the room. Handles the
  Windows↔macOS VM power swap (they share RAM; Windows has GPU passthrough and must
  never be reset), the signing bootstrap, the build launched in the VM's GUI session
  (codesign over plain ssh fails there), the upload with the team App Store Connect
  key, verification against the ASC API, and putting the host back. Use for "ship
  the iOS build", "vydej iOS na TestFlight", "release the app on iOS", "dodělej
  druhou půlku releasu", "iOS build <N>".
---

# /nexusq-ios-release

Delegate to the **`nexusq-ios-release` subagent** (Agent tool,
`subagent_type: "nexusq-ios-release"`) so the VM dance, the polling and the build
log stay out of the main context. Pass anything the user said that narrows it: a
build number, "leave macOS up", "Android is already out".

The agent owns the whole path: pre-flight on the repo and the version, the
Windows→macOS swap on Proxmox, an idempotent signing bootstrap (distribution
identity, `NexusQ Companion Distribution` profile fetched over the ASC API when
absent, repo clone, CocoaPods), the detached build launched via `osascript` into
the GUI session, the upload with the team ASC API key, verification against the
ASC builds endpoint, and the swap back to Windows.

## Before you delegate

- **This costs Petr his Windows VM for the duration.** 106 and 108 share RAM, so
  Windows goes down while macOS builds. Do not start it on your own initiative —
  it needs to be what the user actually asked for.
- **The version must already be right and pushed.** `companion/app/pubspec.yaml`
  is the only place the version lives, and both tracks share the `+N` (it is
  CFBundleVersion on iOS and versionCode on Android). If Android shipped
  1.18.1+52, iOS is 52 — the agent will not bump it and neither should you.
- The Android half is normally released first, from the desktop, with
  `build-apk.sh` + a `app-vX.Y.Z` GitHub release + the `app-release.json` bump.
  An app release is both tracks (Petr's rule since 2026-09-05).

## What comes back

The build number and its real state at App Store Connect (uploaded / processing /
VALID — a fresh upload takes 5–15 min to turn VALID), the Delivery UUID, anything
the agent had to bootstrap on the VM, and the final state of both VMs. Relay the
state honestly: "uploaded, still processing" is the usual answer straight after a
run, and it is a complete one.

## The three traps, in case you are doing this by hand

1. **`codesign` over plain ssh on VM 108 dies with `errSecInternalComponent`.**
   The build has to be launched into the Aqua session with `osascript`.
2. **Windows VM 106 has NVIDIA GPU passthrough — never `qm reset`/`qm reboot`.**
   The vfio reset bug took the whole host down on 2026-06-05. `qm stop` + `qm
   start`, graceful first.
3. **macOS VM has no guest agent**, so `qm shutdown 108` always times out. Stop
   it with ssh `sudo shutdown -h now`, verify `qm status`, and only start Windows
   once 108 reads `stopped`.

Full detail, addresses and the measured timings live in the agent brief
(`.claude/agents/nexusq-ios-release.md`).
