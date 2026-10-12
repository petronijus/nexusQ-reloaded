#!/bin/sh
# Run one action and watch PID 1 while it runs (stall-and-panic-2026-10-12.md).
#   setsid nohup taskset -c 0 sh stall-watch.sh NAME 'COMMAND' </dev/null >/dev/null 2>&1 &
# COMMAND runs in the background under `timeout 300`. Every 6 s a bounded
# D-Bus ping tells whether PID 1 answers. On a stall: SysRq w once, the wchan,
# syscall and state of every thread at 6/12/24/48 s and every minute, and at
# 60 s C3 is disabled on both CPUs to see whether that ends it. Results in
# /root/hang/NAME.log and NAME.dmesg. Bounded to 7 minutes.
NAME=${1:?name}
CMD=${2:?command}
OUT=/root/hang
mkdir -p $OUT
LOG=$OUT/$NAME.log
: >"$LOG"
log() { echo "$(cut -d' ' -f1 /proc/uptime) $*" >>"$LOG"; }

# stat fields after the comm (which may hold spaces): state ppid ...
stat_tail() { sed 's/^.*) //' "$1/stat" 2>/dev/null; }
threads() {
	log "-- threads ($1)"
	for t in /proc/[0-9]*/task/[0-9]*; do
		# shellcheck disable=SC2046 # split the stat fields on purpose
		set -- $(stat_tail "$t")
		st=$1 ppid=$2
		[ -n "$st" ] || continue
		w=$(cat "$t/wchan" 2>/dev/null)
		# Children of PID 1 always (its executor children hold its locks),
		# everything else unless it sleeps in a plain event loop.
		if [ "$ppid" != 1 ]; then
			case "$st:$w" in
			S:do_epoll_wait | S:do_sys_poll | S:do_select | S:hrtimer_nanosleep | S:futex_wait_queue | S:futex_do_wait | S:poll_schedule_timeout.constprop.0 | S:do_sigtimedwait | I:* | S:kthread_worker_fn | S:smpboot_thread_fn | S:worker_thread | S:rescuer_thread | S:rcu_gp_kthread | S:kthreadd | S:pipe_read | S:anon_pipe_read | S:unix_stream_read_generic | S:do_wait | S:sigsuspend | S:irq_thread | S:psi_rtpoll_worker | S:kjournald2) continue ;;
			esac
		fi
		p=${t#/proc/}
		log "   ${p%%/*}/${t##*/} $st ppid=$ppid sc=$(cut -d' ' -f1 "$t/syscall" 2>/dev/null) ${w:--} $(cat "$t/comm")"
	done
	log "   pid1: $(cut -d' ' -f3 /proc/1/stat) $(cat /proc/1/wchan) syscall $(cut -d' ' -f1-3 /proc/1/syscall)"
	locks
}
# Who holds which lock, and who has the console and tty1 open.
locks() {
	log "-- /proc/locks (console $(stat -c '%t:%T %i' /dev/console), tty1 $(stat -c '%t:%T %i' /dev/tty1))"
	sed 's/^/     /' /proc/locks >>"$LOG"
	for f in /proc/[0-9]*/fd/*; do
		case $(readlink "$f" 2>/dev/null) in
		/dev/console | /dev/tty1 | /dev/tty0 | /dev/tty) p=${f#/proc/} && log "     open: pid ${p%%/*} fd ${f##*/} -> $(readlink "$f") $(cat /proc/${p%%/*}/comm)" ;;
		esac
	done
}
idle() { for c in 0 1; do
	u=""
	for s in /sys/devices/system/cpu/cpu"$c"/cpuidle/state*; do u="$u $(cat "$s/usage")"; done
	log "   cpu$c idle$u"
done; }
probe_pid1() {
	rm -f $OUT/pid1.rc
	(
		timeout 5 busctl call org.freedesktop.systemd1 /org/freedesktop/systemd1 \
			org.freedesktop.DBus.Peer Ping >/dev/null 2>&1
		echo $? >$OUT/pid1.rc
	) &
}
pid1_ok() { [ "$(cat $OUT/pid1.rc 2>/dev/null)" = 0 ]; }

log "action: $CMD"
(timeout 300 sh -c "$CMD" >/dev/null 2>&1 &)
t=0
stalled=""
kicked=""
while [ "$t" -lt 420 ]; do
	probe_pid1
	sleep 6
	t=$((t + 6))
	if pid1_ok; then
		[ -n "$stalled" ] && {
			log "PID 1 answers again at ${t}s"
			threads recovered
			break
		}
		[ "$t" -ge 60 ] && { log "PID 1 answered throughout (60 s)"; break; }
		continue
	fi
	if [ -z "$stalled" ]; then
		stalled=$t
		log "STALL: PID 1 silent at ${t}s"
		echo w >/proc/sysrq-trigger
	fi
	case $t in 6 | 12 | 24 | 48)
		threads "t=${t}s"
		log "   (threads done)"
		idle
		log "   (idle done)"
		;;
	esac
	if [ "$t" -ge 60 ] && [ -z "$kicked" ]; then
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
dmesg >"$OUT/$NAME.dmesg"
log "done"
