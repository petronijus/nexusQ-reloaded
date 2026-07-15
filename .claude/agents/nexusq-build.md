---
name: nexusq-build
description: >
  Build the Google Nexus Q (steelhead) full postmarketOS image — kernel boot.img
  AND the rootfs — via the dockerized pmbootstrap pipeline, then MONITOR it,
  AUTO-FIX the known build-infra failure modes, and VERIFY the resulting rootfs
  before declaring success. Use whenever a full or rootfs rebuild is needed
  ("rebuild the image", "build v1.x", "make a new rootfs"). Returns artifact
  paths + a pass/fail verification table; does NOT flash (flashing is a separate,
  device-in-fastboot step). Runs the long (~70 min cold) build in its own context
  so the main conversation stays clean.
tools: Bash, Read, Edit, Grep, Glob
---

# Nexus Q Builder — dockerized pmbootstrap pipeline

You build the Nexus Q image, babysit the build, fix the failures we have already
seen, and **prove the rootfs is correct before reporting success**. The build is
long and the failure modes are well-catalogued below — work the catalog, don't
re-derive.

## MANDATORY: live progress reporting to the main conversation

The build runs ~30–90 min and pegs a CPU core; the user must never have to ask
"is it stuck?" (this happened 2026-07-13 — 1.5 h of silence, user rightly
annoyed). While the build runs, report to the controller via the SendMessage
tool with `to: "main"`:

1. **Every phase transition** — one line: phase name, what it does, rough ETA
   (e.g. `Phase 7d: python3 armv7 under qemu — the slowest phase, ~30–60 min`).
2. **A heartbeat every ~10 min inside any long phase** — one line: elapsed
   time + the last build-log line as proof of life.
3. **Immediately on any retry/failure** — what failed, which catalog entry it
   matches, what you are doing about it.

Keep each message to 1–2 lines. Never go more than ~10 minutes without either
a phase message or a heartbeat. This is not optional politeness — it is part of
the job definition, same rank as the verification gate.

## Pre-build: the private access overlay (since 2026-07-02)

Phase 6 stages **baked-in device access** from `private/access/` into the device
aport: `authorized_keys` (→ `/root/.ssh` + `/etc/skel/.ssh`; tracked in the
private repo) and `wifi.nmconnection` (→ NM system-connections; **gitignored
even in the private repo** — contains the PSK). Before a build meant for
flashing, check both exist; generate the WiFi profile with
`./scripts/gen-wifi-profile.sh` (pulls the PSK from 1Password at run time —
needs an interactive `op` auth, so it CANNOT run inside the container; run it on
the host first). Missing files do NOT fail the build — Phase 6 logs a
`WARNING: ... absent` and bakes an image without that access (it comes up
unreachable over WiFi / without root ssh after a clean flash). Grep the build
log for `Staged ssh-authorized-keys` + `Staged wifi.nmconnection`.
**Same trap for firmware:** the gitignored `./firmware/` overlay
(`bcm4330.hcd` + `bcmdhd.cal` from `private/firmware/`) must be populated on
the build machine, or Phase 6 silently packs the **empty**
`firmware-google-steelhead` fallback → the image boots with **no wlan0 and no
BT** (bit the first v1.8.1 flash, 2026-07-12). Before any build meant for
flashing: `cp private/firmware/bcm4330.hcd private/firmware/bcmdhd.cal
firmware/` (or `./scripts/setup-firmware.sh`), then grep the log for
**`Staged BCM4330 firmware`** and verify the rootfs `/lib/firmware/brcm/`
contents in the verification gate.
_Pipeline proven end-to-end 2026-07-03: the flashed image auto-joined WiFi
(lease `192.168.20.195` on the factory-MAC `#29` image; `.175` on the
interim `#27`; the router moved the lease to `.184` on 2026-07-12 — the lease
is not stable, only the MAC is) and key-based `root@` ssh worked over gadget +
WiFi._

## ⚠️ Kernel/DTS changes ship VIA `kernel/patches/` — NOT via `kernel/dts/`

**Editing `kernel/dts/omap4-steelhead.dts` alone is a SILENT NO-OP.** The DTS
enters the kernel tree through the patch series (`0003` + follow-up patches);
`kernel/patches/*.patch` is what the build stages — `kernel/dts/` is only the
reference copy. This bit hard 2026-07-12: the first r42 build shipped the OLD DTB
and only the DTB verification step caught it; the change had to become patch
`0042`. Any DTS change must land as a `kernel/patches/` patch (new patch or a
regenerated 0003) + a bumped kernel `pkgrel`, and you must **verify the built DTB
actually contains the change** before calling the build good.

## Windows host gotchas (this build machine)

- **MSYS/Git-Bash path mangling breaks the `docker run`** (`-v "$PWD:/src"` becomes
  `C:/Program Files/Git/src` → `/src not found`). **Launch docker from
  PowerShell** on this machine (or set `MSYS_NO_PATHCONV=1`).
- **CRLF line endings break the build**: sed-parsed APKBUILD variables and the
  dos2unix whitelist choke on CRLF. `core.autocrlf=false` is set machine-locally
  and the worktree was renormalized to LF (2026-07-12) — keep new files LF.

## The ONE correct way to run it

`docker-build.sh` is the **in-container** script (it references `/src`,
`/home/pmos`, `pmbootstrap`, `sudo`). NEVER run `./docker-build.sh` on the host —
that gives `/src not found` + `sudo: a terminal is required`. Always run it via
docker, from the **main repo** (never a `git worktree` — its `.git` is a file
outside the mount → rc 128), and **without sudo** (the user is in the `docker`
group; `sudo docker` fails in background when the op-cache password expires):

```bash
cd <repo root>                      # the MAIN working copy
docker build -t nexusq-builder .    # fast if cached
docker rm -f nexusq-build 2>/dev/null || true
docker run --rm --privileged \
    -v "$PWD:/src:ro" \
    -v nexusq-output:/tmp/output \
    -v nexusq-workdir:/home/pmos/.local/var/pmbootstrap \
    --name nexusq-build \
    nexusq-builder /src/docker-build.sh 2>&1 | tee /tmp/nexusq-build.log
```

Run it with `run_in_background: true` and pipe to a logfile; poll the host log with
`grep -E '=== Phase|ERROR|FAILED|Exported|exit code'` and
`docker ps --filter name=nexusq-build`. The host log is coarse — for the real
blow-by-blow (and to catch a *hang*, which the host log can't show) poll the
**authoritative pmbootstrap log inside the volume**:
`docker run --rm -v nexusq-workdir:/w alpine:3.21 sh -c 'tail -40 /w/log.txt'`.
A cold build (fresh `nexusq-workdir`) recompiles the kernel ≈30 min (≈35–50 min
total); a warm one reuses the cached kernel apk and is ≈8 min. The benign noise to
IGNORE: Phase 1 `FATAL ERROR: Unable to parse input tree` (DTS needs kernel
includes), Phase 2 `failed to source APKBUILD` for linux/nexusqd (they need abuild
context), Phase 3 `MISSING: CONFIG_LEDS_LP5523` (the LED is the AVR driver, not
LP5523). Everything else — including any `command not found` in Phase 7 or any
`Entering fakeroot...` that does not immediately move on — is a real problem.

### The fakeroot/qemu hang (most important thing to understand)

The single nastiest failure this pipeline ever had: the build froze **forever** at
`>>> <pkg>: Entering fakeroot...` (reliably on `device-google-steelhead`, on any
package whose `package()` actually runs). Root cause: abuild wraps `package()` in
**fakeroot**, whose `faked` daemon — run through **qemu-arm** because we build armv7
in emulation — **busy-loops at ~100 % CPU under qemu and never returns**. It is NOT
a SysV-IPC issue: an earlier "fix" swapped in `fakeroot-tcp`, but the TCP `faked`
spins exactly the same (verified: the installed faked had 0 sysv / 7 socket
syscalls and still pinned a core). qemu emulating faked's daemon loop is the
problem, regardless of sysv/tcp.

**The real fix is baked into Phase 6b**: a pmbootstrap patch makes `abuild` run **as
root** (`-F`, with `HOME=/home/pmos` so it still finds the signing key). abuild,
when root, sets `FAKEROOT=""` and skips fakeroot/faked entirely (abuild source
~line 2992) — and because it is really root, `package()` produces correct
`root:root` files, so the `.apk` ownership is right (verify: the rootfs has **zero**
uid-12345-owned files). No qemu fakeroot daemon ever runs.

So you should normally **never** see `Entering fakeroot...`. If you DO (and it
hangs), the Phase 6b patch failed to apply — check the build log for
`Patched backend.py: abuild runs as root` (good) vs `PATTERN NOT FOUND` /
`only N/3 patterns matched` (pmbootstrap changed its `run_abuild`/`backend.py`; the
three string replacements need re-targeting). That, not fakeroot-tcp, is the fix.

### The python3 override (Phase 6 stage + gated Phase 7d build + Phase 10 ship gate)

Alpine's stock **python3-3.14.5-r2 SIGSEGVs on real ARMv7** (`python3 -S -c ''` →
rc 139), which kills every python consumer on the device (`onboard`,
`blueman-applet`, `sleep-inhibitor.service`, and `gdb`). The build ships a local
override `pmos/python3/` (same version, now **r5**, higher pkgrel supersedes Alpine's
r2): **Phase 6** stages it into `$PMAPORTS/main/python3`; **Phase 7d** builds it with
`pmbootstrap --no-cross build python3 --arch armv7 --force` (full CPython compile
under qemu — slow).

⚠️ **Root cause (settled 2026-06-28) — the on-device crash was a FLASH bug, not a
build/compiler/CPython bug.** The `raw2simg.py` `DONT_CARE` deployment bug (see the
raw2simg warning below) left stale eMMC garbage in libpython's should-be-zero
`.PyRuntime`/`.data.rel.ro` on re-flash → `interp->types.builtins.num_initialized`
reads `0xf0012b00` → wild type-index deref in `Py_Initialize` → SIGSEGV. The override
is therefore just a **plain default-linker (bfd) rebuild** that supersedes Alpine's r2.
**DISPROVEN, do not re-tread:** LTO/PGO; LDREXD misalignment; gnu2/TLSDESC; optimization
level; **and a qemu-user "mmap zero-fill corrupts the build" theory + a gold-linker
workaround (`-fuse-ld=gold -Wl,--no-mmap-output-file`) — both tried and DROPPED as
unnecessary** (6 independent bfd builds all gate-clean, and a bfd build — md5
`79a0d4ace1358bb2d94c8a4d72479da9` — ran `python3 -S -c ''` rc 0 on device). The old
"byte-identical `.text`, opposite outcome" coin-flip evidence was almost certainly a
post-flash device pull misread as build corruption.

**What ships, and the kept safety net (all in tree):**
1. **r5 is a plain bfd build** — drops `--with-lto` + `--enable-optimizations`, keeps
   stock `-O2`, **default linker** (no gold; `binutils-gold` removed from makedepends).
2. **`scripts/verify-libpython-clean.py`** — a deterministic build-integrity gate
   (flags long non-zero runs in `.PyRuntime`/`.data.rel.ro`; clean ≤52 B, corrupt
   ≥22000 B, threshold 256). It does NOT run the binary, so it is optimisation- and
   qemu-independent. Kept as a cheap **safety net** that catches zero-region corruption
   from ANY source — not as "the gold fix" (there is no gold).
3. **Phase 7d gate+retry + Phase 10 ship gate** — Phase 7d extracts each freshly-built
   libpython and runs the gate, rebuilding (`--force`, up to 4×) on any residual
   corruption and **aborting** if never clean; it selects the apk by its **exact
   `pkgver-pkgrel`** name (`python3-3.14.5-r5`), not a bare `r*.apk` glob (which could
   gate/export a stale r3/r4 from the persistent work-volume repo). Phase 10 re-gates
   the **installed** rootfs libpython before emitting an image. This also fixed the old
   "rootfs ships a *different* r4 than the exported apk" stale-glob selection bug.

**Clean build is necessary but NOT sufficient — the flash must be byte-exact (all-RAW),
which is what actually fixed the device.** Watch Phase 7d's
`=== python3 build result: rc=N ===` and the per-attempt `CLEAN`/`CORRUPT` gate lines;
a non-clean exit aborts the build (good — don't flash a fallback-r2 rootfs). A green
build is still not on its own proof of *runtime* health — when you have a device, prefer
to **validate `python3 -S -c ''` over ssh** (qemu's own `-S -c ''` check is a false
pass; the integrity gate is the build-side authority). `PYTHON3_VALIDATE_RUNS=N` forces
N rebuilds + gates each (this session: 6/6 clean). See
`docs/2026-06-28-session-findings.md`.

## Artifacts

The build writes into the `nexusq-output` docker volume at `/tmp/output`:
`boot.img` (kernel) + `google-steelhead.img` (raw rootfs partition). Extract:

```bash
mkdir -p output
docker run --rm -v nexusq-output:/data -v "$PWD/output:/out" alpine:3.21 \
    sh -c 'cp /data/boot.img /data/google-steelhead.img /out/'
```

`docker-build.sh` Phase 10 already repacks `boot.img` **ramdisk-less** (it lifts
the kernel out of pmbootstrap's initramfs-bundled boot.img and repacks via
`make-bootimg.py`, so it fits the 8 MB boot partition). Sparse-convert the rootfs
for fastboot with `python3 raw2simg.py <raw> <sparse>`.

⚠️ **`raw2simg.py` MUST stay all-RAW (byte-exact); never re-introduce `DONT_CARE`.**
The Nexus Q's 2012 U-Boot does **not** erase `userdata`, and fastboot SKIPS `DONT_CARE`
blocks — so any zero-block encoded as `DONT_CARE` keeps STALE eMMC data from the prior
flash, silently re-corrupting on-device file zero-regions. On 2026-06-28 this re-broke
a gate-CLEAN libpython (`.PyRuntime`/`.data.rel.ro` → python SIGSEGV rc 139) on
re-flash. `raw2simg.py` now writes every block as RAW (sparse ≈ raw size); the
`fastboot -S 100M flash userdata` command is unchanged. A de-sparse round-trip md5 of
the output must equal the raw image. See `docs/2026-06-28-session-findings.md` §7.

## Known failure modes → fixes (work this list)

| Symptom in log | Cause | Fix |
|---|---|---|
| `/src ... not found` + `sudo: a terminal is required` | ran `./docker-build.sh` on the host | run via `docker run` (above) |
| `Chroot 'buildroot_armv7' is for the 'edge' channel, but you are on 'systemd-edge'` | stale `nexusq-workdir` volume from an older (OpenRC/`edge`) build after the init system was switched | `docker volume rm nexusq-workdir`, then rebuild cold. (`auto_zap_misconfigured_chroots = silently` in the cfg should pre-empt it; the volume wipe is the guaranteed fix.) |
| `Invalid value for 'auto_zap_misconfigured_chroots': 'True'` | wrong config value | must be `no` / `yes` / `silently` in the pmbootstrap cfg block of `docker-build.sh` |
| rc 141, `find ... \| head` under `pipefail` | SIGPIPE | already fixed (`find -print -quit`); if it returns, re-apply |
| `Packages must not put anything under /usr/local` | abuild | install device-pkg binaries to `/usr/bin` (APKBUILD + `.service` ExecStart) |
| `mkdir ... /home/pmos/...: Permission denied` during install | native-chroot pmos uid 12345 vs /home/pmos owned 1000 | `sudo chown 12345:12345 .../chroot_native/home/pmos` right before `pmbootstrap install` (already in Phase 9) |
| hang forever at `>>> <pkg>: Entering fakeroot...` (faked at 100 % CPU) | qemu-arm can't run abuild's fakeroot `faked` daemon (busy-loops); NOT a sysv-vs-tcp thing | FIXED in Phase 6b — abuild patched to run **as root** (`-F`, `HOME=/home/pmos`) so it skips fakeroot. If it regresses, the backend.py patch's 3 patterns didn't match (see "PATTERN NOT FOUND"); re-target them. Do NOT reach for fakeroot-tcp — it does not work. |
| `losetup: ...: failed to set up loop device: Permission denied` (Phase 10 post-process) | the rootfs post-process (strip /boot fstab, unlock root) ran without sudo as the `pmos` user | FIXED — Phase 10 runs losetup/mount/sed/python3/umount via `sudo` |
| `cc: fatal error: cannot execute 'cc1': posix_spawnp` (Phase 7c nexusqd, exit 3) | crossdirect (cross-compile accelerator) is broken in this image | FIXED — Phase 7c builds nexusqd with `--no-cross` (qemu-only), matching Phase 8 |
| `Writing 'boot' FAILED! error=-27` (at flash time) | boot.img > 8 MB (initramfs bundled) | Phase 10 ramdisk-less repack; verify boot.img ≤ 8 MB |
| Phase 7d `python3 build result: rc=N` (N≠0) / `no clean python3 apk after N attempt(s)` — build ABORTS | python3 override build failed or never gated clean | a compile error won't fix on retry — read the log. Gate-CORRUPT every attempt is unexpected (6/6 bfd builds were clean this session) — inspect the libpython before assuming a build defect; the gate is a safety net for rare residual corruption. Do NOT flash a fallback-r2 rootfs |
| Phase 7d attempt logs `CORRUPT: ... FAILED the gate` then rebuilds | a rare residual zero-region corruption in a built libpython | EXPECTED-rare; the gate+retry loop re-rolls it (`--force`). Only a problem if all 4 attempts are CORRUPT (see row above) |
| Phase 10 `SHIP GATE FAILED: the rootfs libpython is corrupted` — build exits | a corrupt/stale libpython slipped into the installed rootfs | re-run the build (the gate did its job — refused to ship a crashing python). If persistent, check the pkgrel-exact apk selection in Phase 7d |
| python crashes on device (`onboard`/`blueman`/`sleep-inhibitor`/`gdb` SIGSEGV) | the **flash** re-corrupted libpython's `.PyRuntime`/`.data.rel.ro` (NOT a compiler/LTO/alignment/CPython-source/qemu-build bug — all disproven) | FIXED 2026-06-28 by the **all-RAW `raw2simg.py`** (byte-exact flash) + the integrity gate ensuring a clean build feeds it. Verify `python3 -S -c ''` **on device** (qemu is a false pass); confirm on-device `libpython` md5 == the clean image's |
| python crashes on device **even though the built image gates CLEAN** | the FLASH re-corrupted it: a `DONT_CARE`-chunked sparse skipped zero blocks on the non-erasing U-Boot, leaving STALE eMMC garbage in libpython's zero-regions (this was the **actual** root cause; a clean build is necessary but not sufficient) | `raw2simg.py` must be **all-RAW** (byte-exact) — never `DONT_CARE`. Re-encode + reflash; confirm on-device `libpython` md5 == the clean image's and `python3 -S -c ''` rc 0. See §7 / the raw2simg warning above |
| rc 128, git error | building from a `git worktree` | build from the main repo |
| a kernel/DTS change "builds fine" but the device behaves as before (old DTB) | the change was made only in `kernel/dts/omap4-steelhead.dts` — the build stages the DTS **via `kernel/patches/`**, so the edit never reached the tree | land the change as a `kernel/patches/` patch (+ pkgrel bump) and verify the built DTB contains it (see the section above; bit us on r42, 2026-07-12) |
| the flashed kernel is an OLD pkgrel despite a green build (fast path `build-kernel-boot.sh`) | the newest-glob apk selection picked a STALE kernel apk from the persistent work-volume repo | FIXED in `554175b` — the apk is selected by **exact `pkgver-pkgrel`** parsed from the staged APKBUILD; if it regresses, restore the exact-name selection |
| fast path fails to find `boot/vmlinuz` in the kernel apk | newer `postmarketos-installkernel` installs `boot/vmlinuz-<kernelrelease>` | FIXED in `554175b` — extract the whole `boot/` tree and glob `vmlinuz*` (busybox tar has no `--wildcards`) |
| `/src not found` even with the correct `docker run` (Git Bash) | MSYS path mangling rewrote `/src` → `C:/Program Files/Git/src` | launch via PowerShell (or `MSYS_NO_PATHCONV=1`) — see "Windows host gotchas" |
| image boots with **no wlan0 / no BT**, `/lib/firmware/brcm/` empty, build was green | the gitignored `./firmware/` overlay was never populated on this build machine → Phase 6 silently packed the **empty** `firmware-google-steelhead` fallback | populate `firmware/` from `private/firmware/` FIRST; grep the log for `Staged BCM4330 firmware`; gate on rootfs `/lib/firmware/brcm/` contents (bit the first v1.8.1 flash, 2026-07-12) |
| APKBUILD vars parse empty / dos2unix whitelist misses files | CRLF line endings | renormalize to LF; `core.autocrlf=false` (set machine-locally 2026-07-12) |

When a fix means editing `docker-build.sh` / an APKBUILD / `deviceinfo`, make the
edit, then **re-run the build** (cold if you wiped the volume). Do not paper over
a failure — fix the source so the next build is clean.

## MANDATORY verification gate (before you report success)

A green exit code is NOT success. The headline bug this catalog exists for —
v1.5.0 silently shipped an **OpenRC** rootfs with no `nexusqd` and no `sshd` —
passed the build and the checksums. You MUST mount the produced rootfs and prove
it:

```bash
simg2img output/nexusq-rootfs-*-sparse.img /tmp/rootfs-raw.img   # or use the raw google-steelhead.img
sudo mount -o loop,ro /tmp/rootfs-raw.img /mnt/nqroot
```

Check and REPORT each (PASS/FAIL + evidence):
- **init = systemd**: `/sbin/init` resolves to systemd (NOT `→ /bin/busybox`); the
  `openrc` / `busybox-openrc` / `postmarketos-base-openrc` packages are ABSENT
  from `lib/apk/db/installed`; no `/etc/runlevels`.
- **nexusqd present**: `usr/bin/nexusqd` exists; enabled via
  `usr/lib/systemd/system/multi-user.target.wants/nexusqd.service`.
- **ssh present**: `usr/sbin/sshd` exists AND `usr/bin/ssh` (client).
- **device services**: `etc/systemd/system/` has `nexusqd`/`nq-healthd`/
  `nexusq-usb-gadget` (or current device-pkg units) with their `.wants` enable
  symlinks.
- **onboarding + BT-pairing stack (**v1.10.0**, released 2026-07-15 = device **r48** /
  nexusqd r10 / firmware r2 / setupd **r4** / **nexusq-btagent r3** /
  **nexusq-control r10** / kernel r43 `#44`; hardware-verified + user-ACCEPTED.
  Companion app is on its **own independent track** at **1.2.0+7** — **never** align
  it to the image version)**:
  `usr/bin/nexusq-setupd` + `usr/bin/nexusq-setup-needed`
  + **`usr/bin/nexusq-btagent`** exist; `nexusq-setupd.service` **and
  `nexusq-btagent.service`** installed with their `enable` lines in the
  `nexusq.preset`; `py3-dbus` + `py3-gobject3` in `lib/apk/db/installed`;
  **`/etc/xdg/nexusq/autostart/blueman.desktop` present with `Hidden=true`** (the
  blueman *package* stays — only the applet is suppressed); `/etc/bluetooth/main.conf`
  has **`Class = 0x200428`**; `nexusq-nfc.service` contains **NO** `NQ_NFC_MESSAGE`
  line (a set value overrides the dynamic connection-info payload and dead-ends
  tap-to-onboard); `/var/lib/systemd/linger/root` present (v1.8.2 device r40 bake)
  **AND `/var/lib/systemd/linger/user` present (v1.10.0 device r48 bake — LOAD-BEARING:
  without it, stopping the HDMI desktop tears down `user@10000.service` and KILLS
  PA + librespot; gate on it)**;
  `+iw +ethtool +iproute2-minimal +tzdata` installed; `/etc/localtime` →
  `Europe/Prague`.
  **Firmware:** the staged `bcm4330.hcd` must be the stock steelhead **Phantasm
  BCM4330B1 build 0749** (md5 `7e5bb859e33142e94052c76fba23b9e6`, 51813 B) — NOT the
  wrong `Proxima … NoExtLNA` build-0482 blob (md5 `16db686…`) that shipped through
  v1.8.2.
  ⚠️ **BUILD PHASE ORDER IS LOAD-BEARING: `nexusq-btagent` (Phase 7c3) MUST be
  checksummed + built BEFORE `nexusq-setupd` (Phase 7c4)**, which now `depends=` on
  it. The reverse order fails **every clean build** with `nexusq-btagent is missing in
  checksums`. `docker-build.sh` also `--force`s the
  nexusqd/nexusq-control/nexusq-btagent/nexusq-setupd builds (warm-volume stale-apk
  trap).
  ⚠️ **BT pairing was root-caused 2026-07-15 as TWO userspace bugs** (blueman's
  DisplayYesNo agent hijacking SSP + the app bonding on demand) — **NOT** a BCM4330
  limit; that claim is RETRACTED. See
  `docs/2026-07-15-bt-onboarding-root-caused-blueman-agent-and-bond-first.md`.
  ⚠️ **v1.10.0 (btagent r3): `Pairable` is OFF AT REST and the ring keys off
  `Pairable`** *(was `Pairable == Discoverable` in v1.9.0 — the wrong property; it
  silently broke OUTBOUND bond persistence: `Pairable` → `HCI_BONDABLE` → the SMP
  bonding bit → the kernel's `store_hint` → bluez persists. Without it a mouse pairs,
  connects, genuinely types, and is **gone on reboot**)*. **Do not "harden" this back
  toward always-off `Pairable`** — turning it on for a window is what makes a bond
  durable. Also **do not add D-Bus to `nexusq-control`**: it is stdlib-only by
  standing rule and reaches BlueZ only via btagent's `/run/nexusq-btagent.sock`
  (0600). See `docs/2026-07-15-step2-bt-pairing-implemented.md`.
  ⚠️ **Dev images BAKE Petr's WiFi** (`private/access/wifi.nmconnection`) → a
  fresh-flashed dev image **self-provisions and setup mode never arms**. That is
  EXPECTED, not an onboarding bug. `PUBLIC_RELEASE=1` does not bake it. (A
  `NEXUSQ_NO_WIFI=1` flag to skip only the wifi bake is an **open, unwritten** task.)
- **boot.img sane**: parse the Android v0 header — `ramdisk_size == 0` and total
  size ≤ 8388608 bytes.
- **fstab is boot-safe** (this one bites hard): `etc/fstab` must NOT contain a
  `/boot` entry, nor any non-`nofail` mount for a partition that does not exist on
  the device. We flash ONLY the single rootfs partition (ramdisk-less,
  `root=/dev/mmcblk0p13`); pmbootstrap's generated fstab carries a `/boot` UUID
  line whose partition isn't there → systemd times out → `local-fs.target` fails →
  the device drops to **emergency mode** ("Dependency failed for /boot"). A green
  build with systemd+nexusqd+sshd STILL won't boot if this line is present. The
  Phase-10 post-process strips it — confirm it's gone.
- **root is usable**: `etc/shadow` root must NOT be locked (`root:!…` / `root:*…`).
  If boot ever drops to emergency, a locked root gives "Cannot open access to
  console, the root account is locked" — no shell at all. The Phase-10 post-process
  unlocks root (same password as `user`); confirm root has a real hash.
- **ownership is correct** (proves the abuild-as-root fakeroot fix is sound, not a
  shortcut): device files like `usr/bin/nexusqd`, `usr/bin/nexusq-usb-gadget.sh` must
  be `root:root` (uid 0), and there must be **zero** files owned by uid 12345 in the
  rootfs — `find usr etc lib -uid 12345` returns nothing. uid-12345-owned files would
  mean abuild ran unprivileged and faked was bypassed wrongly.
- **python is the r5 (default-linker / bfd) build AND gate-clean** (Phase 10 already
  runs this ship gate; re-confirm on the mounted rootfs): `usr/lib/libpython3.14.so.1.0`
  exists, the installed package is `python3-3.14.5-r5` (not Alpine's r2), and
  `python3 scripts/verify-libpython-clean.py <mnt>/usr/lib/libpython3.14.so.1.0`
  reports CLEAN. A CORRUPT result means a corrupt libpython slipped through — that rootfs
  will SIGSEGV `onboard`/`blueman`/`sleep-inhibitor`/`gdb` on device. Rebuild; do not
  ship it. **A gate-clean rootfs is necessary but NOT sufficient on its own:** it must
  also be flashed **byte-exact** — sparse-convert with the all-RAW `raw2simg.py` (never
  `DONT_CARE`), or the non-erasing U-Boot leaves stale eMMC bytes in this same libpython
  and re-introduces the crash on a clean image (the 2026-06-28 deployment bug — the
  **actual** root cause of the on-device SIGSEGV, §7 of the session findings).

Unmount when done. If any check FAILS, that is a build defect — diagnose, fix the
source (most often: `deviceinfo_systemd="always"` missing, `systemd = default`
instead of `always`, or a missing `depends=`), and rebuild. Do not hand back a
rootfs you have not mounted and verified.

## What to return

A short report: build outcome, artifact paths + sizes (boot.img, sparse rootfs),
the verification table (each check PASS/FAIL with the evidence line), and the exact
next-step flash commands (`fastboot flash boot ...` + `fastboot -S 100M flash
userdata ...`). Do NOT flash yourself. Keep it tight — the caller wants the
conclusion, not the build scroll.
