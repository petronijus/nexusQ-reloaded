# nq_gadget_up <product-string>
#
# Bring up the RNDIS gadget and a telnet server on 172.16.42.1. This board has
# NO serial console, so an initramfs without this is a black box: if something
# goes wrong there is no way to ask it what, and the only move left is a power
# cycle. Everything here mirrors what nexusq-usb-gadget.sh does on the running
# system, including the wireless-RNDIS class and the MS OS descriptors, so the
# host binds its inbox driver with no .inf dance.
#
# The shell it serves is unauthenticated by design: it exists only in RAM, only
# reaches the machine holding the USB cable, and only runs when somebody
# deliberately booted this image.
nq_gadget_up() {
    _product=${1:-"Nexus Q initramfs"}
    _g=/sys/kernel/config/usb_gadget/g1

    mount -t configfs none /sys/kernel/config 2>/dev/null || true

    _udc=""
    _i=0
    while [ "$_i" -lt 15 ]; do
        _udc=$(ls /sys/class/udc 2>/dev/null | head -1)
        [ -n "$_udc" ] && break
        sleep 1
        _i=$((_i + 1))
    done
    [ -n "$_udc" ] || { say "NO UDC -- no network from here"; return 1; }

    mkdir -p "$_g/strings/0x409" "$_g/configs/c.1/strings/0x409" "$_g/functions/rndis.usb0"
    echo 0x18D1 > "$_g/idVendor"
    echo 0x4EE2 > "$_g/idProduct"
    echo "postmarketOS" > "$_g/strings/0x409/manufacturer"
    echo "$_product"    > "$_g/strings/0x409/product"
    echo "steelhead"    > "$_g/strings/0x409/serialnumber"
    echo "initramfs"    > "$_g/configs/c.1/strings/0x409/configuration"
    echo 250 > "$_g/configs/c.1/MaxPower"
    echo e0 > "$_g/functions/rndis.usb0/class"
    echo 01 > "$_g/functions/rndis.usb0/subclass"
    echo 03 > "$_g/functions/rndis.usb0/protocol"
    echo 0xEF > "$_g/bDeviceClass"
    echo 0x02 > "$_g/bDeviceSubClass"
    echo 0x01 > "$_g/bDeviceProtocol"
    echo 1 > "$_g/os_desc/use"
    echo 0xcd > "$_g/os_desc/b_vendor_code"
    echo MSFT100 > "$_g/os_desc/qw_sign"
    echo RNDIS > "$_g/functions/rndis.usb0/os_desc/interface.rndis/compatible_id" 2>/dev/null || true
    ln -sf "$_g/functions/rndis.usb0" "$_g/configs/c.1/" 2>/dev/null || true
    echo "$_udc" > "$_g/UDC" || { say "could not bind $_udc"; return 1; }
    say "gadget bound to $_udc"

    sleep 2
    ip addr add 172.16.42.1/24 dev usb0 2>/dev/null \
        || ifconfig usb0 172.16.42.1 netmask 255.255.255.0
    ip link set usb0 up 2>/dev/null || ifconfig usb0 up

    # telnetd allocates a pty per connection; without devpts it accepts and then
    # immediately drops every session.
    mkdir -p /dev/pts
    mount -t devpts none /dev/pts 2>/dev/null || true
    telnetd -l /bin/sh -p 23 2>/dev/null || { say "telnetd failed to start"; return 1; }

    say "usb0 = 172.16.42.1, telnet is up"
    say "(use nc, not the telnet client -- it drops piped stdin immediately)"
    return 0
}
