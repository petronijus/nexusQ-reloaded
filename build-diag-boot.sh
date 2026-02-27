#!/bin/bash
set -euo pipefail

ROOTFS="/home/pmos/.local/var/pmbootstrap/chroot_rootfs_google-steelhead"
KERNEL_VER=$(cat "$ROOTFS/usr/share/kernel/google-steelhead/kernel.release")
MODDIR="$ROOTFS/lib/modules/$KERNEL_VER"
echo "Kernel: $KERNEL_VER"

echo ""
echo "=== Building diagnostic initramfs ==="
WORK="/tmp/diag-initramfs"
rm -rf "$WORK"
mkdir -p "$WORK"/{bin,dev,proc,sys,tmp,lib/modules}

# Use busybox from the native chroot
NATIVE="/home/pmos/.local/var/pmbootstrap/chroot_native"
BUSYBOX=$(find "$NATIVE" "$ROOTFS" -name "busybox" -type f 2>/dev/null | head -1)
echo "Busybox: $BUSYBOX"
cp "$BUSYBOX" "$WORK/bin/busybox"
chmod +x "$WORK/bin/busybox"

# Copy kernel modules we need (in correct loading order)
MODS_NEEDED="
    kernel/drivers/usb/common/usb-common.ko
    kernel/drivers/usb/core/usbcore.ko
    kernel/drivers/usb/gadget/udc/udc-core.ko
    kernel/drivers/phy/ti/phy-omap-usb2.ko
    kernel/drivers/usb/musb/musb_hdrc.ko
    kernel/drivers/usb/musb/omap2430.ko
    kernel/fs/configfs/configfs.ko
    kernel/drivers/usb/gadget/libcomposite.ko
    kernel/drivers/usb/gadget/function/u_ether.ko
    kernel/drivers/usb/gadget/function/usb_f_rndis.ko
    kernel/drivers/usb/gadget/function/u_serial.ko
    kernel/drivers/usb/gadget/function/usb_f_acm.ko
    kernel/drivers/gpu/drm/drm_panel_orientation_quirks.ko
    kernel/drivers/gpu/drm/drm.ko
    kernel/drivers/gpu/drm/drm_kms_helper.ko
    kernel/drivers/gpu/drm/display/drm_display_helper.ko
    kernel/drivers/media/cec/core/cec.ko
    kernel/drivers/gpu/drm/omapdrm/omapdrm.ko
    kernel/drivers/gpu/drm/bridge/ti-tpd12s015.ko
    kernel/drivers/gpu/drm/bridge/display-connector.ko
    kernel/drivers/usb/host/ehci-hcd.ko
    kernel/drivers/net/mii.ko
    kernel/drivers/leds/led-class.ko
    kernel/drivers/net/phy/libphy.ko
    kernel/net/core/selftests.ko
    kernel/drivers/net/usb/usbnet.ko
    kernel/drivers/net/usb/smsc95xx.ko
"

for mod in $MODS_NEEDED; do
    src="$MODDIR/$mod"
    if [ -f "$src" ]; then
        mkdir -p "$WORK/lib/modules/$(dirname "$mod")"
        cp "$src" "$WORK/lib/modules/$mod"
    else
        echo "  WARN: $mod not found"
    fi
done
echo "Modules copied: $(find "$WORK/lib/modules" -name '*.ko' | wc -l)"

# Create the diagnostic init script
cat > "$WORK/init" << 'INITEOF'
#!/bin/busybox ash
set -x

/bin/busybox --install -s

mount -t proc proc /proc
mount -t sysfs sysfs /sys
mount -t devtmpfs devtmpfs /dev
mount -t configfs configfs /sys/kernel/config
mkdir -p /dev/pts
mount -t devpts devpts /dev/pts

echo "=== PMOS DIAGNOSTIC BOOT ==="
echo "Kernel cmdline: $(cat /proc/cmdline)"
echo "Kernel version: $(uname -r)"
echo ""

echo "=== Loading USB modules (in order) ==="
for mod in \
    /lib/modules/kernel/drivers/usb/common/usb-common.ko \
    /lib/modules/kernel/drivers/usb/core/usbcore.ko \
    /lib/modules/kernel/drivers/usb/gadget/udc/udc-core.ko \
    /lib/modules/kernel/drivers/phy/ti/phy-omap-usb2.ko \
    /lib/modules/kernel/drivers/usb/musb/musb_hdrc.ko \
    /lib/modules/kernel/drivers/usb/musb/omap2430.ko \
    ; do
    echo "  Loading $(basename $mod)..."
    insmod "$mod" 2>&1 || echo "  FAILED: $?"
done

echo ""
echo "=== UDC devices ==="
ls -la /sys/class/udc/ 2>&1 || echo "No UDC found"

echo ""
echo "=== Setting up USB gadget (RNDIS) ==="
CONFIGFS=/sys/kernel/config/usb_gadget

insmod /lib/modules/kernel/fs/configfs/configfs.ko 2>&1 || true
insmod /lib/modules/kernel/drivers/usb/gadget/libcomposite.ko 2>&1 || true
insmod /lib/modules/kernel/drivers/usb/gadget/function/u_ether.ko 2>&1 || true
insmod /lib/modules/kernel/drivers/usb/gadget/function/usb_f_rndis.ko 2>&1 || true

mkdir -p $CONFIGFS/g1
echo "0x18D1" > $CONFIGFS/g1/idVendor
echo "0x4EE2" > $CONFIGFS/g1/idProduct
mkdir -p $CONFIGFS/g1/strings/0x409
echo "Google" > $CONFIGFS/g1/strings/0x409/manufacturer
echo "NexusQ-diag" > $CONFIGFS/g1/strings/0x409/serialnumber
echo "Nexus Q" > $CONFIGFS/g1/strings/0x409/product

mkdir -p $CONFIGFS/g1/functions/rndis.usb0
mkdir -p $CONFIGFS/g1/configs/c.1
mkdir -p $CONFIGFS/g1/configs/c.1/strings/0x409
echo "RNDIS" > $CONFIGFS/g1/configs/c.1/strings/0x409/configuration
ln -s $CONFIGFS/g1/functions/rndis.usb0 $CONFIGFS/g1/configs/c.1/

echo ""
echo "=== Available UDCs ==="
ls /sys/class/udc/ 2>&1

UDC=$(ls /sys/class/udc/ 2>/dev/null | head -1)
if [ -n "$UDC" ]; then
    echo "Binding to UDC: $UDC"
    echo "$UDC" > $CONFIGFS/g1/UDC
    echo "UDC bound successfully"
else
    echo "ERROR: No UDC available!"
    echo ""
    echo "=== Platform devices ==="
    ls /sys/bus/platform/devices/ 2>&1 | tr ' ' '\n' | grep -i 'usb\|musb\|otg\|phy\|omap' || true
    echo ""
    echo "=== Loaded modules ==="
    cat /proc/modules
    echo ""
    echo "=== dmesg (last 50 lines) ==="
    dmesg | tail -50
fi

echo ""
echo "=== Network interface setup ==="
IFACE=$(ls /sys/class/net/ 2>/dev/null | grep -v lo | head -1)
if [ -n "$IFACE" ]; then
    echo "USB interface: $IFACE"
    ifconfig "$IFACE" 172.16.42.1 netmask 255.255.255.0 up
    echo "IP configured: 172.16.42.1"
else
    echo "No USB network interface found"
fi

echo ""
echo "=== Loading display modules ==="
for mod in \
    /lib/modules/kernel/drivers/gpu/drm/drm_panel_orientation_quirks.ko \
    /lib/modules/kernel/drivers/gpu/drm/drm.ko \
    /lib/modules/kernel/drivers/gpu/drm/drm_kms_helper.ko \
    /lib/modules/kernel/drivers/gpu/drm/display/drm_display_helper.ko \
    /lib/modules/kernel/drivers/media/cec/core/cec.ko \
    /lib/modules/kernel/drivers/gpu/drm/omapdrm/omapdrm.ko \
    /lib/modules/kernel/drivers/gpu/drm/bridge/ti-tpd12s015.ko \
    /lib/modules/kernel/drivers/gpu/drm/bridge/display-connector.ko \
    ; do
    echo "  Loading $(basename $mod)..."
    insmod "$mod" 2>&1 || echo "  FAILED: $?"
done

echo ""
echo "=== Loading Ethernet modules ==="
for mod in \
    /lib/modules/kernel/drivers/usb/host/ehci-hcd.ko \
    /lib/modules/kernel/drivers/net/mii.ko \
    /lib/modules/kernel/drivers/leds/led-class.ko \
    /lib/modules/kernel/drivers/net/phy/libphy.ko \
    /lib/modules/kernel/net/core/selftests.ko \
    /lib/modules/kernel/drivers/net/usb/usbnet.ko \
    /lib/modules/kernel/drivers/net/usb/smsc95xx.ko \
    ; do
    echo "  Loading $(basename $mod)..."
    insmod "$mod" 2>&1 || echo "  FAILED: $?"
done

echo ""
echo "=== dmesg summary ==="
dmesg | grep -iE 'error|fail|panic|oops|musb|gadget|rndis|usb|drm|omap|hdmi|phy' | tail -30

echo ""
echo "=== Starting telnetd ==="
telnetd -l /bin/sh -b 0.0.0.0 -p 23 2>&1 || echo "telnetd failed"
echo "Telnet server started on 172.16.42.1:23"

echo ""
echo "=== DIAGNOSTIC BOOT COMPLETE ==="
echo "Connect via: telnet 172.16.42.1"
echo ""

# Keep alive
while true; do
    sleep 60
    echo "Still alive at $(cat /proc/uptime | cut -d' ' -f1)s"
done
INITEOF
chmod +x "$WORK/init"

echo ""
echo "=== Creating cpio archive ==="
cd "$WORK"
find . | cpio -o -H newc 2>/dev/null | gzip -9 > /tmp/diag-initramfs.gz
echo "Diagnostic initramfs: $(stat -c%s /tmp/diag-initramfs.gz) bytes"

echo ""
echo "=== Building boot.img ==="
sudo apk add --no-cache android-tools 2>&1 | tail -1

VMLINUZ="$ROOTFS/boot/vmlinuz"
DTB=$(find "$ROOTFS/boot/dtbs/" -name "omap4-steelhead.dtb" | head -1)

cat "$VMLINUZ" "$DTB" > /tmp/zImage-dtb
echo "zImage-dtb: $(stat -c%s /tmp/zImage-dtb) bytes"

sudo mkdir -p /tmp/output
sudo chown pmos:pmos /tmp/output

mkbootimg \
    --kernel /tmp/zImage-dtb \
    --ramdisk /tmp/diag-initramfs.gz \
    --base 0x80000000 \
    --kernel_offset 0x00008000 \
    --ramdisk_offset 0x01000000 \
    --second_offset 0x00f00000 \
    --tags_offset 0x00000100 \
    --pagesize 2048 \
    --cmdline "console=ttyS2,115200n8 mem=1G loglevel=7 ignore_loglevel" \
    -o /tmp/output/boot-diag.img

echo ""
echo "=== Result ==="
ls -lh /tmp/output/boot-diag.img
python3 -c "
import struct, math
with open('/tmp/output/boot-diag.img', 'rb') as f:
    f.read(8); ks = struct.unpack('<I', f.read(4))[0]; f.read(4)
    rs = struct.unpack('<I', f.read(4))[0]
    print(f'Kernel: {ks} bytes, Ramdisk: {rs} bytes')
"
echo "Done!"
