# 2026-08-12 — stock-adb-boot.img deleted then rebuilt; now reproducible

## What happened

During today's device-r69 build, a build subagent pruned `output/` with an
over-broad `rm -f *.img` (instead of the documented exclusion `find`) and deleted
several gitignored images, including **`output/stock-adb-boot.img`** — the
stock-kernel RAM-boot diagnostic used for reverse engineering / stock-parity
reads. `stock-boot.img` was a copy of the surviving
`reverse-eng/factory/tungsten-ian67k/boot.img` (restored trivially); the p9
backups were superseded historical snapshots. `stock-adb-boot.img` was the only
one that needed real reconstruction — done here, and turned into a reproducible
artifact so a future deletion is a non-event.

Guardrails added the same day: the `prune-old-build-images` memory and
`.claude/agents/nexusq-build.md` now forbid a bare `rm *.img` and mandate the
exclusion `find` (never delete `stock-*` / `p9-backup-*` / `private-*`).

## What stock-adb-boot.img is

The Google factory Nexus Q `boot.img` (stock 3.0.8 kernel + stock ramdisk) with
the ramdisk patched for an **insecure root adb** shell. `fastboot boot
output/stock-adb-boot.img` RAM-boots the KNOWN-GOOD stock kernel (non-destructive
— p9 keeps pmOS) and gives `adb shell` as root, for live register / dmesg reads on
stock. Background: `docs/2026-06-24-ethernet-stock-proven-its-our-sw.md`,
`docs/2026-06-22-HANDOVER-ethernet-stockinit.md`.

## How it is rebuilt — `scripts/build-stock-adb-boot.sh`

Fully local inputs (no device needed):

- `reverse-eng/factory/tungsten-ian67k/boot.img` — stock kernel + ramdisk (also
  Google's public factory image for codename tungsten/steelhead).
- `reverse-eng/stock-adb-parts/{busybox-armhf,ld-musl-armhf.so.1}` — the shell +
  its musl loader, pulled once from the running pmOS device (the stock ramdisk has
  no shell and /system is never mounted). Kept locally, gitignored like the
  factory image; `SHA256SUMS` alongside.
- `make-bootimg.py` — the header-v0 repacker (base 0x80000000, kernel@0x8000,
  ramdisk@0x1000000, tags@0x100, page 2048 — matches the factory header).

Mods applied to the extracted stock ramdisk (faithful to the original recipe):

| where | change | why |
|---|---|---|
| `default.prop` | `ro.secure=0`, `ro.adb.secure=0`, `ro.debuggable=1`, `persist.sys.usb.config=adb` | adbd runs as root, no RSA; the `persist.sys.usb.config=*` → `sys.usb.config=adb` property chain configures android_usb + `start adbd` |
| `init.rc` `on fs` | the `mount yaffs2 mtd@system/@userdata/@cache` lines commented out | those partitions hold pmOS now, not stock — don't block/fail on them |
| ramdisk `/system/bin/sh` | busybox (+ ~38 applet symlinks), loader at `/lib/ld-musl-armhf.so.1` | stock ramdisk has no shell and /system is never mounted; `adbd` + `init` are already **static**, so only the shell needs libs |

Baked cmdline = the live stock cmdline captured in
`reverse-eng/stock-eth-working-state-2026-06-24.txt`
(`console=ttyFIQ0 … mem=1G …`).

Rebuild: `scripts/build-stock-adb-boot.sh` → `output/stock-adb-boot.img` (~4.8 MB,
< 8 MB p9). Functionally reproducible (not byte-identical — cpio member order +
gzip are non-deterministic; content is identical).

## Verify (needs hardware)

Enter fastboot (cover the mute sensor at power-on → solid red;
`reboot --reboot-argument=bootloader` does NOT work on stock), then
`fastboot boot output/stock-adb-boot.img` → `adb shell` (root). RAM only;
`adb reboot` returns to pmOS. This on-device check has NOT been run for the rebuilt
image yet — the structure + all ramdisk mods are verified, the boot itself is
pending the next fastboot session.
