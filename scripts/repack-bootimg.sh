#!/bin/sh
# Repack a kernel-only boot.img (zImage + appended DTB, NO ramdisk) for the
# Nexus Q U-Boot, sized to fit the 8 MB p9 boot partition.
#
# Runs INSIDE the nexusq-builder container (needs the pmbootstrap workdir volume
# mounted at /home/pmos/.local/var/pmbootstrap and the repo at /src).
#
# cmdline is the authoritative one read live from the running #2 kernel
# (/proc/cmdline) so the repacked image boots identically minus the ramdisk.
set -e

ROOTFS=/home/pmos/.local/var/pmbootstrap/chroot_rootfs_google-steelhead
VMLINUZ="$ROOTFS/boot/vmlinuz"
DTB="$ROOTFS/boot/dtbs/omap4-steelhead.dtb"
OUT=/tmp/output/boot-ethernet.img
CMDLINE="console=ttyS2,115200 console=tty0 root=/dev/mmcblk0p13 rootwait rw mem=1008M ramoops.mem_address=0xbf000000 ramoops.mem_size=0x100000 ramoops.console_size=0x80000 ramoops.record_size=0x20000 ramoops.dump_oops=1 loglevel=4 panic=30"

echo "vmlinuz: $(stat -c%s "$VMLINUZ") bytes"
echo "DTB:     $(stat -c%s "$DTB") bytes"
echo "kernel.release: $(cat "$ROOTFS/usr/share/kernel/google-steelhead/kernel.release" 2>/dev/null)"

cat "$VMLINUZ" "$DTB" > /tmp/zImage-dtb
echo "zImage+DTB: $(stat -c%s /tmp/zImage-dtb) bytes"

sudo mkdir -p /tmp/output
python3 /src/make-bootimg.py /tmp/zImage-dtb "$OUT" - "$CMDLINE"
echo "cmdline baked: $CMDLINE"
ls -l "$OUT"
sha256sum "$OUT" 2>/dev/null || true
