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

Delegate the whole build to the **`nexusq-build` subagent** so the build and its
noisy output stay out of the main context. Since 2026-08-31 everything
cross-compiles (kernel via `pmb:cross-native`, userspace via `cross-native2`), so a
**warm full build is 399 s (6 min 39 s)** where it used to be 68 min; a cold build
has not been re-timed since. Invoke it with the
Agent tool (`subagent_type: "nexusq-build"`), passing any specifics the user gave
(target version, whether to do a cold rebuild / wipe the `nexusq-workdir` volume,
whether to also extract+sparse-convert the artifacts).

⚠️ **Kernel/DTS gotcha (2026-07-12):** editing `kernel/dts/omap4-steelhead.dts`
alone is a **silent no-op** — the DTS enters the kernel tree via
`kernel/patches/` (0003 + follow-ups), which is what the build stages. Any DTS
change must become a patch (+ pkgrel bump) and the built DTB must be verified to
contain it. On a Windows host, launch docker via **PowerShell** (MSYS/Git-Bash
mangles `/src`) and keep files **LF** (CRLF breaks sed-parsed APKBUILD vars —
since 2026-07-13 the repo enforces LF itself via `.gitattributes`, commit
`cb03cf7`; a fresh checkout is safe without machine config).

⚠️ **Firmware-overlay gotcha (2026-07-12):** on any new/other build machine the
gitignored `./firmware/` overlay must be populated
(`cp private/firmware/bcm4330.hcd private/firmware/bcmdhd.cal firmware/`) or the
build silently packs the **empty `firmware-google-steelhead` fallback** → the
image boots with **no wlan0 / no BT** (bit the first v1.8.1 flash). Gate: build
log says `Staged BCM4330 firmware` + rootfs `/lib/firmware/brcm/` is complete.

The agent owns: the correct `docker run` invocation (never `./docker-build.sh` on
the host, never sudo, never from a git worktree), live monitoring **including
mandatory progress reports to the main conversation (SendMessage to "main": every
phase transition + a ~10-min heartbeat inside long phases + immediate
retry/failure notices — the user must never have to ask "is it stuck?")**, the
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

**python3: the local override is RETIRED (2026-08-17) — the rootfs ships Alpine's stock
`python3 3.14.7-r0`, and that is correct.** There is no `pmos/python3`, no Phase 7d and
no `PYTHON3_VALIDATE_RUNS`; do not report their absence as a defect. Why it existed: the
on-device `Py_Initialize` SIGSEGV, which was a **FLASH bug, not a build/compiler/CPython
bug** (✅ root-caused 2026-06-28, hardware-verified) — the old `DONT_CARE`-chunked
`raw2simg.py` left stale eMMC bytes in libpython's should-be-zero regions on re-flash,
fixed by the **all-RAW (byte-exact) `raw2simg.py`**. (A qemu-user build-corruption theory
+ a gold-linker workaround were investigated and **DROPPED as unnecessary**.) Why it went:
Alpine moved to python3 3.14.7 and **apk compares `pkgver` before `pkgrel`**, so our
`3.14.5-r5` stopped winning — the build still built, gated and exported it while the
rootfs installed the stock binary anyway, and a safety net that silently stops being
installed is worse than none. What remains is the **Phase 10 SHIP GATE**, which gates the
libpython actually present in the rootfs whatever its provenance, prints which python3 the
rootfs contains, and fails hard when there is none. ⚠️ Never re-introduce `DONT_CARE` in
`raw2simg.py`: the Nexus Q's non-erasing U-Boot would re-corrupt a clean image on-device.
See `docs/2026-06-28-session-findings.md` and CHANGELOG (2026-08-17, "Removed — the
python3 override, which had quietly stopped being installed").

⚠️ **After the build, a release is TWO publishes — and one command does both
(2026-08-30).** `scripts/package-release.sh v<X.Y.Z>` writes the release assets,
**publishes the OTA apk repo itself**, and then gates on the two agreeing
(`scripts/verify-ota-parity.sh`: every package in `pmos/ota-packages.list` at the same
version in the released rootfs and the published index, and the key baked in the image
being the key that signed the index). `--no-ota` skips the publish; **nothing skips the
gate.** Never hand back "now run `publish-ota-repo.sh`" as a separate step: when the two
were separate, v1.14.2 shipped device r89 as an image while the fleet kept getting r87.
⚠️ And **build/publish on the machine that holds the fleet key** `pmos@local-6a42e957`
(recorded as `pmos/ota-signing-key.rsa.pub`, private half in 1Password) — an image or an
index signed with any other key means `UNTRUSTED signature` and no OTA at all. See
`docs/2026-08-30-release-reaches-nobody-and-the-flag-the-gadget-had.md` and HANDOFF
"WHICH MACHINE BUILDS WHAT". ⚠️ And on a machine that got the fleet key after it had
already built packages, run **`scripts/seed-ota-volume.sh`** once before the first OTA
publish — the publisher takes the newest apk of each package from the volume, and
foreign-signed leftovers would fail `apk upgrade` on every box (2026-09-05;
`publish-ota-repo.sh` now refuses such apks by name).
