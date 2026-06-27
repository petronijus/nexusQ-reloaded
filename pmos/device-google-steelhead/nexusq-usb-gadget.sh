#!/bin/sh
# Nexus Q (steelhead): deterministically bring up the micro-USB gadget as a
# COMPOSITE RNDIS network (172.16.42.1 + sshd) + ACM serial console, every boot,
# straight from configfs.
#
# Why this exists: relying on pmOS's RNDIS bringup followed by the RNDIS->ACM
# swap left the gadget *unbound* on at least one image (host saw nothing at all —
# no network, no console, no way in). This service owns the gadget end-to-end so
# it cannot end up half-configured, and it logs its result to the HDMI console
# (/dev/tty1) so success/failure is visible even with no remote channel.
#
# Idempotent: safe to re-run. The kernel has musb dual-role + libcomposite +
# configfs RNDIS/ACM, so a UDC is expected; we wait for it before binding.
set -u

log() {
	echo "[nq-usb-gadget] $*"
	echo "[nq-usb-gadget] $*" > /dev/tty1 2>/dev/null || true
}

modprobe libcomposite 2>/dev/null || true
mount -t configfs none /sys/kernel/config 2>/dev/null || true

CG=/sys/kernel/config/usb_gadget
G=$CG/g1
CFG=$G/configs/c.1

# Wait for the musb UDC to register (it can appear a few seconds into boot).
i=0
while [ -z "$(ls /sys/class/udc 2>/dev/null)" ] && [ "$i" -lt 30 ]; do
	sleep 1; i=$((i + 1))
done
UDC="$(ls /sys/class/udc 2>/dev/null | head -1)"
if [ -z "$UDC" ]; then
	log "FAILED: no UDC after ${i}s (musb gadget not available)"
	exit 1
fi

mkdir -p "$G"
echo 0x18D1 > "$G/idVendor"  2>/dev/null || true
echo 0x4EE2 > "$G/idProduct" 2>/dev/null || true
mkdir -p "$G/strings/0x409"
echo "postmarketOS" > "$G/strings/0x409/manufacturer" 2>/dev/null || true
echo "Nexus Q"      > "$G/strings/0x409/product"      2>/dev/null || true
echo "steelhead"    > "$G/strings/0x409/serialnumber" 2>/dev/null || true
mkdir -p "$CFG/strings/0x409"
echo "rndis+acm" > "$CFG/strings/0x409/configuration" 2>/dev/null || true
echo 250 > "$CFG/MaxPower" 2>/dev/null || true

# Unbind before (re)shaping the function list.
echo "" > "$G/UDC" 2>/dev/null || true

# RNDIS function: set the stable MACs BEFORE it is linked into a config
# (u_ether returns -EBUSY once linked).
if [ ! -d "$G/functions/rndis.usb0" ]; then
	mkdir -p "$G/functions/rndis.usb0"
	echo "02:1a:11:00:00:01" > "$G/functions/rndis.usb0/dev_addr"  2>/dev/null || true
	echo "02:1a:11:00:00:02" > "$G/functions/rndis.usb0/host_addr" 2>/dev/null || true
fi
# Wireless-RNDIS class (e0/01/03) + Microsoft OS descriptors so Windows AND Linux
# both bind their inbox RNDIS driver with no .inf hassle; device class is IAD.
echo e0   > "$G/functions/rndis.usb0/class"    2>/dev/null || true
echo 01   > "$G/functions/rndis.usb0/subclass" 2>/dev/null || true
echo 03   > "$G/functions/rndis.usb0/protocol" 2>/dev/null || true
echo 0xEF > "$G/bDeviceClass"    2>/dev/null || true
echo 0x02 > "$G/bDeviceSubClass" 2>/dev/null || true
echo 0x01 > "$G/bDeviceProtocol" 2>/dev/null || true
echo 1       > "$G/os_desc/use"           2>/dev/null || true
echo 0xcd    > "$G/os_desc/b_vendor_code" 2>/dev/null || true
echo MSFT100 > "$G/os_desc/qw_sign"       2>/dev/null || true
echo RNDIS   > "$G/functions/rndis.usb0/os_desc/interface.rndis/compatible_id"     2>/dev/null || true
echo 5162001 > "$G/functions/rndis.usb0/os_desc/interface.rndis/sub_compatible_id" 2>/dev/null || true

# ACM function: a serial console on the same composite gadget (/dev/ttyACM0 host).
mkdir -p "$G/functions/acm.usb0" 2>/dev/null || true

# Link both functions into the single config (idempotent).
[ -e "$CFG/rndis.usb0" ] || ln -s "$G/functions/rndis.usb0" "$CFG/" 2>/dev/null || true
[ -e "$CFG/acm.usb0" ]   || ln -s "$G/functions/acm.usb0"   "$CFG/" 2>/dev/null || true
[ -e "$G/os_desc/c.1" ]  || ln -s "$CFG" "$G/os_desc/c.1"           2>/dev/null || true

# Bind to the UDC -> host enumerates the composite device.
if ! echo "$UDC" > "$G/UDC" 2>/dev/null; then
	log "FAILED: could not bind gadget to UDC $UDC"
	exit 1
fi
sleep 1

# Bring the RNDIS net device up with the well-known pmOS USB-net address.
IF="$(cat "$G/functions/rndis.usb0/ifname" 2>/dev/null)"
[ -n "$IF" ] || IF=usb0
ip link set "$IF" up 2>/dev/null || true
ip addr add 172.16.42.1/24 dev "$IF" 2>/dev/null || true

# Make sure ssh is reachable over it, and offer a login on the ACM port.
mkdir -p /var/empty
systemctl start sshd.service 2>/dev/null || systemctl start ssh.service 2>/dev/null \
	|| { command -v sshd >/dev/null 2>&1 && /usr/sbin/sshd 2>/dev/null; } || true
systemctl start serial-getty@ttyGS0.service 2>/dev/null || true

log "UP: UDC=$UDC iface=$IF ip=172.16.42.1/24 (rndis+acm) — ssh root@172.16.42.1"
exit 0
