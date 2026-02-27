#!/bin/bash
set -euo pipefail

ROOTFS="/home/pmos/.local/var/pmbootstrap/chroot_rootfs_google-steelhead"
KERNEL_VER=$(cat "$ROOTFS/usr/share/kernel/google-steelhead/kernel.release")
echo "Kernel version: $KERNEL_VER"

echo ""
echo "=== Updating modules-initfs ==="
dos2unix -q /dev/stdin < /src/pmos/device-google-steelhead/modules-initfs | \
    sudo tee "$ROOTFS/usr/share/mkinitfs/files/30-google-steelhead.files" > /dev/null
echo "Updated."

echo ""
echo "=== Register QEMU binfmt for ARM ==="
sudo apk add --no-cache qemu-arm 2>&1 | tail -1
if [ ! -f /proc/sys/fs/binfmt_misc/qemu-arm ]; then
    echo "Registering qemu-arm binfmt..."
    sudo sh -c 'echo ":qemu-arm:M:0:\\x7fELF\\x01\\x01\\x01\\x00\\x00\\x00\\x00\\x00\\x00\\x00\\x00\\x00\\x02\\x00\\x28\\x00:\\xff\\xff\\xff\\xff\\xff\\xff\\xff\\x00\\x00\\x00\\x00\\x00\\x00\\x00\\x00\\x00\\xfe\\xff\\xff\\xff:/usr/bin/qemu-arm:OCF" > /proc/sys/fs/binfmt_misc/register' 2>/dev/null || true
fi
# Copy qemu-arm into rootfs for chroot to work
sudo cp /usr/bin/qemu-arm "$ROOTFS/usr/bin/qemu-arm" 2>/dev/null || true
echo "Done."

echo ""
echo "=== Regenerating initramfs ==="
sudo chroot "$ROOTFS" /bin/sh -c "
    export PATH=/usr/sbin:/usr/bin:/sbin:/bin
    echo 'Running mkinitfs...'
    mkinitfs -o /boot/initramfs $KERNEL_VER
    echo 'mkinitfs complete'
" 2>&1

echo ""
echo "=== New initramfs ==="
ls -lh "$ROOTFS/boot/initramfs"

echo ""
echo "=== Verify modules in initramfs ==="
# List modules in the new initramfs
zcat "$ROOTFS/boot/initramfs" | cpio -t 2>/dev/null | grep '\.ko' | head -30 || \
    echo "(could not list initramfs contents)"

echo ""
echo "=== Rebuilding boot.img with DTB ==="
sudo apk add --no-cache android-tools 2>&1 | tail -1

VMLINUZ="$ROOTFS/boot/vmlinuz"
DTB=$(find "$ROOTFS/boot/dtbs/" -name "omap4-steelhead.dtb" | head -1)
INITRAMFS="$ROOTFS/boot/initramfs"

cat "$VMLINUZ" "$DTB" > /tmp/zImage-dtb
echo "zImage-dtb: $(stat -c%s /tmp/zImage-dtb) bytes"
echo "Initramfs: $(stat -c%s "$INITRAMFS") bytes"

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
