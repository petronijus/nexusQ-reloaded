#!/bin/sh
# The real-world check for device r128: run it over WiFi, then pull the USB
# cable. It waits for the carrier to drop, lets the ttyGS0 getty restart, and
# then does what used to hang PID 1 -- the HDMI desktop stopping and starting,
# getty@tty1 restarting -- probing PID 1 throughout.
# If PID 1 stays silent for 90 s it syncs and reboots, so nobody has to plug
# the cable back in to rescue it.
#   setsid nohup sh cable-pull-test.sh </dev/null >/dev/null 2>&1 &
OUT=/root/hang
mkdir -p $OUT
LOG=$OUT/cable-pull.log
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
silent=0
step() { # step NAME COMMAND: run it in the background, probe PID 1 for 45 s
	log "step: $1"
	(timeout 120 sh -c "$2" >/dev/null 2>&1 &)
	t=0
	while [ $t -lt 45 ]; do
		sleep 3
		t=$((t + 3))
		if probe; then
			silent=0
		else
			silent=$((silent + 3))
			log "  PID 1 SILENT at ${t}s (wchan $(cat /proc/1/wchan)); console lock: $(console_lock)"
			if [ $silent -ge 90 ]; then
				log "  silent 90 s: sync and reboot"
				dmesg >$OUT/cable-pull.dmesg
				sync
				echo s >/proc/sysrq-trigger
				sleep 3
				echo b >/proc/sysrq-trigger
			fi
		fi
	done
	log "  done: tinydm=$(timeout 5 systemctl is-active tinydm) PID 1 $(probe && echo answers || echo SILENT)"
}

log "TTYReset on ttyGS0: $(systemctl show -p TTYReset serial-getty@ttyGS0.service)"
log "waiting for the USB carrier to drop (pull the cable)"
until [ "$(cat /sys/class/net/usb0/carrier 2>/dev/null)" = 0 ]; do sleep 1; done
log "carrier down"
sleep 10
log "ttyGS0 getty: $(systemctl show -p NRestarts -p SubState serial-getty@ttyGS0.service | tr '\n' ' ')"
log "console lock: $(console_lock)"

step "stop the desktop" "systemctl stop tinydm"
step "start the desktop" "systemctl start tinydm"
log "  session: $(grep nexusq-desktop-session /home/user/.local/state/tinydm.log | tail -1)"
step "restart getty@tty1" "systemctl restart getty@tty1.service"
step "stop the desktop again" "systemctl stop tinydm"
step "start the desktop again" "systemctl start tinydm"
log "  session: $(grep nexusq-desktop-session /home/user/.local/state/tinydm.log | tail -1)"
log "finished"
