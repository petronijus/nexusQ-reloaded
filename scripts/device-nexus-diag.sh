#!/bin/sh
sleep 5
LOG=/var/log/nexus-diag.log
{
echo "########## NEXUS DIAG v2 ##########"
echo "--- eth diagnostics ---"
dmesg | grep -iE "phy|regulator|auxclk|nop_usb|usb3320|hsusb|smsc|lan95|ehci" | tail -30
echo "--- gpio state (1=NENABLE, 62=NRESET) ---"
grep -E "gpio-(1|62)\b" /sys/kernel/debug/gpio
echo "--- auxclk3 ---"
for f in clk_rate clk_enable_count clk_prepare_count; do printf "%s=%s " $f "$(cat /sys/kernel/debug/clk/auxclk3_ck/$f 2>/dev/null)"; done; echo
echo "--- regulators ---"
for r in /sys/class/regulator/regulator.*; do echo "$(cat $r/name 2>/dev/null): $(cat $r/state 2>/dev/null)"; done | grep -iE "hsusb|vbus"
echo "--- USB devices ---"
ls /sys/bus/usb/devices/
} > $LOG 2>&1

# USB gadget network (RNDIS) + sshd on 172.16.42.1
{
modprobe libcomposite 2>/dev/null
mount -t configfs none /sys/kernel/config 2>/dev/null
CG=/sys/kernel/config/usb_gadget
mkdir -p $CG/g1
echo 0x18D1 > $CG/g1/idVendor
echo 0x4EE2 > $CG/g1/idProduct
mkdir -p $CG/g1/strings/0x409
echo "postmarketOS" > $CG/g1/strings/0x409/manufacturer
echo "Nexus Q" > $CG/g1/strings/0x409/product
echo "steelhead" > $CG/g1/strings/0x409/serialnumber
mkdir -p $CG/g1/configs/c.1/strings/0x409
echo "rndis" > $CG/g1/configs/c.1/strings/0x409/configuration
mkdir -p $CG/g1/functions/rndis.usb0 || mkdir -p $CG/g1/functions/ncm.usb0
FN=$(ls $CG/g1/functions | head -1)
# Stable MACs so the gadget keeps the same identity across reboots (otherwise
# the host iface name / RNDIS device churns every boot). MUST be set BEFORE the
# function is linked into the config -- u_ether returns -EBUSY once linked.
echo "02:1a:11:00:00:01" > $CG/g1/functions/$FN/dev_addr 2>/dev/null
echo "02:1a:11:00:00:02" > $CG/g1/functions/$FN/host_addr 2>/dev/null
ln -s $CG/g1/functions/$FN $CG/g1/configs/c.1/ 2>/dev/null
# Make the RNDIS gadget recognizable to BOTH Windows and Linux.
# Wireless-RNDIS interface class e0/01/03 is matched by Windows' inbox
# rndiscmp.inf (USB\Class_e0&SubClass_01&Prot_03) AND Linux rndis_host
# (USB_CLASS_WIRELESS_CONTROLLER,1,3). Microsoft OS descriptors make Windows
# auto-load its signed inbox RNDIS driver with no .inf hassle. The class
# attrs take a 2-digit HEX string; device class is IAD (0xEF/02/01).
# os_desc/interface.rndis only exists for the rndis function.
if echo "$FN" | grep -q rndis; then
    echo e0 > $CG/g1/functions/$FN/class
    echo 01 > $CG/g1/functions/$FN/subclass
    echo 03 > $CG/g1/functions/$FN/protocol
    echo 0xEF > $CG/g1/bDeviceClass
    echo 0x02 > $CG/g1/bDeviceSubClass
    echo 0x01 > $CG/g1/bDeviceProtocol
    echo 1 > $CG/g1/os_desc/use
    echo 0xcd > $CG/g1/os_desc/b_vendor_code
    echo MSFT100 > $CG/g1/os_desc/qw_sign
    echo RNDIS > $CG/g1/functions/$FN/os_desc/interface.rndis/compatible_id
    echo 5162001 > $CG/g1/functions/$FN/os_desc/interface.rndis/sub_compatible_id
    [ -e $CG/g1/os_desc/c.1 ] || ln -s $CG/g1/configs/c.1 $CG/g1/os_desc/c.1 2>/dev/null
fi
UDC=$(ls /sys/class/udc | head -1)
echo "$UDC" > $CG/g1/UDC
sleep 1
IF=$(cat $CG/g1/functions/$FN/ifname 2>/dev/null)
[ -n "$IF" ] && { ip link set "$IF" up; ip addr add 172.16.42.1/24 dev "$IF"; }
mkdir -p /var/empty
/usr/sbin/sshd 2>>$LOG
echo "gadget: UDC=$UDC fn=$FN if=$IF" >> $LOG
} 2>>$LOG

{
echo "########## NEXUS DIAG v2 ##########"
grep -E "gpio-(1|62)\b" /sys/kernel/debug/gpio
echo "auxclk3: $(cat /sys/kernel/debug/clk/auxclk3_ck/clk_rate 2>/dev/null) Hz, en=$(cat /sys/kernel/debug/clk/auxclk3_ck/clk_enable_count 2>/dev/null)"
ls /sys/bus/usb/devices/
echo "USB-GADGET: $(cat /sys/kernel/config/usb_gadget/g1/UDC 2>/dev/null), IP 172.16.42.1"
pgrep -x sshd >/dev/null && echo "sshd: BEZI" || echo "sshd: NEBEZI"
echo "########## DIAG END ##########"
} > /dev/tty1 2>&1
