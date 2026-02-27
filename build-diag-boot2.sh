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
mkdir -p "$WORK"/{bin,dev,proc,sys,tmp,lib/modules/kernel}

# Extract STATIC busybox from the mkinitfs-generated initramfs (ARM, static-linked)
echo "Extracting static busybox from mkinitfs initramfs..."
INITRAMFS="$ROOTFS/boot/initramfs"
if [ -f "$INITRAMFS" ]; then
    mkdir -p /tmp/initramfs-extract
    cd /tmp/initramfs-extract
    zcat "$INITRAMFS" | cpio -idm 2>/dev/null || true
    if [ -f /tmp/initramfs-extract/bin/busybox ]; then
        cp /tmp/initramfs-extract/bin/busybox "$WORK/bin/busybox"
        chmod +x "$WORK/bin/busybox"
        echo "  Got static busybox from initramfs"
        [ -f /tmp/initramfs-extract/bin/busybox-extras ] && \
            cp /tmp/initramfs-extract/bin/busybox-extras "$WORK/bin/busybox-extras" && \
            chmod +x "$WORK/bin/busybox-extras"
    else
        echo "  WARN: busybox not found in initramfs, falling back to rootfs copy"
        cp "$ROOTFS/bin/busybox" "$WORK/bin/busybox"
        chmod +x "$WORK/bin/busybox"
        # Copy musl dynamic linker + libc for dynamically-linked busybox
        mkdir -p "$WORK/lib"
        for lib in "$ROOTFS"/lib/ld-musl-*.so.* "$ROOTFS"/lib/libc.musl-*.so.*; do
            [ -f "$lib" ] && cp "$lib" "$WORK/lib/" && echo "  Copied $(basename "$lib")"
        done
    fi
    rm -rf /tmp/initramfs-extract
    cd /tmp
else
    echo "  WARN: no initramfs found, using rootfs busybox with libs"
    cp "$ROOTFS/bin/busybox" "$WORK/bin/busybox"
    chmod +x "$WORK/bin/busybox"
    mkdir -p "$WORK/lib"
    for lib in "$ROOTFS"/lib/ld-musl-*.so.* "$ROOTFS"/lib/libc.musl-*.so.*; do
        [ -f "$lib" ] && cp "$lib" "$WORK/lib/" && echo "  Copied $(basename "$lib")"
    done
fi

# Copy kernel modules
echo "Copying modules..."
MODS="
usb/common/usb-common.ko
usb/core/usbcore.ko
usb/gadget/udc/udc-core.ko
phy/ti/phy-omap-usb2.ko
usb/musb/musb_hdrc.ko
usb/musb/omap2430.ko
usb/gadget/libcomposite.ko
usb/gadget/function/u_ether.ko
usb/gadget/function/usb_f_rndis.ko
usb/gadget/function/u_serial.ko
usb/gadget/function/usb_f_acm.ko
usb/gadget/function/usb_f_ncm.ko
usb/host/ehci-hcd.ko
net/usb/usbnet.ko
net/usb/smsc95xx.ko
net/mii.ko
net/phy/libphy.ko
leds/led-class.ko
gpu/drm/drm_panel_orientation_quirks.ko
gpu/drm/drm.ko
gpu/drm/drm_kms_helper.ko
gpu/drm/display/drm_display_helper.ko
gpu/drm/omapdrm/omapdrm.ko
gpu/drm/bridge/ti-tpd12s015.ko
gpu/drm/bridge/display-connector.ko
media/cec/core/cec.ko
input/evdev.ko
"

count=0
for mod in $MODS; do
    src="$MODDIR/kernel/drivers/$mod"
    [ ! -f "$src" ] && src="$MODDIR/kernel/$mod" # try without drivers/
    [ ! -f "$src" ] && src="$MODDIR/kernel/net/$(basename "$mod" .ko)/$(basename "$mod")"
    # search
    [ ! -f "$src" ] && src=$(find "$MODDIR" -name "$(basename "$mod")" 2>/dev/null | head -1)
    if [ -n "$src" ] && [ -f "$src" ]; then
        rel="${src#$MODDIR/}"
        mkdir -p "$WORK/lib/modules/$(dirname "$rel")"
        cp "$src" "$WORK/lib/modules/$rel"
        count=$((count+1))
    else
        echo "  WARN: $(basename "$mod") not found"
    fi
done

# Also need configfs
src=$(find "$MODDIR" -name "configfs.ko" | head -1)
[ -n "$src" ] && { rel="${src#$MODDIR/}"; mkdir -p "$WORK/lib/modules/$(dirname "$rel")"; cp "$src" "$WORK/lib/modules/$rel"; count=$((count+1)); }

# selftests.ko (dep of smsc95xx)
src=$(find "$MODDIR" -name "selftests.ko" | head -1)
[ -n "$src" ] && { rel="${src#$MODDIR/}"; mkdir -p "$WORK/lib/modules/$(dirname "$rel")"; cp "$src" "$WORK/lib/modules/$rel"; count=$((count+1)); }

echo "Modules: $count copied"

# Create diagnostic init
cat > "$WORK/init" << 'INITEOF'
#!/bin/busybox ash
export PATH=/bin:/sbin:/usr/bin:/usr/sbin

/bin/busybox --install -s

mount -t proc proc /proc
mount -t sysfs sysfs /sys
mount -t devtmpfs devtmpfs /dev

echo ""
echo "=== NEXUS Q DIAGNOSTIC BOOT ==="
echo "cmdline: $(cat /proc/cmdline)"
echo "kernel:  $(uname -r) $(uname -m)"
echo ""

# Find modules
MDIR=""
for d in /lib/modules/*/kernel /usr/lib/modules/*/kernel; do
    [ -d "$d" ] && MDIR="$(dirname "$d")" && break
done
echo "Module dir: $MDIR"

echo ""
echo "--- Loading USB core ---"
insmod "$MDIR/kernel/drivers/usb/common/usb-common.ko" && echo "  usb-common OK" || echo "  usb-common FAIL"
insmod "$MDIR/kernel/drivers/usb/core/usbcore.ko" && echo "  usbcore OK" || echo "  usbcore FAIL"
insmod "$MDIR/kernel/drivers/usb/gadget/udc/udc-core.ko" && echo "  udc-core OK" || echo "  udc-core FAIL"

echo ""
echo "--- Loading USB PHY ---"
insmod "$MDIR/kernel/drivers/phy/ti/phy-omap-usb2.ko" && echo "  phy-omap-usb2 OK" || echo "  phy-omap-usb2 FAIL"

echo ""
echo "--- Loading MUSB ---"
insmod "$MDIR/kernel/drivers/usb/musb/musb_hdrc.ko" && echo "  musb_hdrc OK" || echo "  musb_hdrc FAIL"
insmod "$MDIR/kernel/drivers/usb/musb/omap2430.ko" && echo "  omap2430 OK" || echo "  omap2430 FAIL"

echo ""
echo "--- UDC check ---"
ls -la /sys/class/udc/ 2>&1
UDC=$(ls /sys/class/udc/ 2>/dev/null | head -1)
echo "UDC: '$UDC'"

echo ""
echo "--- Setting up RNDIS gadget ---"
mount -t configfs configfs /sys/kernel/config 2>/dev/null
insmod "$MDIR/kernel/fs/configfs/configfs.ko" 2>/dev/null
insmod "$MDIR/kernel/drivers/usb/gadget/libcomposite.ko" && echo "  libcomposite OK" || echo "  libcomposite FAIL"
insmod "$MDIR/kernel/drivers/usb/gadget/function/u_ether.ko" 2>/dev/null
insmod "$MDIR/kernel/drivers/usb/gadget/function/usb_f_rndis.ko" 2>/dev/null

CFS=/sys/kernel/config/usb_gadget
mkdir -p $CFS/g1 2>/dev/null
echo "0x18D1" > $CFS/g1/idVendor 2>/dev/null
echo "0x4EE2" > $CFS/g1/idProduct 2>/dev/null
mkdir -p $CFS/g1/strings/0x409 2>/dev/null
echo "postmarketOS" > $CFS/g1/strings/0x409/serialnumber 2>/dev/null
echo "Google" > $CFS/g1/strings/0x409/manufacturer 2>/dev/null
echo "Nexus Q" > $CFS/g1/strings/0x409/product 2>/dev/null

mkdir -p $CFS/g1/functions/rndis.usb0 2>/dev/null
mkdir -p $CFS/g1/configs/c.1/strings/0x409 2>/dev/null
echo "RNDIS" > $CFS/g1/configs/c.1/strings/0x409/configuration 2>/dev/null
ln -s $CFS/g1/functions/rndis.usb0 $CFS/g1/configs/c.1/ 2>/dev/null

if [ -n "$UDC" ]; then
    echo "$UDC" > $CFS/g1/UDC 2>/dev/null && echo "RNDIS gadget bound to $UDC" || echo "Failed to bind UDC"
else
    echo "No UDC - cannot bind gadget"
fi

echo ""
echo "--- Network interfaces ---"
ip link 2>/dev/null || ifconfig -a 2>/dev/null
IFACE=$(ls /sys/class/net/ 2>/dev/null | grep -v lo | head -1)
if [ -n "$IFACE" ]; then
    ifconfig "$IFACE" 172.16.42.1 netmask 255.255.255.0 up 2>/dev/null
    echo "Configured $IFACE = 172.16.42.1"
fi

echo ""
echo "--- USB host + Ethernet ---"
insmod "$MDIR/kernel/drivers/usb/host/ehci-hcd.ko" 2>/dev/null && echo "  ehci-hcd OK" || echo "  ehci-hcd FAIL"
insmod "$MDIR/kernel/drivers/net/mii.ko" 2>/dev/null
insmod "$MDIR/kernel/drivers/leds/led-class.ko" 2>/dev/null
insmod "$MDIR/kernel/drivers/net/phy/libphy.ko" 2>/dev/null
insmod "$MDIR/kernel/net/core/selftests.ko" 2>/dev/null
insmod "$MDIR/kernel/drivers/net/usb/usbnet.ko" 2>/dev/null && echo "  usbnet OK" || echo "  usbnet FAIL"
insmod "$MDIR/kernel/drivers/net/usb/smsc95xx.ko" 2>/dev/null && echo "  smsc95xx OK" || echo "  smsc95xx FAIL"

echo ""
echo "--- dmesg (USB/PHY/MUSB related) ---"
dmesg 2>/dev/null | grep -iE 'usb|musb|gadget|phy|omap|rndis|udc|otg|ehci' | tail -30

echo ""
echo "--- All loaded modules ---"
cat /proc/modules 2>/dev/null

echo ""
echo "--- Starting telnetd ---"
telnetd -l /bin/sh -p 23 2>/dev/null && echo "telnetd on port 23" || echo "telnetd failed"

echo ""
echo "=== DIAG COMPLETE - entering shell ==="
exec /bin/sh
INITEOF
chmod +x "$WORK/init"

echo ""
echo "=== Creating cpio ==="
cd "$WORK"
find . | cpio -o -H newc 2>/dev/null | gzip -9 > /tmp/diag-initramfs.gz
echo "Size: $(stat -c%s /tmp/diag-initramfs.gz) bytes ($(( $(stat -c%s /tmp/diag-initramfs.gz) / 1024 )) KB)"

echo ""
echo "=== Building boot-diag.img ==="
sudo apk add --no-cache android-tools 2>&1 | tail -1

VMLINUZ="$ROOTFS/boot/vmlinuz"
DTB=$(find "$ROOTFS/boot/dtbs/" -name "omap4-steelhead.dtb" | head -1)
echo "vmlinuz: $(stat -c%s "$VMLINUZ") bytes"
echo "DTB: $(stat -c%s "$DTB") bytes"

cat "$VMLINUZ" "$DTB" > /tmp/zImage-dtb

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
    --cmdline "console=ttyS2,115200n8 mem=1G loglevel=7 ignore_loglevel earlyprintk" \
    -o /tmp/output/boot-diag.img

echo ""
echo "=== Result ==="
ls -lh /tmp/output/boot-diag.img
echo "Done!"
