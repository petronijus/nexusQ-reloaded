# Cross-machine handover

Steps that were done on ONE machine but have to be done on the others before the
project works there. Delete a section once its steps are done on that OS.

`HANDOFF.md` is the session log — what happened and why. **This file is the todo
list for the other machines.** Matching tasks live in Todoist → **AI-handover**.

---

## Desktop (petronijus-PC) — 2026-08-31: v1.15.0 SHIPPED

Both steps this section used to list are done, so it is trimmed to what is still
live. **v1.15.0 is published** (mainline 6.18 LTS, cross-native build), the
cross-native kernel **booted** on the Prague Q, and the `k618b` perf study came
back clean — no regression, and the earlier "regression" turned out to be the
collector's own ssh polling. Full record:
`docs/2026-08-31-kernel-6.18-lts-and-the-rollback-that-disarmed-itself.md`.

**Still open, and none of it is a blocker for what shipped:**

- **Ethernet after a cold power-cycle is unverified on 6.18.** Patches
  0006/0008/0012 exist for exactly that path and it only proves itself cold, with
  a cable. HDMI, fastboot-over-ssh (0044), USB-host re-probe and USB Audio are
  likewise unexercised.
- **Kernel OTA itself has been running safely in the field** (Petr, 2026-09-01) —
  the trial-slot flow with its health gate is not the shaky part, and nothing here
  should be read as a warning against using it.
  The narrower open item is the **rollback's module-restore path** (`nexusq-kernel-ota`
  r4): it only executes when a trial kernel actually fails and gets rolled back, so
  a run of good OTAs — however long — cannot exercise it. Still unproven rather
  than suspect.
- **The app cannot offer a kernel update.** `checkSystemUpdate` filters the kernel
  out — correctly, since apk must never apply one — so a kernel reaches a device
  only via `nq-kernel-ota` over ssh. A proper fix gives the kernel its own track.
  Rationale and consequence are written into `nexusq-control` at `_KERNEL_PKG`.
- **Šumperák** still trusts a different signing key and cannot OTA at all.

**Two live traps worth keeping in front of anyone touching this:**

- 🚨 **`172.16.42.1` is the Lumia, not the Q.** Both projects share the USB-gadget
  subnet, and `nqctl` auto-mode tries USB *before* WiFi. It also reports the Q
  unreachable when OPNsense is down, because it resolves the WiFi lease through
  it. `hostname` first, always. The Q lives at **192.168.20.246**.
- 🚨 **One build at a time on `nexusq-workdir`, across all sessions.** A second
  build zaps the first one's chroots mid-compile and the victim sees a *fake
  toolchain error*. `docker ps` before starting anything.

## Desktop (petronijus-PC) — the 6.18 bump: lessons worth keeping

⚠️ This section used to read *"the 6.18 kernel rebase is done but UNBUILT"* and
carried a **Resume here** checklist. All of it shipped in **v1.15.0** on
2026-08-31 — the rebase is in git, the kernel is built, booted and published, and
the patch stack is at 6.18.48. The checklist is deleted rather than corrected: a
todo list that describes finished work sends the next session to redo it, and its
`6.12.12` references made the repo look like it was still on the old kernel.

What is kept below is the part that outlives the bump and applies to the **next**
one (the following LTS is due around Nov/Dec 2026). Full record:
`docs/2026-08-31-kernel-6.18-lts-and-the-rollback-that-disarmed-itself.md`;
current state in memory `kernel-618-rebase-result`.

### Found at build time (2026-08-31)

- **Three patches applied with zero fuzz and still did not compile** against 6.18:
  0005 and 0029 (upstream constified the sysfs `bin_attribute` API) and 0007
  (upstream migrated clk from `.round_rate` to `.determine_rate(hw, req)`, and
  git's 3-way merge planted our body into the new signature, where the old
  parameters no longer exist). All three are fixed and compile-verified.
  **A clean `patch` apply says nothing about compiling** — the GNU-patch gate is
  necessary, not sufficient, and it cannot see a 3-way-merge hazard like 0007.

  **Pre-flight before booking the shared build volume**, which catches all of them
  in one pass in ~102 s with no docker and no volume:

  ```sh
  cd ~/nexusq-build/kstack/linux            # the patch stack, branch `steelhead`
  export ARCH=arm CROSS_COMPILE=~/Documents/Dev/nexusQ-reloaded/build/\
  arm-gnu-toolchain-13.3.rel1-x86_64-arm-none-linux-gnueabihf/bin/arm-none-linux-gnueabihf-
  cp ../../../Documents/Dev/nexusQ-reloaded/kernel/configs/steelhead_defconfig .config
  make olddefconfig && make -j"$(nproc)" all
  ```

  ⚠️ **A green build here is NOT proof the shipped kernel is good.** This is
  arm-gnu 13.3 against glibc headers; the kernel actually ships built with Alpine
  gcc 15.2.0 for musl. It is a fast *API-drift* gate, nothing more — the real
  build still has to run, and the device still has to boot it.
- **Only one build may run on this machine at a time**, across all sessions — see
  memory `build-volume-is-single-writer`. A second build zaps the first one's
  chroots mid-compile and the victim sees a *fake toolchain error*
  (`cannot execute cc1: posix_spawn`). `docker ps` before starting anything.
- **`sha512sums` must be trimmed alongside `source=`.** Dropping 0004 and 0032
  from `source=` while leaving their `SKIP` lines aborts abuild with
  "Number of checksums(96 / 2) does not correspond to number of sources(46)".

### A patch worth sending upstream

Mainline's `tas571x_coefficient_info()` **still** sets
`uinfo->value.integer.max = 0xffffffff`, which is `-1` in a 32-bit `long`, so
every biquad coefficient write is clamped. That is our patch 0046. As of 6.18.48
it is unfixed and now also reaches TAS5717/5719 and the newly added TAS5733 on
every 32-bit host. Small, clean, defensible — worth a post to ASoC.

Full state: memory `kernel-618-rebase-result`.

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
