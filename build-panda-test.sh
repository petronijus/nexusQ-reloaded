#!/bin/bash
set -e

ROOTFS=/home/pmos/.local/var/pmbootstrap/chroot_rootfs_google-steelhead
VMLINUZ=$ROOTFS/boot/vmlinuz

echo "=== Looking for DTBs ==="
find /home/pmos/.local/var/pmbootstrap/ -name "*.dtb" 2>/dev/null | head -30

PANDA_DTB=$ROOTFS/boot/dtbs/omap4-panda-es.dtb
echo "PandaBoard DTB: $PANDA_DTB ($(stat -c%s "$PANDA_DTB") bytes)"

echo ""
echo "=== Building test image with PandaBoard DTB ==="
cat "$VMLINUZ" "$PANDA_DTB" > /tmp/zImage-panda-dtb
echo "zImage+PandaDTB: $(stat -c%s /tmp/zImage-panda-dtb) bytes"

mkdir -p /tmp/empty-rd
cd /tmp/empty-rd
echo "x" > x
find . | cpio -o -H newc 2>/dev/null | gzip -9 > /tmp/empty.gz

sudo apk add --no-cache android-tools 2>&1 | tail -1

mkbootimg \
    --kernel /tmp/zImage-panda-dtb \
    --ramdisk /tmp/empty.gz \
    --base 0x80000000 \
    --kernel_offset 0x00008000 \
    --ramdisk_offset 0x01000000 \
    --second_offset 0x00f00000 \
    --tags_offset 0x00000100 \
    --pagesize 2048 \
    --cmdline "console=tty0 console=ttyO2,115200 loglevel=7 ignore_loglevel earlyprintk panic=10" \
    -o /tmp/output/boot-panda-test.img

ls -lh /tmp/output/boot-panda-test.img
echo "DONE"
