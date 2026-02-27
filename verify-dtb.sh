#!/bin/bash
set -euo pipefail

ROOTFS="/home/pmos/.local/var/pmbootstrap/chroot_rootfs_google-steelhead"
DTB=$(find "$ROOTFS/boot/dtbs/" -name "omap4-steelhead.dtb" | head -1)
VMLINUZ="$ROOTFS/boot/vmlinuz"

echo "=== DTB validation ==="
ls -la "$DTB"
DTB_MAGIC=$(od -A n -t x1 -N 4 "$DTB" | tr -d ' ')
echo "DTB magic: $DTB_MAGIC (expected: d00dfeed)"

echo ""
echo "=== DTB decompile (key sections) ==="
sudo apk add --no-cache dtc 2>&1 | tail -1
echo ""
echo "--- Root compatible ---"
dtc -I dtb -O dts "$DTB" 2>/dev/null | head -15

echo ""
echo "--- TWL6030 node (checking for missing compatible) ---"
dtc -I dtb -O dts "$DTB" 2>/dev/null | grep -B 2 -A 10 'twl@48'

echo ""
echo "--- USB OTG ---"
dtc -I dtb -O dts "$DTB" 2>/dev/null | grep -B 2 -A 5 'usb_otg\|usb@4a0ab'

echo ""
echo "--- DTC warnings/errors ---"
dtc -I dtb -O dts "$DTB" > /dev/null 2>&1
echo "DTC exit code: $?"
dtc -I dtb -O dts "$DTB" 2>&1 1>/dev/null | head -20

echo ""
echo "=== Boot.img kernel+DTB check ==="
KSIZE=$(stat -c%s "$VMLINUZ")
DSIZE=$(stat -c%s "$DTB")
echo "Kernel: $KSIZE bytes"
echo "DTB: $DSIZE bytes"

# Check DTB is properly positioned in the combined image
cat "$VMLINUZ" "$DTB" > /tmp/combined-test
DTB_AT_END=$(od -A n -t x1 -j $KSIZE -N 4 /tmp/combined-test | tr -d ' ')
echo "DTB magic at kernel end (offset $KSIZE): $DTB_AT_END (expect d00dfeed)"

echo ""
echo "=== vmlinuz zImage info ==="
ZIMG_MAGIC=$(od -A n -t x4 -j 36 -N 4 "$VMLINUZ" | tr -d ' ')
echo "zImage magic: 0x$ZIMG_MAGIC (expect 016f2818)"
ZIMG_START=$(od -A n -t u4 -j 40 -N 4 "$VMLINUZ" | tr -d ' ')
ZIMG_END=$(od -A n -t u4 -j 44 -N 4 "$VMLINUZ" | tr -d ' ')
echo "Start: 0x$(printf '%x' $ZIMG_START), End: 0x$(printf '%x' $ZIMG_END)"
echo "Decompressed: $(( (ZIMG_END - ZIMG_START) )) bytes ($(( (ZIMG_END - ZIMG_START) / 1024 / 1024 )) MB)"

echo ""
echo "Done!"
