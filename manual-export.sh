#!/bin/bash
set -euo pipefail

ROOTFS="/home/pmos/.local/var/pmbootstrap/chroot_rootfs_google-steelhead"
KVER=$(cat "$ROOTFS/usr/share/kernel/google-steelhead/kernel.release")
VMLINUZ="$ROOTFS/boot/vmlinuz"
DTB="$ROOTFS/boot/dtbs/omap4-steelhead.dtb"

echo "=== Manual image export ==="
echo "Kernel: $KVER"
echo "vmlinuz: $(stat -c%s "$VMLINUZ") bytes"
echo "DTB: $(stat -c%s "$DTB") bytes"

echo ""
echo "=== Step 1: Run mkinitfs manually ==="
MODDIR="$ROOTFS/lib/modules/$KVER"
echo "Module dir: $MODDIR"
ls "$MODDIR" 2>/dev/null | head -5

# Read modules-initfs from deviceinfo package
MODULES_FILE="$ROOTFS/usr/share/mkinitfs/modules/00-device-google-steelhead.modules"
if [ -f "$MODULES_FILE" ]; then
    echo "Modules file: $MODULES_FILE"
    cat "$MODULES_FILE"
else
    echo "No modules file found (expected with built-in drivers)"
fi

# Try running mkinitfs in the chroot
echo ""
echo "Attempting mkinitfs in chroot..."
# Fix deviceinfo DTB path in chroot
CHROOT_DEVICEINFO="$ROOTFS/etc/deviceinfo"
if [ -f "$CHROOT_DEVICEINFO" ]; then
    echo "Current DTB in chroot deviceinfo:"
    grep dtb "$CHROOT_DEVICEINFO" || true
    sed -i 's|deviceinfo_dtb="ti/omap/omap4-steelhead"|deviceinfo_dtb="omap4-steelhead"|' "$CHROOT_DEVICEINFO"
    echo "Fixed DTB path in chroot deviceinfo"
    grep dtb "$CHROOT_DEVICEINFO" || true
fi

# Also fix in /usr/share/deviceinfo
SHARE_DEVICEINFO="$ROOTFS/usr/share/deviceinfo/device-google-steelhead"
if [ -f "$SHARE_DEVICEINFO" ]; then
    sed -i 's|deviceinfo_dtb="ti/omap/omap4-steelhead"|deviceinfo_dtb="omap4-steelhead"|' "$SHARE_DEVICEINFO"
    echo "Fixed DTB in share deviceinfo"
fi

# Now try mkinitfs via chroot
sudo chroot "$ROOTFS" /bin/sh -c "mkinitfs" 2>&1 || {
    echo "mkinitfs via chroot failed, building initramfs manually..."

    WORK="/tmp/manual-initramfs"
    rm -rf "$WORK"
    mkdir -p "$WORK"

    # Get busybox-static from the mkinitfs package
    MKINITFS_BUSYBOX=$(find "$ROOTFS" -name "busybox" -path "*/mkinitfs/*" 2>/dev/null | head -1)
    if [ -z "$MKINITFS_BUSYBOX" ]; then
        MKINITFS_BUSYBOX="$ROOTFS/bin/busybox"
    fi
    echo "Using busybox: $MKINITFS_BUSYBOX"

    # Copy the mkinitfs files list
    FILES_LIST="$ROOTFS/usr/share/mkinitfs/files/00-device-google-steelhead-modules.files"
    if [ -f "$FILES_LIST" ]; then
        echo "Files list:"
        cat "$FILES_LIST"
    fi

    # Build a minimal initramfs with postmarketOS init
    mkdir -p "$WORK"/{bin,sbin,dev,proc,sys,tmp,run,etc,usr/bin,usr/sbin,usr/lib/modules,lib/modules}

    # Copy busybox
    cp "$MKINITFS_BUSYBOX" "$WORK/bin/busybox"
    chmod +x "$WORK/bin/busybox"

    # Copy musl dynamic linker if needed
    for lib in "$ROOTFS"/lib/ld-musl-*.so.*; do
        [ -f "$lib" ] && mkdir -p "$WORK/lib" && cp "$lib" "$WORK/lib/"
    done
    for lib in "$ROOTFS"/usr/lib/libc.musl-*.so.*; do
        [ -f "$lib" ] && mkdir -p "$WORK/usr/lib" && cp "$lib" "$WORK/usr/lib/"
    done

    # Copy postmarketOS init scripts if available
    for f in "$ROOTFS"/usr/share/mkinitfs/init "$ROOTFS"/usr/share/mkinitfs/init_functions.sh; do
        if [ -f "$f" ]; then
            cp "$f" "$WORK/$(basename "$f")"
            chmod +x "$WORK/$(basename "$f")"
            echo "Copied $(basename "$f")"
        fi
    done

    # If no pmos init, create a minimal one
    if [ ! -f "$WORK/init" ]; then
        cat > "$WORK/init" << 'INITEOF'
#!/bin/busybox ash
/bin/busybox --install -s
mount -t proc proc /proc
mount -t sysfs sysfs /sys
mount -t devtmpfs devtmpfs /dev

echo ""
echo "=== PostmarketOS boot (manual initramfs) ==="
echo "cmdline: $(cat /proc/cmdline)"
echo "kernel:  $(uname -r) $(uname -m)"
echo ""

# Network interfaces
echo "--- Network ---"
ip link 2>/dev/null || ifconfig -a
for iface in $(ls /sys/class/net/ 2>/dev/null | grep -v lo); do
    ifconfig "$iface" 172.16.42.1 netmask 255.255.255.0 up 2>/dev/null
    echo "Configured $iface = 172.16.42.1"
done

echo ""
echo "--- dmesg (last 40 lines) ---"
dmesg | tail -40

echo ""
echo "--- Starting telnetd ---"
telnetd -l /bin/sh -p 23 2>/dev/null && echo "telnetd on port 23" || echo "telnetd failed"

echo ""
echo "=== Entering shell ==="
exec /bin/sh
INITEOF
        chmod +x "$WORK/init"
    fi

    # Copy deviceinfo
    mkdir -p "$WORK/etc"
    [ -f "$CHROOT_DEVICEINFO" ] && cp "$CHROOT_DEVICEINFO" "$WORK/etc/deviceinfo"

    # Copy remaining kernel modules (those that are still =m)
    if [ -d "$MODDIR" ]; then
        echo "Copying kernel modules..."
        cp -a "$MODDIR" "$WORK/usr/lib/modules/"
        MOD_COUNT=$(find "$WORK/usr/lib/modules/" -name "*.ko" | wc -l)
        echo "Copied $MOD_COUNT modules"
    fi

    # Create cpio
    cd "$WORK"
    find . | cpio -o -H newc 2>/dev/null | gzip -9 > /tmp/initramfs-manual.gz
    echo "Initramfs size: $(stat -c%s /tmp/initramfs-manual.gz) bytes"
    INITRAMFS_PATH="/tmp/initramfs-manual.gz"
}

# Check if mkinitfs succeeded
if [ -f "$ROOTFS/boot/initramfs" ]; then
    INITRAMFS_PATH="$ROOTFS/boot/initramfs"
    echo "Using mkinitfs initramfs"
elif [ ! -f "/tmp/initramfs-manual.gz" ]; then
    echo "ERROR: No initramfs available!"
    exit 1
fi

echo ""
echo "=== Step 2: Build boot.img ==="
sudo apk add --no-cache android-tools 2>&1 | tail -1

# Append DTB to kernel
cat "$VMLINUZ" "$DTB" > /tmp/zImage-dtb
echo "zImage+DTB: $(stat -c%s /tmp/zImage-dtb) bytes"

sudo mkdir -p /tmp/output
sudo chown pmos:pmos /tmp/output 2>/dev/null || true

mkbootimg \
    --kernel /tmp/zImage-dtb \
    --ramdisk "$INITRAMFS_PATH" \
    --base 0x80000000 \
    --kernel_offset 0x00008000 \
    --ramdisk_offset 0x01000000 \
    --second_offset 0x00f00000 \
    --tags_offset 0x00000100 \
    --pagesize 2048 \
    --cmdline "console=ttyS2,115200n8 mem=1G loglevel=7 ignore_loglevel" \
    -o /tmp/output/boot.img

echo ""
echo "=== boot.img ==="
ls -lh /tmp/output/boot.img

echo ""
echo "=== Step 3: Create rootfs image ==="

# Create rootfs ext4 image from the chroot
ROOTFS_IMG="/tmp/output/rootfs.img"
ROOTFS_SIZE=$(du -sm "$ROOTFS" | awk '{print $1}')
ROOTFS_SIZE=$((ROOTFS_SIZE + 200))
echo "Rootfs size: ~${ROOTFS_SIZE}MB"

dd if=/dev/zero of="$ROOTFS_IMG" bs=1M count="$ROOTFS_SIZE" 2>/dev/null
mkfs.ext4 -L pmOS_root "$ROOTFS_IMG" 2>&1 | tail -2

MOUNT_DIR="/tmp/rootfs-mount"
mkdir -p "$MOUNT_DIR"
mount -o loop "$ROOTFS_IMG" "$MOUNT_DIR"

echo "Copying rootfs files..."
cp -a "$ROOTFS"/* "$MOUNT_DIR"/ 2>/dev/null || true
sync
umount "$MOUNT_DIR"

echo "Rootfs image: $(stat -c%s "$ROOTFS_IMG") bytes ($(du -sh "$ROOTFS_IMG" | awk '{print $1}'))"

echo ""
echo "=== Done ==="
ls -lh /tmp/output/
