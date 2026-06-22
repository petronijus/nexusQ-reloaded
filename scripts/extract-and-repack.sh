#!/bin/bash
# Extract the freshly-compiled kernel (vmlinuz + DTB) straight from the
# linux-google-steelhead BUILD chroot pkgdir and repack a kernel-only boot.img
# (zImage + appended DTB, no ramdisk) sized for the Nexus Q p9 boot partition.
#
# Why pkgdir and not the rootfs chroot: the pkgdir holds exactly what abuild
# packages -- `make zinstall modules_install dtbs_install` ran into it -- so
# these artifacts are byte-identical to the .apk contents but available without
# waiting for `pmbootstrap install`.
#
# HISTORICAL NOTE (fixed 2026-06-22): abuild's final create_apks step used to
# fail with "can't create /home/pmos/packages//pmos/armv7/...apk: Permission
# denied", so `pmbootstrap install` never ran and chroot_rootfs had no kernel --
# this script was the only way out. Root cause: $WORK/packages on the reused
# nexusq-workdir volume was owned by the container pmos (uid 1000), but abuild
# inside the chroot runs as uid 12345, so it could not write its .apk. Fixed in
# docker-build.sh "Phase 7a" (chown $WORK/packages -> 12345 before the build).
# Builds now produce linux-google-steelhead-*.apk cleanly and `pmbootstrap
# install` runs. This script is KEPT as a still-useful fast path: it skips the
# rootfs build entirely and repacks a kernel-only boot.img straight from the
# pkgdir, which is much quicker when you only changed the kernel/DTB.
#
# Runs INSIDE the nexusq-builder container via the entrypoint:
#   docker run --rm \
#     -v nexusq-workdir:/home/pmos/.local/var/pmbootstrap \
#     -v "<repo>:/src:ro" -v "<repo>/output:/out" \
#     nexusq-builder /src/scripts/extract-and-repack.sh
set -e

PK=/home/pmos/.local/var/pmbootstrap/chroot_buildroot_armv7/home/pmos/build/pkg/linux-google-steelhead
VM="$PK/boot/vmlinuz"
DTB="$PK/boot/dtbs/omap4-steelhead.dtb"
OUT_IMG=/out/boot-ethernet-b7.img

# Authoritative cmdline, read live from the running #2 kernel's /proc/cmdline
# (the repacked image must boot identically minus the ramdisk).
CMDLINE="console=ttyS2,115200 console=tty0 root=/dev/mmcblk0p13 rootwait rw mem=1008M ramoops.mem_address=0xbf000000 ramoops.mem_size=0x100000 ramoops.console_size=0x80000 ramoops.record_size=0x20000 ramoops.dump_oops=1 earlyprintk loglevel=7 ignore_loglevel panic=30"

[ -f "$VM" ]  || { echo "missing vmlinuz at $VM"; exit 1; }
[ -f "$DTB" ] || { echo "missing dtb at $DTB"; exit 1; }

echo "=== B2 sanity: CPU nodes in the built DTB (expect only cpu@0) ==="
dtc -I dtb -O dts "$DTB" 2>/dev/null | grep -nE "cpu@[0-9]" || echo "  (no cpu@ match)"

echo "=== sizes ==="
echo "  vmlinuz: $(stat -c%s "$VM") bytes   dtb: $(stat -c%s "$DTB") bytes"

echo "=== repack boot.img (zImage + appended DTB, no ramdisk) ==="
cat "$VM" "$DTB" > /tmp/zImage-dtb
echo "  zImage+DTB: $(stat -c%s /tmp/zImage-dtb) bytes"
python3 /src/make-bootimg.py /tmp/zImage-dtb "$OUT_IMG" - "$CMDLINE"

cp "$VM"  /out/vmlinuz-4
cp "$DTB" /out/omap4-steelhead-4.dtb

echo "=== output ==="
ls -lh "$OUT_IMG" /out/vmlinuz-4 /out/omap4-steelhead-4.dtb
echo "cmdline baked: $CMDLINE"
sha256sum "$OUT_IMG"
