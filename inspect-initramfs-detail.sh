#!/bin/bash
set -euo pipefail

echo "=== Extracting initramfs ==="
cd /tmp
mkdir -p /tmp/initramfs-detail
cd /tmp/initramfs-detail
zcat /tmp/output/boot.img 2>/dev/null || true

# Extract from boot.img properly
python3 -c "
import struct, math
with open('/tmp/output/boot.img', 'rb') as f:
    f.read(8)  # magic
    kernel_size = struct.unpack('<I', f.read(4))[0]
    f.read(4)  # kernel_addr
    ramdisk_size = struct.unpack('<I', f.read(4))[0]
    f.read(4)  # ramdisk_addr
    f.read(8)  # second_size, second_addr
    f.read(4)  # tags_addr
    page_size = struct.unpack('<I', f.read(4))[0]
    ramdisk_offset = (1 + math.ceil(kernel_size / page_size)) * page_size
    f.seek(ramdisk_offset)
    with open('/tmp/ramdisk2.gz', 'wb') as out:
        out.write(f.read(ramdisk_size))
"

rm -rf /tmp/initramfs-detail/*
cd /tmp/initramfs-detail
zcat /tmp/ramdisk2.gz | cpio -idm 2>/dev/null

echo ""
echo "=== /lib/modules/initramfs.load ==="
cat /tmp/initramfs-detail/lib/modules/initramfs.load 2>/dev/null || echo "NOT FOUND"

echo ""
echo "=== /etc/deviceinfo ==="
cat /tmp/initramfs-detail/etc/deviceinfo 2>/dev/null || echo "NOT FOUND"

echo ""
echo "=== init_functions.sh - load_modules function ==="
grep -A 20 'load_modules\b' /tmp/initramfs-detail/init_functions.sh 2>/dev/null || echo "NOT FOUND"

echo ""
echo "=== init_functions.sh - setup_usb_network ==="
grep -A 30 'setup_usb_network\b' /tmp/initramfs-detail/init_functions.sh 2>/dev/null || echo "NOT FOUND"

echo ""
echo "=== init_functions.sh - setup_mdev ==="
grep -A 10 'setup_mdev\b' /tmp/initramfs-detail/init_functions.sh 2>/dev/null || echo "NOT FOUND"

echo ""
echo "=== /usr/share/misc/source_deviceinfo ==="
cat /tmp/initramfs-detail/usr/share/misc/source_deviceinfo 2>/dev/null || echo "NOT FOUND"

echo ""
echo "=== /usr/share/deviceinfo/deviceinfo ==="
cat /tmp/initramfs-detail/usr/share/deviceinfo/deviceinfo 2>/dev/null || echo "NOT FOUND"

echo ""
echo "=== Full directory tree (key files) ==="
find /tmp/initramfs-detail -name '*.load' -o -name 'deviceinfo*' -o -name '*init*' -o -name '*.conf' -o -name 'unudhcpd*' | sort

echo ""
echo "=== /etc/unudhcpd.conf ==="
cat /tmp/initramfs-detail/etc/unudhcpd.conf 2>/dev/null || echo "NOT FOUND"
