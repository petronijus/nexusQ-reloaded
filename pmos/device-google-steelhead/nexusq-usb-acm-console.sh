#!/bin/sh
# Nexus Q (steelhead): turn the USB gadget into an ACM serial console.
#
# pmOS's initramfs brings the micro-USB gadget up as an RNDIS *network* device
# (deviceinfo_usb_network_function_default="rndis", the 172.16.42.1 link). Now
# that the on-board LAN9500A ethernet works (v1.3.0), networking lives on eth0
# and the USB port is only wanted as a debug console + for fastboot. This script
# swaps the single gadget config from the network function to an ACM function so
# the host sees /dev/ttyACM0 and a getty can offer a login over it. fastboot is
# unaffected (it is handled by the bootloader, not this booted gadget).
#
# Idempotent: safe to re-run; leaves an already-ACM gadget alone.
set -eu

G=/sys/kernel/config/usb_gadget/g1
[ -d "$G" ] || exit 0					# no configfs gadget -> nothing to do

CFG="$G/configs/c.1"
[ -d "$CFG" ] || exit 0

# Let udev finish bringing the just-appeared gadget up before we re-shape it.
sleep 2

# Already an ACM-only console? then we're done (idempotent on re-run / reboot).
if [ -e "$CFG/acm.usb0" ] && ! ls "$CFG"/rndis.usb0 "$CFG"/ecm.usb0 >/dev/null 2>&1; then
	exit 0
fi

UDC=$(ls /sys/class/udc 2>/dev/null | head -1)

# Unbind the gadget before re-shaping its functions.
echo "" > "$G/UDC" 2>/dev/null || true

# Drop every network function symlink from the config (rndis/ecm/...), keep acm.
for link in "$CFG"/*.usb0; do
	[ -e "$link" ] || continue
	case "$(basename "$link")" in
		acm.usb0) : ;;
		*) rm "$link" ;;
	esac
done

# Create + link the ACM function if it isn't there yet.
[ -d "$G/functions/acm.usb0" ] || mkdir "$G/functions/acm.usb0"
[ -e "$CFG/acm.usb0" ] || ln -s "$G/functions/acm.usb0" "$CFG/"

# Re-bind to the UDC so the host re-enumerates us as a serial device.
[ -n "$UDC" ] && echo "$UDC" > "$G/UDC"
