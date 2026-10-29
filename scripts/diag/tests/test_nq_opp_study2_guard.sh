#!/usr/bin/env bash
# Host tests for nq-opp-study2.sh: the playback guard, GPU=1 capture, and that a
# counter planted mid-window comes out of analyze-gpu-window.py.
#
# What is protected. The guard is the only thing that keeps a window with music
# in it from being reported as an idle baseline, and it has been wrong twice:
# until 2026-08-24 it could never fire (wrong cgroup tree), and from then until
# 2026-10-11 it fired on every start (it tested "is a player unit running", and
# librespot always is). It now reads the ALSA substreams. The GPU protocol's
# numbers are deltas of kernel counters; a sampler that silently drops one, or
# an analyser that reads the wrong field, produces a clean-looking verdict about
# nothing. So every case below runs the real script against a fake /sys + /proc
# (NQ_SYS / NQ_PROC) and changes something while the window is open.
#
# Seen failing (2026-10-11): with `playing` forced to return 1 the four guard
# cases go red; with gpu_snap's gfx_rpm block removed the planted-counter case
# goes red.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
STUDY="$HERE/../nq-opp-study2.sh"
ANALYZE="$HERE/../analyze-gpu-window.py"
PASS=0
FAIL=0
TMP="$(mktemp -d "${TMPDIR:-/tmp}/nq-study-test.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

ok() { PASS=$((PASS + 1)); printf '  \033[32mPASS\033[0m  %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  \033[31mFAIL\033[0m  %s\n' "$1"; [ -n "${2:-}" ] && sed 's/^/        /' "$2" | tail -n 15; }

# fake_tree DIR: a Q at rest — speaker sink closed, USB host not streaming
fake_tree() {
    local r=$1 s p
    s=$r/sys p=$r/proc
    mkdir -p "$s/devices/system/cpu/cpufreq/policy0/stats" "$s/devices/system/cpu/cpufreq/conservative" \
        "$s/class/thermal/thermal_zone0" "$s/class/hwmon/hwmon0" \
        "$s/bus/platform/devices/5600fe00.target-module/power" \
        "$s/kernel/debug/pm_genpd/prm_gfx" "$s/kernel/debug/pm_debug" \
        "$p/asound/card1/pcm0p/sub0" "$p/asound/card4/pcm0c/sub0" "$p/asound/card0/pcm0p/sub0" \
        "$p/sys/kernel" "$r/bin"
    for c in 0 1; do
        for st in 0 1 2; do
            mkdir -p "$s/devices/system/cpu/cpu$c/cpuidle/state$st"
            echo $((1000 * (st + 1))) >"$s/devices/system/cpu/cpu$c/cpuidle/state$st/usage"
            echo $((100000 * (st + 1))) >"$s/devices/system/cpu/cpu$c/cpuidle/state$st/time"
            echo "C$((st + 1))" >"$s/devices/system/cpu/cpu$c/cpuidle/state$st/name"
        done
    done
    local f=$s/devices/system/cpu/cpufreq/policy0
    echo conservative >"$f/scaling_governor"
    printf '350000 1000\n700000 10\n920000 1\n1200000 1\n' >"$f/stats/time_in_state"
    echo 100 >"$f/stats/total_trans"
    printf '   From  :    To\n         :    350000    700000\n   350000:         0        50\n   700000:        50         0\n' \
        >"$f/stats/trans_table"
    echo 80 >"$s/devices/system/cpu/cpufreq/conservative/up_threshold"
    echo 67000 >"$s/class/thermal/thermal_zone0/temp"
    echo tmp101 >"$s/class/hwmon/hwmon0/name"
    echo 45000 >"$s/class/hwmon/hwmon0/temp1_input"
    local g=$s/bus/platform/devices/5600fe00.target-module/power
    echo suspended >"$g/runtime_status"
    echo 3 >"$g/runtime_active_time"
    echo 1623245 >"$g/runtime_suspended_time"
    echo off-0 >"$s/kernel/debug/pm_genpd/prm_gfx/current_state"
    echo "5 ms" >"$s/kernel/debug/pm_genpd/prm_gfx/active_time"
    echo "1624502 ms" >"$s/kernel/debug/pm_genpd/prm_gfx/total_idle_time"
    printf 'mpu_pwrdm (ON),OFF:0,RET:250756,INA:11462,ON:262219\ngfx_pwrdm (OFF),OFF:3,RET:0,INA:0,ON:2\n' \
        >"$s/kernel/debug/pm_debug/count"
    printf 'mpu_pwrdm (ON),OFF:0,RET:8215,INA:229,ON:7800\ngfx_pwrdm (OFF),OFF:16233,RET:0,INA:0,ON:11\n' \
        >"$s/kernel/debug/pm_debug/time"
    echo "1527.05 2419.23" >"$p/uptime"
    printf 'cpu  100 0 50 10000 5 1 2 0 0 0\ncpu0 50 0 25 5000 2 1 1 0 0 0\nctxt 5000\nprocesses 300\n' >"$p/stat"
    printf '           CPU0       CPU1       \n 24:     170736     113220 GIC-0  29 Edge      twd\n159:     102237          0    WUGEN  92 Level     musb-hdrc.0.auto\nIPI2:      8472      41433  Rescheduling interrupts\n' \
        >"$p/interrupts"
    printf '                    CPU0       CPU1       \n          HI:          0          1\n       TIMER:      39167      88770\n' \
        >"$p/softirqs"
    echo "0.10 0.12 0.10 1/90 1000" >"$p/loadavg"
    echo steelhead >"$p/sys/kernel/hostname"
    echo Loopback >"$p/asound/card0/id"
    echo NexusQSpeaker >"$p/asound/card1/id"
    echo UAC2Gadget >"$p/asound/card4/id"
    echo closed >"$p/asound/card0/pcm0p/sub0/status"
    echo closed >"$p/asound/card1/pcm0p/sub0/status"
    echo closed >"$p/asound/card4/pcm0c/sub0/status"
    printf '[    0.000000] Booting Linux on physical CPU 0x0\n[    1.0] omap-mcbsp 40124000.mcbsp: McBSP2 ready\n' >"$r/dmesg.txt"
    # a module for the vermagic read to find, under the kernel this host runs
    mkdir -p "$r/modules/$(uname -r)/kernel/a/b" && : >"$r/modules/$(uname -r)/kernel/a/b/x.ko"
    # host stand-ins for the device's tools
    printf '#!/bin/sh\ncat "%s"\n' "$r/dmesg.txt" >"$r/bin/dmesg"
    printf '#!/bin/sh\necho "6.18.48-r21 SMP mod_unload modversions ARMv7 p2v8 "\n' >"$r/bin/modinfo"
    printf '#!/bin/sh\necho "multi-user.target reached after 20.717s in userspace."\n' >"$r/bin/systemd-analyze"
    printf '#!/bin/sh\necho "PASS  host        steelhead"\necho "FAIL  gpu_driver  no driver bound"\nexit 1\n' >"$r/probe.sh"
    chmod +x "$r/bin/"*
}

# run_study DIR [VAR=value ...]: one 4 s arm, guard every second, in the background
run_study() {
    local r=$1
    shift
    env PATH="$r/bin:$PATH" NQ_SYS="$r/sys" NQ_PROC="$r/proc" NQ_MODULES="$r/modules" OUT="$r/out" GPU_PROBE="$r/probe.sh" \
        SETTLE_S=1 PRE_S=0 ARM_S=4 GUARD_S=1 GPU=1 "$@" sh "$STUDY" 'T:-:-:-:-:-:none' &
    STUDY_PID=$!
    # the fake /proc/uptime ticks with the wall clock while the study runs
    (
        t0=$(date +%s.%N)
        while kill -0 "$STUDY_PID" 2>/dev/null; do
            awk -v a="$t0" -v b="$(date +%s.%N)" 'BEGIN { printf "%.2f 0.00\n", 1527 + b - a }' >"$r/proc/uptime.new"
            mv "$r/proc/uptime.new" "$r/proc/uptime"
            sleep 0.2
        done
    ) &
}

live() { echo "state: RUNNING" >"$1"; }

# window_open DIR: block until the study's first (pre) snapshot is complete, i.e.
# the window is open and a change made now falls inside it. A fixed sleep cannot
# say that: how long the study takes to get there depends on the shell running it
# (bash 3.2 as `sh` spends a second probing `read -t`, dash does not).
window_open() {
    for _ in $(seq 1 100); do
        grep -q '^first ' "$1/out/arm_T_pre.snap" 2>/dev/null && return 0
        sleep 0.1
    done
    echo "window_open: no complete pre snapshot in $1/out after 10 s" >&2
}

echo "=== guard ==="

r=$TMP/idle; fake_tree "$r"; run_study "$r"; wait "$STUDY_PID"
if [ ! -e "$r/out/ABORTED" ] && [ -s "$r/out/arm_T_post.snap" ]; then ok "a quiet box: the window runs to the end"; else bad "a quiet box: the window runs to the end" "$r/out/run.log"; fi

r=$TMP/play; fake_tree "$r"; run_study "$r"; window_open "$r"; live "$r/proc/asound/card1/pcm0p/sub0/status"; wait "$STUDY_PID"
if grep -q '^aborted:playback' "$r/out/ABORTED" 2>/dev/null && [ ! -e "$r/out/arm_T_post.snap" ]; then
    ok "speaker playback starting mid-window aborts it"
else bad "speaker playback starting mid-window aborts it" "$r/out/run.log"; fi

r=$TMP/usb; fake_tree "$r"; live "$r/proc/asound/card4/pcm0c/sub0/status"; run_study "$r"; wait "$STUDY_PID"
if grep -q '^aborted-at-start:usb-in' "$r/out/ABORTED" 2>/dev/null; then ok "a streaming USB host refuses an idle window"; else bad "a streaming USB host refuses an idle window" "$r/out/run.log"; fi

r=$TMP/usbok; fake_tree "$r"; live "$r/proc/asound/card4/pcm0c/sub0/status"
run_study "$r" ALLOW_UNITS=nexusq-uac2-in.service; wait "$STUDY_PID"
if [ ! -e "$r/out/ABORTED" ] && grep -q 'ALLOW_UNITS (deliberately live during this run): nexusq-uac2-in.service' "$r/out/run.log" \
    && grep -q '^@audio playback=0 usb-in=1 roon-loop=0' "$r/out/arm_T_post.snap"; then
    ok "ALLOW_UNITS lets the USB stream run, and both run.log and the snapshot say so"
else bad "ALLOW_UNITS lets the USB stream run, and both run.log and the snapshot say so" "$r/out/run.log"; fi

r=$TMP/usbstop; fake_tree "$r"; live "$r/proc/asound/card4/pcm0c/sub0/status"
run_study "$r" ALLOW_UNITS=nexusq-uac2-in.service; window_open "$r"; echo closed >"$r/proc/asound/card4/pcm0c/sub0/status"; wait "$STUDY_PID"
if grep -q 'allowed path changed' "$r/out/ABORTED" 2>/dev/null; then ok "an allowed path that stops mid-window aborts too"; else bad "an allowed path that stops mid-window aborts too" "$r/out/run.log"; fi

r=$TMP/usbplay; fake_tree "$r"; live "$r/proc/asound/card4/pcm0c/sub0/status"
run_study "$r" ALLOW_UNITS=nexusq-uac2-in.service; window_open "$r"; live "$r/proc/asound/card1/pcm0p/sub0/status"; wait "$STUDY_PID"
if grep -q '^aborted:playback' "$r/out/ABORTED" 2>/dev/null; then ok "allowing USB does not allow the speaker"; else bad "allowing USB does not allow the speaker" "$r/out/run.log"; fi

echo "=== GPU=1 capture ==="

r=$TMP/plant; fake_tree "$r"; run_study "$r"; window_open "$r"
echo 903 >"$r/sys/bus/platform/devices/5600fe00.target-module/power/runtime_active_time"
echo "[ 2000.1] BUG: sleeping function called from invalid context at kernel/x.c:1" >>"$r/dmesg.txt"
echo "[ 2000.2] davinci-mcasp: XRUN on playback" >>"$r/dmesg.txt"
wait "$STUDY_PID"
post=$r/out/arm_T_post.snap
missing=""
for sec in @wall @pm_debug_count @pm_debug_time @gfx_rpm @genpd_prm_gfx @hwmon @dmesg_counts @audio @cpuidle @interrupts @softirqs @proc_stat; do
    grep -q "^$sec" "$post" 2>/dev/null || missing="$missing $sec"
done
if [ -z "$missing" ]; then ok "every GPU item is in the snapshot"; else bad "every GPU item is in the snapshot (missing:$missing)" "$r/out/run.log"; fi
for sec in @uname @vermagic @boot @gpu_probe @gpu_probe_exit @dmesg; do
    grep -q "^$sec" "$r/out/arm_T_pre.edge" 2>/dev/null || missing="$missing $sec"
done
if [ -z "$missing" ] && grep -q 'FAIL  gpu_driver' "$r/out/arm_T_post.edge"; then ok "both edge files carry identity, boot time, probe and dmesg"; else bad "edge files (missing:$missing)" "$r/out/run.log"; fi
if [ "$(wc -l <"$r/out/thermal_1hz.log")" -ge 3 ]; then ok "the 1 Hz thermal logger ran"; else bad "the 1 Hz thermal logger ran" "$r/out/run.log"; fi
tpid=$(sed -n 's/^=== thermal logger pid \([0-9]*\).*/\1/p' "$r/out/run.log")
sleep 1.5
if [ -n "$tpid" ] && ! kill -0 "$tpid" 2>/dev/null; then ok "the thermal logger died with the study"; else bad "the thermal logger died with the study (pid '$tpid')" "$r/out/run.log"; fi

json=$(python3 "$ANALYZE" summary "$r/out" --json 2>"$TMP/an.err")
check_json() { # check_json <python expr over w> <description>
    if python3 -c "import json,sys; w=json.loads(sys.argv[1]); sys.exit(0 if ($1) else 1)" "$json" 2>/dev/null; then ok "$2"; else bad "$2" "$TMP/an.err"; fi
}
check_json "w['gfx_rpm_active_ms'] == 900" "a planted GFX runtime-PM change shows up (900 ms)"
check_json "w['dmesg']['sleeping_in_atomic'] == 1 and w['dmesg']['audio_err'] == 1" "planted dmesg lines show up as deltas"
check_json "w['vermagic'].startswith('6.18.48-r21') and w['boot_multi_user_userspace_s'] == 20.717" "vermagic and boot time are read"

base=$TMP/idle/out
if python3 "$ANALYZE" compare --arm a1 "$base" --test "$r/out" >"$TMP/cmp.out" 2>&1; then
    bad "A1 verdict on the planted window is FAIL" "$TMP/cmp.out"
elif grep -q 'FAIL  GFX active' "$TMP/cmp.out" && grep -q 'FAIL  dmesg sleeping_in_atomic' "$TMP/cmp.out"; then
    ok "A1 verdict on the planted window is FAIL, for GFX and the atomic-sleep splat"
else bad "A1 verdict names the planted causes" "$TMP/cmp.out"; fi
if python3 "$ANALYZE" compare --arm a1 "$base" --test "$TMP/usbok/out" >"$TMP/cmp2.out" 2>&1; then
    bad "windows with different audio states are not comparable" "$TMP/cmp2.out"
elif grep -q 'FAIL  same audio state' "$TMP/cmp2.out"; then ok "windows with different audio states are not comparable"
else bad "windows with different audio states are not comparable" "$TMP/cmp2.out"; fi

echo "=== dmesg_counts (extracted by its TESTABLE marker) ==="
eval "$(sed -n '/^# TESTABLE:dmesg_counts/,/^}/p' "$STUDY")"
got=$(printf '%s\n' '[ 1.0] booting' \
    '[ 5.1] davinci-mcasp 40128000.mcasp: XRUN!' \
    '[ 6.2] BUG: scheduling while atomic: kworker/0:1/12/0x00000002' \
    '[ 7.3] BUG: using smp_processor_id() in preemptible [00000000] code: x/1' \
    '[ 8.4] rcu: INFO: rcu_preempt detected stalls on CPUs/tasks:' \
    '[ 9.5] rcu: INFO: rcu_sched detected stalls on CPUs/tasks:' | dmesg_counts | tr '\n' ' ')
want='audio_err 1 sleeping_in_atomic 0 smp_processor_id_preemptible 1 scheduling_while_atomic 1 rcu_stall 2 kernel_warn 2 lines 6 first [ 1.0] '
if [ "$got" = "$want" ]; then ok "known XRUN / B.8 lines are counted"; else bad "known XRUN / B.8 lines are counted: got [$got]"; fi

echo "=== $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
