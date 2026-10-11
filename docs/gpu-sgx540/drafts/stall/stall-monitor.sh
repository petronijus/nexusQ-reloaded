#!/bin/sh
# Next step for the SGX bring-up stall (docs/gpu-sgx540/stall-and-panic-2026-10-12.md).
# Run on the unit pinned to CPU0 (`setsid taskset -c 0 sh stall-monitor.sh &`),
# USB unplugged, desktop off. It starts the desktop the way the app does and,
# on a stall, records where PID 1, udev and pvrsrvinit are blocked. Nothing in
# its own loop talks to PID 1 synchronously: systemctl calls run in the
# background under `timeout`, so a hung PID 1 cannot stop the recording.
OUT=/root/hang
mkdir -p $OUT
LOG=$OUT/stall.log
: >$LOG
log() { echo "$(cut -d' ' -f1 /proc/uptime) $*" >>$LOG; }
stacks() {
	for p in /proc/[0-9]*; do
		c=$(tr '\0' ' ' <$p/cmdline 2>/dev/null)
		case $c in
		/sbin/init* | /usr/lib/systemd/systemd* | *systemd-udevd* | *pvrsrvinit* | *modprobe* | *systemd-logind* | *labwc*)
			log "== pid ${p#/proc/} st=$(cut -d' ' -f3 $p/stat) cpu$(cut -d' ' -f39 $p/stat) $c"
			sed 's/^/     /' $p/stack >>$LOG 2>/dev/null
			;;
		esac
	done
}

ddk_ok() { dmesg | grep -c 'UM DDK-(4948957) and KM DDK-(4948957) match'; }
base=$(ddk_ok)
log "idle 20 s, then start the desktop"
sleep 20
(timeout 600 systemctl start tinydm >/dev/null 2>&1 &)
t=0
while [ $t -lt 600 ]; do
	if [ "$(ddk_ok)" -gt "$base" ]; then
		log "SGX services up after ${t}s"
		break
	fi
	if [ $t = 20 ] || [ $t = 60 ] || [ $t = 180 ]; then
		log "STALL at ${t}s"
		stacks
		[ $t = 20 ] && { echo w >/proc/sysrq-trigger; echo l >/proc/sysrq-trigger; }
	fi
	sleep 2
	t=$((t + 2))
done
dmesg >$OUT/dmesg.txt
log "done"
