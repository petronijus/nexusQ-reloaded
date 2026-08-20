#!/usr/bin/env bash
# Build the A/B boot image: the running kernel plus an initramfs whose only job
# is to read the slot marker from p7 "misc" and switch_root into p13 or p14.
#
# This is what makes a rootfs OTA possible on this device. The kernel is built
# with CONFIG_CMDLINE_FORCE and a hardcoded root=/dev/mmcblk0p13, so the rootfs
# can never be chosen on the command line; an initramfs is the only place the
# choice can be made. One image serves both slots -- switching is a 512-byte
# write, and a slot that fails to boot costs exactly one reboot because the
# initramfs clears the trial BEFORE handing that rootfs control.
#
# Test it the same way as the rescue image -- stage it in the trial slot and boot
# it from there -- before it ever goes near slot A. A failed initramfs is not
# fatal on this device: the kernel falls through to its forced root=p13 and the
# normal system comes up, which is exactly how the ramdisk-address bug hid.
set -euo pipefail
cd "$(dirname "$0")/.."
. scripts/nq-initramfs-lib.sh

DEV="${NQ_DEV:-root@172.16.42.1}"
OUT="${NQ_OUT:-output/ab}"
mkdir -p "$OUT"

STAGE=$(mktemp -d); trap 'rm -rf "$STAGE"' EXIT
mkdir -p "$STAGE/lib" "$STAGE/bin"
cp scripts/initramfs/nq-gadget.sh   "$STAGE/lib/"
cp userspace/nexusq-rootfs-ab/nq-slot "$STAGE/bin/"
chmod +x "$STAGE/bin/nq-slot"

# No extra device binaries: everything this image does -- read a 512-byte record,
# mount ext4, switch_root -- is a busybox applet. Keeping it to busybox is what
# leaves room for the kernel in an 8 MiB slot.
nq_build_cpio "$DEV" scripts/initramfs/init-ab "$STAGE" "$OUT/ab-initramfs.cpio.gz"

nq_pack_bootimg "$DEV" "$OUT/ab-initramfs.cpio.gz" "$OUT/ab-boot.img"

cat <<MSG

Built $OUT/ab-boot.img
  try it WITHOUT committing:  nq-kernel-ota rescue /tmp/ab-boot.img
    (that stages it in the trial slot and boots it once; it is not a rescue
     image, but the mechanism is the same and it never arms a pending promote)
  once proven, it becomes the image written to slot A.
MSG
