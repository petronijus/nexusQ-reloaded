#!/bin/bash
set -euo pipefail

cd /tmp
python3 -c "
import struct, math
with open('/tmp/output/boot.img', 'rb') as f:
    f.read(8); kernel_size = struct.unpack('<I', f.read(4))[0]; f.read(4)
    ramdisk_size = struct.unpack('<I', f.read(4))[0]; f.read(12)
    page_size = struct.unpack('<I', f.read(4))[0]
    ramdisk_offset = (1 + math.ceil(kernel_size / page_size)) * page_size
    f.seek(ramdisk_offset)
    with open('/tmp/ramdisk3.gz', 'wb') as out: out.write(f.read(ramdisk_size))
"
rm -rf /tmp/initrd3; mkdir -p /tmp/initrd3; cd /tmp/initrd3
zcat /tmp/ramdisk3.gz | cpio -idm 2>/dev/null

echo "=== init_2nd.sh ==="
cat /tmp/initrd3/init_2nd.sh

echo ""
echo "=== init_functions_2nd.sh (first 200 lines) ==="
head -200 /tmp/initrd3/init_functions_2nd.sh 2>/dev/null

echo ""
echo "=== setup_usb_network_configfs ==="
grep -A 80 'setup_usb_network_configfs()' /tmp/initrd3/init_functions.sh 2>/dev/null

echo ""
echo "=== setup_usb_network_android ==="
grep -A 20 'setup_usb_network_android()' /tmp/initrd3/init_functions.sh 2>/dev/null
