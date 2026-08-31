# Cross-machine handover

Steps that were done on ONE machine but have to be done on the others before the
project works there. Delete a section once its steps are done on that OS.

`HANDOFF.md` is the session log — what happened and why. **This file is the todo
list for the other machines.** Matching tasks live in Todoist → **AI-handover**.

---

## Desktop (petronijus-PC) — 2026-08-31 evening: v1.15.0 is a DRAFT, two steps left

Session was restarted here. **A background task that was waiting for the perf
study died with it** — the study itself survives (it was started `setsid nohup`),
but nothing will collect it. Pick these up in order.

### State right now

- **v1.15.0 is built, packaged, gated and uploaded — but it is a GitHub DRAFT.**
  All three assets are attached (boot 6 713 344 B, rootfs .zst 661 977 028 B,
  sha256sums). 13/13 release gates passed. It became a draft by accident (a
  `gh release create` upload timed out), and that accident is *useful*: it puts
  the boot test before publication instead of after.
- `main` is pushed and carries everything: the 6.18 bump, the kernel-OTA rollback
  fix, and the full cross-native build.
- The Prague Q at **192.168.20.246** runs 6.18.48-r0 — but the **qemu-built**
  kernel, because staging picked the newest apk in the volume and that was build B.
  The **release image contains the cross-native build**, which has never booted.
  That is the gap the boot test closes.
- ⚠️ **`172.16.42.1` is the Lumia, not the Q.** `nqctl` auto-mode tries USB before
  WiFi and calls the Q unreachable when OPNsense is down. `hostname` first, always.

### 1. Collect the perf study (do this first, it is time-sensitive)

Arm `k618b` was started at device uptime 9156 s: `ARM_S=7200`, `SETTLE_S=180`, so
it ends around **uptime 16 536 s** and writes `/tmp/study2.done` when it exits.
Results land in `/var/log/nq-opp-study2-k618b/`.

```sh
ssh root@192.168.20.246 'cat /tmp/study2.done; tail -5 /var/log/nq-opp-study2-k618b/run.log'
scp root@192.168.20.246:/var/log/nq-opp-study2-k618b/* nq-captures/opp-k618b/
```

**Do not poll the device while an arm is running.** The first study (`k618`) was
invalidated exactly that way: the collector ssh'd in once a minute for 50 minutes,
53 logins inside the measurement window, and the memory note for this method says
in as many words *run detached and fetch once*.

Compare against the archived **old-kernel** runs on the device,
`/var/log/nq-opp-study2-allon2` and `-allon3`, which used the same arm shape.
Price the OPP mix by V²f, never by CPU time: 700 MHz = 2.75x, 920 MHz = 4.34x,
**1200 MHz = 6.21x** the cost of 350 MHz. And note the two old runs disagree with
each other by 1.20x, so treat anything inside that spread as noise.

### 2. Boot the cross-native kernel, then publish

The kernel apk rebuilt cross-native sits in the build volume (16:22). Verify which
build an image carries by decompressing its LZMA payload and reading the banner:
`armv7-alpine-linux-musleabihf-gcc` = cross-native, plain `cc` = qemu.

```sh
docker run --rm -v nexusq-workdir:/w -v /tmp/k:/out alpine sh -c \
  'cp /w/packages/edge/armv7/linux-google-steelhead-6.18.48-r0.apk /out/'
scp /tmp/k/linux-google-steelhead-6.18.48-r0.apk root@192.168.20.246:/tmp/
ssh root@192.168.20.246 'nq-kernel-ota stage-apk /tmp/linux-google-steelhead-6.18.48-r0.apk'
ssh root@192.168.20.246 'NQ_KOTA_YES=1 nq-kernel-ota try'
```

⚠️ **A trial boot cannot be undone remotely.** Stock u-boot has no bootcount and
does not fall back: if it does not boot, the Q stops at the bootloader and needs
hands on it. Do it with the device in reach. Slot A and
`/var/lib/nexusq-kernel-ota/slot-a-backup.img` are untouched either way.

Then the full `nexusq-diag` sweep, and only then:

```sh
gh release edit v1.15.0 --draft=false
```

### 3. Still unverified on 6.18 — say so, do not quietly tick it off

**Ethernet after a cold power-cycle** (patches 0006/0008/0012 exist for it and it
only proves itself cold), HDMI, fastboot-over-ssh (0044), USB-host re-probe, USB
Audio latency. Also: the kernel-OTA rollback fix was **seen failing, not seen
working** — it needs the next OTA cycle.

---

## Desktop (petronijus-PC) — 2026-08-31: the 6.18 kernel rebase is done but UNBUILT

### Why this is in this file

The rebase is **not in git**. It lives in `~/nexusq-build/kstack` (2.1 GB) on the
desktop only, so a `git pull` on the MacBook gets you nothing and re-doing it
there would be an hour wasted. Everything below happens on `petronijus-PC`.
The repo itself is clean — no APKBUILD or patch changes were committed.

### What is already done

`kernel/patches/` was replayed from 6.12.12 onto **6.18.48** (the newest LTS;
Petr's call over 7.1, which is what `linux-postmarketos-omap` runs, and over
staying on 6.12). Method and rationale: memory `kernel-bump-git-patch-stack`.

| | |
|---|---|
| patches in | 46 |
| applied | **44**, every one verified to apply to a pristine 6.18.48 with GNU `patch` |
| dropped | **0004**, **0032** — upstream fixed both, independently |
| conflicts | 3, all trivial |
| staged series | `~/nexusq-build/kstack/patches-6.18.48` |
| git stack | `~/nexusq-build/kstack/linux`, branch `steelhead`, tags `base-6.12.12` / `base-6.18.48`, `rerere` on |

The two dropped patches were checked, not assumed:

- **0004** (twl-core clock cell for TWL6030) — mainline now carries our exact
  `twl_class_is_6030()` condition *plus* a dedicated `twl6030-clk` cell, and
  `clk-twl.c`'s id table maps that cell to the same clk32kg + clk32kaudio data.
  The BCM4330 sleep clock survives. Upstream's version is better than ours.
- **0032** (omap-usb-host depopulate on remove) — upstream fixed the same bug in
  the same place with `if (pdev->dev.of_node) of_platform_depopulate()`.
  Equivalent for a DT-only platform, which is what we are.

The whole `arch/arm/mach-omap2` block — 12 patches covering VDD_MPU, VC, ABB,
OPP, cpuidle, restart and SMP — had **zero upstream churn** and rebased
untouched. That is the part that was expected to hurt, and it did not.

### Resume here

1. **Do NOT renumber the patches.** `git format-patch` emitted 0001-0044, but the
   docs and the memory index refer to patches by number ("patch 0046 = the biquad
   fix", "0044 = reboot reason", "0018 = the ti-abb catch-22"). Re-export keeping
   the original names, leaving **gaps at 0004 and 0032**. Renumbering silently
   breaks every one of those references.
2. `pmos/linux-google-steelhead/APKBUILD`: `pkgver=6.18.48`, `pkgrel=0`, and drop
   the 0004 and 0032 lines from `source=`. Then `pmbootstrap checksum
   linux-google-steelhead`. apk still sees this as an upgrade from `6.12.12-r52`
   — `pkgver` dominates `pkgrel`.
   ⚠️ `prepare()` rewrites `CONFIG_LOCALVERSION="-r$pkgrel"`, so pkgrel=0 gives
   `-r0` and therefore a `/lib/modules/6.18.48-r0` of its own. That is correct and
   is exactly what the kernel-OTA rollback path depends on — do not "tidy" it.
3. Build via the `nexusq-build` subagent.
4. **Measure `boot.img` against the 8 MB boot partition.** It is 6.2 MB on 6.12;
   six minor versions of growth is the one thing that can still sink this plan.
5. Take the authoritative Kconfig diff **from the pipeline**. The 781-line diff
   taken on 2026-08-31 was run with the host gcc, so half of it is `CC_HAS_*` and
   `AS_VERSION` noise. `olddefconfig` did succeed and every critical symbol
   survived (TAS571X, LEDS_STEELHEAD_AVR, MFD_OMAP_USB_HOST, USB_EHCI_HCD_OMAP,
   REGULATOR_TI_ABB, BRCMFMAC, NFC_PN544_I2C, SMP).
6. Deploy to the **trial slot p8 via kernel OTA**, not to the production slot.
   The health gate rolls a bad kernel back on its own; nothing needs a cable.
7. Then the full `nexusq-diag` sweep before calling it good.

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
