#!/bin/bash
set -euo pipefail

ROOTFS="/home/pmos/.local/var/pmbootstrap/chroot_rootfs_google-steelhead"
KERNEL_VER=$(cat "$ROOTFS/usr/share/kernel/google-steelhead/kernel.release")

echo "=== Extracting initramfs from boot.img ==="
sudo apk add --no-cache android-tools binutils 2>&1 | tail -1

# Extract initramfs from boot.img
cd /tmp
cp /tmp/output/boot.img /tmp/boot-inspect.img

# Parse Android boot image header manually
python3 -c "
import struct
with open('/tmp/boot-inspect.img', 'rb') as f:
    magic = f.read(8)
    print(f'Magic: {magic}')
    kernel_size, kernel_addr, ramdisk_size, ramdisk_addr = struct.unpack('<IIII', f.read(16))
    second_size, second_addr, tags_addr, page_size = struct.unpack('<IIII', f.read(16))
    print(f'Kernel: {kernel_size} bytes at 0x{kernel_addr:08x}')
    print(f'Ramdisk: {ramdisk_size} bytes at 0x{ramdisk_addr:08x}')
    print(f'Page size: {page_size}')
    
    # Ramdisk starts after kernel pages
    import math
    kernel_pages = math.ceil(kernel_size / page_size)
    ramdisk_offset = (1 + kernel_pages) * page_size
    print(f'Ramdisk offset in file: {ramdisk_offset}')
    
    f.seek(ramdisk_offset)
    ramdisk_data = f.read(ramdisk_size)
    with open('/tmp/ramdisk.gz', 'wb') as out:
        out.write(ramdisk_data)
    print(f'Extracted ramdisk: {len(ramdisk_data)} bytes')
"

echo ""
echo "=== Initramfs contents ==="
mkdir -p /tmp/initramfs-inspect
cd /tmp/initramfs-inspect
zcat /tmp/ramdisk.gz | cpio -idm 2>/dev/null

echo ""
echo "--- /init (first 100 lines) ---"
head -100 /tmp/initramfs-inspect/init 2>/dev/null || echo "No /init found"

echo ""
echo "--- Module loading related files ---"
find /tmp/initramfs-inspect -name '*module*' -o -name '*modprobe*' -o -name '*depmod*' | head -20
cat /tmp/initramfs-inspect/etc/modules-initfs 2>/dev/null || echo "No /etc/modules-initfs"

echo ""
echo "--- All .ko modules in initramfs ---"
find /tmp/initramfs-inspect -name '*.ko*' | sort

echo ""
echo "--- modules.dep ---"
find /tmp/initramfs-inspect -name 'modules.dep' -exec echo "File: {}" \; -exec cat {} \; | head -50

echo ""
echo "--- deviceinfo in initramfs ---"
cat /tmp/initramfs-inspect/etc/deviceinfo 2>/dev/null || echo "No /etc/deviceinfo"

echo ""
echo "--- Search for module loading in init ---"
grep -n 'modprobe\|insmod\|load_module\|module' /tmp/initramfs-inspect/init 2>/dev/null | head -30

echo ""
echo "--- Kernel cmdline (built into boot.img) ---"
strings /tmp/boot-inspect.img | grep -i "console\|root=" | head -5

echo ""
echo "--- Check root partition config ---"
grep -rn 'root\|mount\|partition\|mmcblk\|pmOS' /tmp/initramfs-inspect/init 2>/dev/null | head -20
