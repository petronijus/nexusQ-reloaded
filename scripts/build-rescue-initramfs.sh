#!/usr/bin/env bash
# Build the RAM-only rescue environment: kernel + an initramfs carrying the
# filesystem and partition tools, with the rootfs deliberately left unmounted.
#
# Boot it with `nq-kernel-ota rescue <img>` on the device -- that writes it to the
# trial slot and selects it through the SAR reboot reason, so it needs no cable
# and no fastboot. `reboot -f` from inside returns to the normal system.
#
# Reach the shell with `nc 172.16.42.1 23`, NOT the telnet client: telnet drops
# piped stdin immediately. Keep stdin open a few seconds past the last command.
set -euo pipefail
cd "$(dirname "$0")/.."
. scripts/nq-initramfs-lib.sh

DEV="${NQ_DEV:-root@172.16.42.1}"
OUT="${NQ_OUT:-output/rescue}"
mkdir -p "$OUT"

STAGE=$(mktemp -d); trap 'rm -rf "$STAGE"' EXIT
mkdir -p "$STAGE/lib"
cp scripts/initramfs/nq-gadget.sh "$STAGE/lib/"

# Only what the job needs. mke2fs/tune2fs/dumpe2fs/parted are deliberately absent:
# every byte here is a byte that has to survive the USB transfer, and shrinking a
# filesystem and rewriting a partition table needs exactly these three.
nq_build_cpio "$DEV" scripts/initramfs/init-rescue "$STAGE" "$OUT/rescue-initramfs.cpio.gz" \
    /usr/sbin/e2fsck /usr/sbin/resize2fs /usr/sbin/sfdisk /usr/sbin/blockdev /usr/sbin/partx

nq_pack_bootimg "$DEV" "$OUT/rescue-initramfs.cpio.gz" "$OUT/rescue-boot.img"

cat <<MSG

Built $OUT/rescue-boot.img
  scp it to the device, then:  nq-kernel-ota rescue /tmp/rescue-boot.img
  once it is up:               nc 172.16.42.1 23   (then run 'stay')
MSG
