#!/bin/sh
# Reproduce the PID 1 stall without touching a cable, and rescue it without a
# hand (stall-and-panic-2026-10-12.md). Unbinding the gadget from its UDC is a
# cable pull as far as u_serial is concerned (no bound port: ttyGS0 takes no
# byte), so the ttyGS0 getty is hung up and restarted. Then getty@tty1 is
# restarted, which needs the /dev/console lock in PID 1 (its TTY reset).
# Rebinding the UDC is the rescue (the cable is still in a host); if PID 1 is
# still silent 60 s later the unit syncs and reboots by itself.
#   setsid nohup sh gadget-detach-test.sh NAME ['TRIGGER'] </dev/null >/dev/null 2>&1 &
# TRIGGER defaults to restarting getty@tty1; 'systemctl start tinydm' is the
# real-world case (the HDMI desktop).
NAME=${1:-detach}
TRIGGER=${2:-systemctl restart getty@tty1.service}
OUT=/root/hang
mkdir -p $OUT
LOG=$OUT/$NAME.log
: >"$LOG"
log() { echo "$(cut -d' ' -f1 /proc/uptime) $*" >>"$LOG"; }
probe() {
	timeout 5 busctl call org.freedesktop.systemd1 /org/freedesktop/systemd1 \
		org.freedesktop.DBus.Peer Ping >/dev/null 2>&1
}
console_lock() {
	ino=$(stat -c %i /dev/console)
	grep -E " 00:06:$ino " /proc/locks | while read -r _ _ _ mode pid _; do
		echo "$mode by $pid $(cat /proc/"$pid"/comm 2>/dev/null) $(cat /proc/"$pid"/wchan 2>/dev/null)"
	done
}

UDCF=$(ls /sys/kernel/config/usb_gadget/*/UDC | head -1)
UDC=$(cat "$UDCF")
log "gadget $UDCF bound to '$UDC'; drop-in: $(systemctl show -p TTYReset serial-getty@ttyGS0.service)"
[ -n "$UDC" ] || { log "no UDC bound, nothing to test"; exit 1; }
probe && log "PID 1 answers" || { log "PID 1 silent before the test, abort"; exit 1; }

log "unbind the UDC (= cable pull)"
echo "" >"$UDCF"
sleep 8
log "ttyGS0 getty: $(systemctl show -p NRestarts -p SubState serial-getty@ttyGS0.service | tr '\n' ' ')"
log "console lock: $(console_lock)"

log "trigger: $TRIGGER (a TTY reset in PID 1)"
(timeout 120 sh -c "$TRIGGER" >/dev/null 2>&1 &)
stalled=""
t=0
while [ $t -lt 30 ]; do
	sleep 3
	t=$((t + 3))
	if probe; then
		log "PID 1 answers at ${t}s"
	else
		stalled=1
		log "PID 1 SILENT at ${t}s (pid1 wchan $(cat /proc/1/wchan)); console lock: $(console_lock)"
	fi
done

log "rebind the UDC to '$UDC' (= cable back)"
echo "$UDC" >"$UDCF"
t=0
while [ $t -lt 60 ]; do
	sleep 3
	t=$((t + 3))
	if probe; then
		log "PID 1 answers ${t}s after the rebind; stalled before: ${stalled:-no}"
		log "done"
		exit 0
	fi
done
log "PID 1 still silent 60 s after the rebind: sync and reboot"
dmesg >"$OUT/$NAME.dmesg"
sync
echo s >/proc/sysrq-trigger
sleep 3
echo b >/proc/sysrq-trigger
