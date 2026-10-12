#!/bin/sh
# Does a write to the console UART get its serial-core port device resumed?
# (stall-and-panic-2026-10-12.md). Since 6.5 a uart write after >500 ms idle
# does not start TX directly: __uart_start() takes an async runtime-PM ref on
# the port device (48020000.serial:0.0), and serial_port_runtime_resume(),
# run from the per-CPU pm_wq, starts TX. This probe writes a short line to
# ttyS2 from CPU0 and from CPU1 in turn, after the port device has
# autosuspended, and records whether the resume ran. No PID 1 lock is held by
# this writer and every write is bounded, so a missed resume cannot stall the
# system. It only reads sysfs; it never opens /proc/tty/driver/*.
PD=/sys/bus/platform/devices/48020000.serial/48020000.serial:0/48020000.serial:0.0/power
N=${1:-20}
i=0
while [ "$i" -lt "$N" ]; do
	cpu=$((i % 2))
	sleep 2 # > the 500 ms autosuspend delay
	before=$(cat $PD/runtime_active_time)
	s0=$(cat $PD/runtime_status)
	timeout 5 taskset -c $cpu sh -c 'printf "nq-probe %s\r\n" "$1" >/dev/ttyS2' _ "$i"
	rc=$?
	s1=$(cat $PD/runtime_status)
	sleep 0.3
	s2=$(cat $PD/runtime_status)
	after=$(cat $PD/runtime_active_time)
	echo "i=$i cpu$cpu rc=$rc status $s0 -> $s1 -> $s2 active_ms +$((after - before))"
	i=$((i + 1))
done
