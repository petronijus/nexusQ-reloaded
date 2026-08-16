#!/bin/sh
# nq-opp-study — why does an idle Nexus Q spend 22.6 % of its time at 700 MHz?
#
# Runs DETACHED (no ssh session open) because an open session heats the die to
# 74-79 C and drags the OPP up with it — the 2026-07-13 Finding 1 rule. Results
# are fetched ONCE, afterwards.
#
# Phase 1: ftrace event capture (60 s) — who wakes the CPU, and what runs
#          immediately before each power:cpu_frequency ramp.
# Phase 2: governor A/B — five arms, each measured from kernel time_in_state /
#          trans_table deltas, plus per-cgroup CPU, IRQ and softirq deltas.
#
# Read-only except for the cpufreq governor tunables it deliberately A/Bs; an
# EXIT trap restores the production settings on every exit path.
set -u

OUT=${OUT:-/var/log/nq-opp-study}
ARM_S=${ARM_S:-720}          # 12 min per arm
TRACE_S=${TRACE_S:-60}
SETTLE_S=${SETTLE_S:-90}     # let our own ssh logout drain before measuring
P=/sys/devices/system/cpu/cpufreq/policy0
G=/sys/devices/system/cpu/cpufreq/conservative
T=/sys/kernel/tracing

mkdir -p "$OUT"
exec >>"$OUT/run.log" 2>&1
echo "=== nq-opp-study start $(cat /proc/uptime)"

# ---- production settings, restored no matter how we exit --------------------
ORIG_GOV=$(cat $P/scaling_governor)
ORIG_SR=$(cat $G/sampling_rate 2>/dev/null)
ORIG_UP=$(cat $G/up_threshold 2>/dev/null)
ORIG_DOWN=$(cat $G/down_threshold 2>/dev/null)

restore() {
    echo "$ORIG_GOV" > $P/scaling_governor 2>/dev/null
    [ -n "$ORIG_SR" ] && echo "$ORIG_SR" > $G/sampling_rate 2>/dev/null
    [ -n "$ORIG_UP" ] && echo "$ORIG_UP" > $G/up_threshold 2>/dev/null
    [ -n "$ORIG_DOWN" ] && echo "$ORIG_DOWN" > $G/down_threshold 2>/dev/null
    echo 0 > $T/tracing_on 2>/dev/null
    echo nop > $T/current_tracer 2>/dev/null
    echo > $T/set_event 2>/dev/null
    echo 1408 > $T/buffer_size_kb 2>/dev/null
    echo "=== restored gov=$(cat $P/scaling_governor) sr=$(cat $G/sampling_rate 2>/dev/null) up=$(cat $G/up_threshold 2>/dev/null)"
}
trap 'restore; echo "=== exit $(cat /proc/uptime)"; exit' EXIT INT TERM

# ---- fork-free sleep: a fifo + read -t, the nq-healthd r71 trick ------------
FIFO=$OUT/.tick
[ -p "$FIFO" ] || mkfifo "$FIFO" 2>/dev/null
exec 9<>"$FIFO" 2>/dev/null
if read -t 1 _x <&9 2>/dev/null; [ $? -gt 1 ]; then
    echo "fifo tick unavailable, falling back to sleep (1 fork per nap)"
    napp() { sleep "$1"; }
else
    napp() { read -t "$1" _x <&9 2>/dev/null || :; }   # timeout = fork-free sleep
fi

# ---- playback guard --------------------------------------------------------
# If Petr starts listening mid-study the numbers are worthless AND an arm might
# be holding the CPU at 350 MHz under a real audio load. Abort, restore, leave a
# marker. One fork per 30 s, against a ~2.6 forks/s baseline.
UNITS="librespot.service shairport-sync.service roon.service nexusq-uac2-in.service"
playing() {
    for _u in $UNITS; do
        [ "$(systemctl is-active $_u 2>/dev/null)" = active ] && { echo "$_u"; return 0; }
    done
    return 1
}

# nap for $1 seconds in 30 s slices, aborting the whole study if playback starts
wait_idle() {
    _left=$1
    while [ "$_left" -gt 0 ]; do
        _step=30; [ "$_left" -lt 30 ] && _step=$_left
        napp "$_step"
        _left=$((_left - _step))
        if _u=$(playing); then
            echo "!!! ABORT: $_u went active - playback started, study invalid"
            echo "aborted:$_u" > "$OUT/ABORTED"
            exit 1
        fi
    done
}

# ---- one snapshot of every counter that matters, fork-free where possible ---
snap() {
    _f=$1
    {
        printf '@uptime %s\n' "$(cat /proc/uptime)"
        printf '@time_in_state\n'; cat $P/stats/time_in_state
        printf '@total_trans %s\n' "$(cat $P/stats/total_trans)"
        printf '@trans_table\n';   cat $P/stats/trans_table
        printf '@proc_stat\n';     grep -E '^(cpu|ctxt|processes|intr )' /proc/stat
        printf '@interrupts\n';    cat /proc/interrupts
        printf '@softirqs\n';      cat /proc/softirqs
        printf '@cpuidle\n'
        for s in /sys/devices/system/cpu/cpu*/cpuidle/state*; do
            printf '%s usage=%s time=%s\n' "$s" "$(cat $s/usage)" "$(cat $s/time)"
        done
        printf '@cgroups\n'
        for c in /sys/fs/cgroup/*.slice/*.service /sys/fs/cgroup/*.slice \
                 /sys/fs/cgroup/*.scope /sys/fs/cgroup; do
            [ -f "$c/cpu.stat" ] || continue
            printf '%s %s\n' "$c" "$(grep -E '^(usage_usec|user_usec|system_usec|nr_periods)' $c/cpu.stat | tr '\n' ' ')"
        done
        printf '@thermal\n'
        for z in /sys/class/thermal/thermal_zone*/temp; do printf '%s %s\n' "$z" "$(cat $z)"; done
        printf '@loadavg %s\n' "$(cat /proc/loadavg)"
    } > "$_f"
}

# ---- Phase 0: quiescence gate ----------------------------------------------
# Never measure while anything plays or while the LED ring still renders: wait
# for the screensaver to have blanked the ring (led_sum == 0) as the 2026-08-11
# method note requires.
napp "$SETTLE_S"
if _u=$(playing); then
    echo "!!! $_u is active at start - not an idle device, refusing to measure"
    echo "aborted-at-start:$_u" > "$OUT/ABORTED"
    exit 1
fi
i=0
while [ $i -lt 60 ]; do
    led=$(tail -n1 /var/log/nq-health/health.jsonl 2>/dev/null | sed -n 's/.*"led_sum":\([0-9]*\).*/\1/p')
    [ -z "$led" ] && led=0
    [ "$led" = 0 ] && break
    echo "waiting for blanked ring, led_sum=$led"
    napp 30
    i=$((i + 1))
done
echo "gate passed led_sum=${led:-?} sessions=$(ls /run/systemd/sessions 2>/dev/null | wc -l)"

# ---- Phase 1: ftrace event capture -----------------------------------------
if [ -d "$T" ]; then
    echo 0 > $T/tracing_on
    echo > $T/trace
    echo 16384 > $T/buffer_size_kb 2>/dev/null || echo 8192 > $T/buffer_size_kb
    echo global > $T/trace_clock 2>/dev/null
    : > $T/set_event
    for e in power:cpu_frequency sched:sched_wakeup sched:sched_switch \
             sched:sched_process_fork sched:sched_process_exec \
             irq:irq_handler_entry workqueue:workqueue_execute_start \
             timer:hrtimer_expire_entry; do
        echo "$e" >> $T/set_event 2>/dev/null || echo "event unavailable: $e"
    done
    echo "tracing $TRACE_S s with: $(cat $T/set_event | tr '\n' ' ')"
    snap "$OUT/trace_pre.snap"
    echo 1 > $T/tracing_on
    wait_idle "$TRACE_S"
    echo 0 > $T/tracing_on
    snap "$OUT/trace_post.snap"
    cp $T/trace "$OUT/trace.txt" 2>/dev/null
    gzip -f "$OUT/trace.txt" 2>/dev/null
    : > $T/set_event
    echo > $T/trace
    echo 1408 > $T/buffer_size_kb 2>/dev/null
    echo "trace captured: $(ls -l $OUT/trace.txt.gz 2>/dev/null)"
fi

# ---- Phase 2: governor A/B --------------------------------------------------
# arm = label:governor:sampling_rate:up_threshold  ('-' = leave alone)
arm() {
    _label=$1 _gov=$2 _sr=$3 _up=$4
    echo "--- arm $_label gov=$_gov sr=$_sr up=$_up  $(cat /proc/uptime)"
    echo "$_gov" > $P/scaling_governor
    [ "$_sr" != - ] && echo "$_sr" > $G/sampling_rate
    [ "$_up" != - ] && echo "$_up" > $G/up_threshold
    napp 20                                   # let the new policy settle
    snap "$OUT/arm_${_label}_pre.snap"
    wait_idle "$ARM_S"
    snap "$OUT/arm_${_label}_post.snap"
    echo "--- arm $_label done temp=$(cat /sys/class/thermal/thermal_zone0/temp 2>/dev/null)"
}

arm baseline    conservative 20000  80    # exactly what ships today
arm sr100ms     conservative 100000 80    # evaluate 5x/s instead of 50x/s
arm sr100up95   conservative 100000 95    # + a burst must fill 95 % of the window
arm sr20up95    conservative 20000  95    # threshold alone, unchanged cadence
arm powersave   powersave    -      -     # reference bound: locked at 350 MHz

restore
echo "=== nq-opp-study finished $(cat /proc/uptime)"
