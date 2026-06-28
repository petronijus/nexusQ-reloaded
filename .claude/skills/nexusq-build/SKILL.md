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

The build now also stages + builds a local **`python3` override** (Phase 6/7d, now
r4) to dodge Alpine's broken armv7 python3-3.14.5-r2. ⚠️ As of 2026-06-28 that
override is NOT confirmed working and the bug is **OPEN**: narrowed to a **CPython
3.14 source-level use-before-init / garbage-pointer read** in `Py_Initialize` (NOT
LTO/PGO, NOT LDREXD alignment, NOT a compiler/`-O` bug — all disproven), which
**qemu does not reproduce (false pass)**. So a green build does not prove python
works — validate `python3 -S -c ''` **on the device**. Also beware the pipeline can
ship a *different* r4 than the exported apk (md5 `30e88d28` vs `d43b6509`) — verify
by libpython md5, not just version. See `docs/2026-06-28-session-findings.md`.
