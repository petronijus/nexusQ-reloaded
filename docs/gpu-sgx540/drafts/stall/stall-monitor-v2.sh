#!/bin/sh
# Second measurement of the SGX bring-up stall (stall-and-panic-2026-10-12.md).
# Run once per boot of a GPU kernel, desktop off, USB unplugged, pinned to CPU0:
#   setsid nohup taskset -c 0 sh stall-monitor-v2.sh </dev/null >/dev/null 2>&1 &
# Run 1 showed that /proc/<pid>/stack is empty for other tasks on ARM SMP, so
# this one records wchan, the current syscall and the state of every thread.
# It loads the module itself (not through systemd), so it shows whether PID 1
# stops answering even when it plays no part in the load. After 60 s of stall
# it disables C3 on both CPUs, to see whether that ends the stall the way a USB
# carrier did. Nothing here calls PID 1 synchronously; every probe is bounded.
OUT=/root/hang
mkdir -p $OUT
LOG=$OUT/stall2.log
: >$LOG
log() { echo "$(cut -d' ' -f1 /proc/uptime) $*" >>$LOG; }

# One line per thread outside the plain event-loop sleeps; zombies always.
threads() {
	log "-- threads ($1)"
	for t in /proc/[0-9]*/task/[0-9]*; do
		st=$(cut -d' ' -f3 $t/stat 2>/dev/null) || continue
		w=$(cat $t/wchan 2>/dev/null)
		case "$st:$w" in
		S:do_epoll_wait | S:do_sys_poll | S:do_select | S:hrtimer_nanosleep | S:futex_wait_queue | S:do_sigtimedwait | I:* | S:kthread_worker_fn | S:smpboot_thread_fn | S:worker_thread | S:rescuer_thread | S:rcu_gp_kthread | S:kthreadd | S:pipe_read | S:unix_stream_read_generic | S:wait_woken | S:do_wait | S:sigsuspend) ;;
		*)
			p=${t#/proc/}
			log "   ${p%%/*}/${t##*/} $st $(cut -d' ' -f4 $t/stat) $(cut -d' ' -f1 $t/syscall 2>/dev/null) ${w:--} $(cat $t/comm)"
			;;
		esac
	done
	log "   pid1: $(cut -d' ' -f3 /proc/1/stat) $(cat /proc/1/wchan) syscall $(cut -d' ' -f1-3 /proc/1/syscall)"
}

# Does PID 1 answer a D-Bus call within 5 s? Run in the background, read later.
probe_pid1() {
	rm -f $OUT/pid1.rc
	(
		timeout 5 busctl call org.freedesktop.systemd1 /org/freedesktop/systemd1 \
			org.freedesktop.DBus.Peer Ping >/dev/null 2>&1
		echo $? >$OUT/pid1.rc
	) &
}
pid1_ok() { [ "$(cat $OUT/pid1.rc 2>/dev/null)" = 0 ]; }

idle() { for c in 0 1; do
	u=""
	for s in /sys/devices/system/cpu/cpu$c/cpuidle/state*; do u="$u $(cat $s/usage)"; done
	log "   cpu$c idle$u"
done; }

log "idle 20 s"
sleep 20
probe_pid1
sleep 6
pid1_ok && log "PID 1 answers before the load" || log "PID 1 does NOT answer before the load"

log "modprobe (direct)"
timeout 60 modprobe pvrsrvkm_omap4_sgx540_120
log "modprobe rc=$? "

t=0
stalled=""
kicked=""
while [ $t -lt 420 ]; do
	probe_pid1
	sleep 6
	t=$((t + 6))
	if pid1_ok; then
		log "PID 1 answers at ${t}s"
		[ -n "$stalled" ] && { threads recovered; break; }
		[ $t -ge 30 ] && break
		continue
	fi
	if [ -z "$stalled" ]; then
		stalled=$t
		log "STALL: PID 1 silent at ${t}s"
		echo w >/proc/sysrq-trigger
	fi
	case $t in 6 | 12 | 24 | 48) threads "t=${t}s"; idle ;; esac
	if [ $t -ge 60 ] && [ -z "$kicked" ]; then
		kicked=1
		threads "before kick"
		idle
		log "KICK: disable C3 on both CPUs"
		echo 1 >/sys/devices/system/cpu/cpu0/cpuidle/state2/disable
		echo 1 >/sys/devices/system/cpu/cpu1/cpuidle/state2/disable
	fi
	[ $((t % 60)) = 0 ] && threads "t=${t}s"
done
if [ -n "$kicked" ]; then
	echo 0 >/sys/devices/system/cpu/cpu0/cpuidle/state2/disable
	echo 0 >/sys/devices/system/cpu/cpu1/cpuidle/state2/disable
fi

# Phase 2, only when PID 1 is healthy: the service start (pvrsrvinit) the way
# the desktop does it, bounded.
if pid1_ok; then
	log "systemctl start nexusq-sgx (background, bounded)"
	(timeout 300 systemctl start nexusq-sgx.service >/dev/null 2>&1 &)
	ddk() { dmesg | grep -c 'UM DDK-(4948957) and KM DDK-(4948957) match'; }
	base=$(ddk)
	t=0
	while [ $t -lt 300 ]; do
		sleep 2
		t=$((t + 2))
		[ "$(ddk)" -gt "$base" ] && { log "SGX services up after ${t}s"; break; }
		case $t in 10 | 30 | 90 | 200) threads "service t=${t}s"; idle ;; esac
	done
fi
dmesg >$OUT/dmesg2.txt
log "done"
