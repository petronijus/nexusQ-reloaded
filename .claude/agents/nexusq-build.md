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

### The python3 override (Phase 6 stage + Phase 7d build)

Alpine's stock **python3-3.14.5-r2 SIGSEGVs deterministically on real ARMv7**
(`python3 -S -c ''` → rc 139), which kills every python consumer on the device
(`onboard`, `blueman-applet`, `sleep-inhibitor.service`, and `gdb`). So the build
ships a local override `pmos/python3/` (same version, now **r4**, higher pkgrel is
meant to supersede Alpine's r2): **Phase 6** stages it into `$PMAPORTS/main/python3`;
**Phase 7d** builds it with `pmbootstrap --no-cross build python3 --arch armv7` (a
full CPython compile under qemu — slow). Watch Phase 7d's
`=== python3 build exit code: N ===`; a non-zero rc (or a missing
`python3-3.14.5-r*.apk` under `$WORK/packages`) means the rootfs would **fall back
to Alpine's broken r2** — do not flash.

⚠️ **It is NOT a compiler bug, and qemu gives a FALSE PASS for it.** Narrowed
2026-06-28 to a **CPython 3.14 source-level use-before-init / garbage-pointer read**
in `_PyStaticType_InitBuiltin` during `Py_Initialize` (it reads a garbage type-index
`0xf0012b00` and derefs a wild address; unmapped on hardware → SIGSEGV, mapped under
qemu → false pass). **DISPROVEN:** LTO/PGO, LDREXD misalignment (faulting addr is
8-byte aligned but UNMAPPED), gnu2/TLSDESC, and optimization level itself — two
`-O0` r4 builds with **byte-identical `.text`** differing only in data behave
oppositely on the same device. No compiler flag fixes it; the fix is source/upstream
(candidate 3.14.6). **OPEN.** A green Phase 7d does **NOT** prove python works —
**validate `python3 -S -c ''` ON THE DEVICE over ssh**, never on the qemu chroot.

⚠️ **Pipeline pitfall (OPEN):** Phase 7d exports a *running* r4 apk to `output/`
(libpython md5 `d43b6509`) but the Phase 9 rootfs has shipped a *different* r4 build
(md5 `30e88d28`, crashes). The version check (`r4` present) is not enough —
**byte-verify the rootfs libpython md5 against the exported apk.** See
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
| Phase 7d `python3 build exit code: N` (N≠0) or `the python3-3.14.5-r*.apk was not found` | python3 override build failed → rootfs falls back to Alpine's broken r2 | fix `pmos/python3/` (sha512sums / makedepends) + rebuild; do NOT flash a fallback-r2 rootfs |
| python crashes on device (`onboard`/`blueman`/`sleep-inhibitor`/`gdb` SIGSEGV) but Phase 7d was green | CPython 3.14 source-level use-before-init / garbage-pointer read in `Py_Initialize` (qemu FALSE PASS); NOT a compiler/LTO/alignment bug | OPEN (2026-06-28); needs a source/upstream fix (3.14.6?), no `-O`/`-f` flag helps. Validate `python3 -S -c ''` **on device**, not qemu |
| device python crashes but Phase 7d exported a *running* apk | Phase 9 rootfs shipped a **different** r4 build than the verified/exported apk (libpython md5 `30e88d28` vs `d43b6509`); version-only check missed it | OPEN; byte-verify rootfs libpython md5 vs `output/`'s apk; reconcile why two r4 builds exist |
| rc 128, git error | building from a `git worktree` | build from the main repo |

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
