#!/bin/bash
set -euo pipefail

ROOTFS="/home/pmos/.local/var/pmbootstrap/chroot_rootfs_google-steelhead"

echo "=== Extracting original initramfs from rootfs chroot ==="
rm -rf /tmp/initrd4; mkdir -p /tmp/initrd4; cd /tmp/initrd4
zcat "$ROOTFS/boot/initramfs" | cpio -idm 2>/dev/null

echo "=== init_2nd.sh ==="
cat /tmp/initrd4/init_2nd.sh 2>/dev/null || echo "NOT FOUND in original either"

echo ""
echo "=== init_functions_2nd.sh (first 200 lines) ==="
head -200 /tmp/initrd4/init_functions_2nd.sh 2>/dev/null || echo "NOT FOUND"

echo ""
echo "=== setup_usb_network_configfs ==="
grep -A 80 'setup_usb_network_configfs()' /tmp/initrd4/init_functions.sh 2>/dev/null

echo ""
echo "=== setup_usb_network_android ==="
grep -A 20 'setup_usb_network_android()' /tmp/initrd4/init_functions.sh 2>/dev/null

echo ""
echo "=== mount_subpartitions ==="
grep -A 30 'mount_subpartitions()' /tmp/initrd4/init_functions.sh 2>/dev/null
