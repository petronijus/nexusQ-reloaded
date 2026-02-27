#!/bin/bash
set -euo pipefail

ROOTFS="/home/pmos/.local/var/pmbootstrap/chroot_rootfs_google-steelhead"
KERNEL_VER=$(cat "$ROOTFS/usr/share/kernel/google-steelhead/kernel.release")
echo "Kernel version: $KERNEL_VER"

echo ""
echo "=== Updating modules-initfs ==="
sudo cp /src/pmos/device-google-steelhead/modules-initfs "$ROOTFS/usr/share/mkinitfs/files/30-google-steelhead.files"
dos2unix -q "$ROOTFS/usr/share/mkinitfs/files/30-google-steelhead.files" 2>/dev/null || \
    tr -d '\r' < /src/pmos/device-google-steelhead/modules-initfs | sudo tee "$ROOTFS/usr/share/mkinitfs/files/30-google-steelhead.files" > /dev/null
echo "Contents:"
cat "$ROOTFS/usr/share/mkinitfs/files/30-google-steelhead.files"

echo ""
echo "=== Checking available kernel modules ==="
MODDIR="$ROOTFS/lib/modules/$KERNEL_VER"
for mod in omap_hsmmc phy-omap-usb2 phy_omap_usb2 twl6030-usb twl6030_usb \
           ehci-hcd ehci_hcd ehci-platform ehci_platform \
           musb-hdrc musb_hdrc omap2430 \
           smsc95xx usbnet usbcore \
           omapdss omapdrm ti-tpd12s015 display-connector display_connector; do
    found=$(find "$MODDIR" -name "${mod}.ko*" 2>/dev/null | head -1)
    if [ -n "$found" ]; then
        echo "  OK: $mod -> $(basename "$found")"
    fi
done

echo ""
echo "=== Regenerating initramfs ==="
export XDG_CONFIG_HOME=/home/pmos/.config
export XDG_DATA_HOME=/home/pmos/.local/share
export XDG_CACHE_HOME=/home/pmos/.cache
export XDG_RUNTIME_DIR=/run/user/$(id -u)

sudo chroot "$ROOTFS" /bin/sh -c "
    export PATH=/usr/sbin:/usr/bin:/sbin:/bin
    mkinitfs -o /boot/initramfs $KERNEL_VER 2>&1
" || {
    echo "mkinitfs failed, trying manual approach..."
    # If mkinitfs isn't available in the rootfs, try from native chroot
    NATIVE="/home/pmos/.local/var/pmbootstrap/chroot_native"
    if [ -x "$NATIVE/usr/sbin/mkinitfs" ]; then
        echo "Using native chroot mkinitfs..."
        sudo chroot "$NATIVE" /bin/sh -c "
            export PATH=/usr/sbin:/usr/bin:/sbin:/bin
            mkinitfs -o /mnt/rootfs/boot/initramfs \
                -b /mnt/rootfs \
                $KERNEL_VER 2>&1
        "
    else
        echo "ERROR: Cannot find mkinitfs"
        exit 1
    fi
}

echo ""
echo "=== Initramfs size ==="
ls -lh "$ROOTFS/boot/initramfs"
INITRAMFS_SIZE=$(stat -c%s "$ROOTFS/boot/initramfs")
echo "Size: $INITRAMFS_SIZE bytes"

echo ""
echo "=== Rebuilding boot.img with DTB ==="
sudo apk add --no-cache android-tools 2>&1 | tail -1

VMLINUZ="$ROOTFS/boot/vmlinuz"
DTB=$(find "$ROOTFS/boot/dtbs/" -name "omap4-steelhead.dtb" | head -1)
INITRAMFS="$ROOTFS/boot/initramfs"

echo "Kernel: $VMLINUZ ($(stat -c%s "$VMLINUZ") bytes)"
echo "DTB: $DTB ($(stat -c%s "$DTB") bytes)"
echo "Initramfs: $INITRAMFS ($INITRAMFS_SIZE bytes)"

cat "$VMLINUZ" "$DTB" > /tmp/zImage-dtb
echo "zImage-dtb: $(stat -c%s /tmp/zImage-dtb) bytes"

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
