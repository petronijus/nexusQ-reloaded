#!/bin/sh
set -e

ROOTFS=/home/pmos/.local/var/pmbootstrap/chroot_rootfs_google-steelhead
VMLINUZ=$ROOTFS/boot/vmlinuz
DTB=$ROOTFS/boot/dtbs/omap4-steelhead.dtb

echo "vmlinuz: $(stat -c%s "$VMLINUZ") bytes"
echo "DTB: $(stat -c%s "$DTB") bytes"

cat "$VMLINUZ" "$DTB" > /tmp/zImage-dtb
echo "zImage+DTB: $(stat -c%s /tmp/zImage-dtb) bytes"

# Tiny ramdisk (mkbootimg requires one)
mkdir -p /tmp/empty-rd
cd /tmp/empty-rd
echo "x" > x
find . | cpio -o -H newc 2>/dev/null | gzip -9 > /tmp/empty.gz
echo "Empty ramdisk: $(stat -c%s /tmp/empty.gz) bytes"

sudo apk add --no-cache android-tools 2>&1 | tail -1

# console=tty0 routes kernel messages to framebuffer
mkbootimg \
    --kernel /tmp/zImage-dtb \
    --ramdisk /tmp/empty.gz \
    --base 0x80000000 \
    --kernel_offset 0x00008000 \
    --ramdisk_offset 0x01000000 \
    --second_offset 0x00f00000 \
    --tags_offset 0x00000100 \
    --pagesize 2048 \
    --cmdline "console=tty0 loglevel=7 ignore_loglevel earlyprintk panic=30" \
    -o /tmp/output/boot-noramdisk.img

ls -lh /tmp/output/boot-noramdisk.img
echo "DONE"
