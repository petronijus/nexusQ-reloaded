#!/bin/bash
set -euo pipefail

ROOTFS="/home/pmos/.local/var/pmbootstrap/chroot_rootfs_google-steelhead"

echo "=== Finding DTB ==="
find "$ROOTFS/boot/dtbs/" -name "*steelhead*" 2>/dev/null || true
DTB=$(find "$ROOTFS/boot/dtbs/" -name "omap4-steelhead.dtb" 2>/dev/null | head -1)
echo "DTB: $DTB"
if [ -z "$DTB" ]; then echo "ERROR: DTB not found!"; exit 1; fi
echo "DTB size: $(stat -c%s "$DTB") bytes"

echo ""
echo "=== Finding kernel ==="
ls -la "$ROOTFS/boot/" || true
VMLINUZ=$(find "$ROOTFS/boot/" -maxdepth 1 \( -name "vmlinuz*" -o -name "zImage*" \) 2>/dev/null | head -1)
echo "Kernel: $VMLINUZ"
if [ -z "$VMLINUZ" ]; then echo "ERROR: Kernel not found!"; exit 1; fi
echo "Kernel size: $(stat -c%s "$VMLINUZ") bytes"

echo ""
echo "=== Creating zImage-dtb ==="
cat "$VMLINUZ" "$DTB" > /tmp/zImage-dtb
echo "zImage-dtb size: $(stat -c%s /tmp/zImage-dtb) bytes"

echo ""
echo "=== Finding initramfs ==="
INITRAMFS=$(find "$ROOTFS/boot/" -maxdepth 1 -name "initramfs*" 2>/dev/null | head -1)
echo "Initramfs: $INITRAMFS"
echo "Initramfs size: $(stat -c%s "$INITRAMFS") bytes"

echo ""
echo "=== Installing mkbootimg ==="
sudo apk add --no-cache android-tools 2>&1 | tail -3

echo ""
echo "=== Rebuilding boot.img ==="
sudo mkdir -p /tmp/output
sudo chown pmos:pmos /tmp/output

mkbootimg \
    --kernel /tmp/zImage-dtb \
    --ramdisk "$INITRAMFS" \
    --base 0x80000000 \
    --kernel_offset 0x00008000 \
    --ramdisk_offset 0x01000000 \
    --second_offset 0x00f00000 \
    --tags_offset 0x00000100 \
    --pagesize 2048 \
    --cmdline "console=ttyS2,115200n8 mem=1G" \
    -o /tmp/output/boot.img

echo ""
echo "=== Result ==="
ls -lh /tmp/output/boot.img
echo "Done!"
