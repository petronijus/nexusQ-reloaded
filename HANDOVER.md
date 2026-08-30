# Cross-machine handover

Steps that were done on ONE machine but have to be done on the others before the
project works there. Delete a section once its steps are done on that OS.

`HANDOFF.md` is the session log — what happened and why. **This file is the todo
list for the other machines.** Matching tasks live in Todoist → **AI-handover**.

---

## MacBook — 2026-08-30: you can cut releases here now, after one command

### Why this exists

Until today the rule was "build release images on the desktop". That rule was
never about the desktop. pmbootstrap runs `abuild-keygen` the first time a build
volume is initialised, so **every machine invented its own package-signing key**:

| machine / image | key |
|---|---|
| desktop `nexusq-workdir` | `pmos@local-6a42e957` ← the fleet key |
| **MacBook** `nexusq-workdir` | `pmos@local-6a93112c` |
| image v1.13.0 (Šumperák was flashed from it) | `pmos@local-6a913e9e` |

That key does two jobs at once, and the second one is the dangerous one: it
signs the packages, **and its public half is baked into the image's
`/etc/apk/keys`**. So an image built here decides whether the box flashed from it
can ever use the OTA repo. v1.14.0, v1.14.1 and v1.14.2 were all cut on this
MacBook — every Q flashed from them answers `apk update` with `UNTRUSTED
signature` and cannot OTA at all.

### Do this once (~1 minute)

```sh
cd ~/Documents/Dev/nexusQ-reloaded
git pull
op signin
scripts/install-fleet-signing-key.sh
```

It streams the private key from **1Password → document "nexusQ OTA signing key
(fleet)"** (account `my`) straight into the docker volume — never onto the disk,
never echoed, never an argument — and installs it **only after `openssl` derives
the public half from it and finds it byte-identical to
`pmos/ota-signing-key.rsa.pub`**. A name match would prove nothing; that is
exactly how the drift stayed invisible for weeks. Any other key in the volume is
moved to `config_abuild/retired/`, because `publish-ota-repo.sh` discovers the key
by globbing and alphabetical order is not a decision.

Check without changing anything: `scripts/install-fleet-signing-key.sh --check`

### ⚠️ Then rebuild, before publishing anything

The packages already sitting in that volume's `packages/edge/armv7` were signed
with the **old** key. `publish-ota-repo.sh` would happily re-sign a fresh index
over stale apks. Run a full build after installing the key.

### What a release looks like now

A release is **two publishes of one build**, and they used to be separate commands
joined by nothing — which is how v1.14.2 shipped device r89 as an image while the
OTA repo kept serving r87 for two days, with every UI reporting "up to date".

```sh
./docker-build.sh                       # or PUBLIC_RELEASE=1 for a clean image
scripts/package-release.sh v1.15.0      # image assets + OTA publish + the gates
```

`package-release.sh` now publishes the OTA repo itself and then gates on the two
agreeing. `--no-ota` skips the publish; **nothing skips the gates.**

| gate | what stops you |
|---|---|
| `release-preflight-no-secrets.sh` | a personal image (baked WiFi PSK / ssh keys) being packaged |
| INSTALL.md marker | cutting `vX.Y.Z` while the guide's `<!-- RELEASE: -->` marker says something else |
| `verify-apk-no-secrets.sh` | publishing an apk that carries a PSK, `authorized_keys` or a private key |
| `verify-ota-parity.sh` | the image and the published repo disagreeing on versions or on the signing key |
| `docker-build.sh` fleet check | building with `PUBLIC_RELEASE=1` on a machine whose key is not the fleet key (hard failure) |

### macOS specifics

- **The gates work here.** `release-preflight-no-secrets.sh` and
  `verify-ota-parity.sh` both read the ext4 rootfs with `debugfs` rather than
  mounting it, and both re-run themselves inside a throwaway container when the
  host has no `debugfs` — which macOS does not. No root, no loop devices.
  Verified end to end on 2026-08-30 by hiding `debugfs` from `PATH`.
- **`scripts/verify-rootfs.sh` is the exception**: it still `sudo mount`s, so on
  macOS run it inside the privileged builder image
  (`docker run --privileged --user root -v /dev:/dev -v "$PWD:/src" -w /src
  nexusq-builder bash scripts/verify-rootfs.sh output/google-steelhead.img`).
  Run it **as root and from the repo root** — two of its gates were found on
  2026-08-30 passing silently when they could not read root-owned files or
  resolve a relative path.
- `scripts/tests/*` and the migration test use `mkfs.ext4 -d`, which macOS lacks.
  They are development tests, not release steps; run them on Linux.
- The **private overlay** (`private/`) must be cloned for a personal build, and
  this MacBook's ssh key should be in `private/access/authorized_keys` — see the
  older AI-handover task for that.

### Related, still open

- **Šumperák** trusts `pmos@local-6a913e9e` and therefore still cannot OTA at
  all. It needs `pmos/ota-signing-key.rsa.pub` copied into its `/etc/apk/keys`,
  or a reflash from an image built with the fleet key. Needs someone on site.

Full story: `docs/2026-08-30-release-reaches-nobody-and-the-flag-the-gadget-had.md`
and HANDOFF.md → "WHICH MACHINE BUILDS WHAT".
