#!/bin/sh
# nq-deep-idle-ladder.sh -- run ONE rung of the R2 deep-idle experiment ON the Q.
#
# See docs/2026-09-20-sleep-states-design.md §4m/§4n for why every step here
# exists. In short, C2 is only actually selectable on a running box when ALL of
# these hold:
#   * the Bluetooth UART is released -- while hci_uart_bcm holds it open,
#     8250_omap pins a 170 us CPU-latency QoS request (3 Mbaud) and menu/teo can
#     never pick C2 (768 us exit) or C3 (978 us);
#   * the per-state sysfs `disable` is 0 on both CPUs -- CPUIDLE_FLAG_OFF sets the
#     USER bit, so that file is the real switch (0048 rev 1's deep_idle knob
#     toggled the DRIVER bit instead; it is gone in r8).
#
# A hang is expected on some rungs. The hardware watchdog (omap_wdt WDT2) is
# armed through systemd for the duration, non-persistently: a hang becomes a warm
# reset ~50 s later, the unit boots back to defaults, and ramoops survives in
# /var/lib/systemd/pstore/console-ramoops-0 (console loglevel is raised to 8 so
# pr_info lines land in it too).
#
# usage (as root on the device):
#   nq-deep-idle-ladder.sh <skip_cpu1_wait> <keep_mpu_on> <skip_lowpower> [seconds] [cpu1_offline] [keep_core_on]
#
# keep_core_on needs kernel >= 6.18.48-r8 (patch 0048 rev 2); on r7 the
# parameter does not exist and the script refuses a non-zero value.
#
# Rungs run on 2026-09-22 (kernel 6.18.48-r7):
#   T1  1 1 1        -> 4969 C2 entries / 60 s, fine
#   T2  1 1 0        -> hang
#   T3  0 1 0        -> hang
#   T3b 0 1 0 60 1   -> hang
# NOTE: on r7 keep_mpu_on does NOT hold mpu_pwrdm ON (it only skips
# re-programming; pwrdms_setup armed MPU/CORE for RET at boot), so T2-T3b were
# not clean CPU-OFF tests. r8 fixes that (0048 rev 2, §4n).
set -u

P=/sys/module/cpuidle44xx/parameters
C2="/sys/devices/system/cpu/cpu0/cpuidle/state1 /sys/devices/system/cpu/cpu1/cpuidle/state1"
BT=/sys/bus/serial/drivers/hci_uart_bcm

[ $# -ge 3 ] || { sed -n '2,36p' "$0"; exit 2; }
SKIP_WAIT=$1 KEEP_MPU=$2 SKIP_LP=$3 SECS=${4:-60} CPU1_OFF=${5:-0} KEEP_CORE=${6:-0}

hostname
[ "$(hostname)" = steelhead ] || { echo "not the Q -- refusing" >&2; exit 1; }

qos() { python3 -c 'import struct;print(struct.unpack("i",open("/dev/cpu_dma_latency","rb").read(4))[0])'; }
c2() { for s in $C2; do [ -d "$s" ] && printf '%s usage=%s time=%s  ' "${s#/sys/devices/system/cpu/}" "$(cat $s/usage)" "$(cat $s/time)"; done; echo; }

busctl set-property org.freedesktop.systemd1 /org/freedesktop/systemd1 \
	org.freedesktop.systemd1.Manager RuntimeWatchdogUSec t 30000000
systemctl show -p RuntimeWatchdogUSec
dmesg -n 8

[ -e $BT/serial0-0 ] && echo serial0-0 > $BT/unbind
[ "$CPU1_OFF" = 1 ] && echo 0 > /sys/devices/system/cpu/cpu1/online
sleep 2
echo "qos=$(qos) us  online=$(cat /sys/devices/system/cpu/online)"

echo "$SKIP_WAIT" > $P/skip_cpu1_wait
echo "$KEEP_MPU"  > $P/keep_mpu_on
echo "$SKIP_LP"   > $P/skip_lowpower
if [ -e $P/keep_core_on ]; then
	echo "$KEEP_CORE" > $P/keep_core_on
elif [ "$KEEP_CORE" != 0 ]; then
	echo "keep_core_on needs kernel r8 or later" >&2; exit 1
fi
grep -H . $P/*
grep -E '^(mpu|core|cpu0|cpu1)_pwrdm' /sys/kernel/debug/pm_debug/count
c2

echo "ARM at $(date +%T)"
for s in $C2; do [ -d "$s" ] && echo 0 > $s/disable; done
i=0
while [ $i -lt "$SECS" ]; do sleep 10; i=$((i + 10)); echo "t+$i"; c2; done

for s in $C2; do [ -d "$s" ] && echo 1 > $s/disable; done
echo "DISARMED at $(date +%T)"
grep -E '^(mpu|core|cpu0|cpu1)_pwrdm' /sys/kernel/debug/pm_debug/count

echo 0 > $P/skip_cpu1_wait; echo 0 > $P/keep_mpu_on; echo 0 > $P/skip_lowpower
[ -e $P/keep_core_on ] && echo 0 > $P/keep_core_on
[ "$CPU1_OFF" = 1 ] && echo 1 > /sys/devices/system/cpu/cpu1/online
echo serial0-0 > $BT/bind
dmesg -n 4
busctl set-property org.freedesktop.systemd1 /org/freedesktop/systemd1 \
	org.freedesktop.systemd1.Manager RuntimeWatchdogUSec t 0
echo "restored: qos=$(qos) us, watchdog off, knobs off"
