#!/bin/sh
# nq-opp-study2 — second round of idle-OPP A/B arms, parameterised.
#
# Round 1 (nq-opp-study.sh) A/B'd the governor's sampling cadence and
# up_threshold. This one exists for the two levers round 1 does not touch:
#
#   * ignore_nice_load + renicing the housekeeping daemons. `conservative`
#     counts nice time as load by default, so nq-healthd / nexusq-mqtt /
#     nexusq-control / the watchdogs drive the CPU frequency even though none of
#     them is latency-critical. With ignore_nice_load=1 their CPU time is
#     credited as idle, so only the audio path (librespot/PA, never nice'd) can
#     ramp the clock.
#   * down_threshold. Between down_threshold and up_threshold conservative
#     HOLDS the frequency; at 20 % a mere 4 ms of work per 20 ms window pins the
#     CPU at 700 MHz. Raising it should collapse the decay tail.
#
# Arms are given on the command line so the round-1 results can pick them:
#   nq-opp-study2.sh 'label:gov:sampling_rate:up:down:ignore_nice:nice_mode' ...
# where '-' leaves a knob alone and nice_mode is 'none' or 'hk19' (renice the
# housekeeping units to 19 for the duration of the arm).
#
# Read-only apart from those knobs; an EXIT trap restores everything, including
# every renice'd PID's original priority.
set -u

OUT=${OUT:-/var/log/nq-opp-study2}
ARM_S=${ARM_S:-720}
SETTLE_S=${SETTLE_S:-90}
P=/sys/devices/system/cpu/cpufreq/policy0
G=/sys/devices/system/cpu/cpufreq/conservative

# housekeeping units: everything that is background telemetry/plumbing. NOT
# nexusqd (it drives the LED ring the user looks at) and NOT the audio path.
HK_UNITS="nq-healthd.service nexusq-mqtt.service nexusq-control.service
          nexusq-wifi-watchdog.service nexusq-btagent.service nexusq-nfc.service"
UNITS="librespot.service shairport-sync.service roon.service nexusq-uac2-in.service"

mkdir -p "$OUT"
exec >>"$OUT/run.log" 2>&1
echo "=== nq-opp-study2 start $(cat /proc/uptime)  arms: $*"

ORIG_GOV=$(cat $P/scaling_governor)
ORIG_SR=$(cat $G/sampling_rate 2>/dev/null)
ORIG_UP=$(cat $G/up_threshold 2>/dev/null)
ORIG_DOWN=$(cat $G/down_threshold 2>/dev/null)
ORIG_IGN=$(cat $G/ignore_nice_load 2>/dev/null)
RENICED=""            # "pid:oldnice pid:oldnice ..."

unnice() {
    for _e in $RENICED; do
        renice -n "${_e#*:}" -p "${_e%:*}" >/dev/null 2>&1
    done
    RENICED=""
}

restore() {
    unnice
    echo "$ORIG_GOV" > $P/scaling_governor 2>/dev/null
    [ -n "$ORIG_SR" ]   && echo "$ORIG_SR"   > $G/sampling_rate 2>/dev/null
    [ -n "$ORIG_UP" ]   && echo "$ORIG_UP"   > $G/up_threshold 2>/dev/null
    [ -n "$ORIG_DOWN" ] && echo "$ORIG_DOWN" > $G/down_threshold 2>/dev/null
    [ -n "$ORIG_IGN" ]  && echo "$ORIG_IGN"  > $G/ignore_nice_load 2>/dev/null
    echo "=== restored gov=$(cat $P/scaling_governor) sr=$(cat $G/sampling_rate 2>/dev/null)" \
         "up=$(cat $G/up_threshold 2>/dev/null) down=$(cat $G/down_threshold 2>/dev/null)" \
         "ign=$(cat $G/ignore_nice_load 2>/dev/null)"
}
trap 'restore; echo "=== exit $(cat /proc/uptime)"; exit' EXIT INT TERM

FIFO=$OUT/.tick
[ -p "$FIFO" ] || mkfifo "$FIFO" 2>/dev/null
exec 9<>"$FIFO" 2>/dev/null
if read -t 1 _x <&9 2>/dev/null; [ $? -gt 1 ]; then
    napp() { sleep "$1"; }
else
    napp() { read -t "$1" _x <&9 2>/dev/null || :; }
fi

# Round 1 measured its own guard: `systemctl is-active` costs a fork AND wakes
# pid 1, whose service slices run up to 59 ms — long enough to ramp the governor
# all by itself, which is the very thing being measured. A running unit has a
# cgroup directory and a stopped one does not, so test that instead: no fork, no
# pid-1 wakeup. (nq-healthd already uses this trick for librespot liveness.)
playing() {
    for _u in $UNITS; do
        [ -d "/sys/fs/cgroup/system.slice/$_u" ] && { echo "$_u"; return 0; }
    done
    return 1
}

wait_idle() {
    _left=$1
    while [ "$_left" -gt 0 ]; do
        _step=30; [ "$_left" -lt 30 ] && _step=$_left
        napp "$_step"; _left=$((_left - _step))
        if _u=$(playing); then
            echo "!!! ABORT: $_u went active - playback started, study invalid"
            echo "aborted:$_u" > "$OUT/ABORTED"; exit 1
        fi
    done
}

# renice every process in the housekeeping cgroups, remembering what it was
nice_housekeeping() {
    for _u in $HK_UNITS; do
        _cg=/sys/fs/cgroup/system.slice/$_u/cgroup.procs
        [ -f "$_cg" ] || continue
        while IFS= read -r _pid; do
            [ -n "$_pid" ] || continue
            # nice is field 19 of /proc/pid/stat, but comm (field 2) may contain
            # spaces or parens — strip through the LAST ')' first, then take 17.
            _old=$(awk '{sub(/^[0-9]+ \(.*\) /, ""); print $17}' /proc/$_pid/stat 2>/dev/null)
            [ -n "$_old" ] || continue
            if renice -n 19 -p "$_pid" >/dev/null 2>&1; then
                RENICED="$RENICED $_pid:$_old"
            fi
        done < "$_cg"
    done
    echo "reniced to 19:$RENICED"
}

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
            printf '%s %s\n' "$c" "$(grep -E '^(usage_usec|user_usec|system_usec)' $c/cpu.stat | tr '\n' ' ')"
        done
        printf '@thermal\n'
        for z in /sys/class/thermal/thermal_zone*/temp; do printf '%s %s\n' "$z" "$(cat $z)"; done
        printf '@loadavg %s\n' "$(cat /proc/loadavg)"
    } > "$_f"
}

napp "$SETTLE_S"
if _u=$(playing); then
    echo "!!! $_u active at start - refusing to measure"
    echo "aborted-at-start:$_u" > "$OUT/ABORTED"; exit 1
fi

for spec in "$@"; do
    IFS=: read -r label gov sr up down ign nicemode <<EOF
$spec
EOF
    echo "--- arm $label gov=$gov sr=$sr up=$up down=$down ign=$ign nice=$nicemode $(cat /proc/uptime)"
    [ "$gov"  != - ] && echo "$gov"  > $P/scaling_governor
    [ "$sr"   != - ] && echo "$sr"   > $G/sampling_rate
    [ "$up"   != - ] && echo "$up"   > $G/up_threshold
    [ "$down" != - ] && echo "$down" > $G/down_threshold
    [ "$ign"  != - ] && echo "$ign"  > $G/ignore_nice_load
    # ALWAYS unwind the previous arm's renices first. Two consecutive hk19 arms
    # used to append to RENICED without unwinding, so the restore replayed
    # "pid:10" and then "pid:19" for the same pid and the LAST write won — the
    # 2026-08-16 round-2 run left every housekeeping daemon at nice 19.
    unnice
    case "$nicemode" in
        hk19) nice_housekeeping ;;
    esac
    napp 20
    snap "$OUT/arm_${label}_pre.snap"
    wait_idle "$ARM_S"
    snap "$OUT/arm_${label}_post.snap"
    echo "--- arm $label done temp=$(cat /sys/class/thermal/thermal_zone0/temp 2>/dev/null)"
done

restore
echo "=== nq-opp-study2 finished $(cat /proc/uptime)"
