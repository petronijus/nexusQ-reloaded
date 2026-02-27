#!/bin/bash
set -euo pipefail

ROOTFS="/home/pmos/.local/var/pmbootstrap/chroot_rootfs_google-steelhead"
KERNEL_VER=$(cat "$ROOTFS/usr/share/kernel/google-steelhead/kernel.release")
MODDIR="$ROOTFS/lib/modules/$KERNEL_VER"
echo "Kernel version: $KERNEL_VER"

echo ""
echo "=== Extracting original initramfs ==="
WORK="/tmp/initramfs-fixed"
rm -rf "$WORK"
mkdir -p "$WORK"
cd "$WORK"
zcat "$ROOTFS/boot/initramfs" | cpio -idm 2>/dev/null

# Find the actual module directory in the initramfs
INITFS_MODDIR=$(find "$WORK" -type d -name "$KERNEL_VER" | head -1)
echo "Initramfs module dir: $INITFS_MODDIR"

echo ""
echo "=== Current modules in initramfs ==="
find "$INITFS_MODDIR" -name '*.ko' | sort | while read f; do
    echo "  $(basename "$f")"
done

echo ""
echo "=== Adding missing USB controller modules ==="
MODULES_TO_ADD="
    drivers/phy/ti/phy-omap-usb2.ko
    drivers/usb/host/ehci-hcd.ko
    drivers/usb/musb/musb_hdrc.ko
    drivers/usb/musb/omap2430.ko
    drivers/gpu/drm/bridge/display-connector.ko
"

for relpath in $MODULES_TO_ADD; do
    src="$MODDIR/kernel/$relpath"
    if [ -f "$src" ]; then
        dest="$INITFS_MODDIR/kernel/$relpath"
        mkdir -p "$(dirname "$dest")"
        cp "$src" "$dest"
        echo "  Added: $relpath"
    else
        echo "  SKIP: $relpath (not in kernel build)"
    fi
done

echo ""
echo "=== Updating initramfs.load ==="
LOAD_FILE=$(find "$WORK" -name 'initramfs.load' | head -1)
echo "Load file: $LOAD_FILE"
echo "Before:"
cat "$LOAD_FILE"

dos2unix -q /dev/stdin < /src/pmos/device-google-steelhead/modules-initfs > "$LOAD_FILE"
echo ""
echo "After:"
cat "$LOAD_FILE"

echo ""
echo "=== Regenerating modules.dep ==="
# depmod needs the correct base path
# The initramfs has modules at /usr/lib/modules/KVER
# depmod -b expects to find lib/modules/KVER under the base
DEPMOD_BASE="$WORK/usr"
depmod -b "$DEPMOD_BASE" -a "$KERNEL_VER" 2>&1 || {
    echo "depmod failed, generating minimal deps..."
}
echo "modules.dep entries: $(wc -l < "$INITFS_MODDIR/modules.dep")"
echo ""
echo "Key deps:"
grep -E 'omap2430|musb_hdrc|ehci-hcd|phy-omap-usb2' "$INITFS_MODDIR/modules.dep"

echo ""
echo "=== All modules now ==="
find "$INITFS_MODDIR" -name '*.ko' | sort | while read f; do
    echo "  $(basename "$f")"
done
echo "Total: $(find "$INITFS_MODDIR" -name '*.ko' | wc -l) modules"

echo ""
echo "=== Repacking initramfs ==="
cd "$WORK"
find . | cpio -o -H newc 2>/dev/null | gzip -9 > /tmp/initramfs-fixed.gz
NEWSIZE=$(stat -c%s /tmp/initramfs-fixed.gz)
OLDSIZE=$(stat -c%s "$ROOTFS/boot/initramfs")
echo "Old: $OLDSIZE bytes ($(( OLDSIZE / 1024 )) KB)"
echo "New: $NEWSIZE bytes ($(( NEWSIZE / 1024 )) KB)"

echo ""
echo "=== Rebuilding boot.img ==="
sudo apk add --no-cache android-tools 2>&1 | tail -1

VMLINUZ="$ROOTFS/boot/vmlinuz"
DTB=$(find "$ROOTFS/boot/dtbs/" -name "omap4-steelhead.dtb" | head -1)

cat "$VMLINUZ" "$DTB" > /tmp/zImage-dtb
echo "zImage-dtb: $(stat -c%s /tmp/zImage-dtb) bytes"
echo "Initramfs: $NEWSIZE bytes"

sudo mkdir -p /tmp/output
sudo chown pmos:pmos /tmp/output

mkbootimg \
    --kernel /tmp/zImage-dtb \
    --ramdisk /tmp/initramfs-fixed.gz \
    --base 0x80000000 \
    --kernel_offset 0x00008000 \
    --ramdisk_offset 0x01000000 \
    --second_offset 0x00f00000 \
    --tags_offset 0x00000100 \
    --pagesize 2048 \
    --cmdline "console=ttyS2,115200n8 mem=1G" \
    -o /tmp/output/boot.img

echo ""
echo "=== Verify boot.img ==="
ls -lh /tmp/output/boot.img
python3 -c "
import struct, math
with open('/tmp/output/boot.img', 'rb') as f:
    magic = f.read(8)
    ks = struct.unpack('<I', f.read(4))[0]
    f.read(4)
    rs = struct.unpack('<I', f.read(4))[0]
    print(f'Kernel: {ks} bytes, Ramdisk: {rs} bytes')
"
echo "Done!"
