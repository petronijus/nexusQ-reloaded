#!/bin/bash
set -euo pipefail

ROOTFS="/home/pmos/.local/var/pmbootstrap/chroot_rootfs_google-steelhead"
KERNEL_VER=$(cat "$ROOTFS/usr/share/kernel/google-steelhead/kernel.release")
MODDIR="$ROOTFS/lib/modules/$KERNEL_VER"
echo "Kernel version: $KERNEL_VER"

echo ""
echo "=== Extracting current initramfs ==="
WORK="/tmp/initramfs-work"
mkdir -p "$WORK"
cd "$WORK"
zcat "$ROOTFS/boot/initramfs" | cpio -idm 2>/dev/null
echo "Extracted. Module count before: $(find . -name '*.ko*' | wc -l)"
find . -name '*.ko*' | sort

echo ""
echo "=== Adding missing USB and display modules ==="
MODULES_TO_ADD="
    phy-omap-usb2
    ehci-hcd
    musb_hdrc
    omap2430
    smsc95xx
    usbnet
    usbcore
    usb-common
    omapdrm
    omapdss
    ti-tpd12s015
    display-connector
    drm
    drm_kms_helper
    mii
    crc32c_generic
    libcrc32c
"

INITFS_MODDIR="$WORK/lib/modules/$KERNEL_VER"
mkdir -p "$INITFS_MODDIR"

for mod in $MODULES_TO_ADD; do
    modname=$(echo "$mod" | tr '-' '_')
    modname2=$(echo "$mod" | tr '_' '-')
    kofile=$(find "$MODDIR" \( -name "${modname}.ko" -o -name "${modname}.ko.gz" -o -name "${modname}.ko.xz" \
                             -o -name "${modname2}.ko" -o -name "${modname2}.ko.gz" -o -name "${modname2}.ko.xz" \) \
             2>/dev/null | head -1)
    if [ -n "$kofile" ]; then
        relpath="${kofile#$MODDIR/}"
        mkdir -p "$INITFS_MODDIR/$(dirname "$relpath")"
        cp "$kofile" "$INITFS_MODDIR/$relpath"
        echo "  Added: $relpath"
    else
        echo "  SKIP: $mod (not found in kernel modules)"
    fi
done

echo ""
echo "=== Generating modules.dep ==="
# Create a simple modules.dep so modprobe works
depmod -b "$WORK" -a "$KERNEL_VER" 2>/dev/null || {
    echo "  depmod not available, creating minimal modules.dep..."
    find "$INITFS_MODDIR" -name '*.ko*' | sed "s|$INITFS_MODDIR/||" | while read mod; do
        echo "$mod:"
    done > "$INITFS_MODDIR/modules.dep"
}
echo "Module count after: $(find "$INITFS_MODDIR" -name '*.ko*' | wc -l)"

echo ""
echo "=== Repacking initramfs ==="
cd "$WORK"
find . | cpio -o -H newc 2>/dev/null | gzip -9 > /tmp/initramfs-new
echo "New initramfs: $(stat -c%s /tmp/initramfs-new) bytes ($(( $(stat -c%s /tmp/initramfs-new) / 1024 )) KB)"
echo "Old initramfs: $(stat -c%s "$ROOTFS/boot/initramfs") bytes"

echo ""
echo "=== Rebuilding boot.img ==="
sudo apk add --no-cache android-tools 2>&1 | tail -1

VMLINUZ="$ROOTFS/boot/vmlinuz"
DTB=$(find "$ROOTFS/boot/dtbs/" -name "omap4-steelhead.dtb" | head -1)

cat "$VMLINUZ" "$DTB" > /tmp/zImage-dtb
echo "zImage-dtb: $(stat -c%s /tmp/zImage-dtb) bytes"

sudo mkdir -p /tmp/output
sudo chown pmos:pmos /tmp/output

mkbootimg \
    --kernel /tmp/zImage-dtb \
    --ramdisk /tmp/initramfs-new \
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
