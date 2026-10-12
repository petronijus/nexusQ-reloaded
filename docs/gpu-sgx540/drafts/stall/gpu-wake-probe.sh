#!/bin/sh
# ttyS2-wake-probe.sh with the SGX driver loaded, self-rescuing
# (stall-and-panic-2026-10-12.md). Every stall so far had the GPU module
# loaded; without it 12/12 console writes got their port device resumed.
# Run detached:  setsid nohup sh gpu-wake-probe.sh </dev/null >/dev/null 2>&1 &
# On a missed resume it records SysRq t (tasks plus busy workqueues, to the
# log buffer only at loglevel 4), then tries rescues in order and logs which
# one ended it: a wakeup of CPU1, of CPU0, a synchronous resume through
# power/control=on. If none works within ~60 s it syncs and reboots, so the
# unit never needs a hand.
OUT=/root/hang
mkdir -p $OUT
LOG=$OUT/gpu-wake.log
: >$LOG
log() { echo "$(cut -d' ' -f1 /proc/uptime) $*" >>$LOG; }
PD=/sys/bus/platform/devices/48020000.serial/48020000.serial:0/48020000.serial:0.0/power
resumed() { [ "$(cat $PD/runtime_status)" = active ] || [ "$(cat $PD/runtime_active_time)" != "$1" ]; }

workers() {
	for t in /proc/[0-9]*; do
		case $(cat "$t/comm" 2>/dev/null) in
		kworker/* | pvr* | PVR*) log "   ${t#/proc/} $(sed 's/^.*) //' "$t/stat" | cut -d' ' -f1) $(cat "$t/wchan") $(cat "$t/comm")" ;;
		esac
	done
}

missed() {
	log "MISS at i=$1 (cpu$2): port device stayed suspended"
	echo t >/proc/sysrq-trigger
	workers
	for r in cpu1 cpu0 control; do
		case $r in
		cpu1) taskset -c 1 true ;;
		cpu0) taskset -c 0 true ;;
		control)
			(timeout 5 sh -c "echo on >$PD/control") &
			sleep 1
			;;
		esac
		sleep 3
		if [ "$(cat $PD/runtime_status)" = active ] || [ "$(cat $PD/runtime_active_time)" != "$3" ]; then
			log "RESCUED by $r"
			echo auto >$PD/control
			return 0
		fi
		log "   $r did not help"
	done
	echo auto >$PD/control
	log "nothing helped; waiting 50 s, then sync + reboot"
	sleep 50
	resumed "$3" && { log "resumed by itself"; return 0; }
	dmesg >$OUT/gpu-wake.dmesg
	sync
	echo s >/proc/sysrq-trigger
	sleep 3
	echo b >/proc/sysrq-trigger
}

log "load the GPU (nexusq-sgx.service)"
timeout 60 systemctl start nexusq-sgx.service
log "start rc=$? $(lsmod | grep -c pvrsrvkm) module(s)"
N=${1:-40}
i=0
while [ "$i" -lt "$N" ]; do
	cpu=$((i % 2))
	sleep 2
	before=$(cat $PD/runtime_active_time)
	timeout 5 taskset -c $cpu sh -c 'printf "nq-probe %s\r\n" "$1" >/dev/ttyS2' _ "$i"
	rc=$?
	sleep 1
	if resumed "$before"; then
		log "i=$i cpu$cpu rc=$rc ok"
	else
		missed "$i" "$cpu" "$before"
	fi
	i=$((i + 1))
done
dmesg >$OUT/gpu-wake.dmesg
log "done"
