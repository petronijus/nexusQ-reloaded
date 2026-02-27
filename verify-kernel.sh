#!/bin/bash
set -euo pipefail

ROOTFS="/home/pmos/.local/var/pmbootstrap/chroot_rootfs_google-steelhead"

echo "=== Checking vmlinuz ==="
VMLINUZ="$ROOTFS/boot/vmlinuz"
ls -la "$VMLINUZ"
hexdump -C "$VMLINUZ" | head -5
# zImage magic at offset 0x24 should be 0x016F2818
MAGIC=$(hexdump -s 0x24 -n 4 -e '1/4 "%08x"' "$VMLINUZ")
echo "zImage magic at 0x24: 0x$MAGIC (expected: 016f2818)"
if [ "$MAGIC" = "016f2818" ]; then
    echo "  Valid ARM zImage"
    # Extract zImage header info
    START=$(hexdump -s 0x28 -n 4 -e '1/4 "%u"' "$VMLINUZ")
    END=$(hexdump -s 0x2c -n 4 -e '1/4 "%u"' "$VMLINUZ")
    echo "  Start addr: 0x$(printf '%x' $START)"
    echo "  End addr: 0x$(printf '%x' $END)"
    echo "  Decompressed size: $(( (END - START) / 1024 / 1024 )) MB"
else
    echo "  WARNING: Not a valid zImage!"
fi

echo ""
echo "=== Checking DTB ==="
DTB=$(find "$ROOTFS/boot/dtbs/" -name "omap4-steelhead.dtb" | head -1)
ls -la "$DTB"
hexdump -C "$DTB" | head -3
# DTB magic should be 0xd00dfeed
DTB_MAGIC=$(hexdump -s 0 -n 4 -e '1/4 "%08x"' "$DTB")
echo "DTB magic: 0x$DTB_MAGIC (expected: d00dfeed)"

echo ""
echo "=== DTB contents (decompile) ==="
sudo apk add --no-cache dtc 2>&1 | tail -1
dtc -I dtb -O dts "$DTB" 2>&1 | head -50
echo "..."
echo ""
echo "--- Check /chosen node ---"
dtc -I dtb -O dts "$DTB" 2>/dev/null | grep -A 5 'chosen'
echo ""
echo "--- Check /memory node ---"
dtc -I dtb -O dts "$DTB" 2>/dev/null | grep -A 5 'memory'
echo ""
echo "--- Check compatible ---"
dtc -I dtb -O dts "$DTB" 2>/dev/null | grep 'compatible' | head -10
echo ""
echo "--- Check for USB OTG ---"
dtc -I dtb -O dts "$DTB" 2>/dev/null | grep -A 3 'usb_otg_hs\|usb@' | head -20

echo ""
echo "=== Verify zImage+DTB concatenation ==="
cat "$VMLINUZ" "$DTB" > /tmp/zImage-dtb-test
TOTAL=$(stat -c%s /tmp/zImage-dtb-test)
KSIZE=$(stat -c%s "$VMLINUZ")
DSIZE=$(stat -c%s "$DTB")
echo "Kernel: $KSIZE bytes"
echo "DTB: $DSIZE bytes"
echo "Combined: $TOTAL bytes"
# Check DTB magic at kernel end
DTB_AT_END=$(hexdump -s $KSIZE -n 4 -e '1/4 "%08x"' /tmp/zImage-dtb-test)
echo "DTB magic at offset $KSIZE: 0x$DTB_AT_END (expected: d00dfeed)"

echo ""
echo "=== Check boot-diag.img ==="
python3 -c "
import struct, math
with open('/tmp/output/boot-diag.img', 'rb') as f:
    magic = f.read(8)
    print(f'Magic: {magic}')
    ks, ka, rs, ra = struct.unpack('<IIII', f.read(16))
    ss, sa, ta, ps = struct.unpack('<IIII', f.read(16))
    f.read(4)  # dt_size
    f.read(4)  # unused
    name = f.read(16)
    cmdline = f.read(512)
    print(f'Kernel: {ks} bytes @ 0x{ka:08x}')
    print(f'Ramdisk: {rs} bytes @ 0x{ra:08x}')
    print(f'Second: {ss} bytes @ 0x{sa:08x}')
    print(f'Tags: 0x{ta:08x}')
    print(f'Page size: {ps}')
    print(f'Name: {name.rstrip(b\"\\x00\")}')
    print(f'Cmdline: {cmdline.rstrip(b\"\\x00\").decode()}')

    # Check kernel bytes
    koff = ps  # first page is header
    f.seek(koff)
    kmagic_offset = koff + 0x24
    f.seek(kmagic_offset)
    km = struct.unpack('<I', f.read(4))[0]
    print(f'')
    print(f'Kernel zImage magic at offset 0x{kmagic_offset:x}: 0x{km:08x} (expect 0x016f2818)')

    # Check DTB appended at end of kernel within boot.img
    dtb_offset = koff + ks - $DSIZE
    f.seek(dtb_offset)
    dm = struct.unpack('>I', f.read(4))[0]
    print(f'DTB magic at offset 0x{dtb_offset:x}: 0x{dm:08x} (expect 0xd00dfeed)')
"

echo ""
echo "Done!"
