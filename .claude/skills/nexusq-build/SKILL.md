---
name: nexusq-build
description: >-
  Build the Google Nexus Q (steelhead) postmarketOS image — kernel boot.img and
  the full rootfs — via the dockerized pmbootstrap pipeline, with monitoring,
  auto-fix of the known build-infra failures, and a mandatory rootfs verification
  gate (systemd init / nexusqd / sshd / ramdisk-less boot.img) before success.
  Use when asked to rebuild the image, build a new version, or produce a fresh
  rootfs. Trigger phrases: "build nexus", "rebuild the image", "build v1.x",
  "make a new rootfs", "nexusq build".
---

# /nexusq-build

Delegate the whole build to the **`nexusq-build` subagent** so the long (~35–50 min
cold, ~8 min warm) build and its noisy output stay out of the main context. Invoke it with the
Agent tool (`subagent_type: "nexusq-build"`), passing any specifics the user gave
(target version, whether to do a cold rebuild / wipe the `nexusq-workdir` volume,
whether to also extract+sparse-convert the artifacts).

The agent owns: the correct `docker run` invocation (never `./docker-build.sh` on
the host, never sudo, never from a git worktree), live monitoring, the
known-failure catalog with fixes (channel mismatch → volume wipe, oversized
boot.img → ramdisk-less repack, /usr/local, uid drift, SIGPIPE, …), and the
**mandatory verification gate** — it mounts the produced rootfs and proves init =
systemd, `nexusqd` + `sshd` present, device units enabled, boot.img ramdisk-less
≤ 8 MB — before reporting success.

It returns artifact paths + a pass/fail verification table + the exact flash
commands. It does **not** flash (that is a separate device-in-fastboot step). When
it reports back, relay the verification result and the flash commands to the user;
flash only on explicit go-ahead, and follow the
[[always-preserve-working-image]] rule — snapshot any image that boots.

The build also stages + builds a local **`python3` override** (Phase 6/7d, now **r5**,
**default linker / bfd**) — a plain rebuild whose higher pkgrel supersedes Alpine's
broken armv7 python3-3.14.5-r2. ✅ **FIXED 2026-06-28 (hardware-verified).** The
on-device `Py_Initialize` SIGSEGV was a **FLASH bug, not a build/compiler/CPython bug**:
the old `DONT_CARE`-chunked `raw2simg.py` left stale eMMC bytes in libpython's
should-be-zero regions on re-flash — fixed by the **all-RAW (byte-exact) `raw2simg.py`**.
(A qemu-user build-corruption theory + a gold-linker workaround were investigated and
**DROPPED as unnecessary** — 6/6 default-linker builds were gate-clean, one ran rc 0 on
device.) Kept as a **safety net** (not "the gold fix"): Phase 7d gates every build with
`scripts/verify-libpython-clean.py` (rebuild-on-corruption) and Phase 10 re-gates the
installed rootfs libpython (ship gate), with pkgrel-exact apk selection — so a corrupt
python can't reach a flashable image. The agent's verification gate confirms the rootfs
ships the gate-clean r5. qemu's own `python3 -S -c ''` build check is still a false pass;
trust the integrity gate (build-side) and `python3 -S -c ''` **on device**. ⚠️ A clean
build is **necessary but not sufficient** — the FLASH must also be byte-exact: never
re-introduce `DONT_CARE` in `raw2simg.py`, or the Nexus Q's non-erasing U-Boot leaves
stale eMMC bytes in libpython and re-corrupts the (clean) image on-device. Shipped in
**v1.6.0** (python works from a clean flash). See
`docs/2026-06-28-session-findings.md`.
