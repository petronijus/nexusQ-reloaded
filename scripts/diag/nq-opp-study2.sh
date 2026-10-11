#!/bin/sh
# shellcheck disable=SC3045  # runs on the Q, whose /bin/sh is busybox ash: read -t exists there
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
#   nq-opp-study2.sh 'label:gov:sampling_rate:up:down:ignore_nice:nice_mode[:rate_limit_us]' ...
# where '-' leaves a knob alone and nice_mode is 'none' or 'hk19' (renice the
# housekeeping units to 19 for the duration of the arm).
#
# Read-only apart from those knobs; an EXIT trap restores everything, including
# every renice'd PID's original priority.
#
# GPU=1 adds the GPU measurement items of docs/gpu-sgx540/drafts/
# measurement-protocol.md §3 and kernel-driver-port.md Addendum B.8 to every
# snapshot: pm_debug count/time, the SGX target-module's runtime PM, genpd
# prm_gfx, the TMP101, kernel audio-error and preemption-bug counts from dmesg,
# and the wall clock (for `nq-health-report --since/--until`). Around each arm,
# OUTSIDE its window, it writes arm_<label>_{pre,post}.edge: the GPU probe
# (GPU_PROBE, default nexusq-gpu-probe.sh next to this script), uname/vermagic,
# boot-to-multi-user time and the full dmesg. A background logger reads
# thermal_zone0 at 1 Hz into thermal_1hz.log (one builtin read per second, no
# fork). Analyse with scripts/diag/analyze-gpu-window.py. A GFX-idle window:
#   GPU=1 ARM_S=3600 SETTLE_S=900 OUT=/var/log/nq-gpu/A0-1 \
#     nq-opp-study2.sh 'A0:-:-:-:-:-:none'
#
# NQ_SYS / NQ_PROC re-root /sys and /proc. They exist for the host test
# (scripts/diag/tests/test_nq_opp_study2_guard.sh); on the Q leave them unset.
set -u

OUT=${OUT:-/var/log/nq-opp-study2}
ARM_S=${ARM_S:-720}
SETTLE_S=${SETTLE_S:-90}
GUARD_S=${GUARD_S:-30}       # how often the playback guard looks
PRE_S=${PRE_S:-20}           # pause between setting an arm up and its first snapshot
GPU=${GPU:-0}
TO=${NQ_TIMEOUT:-20}         # bound on every external command the GPU items run
SYS=${NQ_SYS:-/sys}
PROC=${NQ_PROC:-/proc}
P=$SYS/devices/system/cpu/cpufreq/policy0
G=$SYS/devices/system/cpu/cpufreq/conservative
_here=$(cd "$(dirname "$0")" && pwd)
GPU_PROBE=${GPU_PROBE:-$_here/nexusq-gpu-probe.sh}

# housekeeping units: everything that is background telemetry/plumbing. NOT
# nexusqd (it drives the LED ring the user looks at) and NOT the audio path.
HK_UNITS="nq-healthd.service nexusq-mqtt.service nexusq-control.service
          nexusq-wifi-watchdog.service nexusq-btagent.service nexusq-nfc.service"
# Deliberately profiling one audio path (e.g. "what does USB audio cost when
# nothing plays?") is a legitimate study - it just must not be mistaken for an
# idle baseline. ALLOW_UNITS lets that path be live (see the guard below) AND is
# echoed into the run log, so a capture always says which audio path was live.
ALLOW_UNITS=${ALLOW_UNITS:-}

mkdir -p "$OUT"
exec >>"$OUT/run.log" 2>&1
echo "=== nq-opp-study2 start $(cat /proc/uptime)  arms: $*"
[ -n "$ALLOW_UNITS" ] && echo "=== ALLOW_UNITS (deliberately live during this run): $ALLOW_UNITS"
[ "${ALLOW_PLAYBACK:-0}" = 1 ] && echo "=== ALLOW_PLAYBACK=1 (an audio arm: playback must stay live throughout)"
echo "=== GPU=$GPU ARM_S=$ARM_S SETTLE_S=$SETTLE_S GUARD_S=$GUARD_S OUT=$OUT"

ORIG_GOV=$(cat "$P"/scaling_governor 2>/dev/null)
ORIG_SR=$(cat "$G"/sampling_rate 2>/dev/null)
ORIG_UP=$(cat "$G"/up_threshold 2>/dev/null)
ORIG_DOWN=$(cat "$G"/down_threshold 2>/dev/null)
ORIG_IGN=$(cat "$G"/ignore_nice_load 2>/dev/null)
RENICED=""            # "pid:oldnice pid:oldnice ..."

unnice() {
    for _e in $RENICED; do
        renice -n "${_e#*:}" -p "${_e%:*}" >/dev/null 2>&1
    done
    RENICED=""
}

restore() {
    unnice
    [ -n "$ORIG_GOV" ]  && echo "$ORIG_GOV" > "$P"/scaling_governor 2>/dev/null
    [ -n "$ORIG_SR" ]   && echo "$ORIG_SR"   > "$G"/sampling_rate 2>/dev/null
    [ -n "$ORIG_UP" ]   && echo "$ORIG_UP"   > "$G"/up_threshold 2>/dev/null
    [ -n "$ORIG_DOWN" ] && echo "$ORIG_DOWN" > "$G"/down_threshold 2>/dev/null
    [ -n "$ORIG_IGN" ]  && echo "$ORIG_IGN"  > "$G"/ignore_nice_load 2>/dev/null
    echo "=== restored gov=$(cat "$P"/scaling_governor) sr=$(cat "$G"/sampling_rate 2>/dev/null)" \
         "up=$(cat "$G"/up_threshold 2>/dev/null) down=$(cat "$G"/down_threshold 2>/dev/null)" \
         "ign=$(cat "$G"/ignore_nice_load 2>/dev/null)"
}
THERM_PID=""
stop_thermal() {
    [ -n "$THERM_PID" ] && kill "$THERM_PID" 2>/dev/null
    THERM_PID=""
}
trap 'stop_thermal; restore; echo "=== exit $(cat "$PROC"/uptime)"; exit' EXIT INT TERM

FIFO=$OUT/.tick
[ -p "$FIFO" ] || mkfifo "$FIFO" 2>/dev/null
exec 9<>"$FIFO" 2>/dev/null
if read -t 1 _x <&9 2>/dev/null; [ $? -gt 1 ]; then
    napp() { sleep "$1"; }
else
    napp() { read -t "$1" _x <&9 2>/dev/null || :; }
fi

# The guard must not wake anything up: round 1 measured that `systemctl
# is-active` costs a fork and wakes pid 1, whose slices run up to 59 ms - enough
# to ramp the governor all by itself. Everything below is shell builtins over
# procfs: no exec, no pid-1 wakeup (the one `$(playing)` subshell per check is
# all it costs).
#
# What it asks is "is audio FLOWING", read off the ALSA substreams, not "is a
# player unit running". The unit question was the guard up to 2026-10-11, and it
# was wrong both ways in turn: until 2026-08-24 it looked only under system.slice,
# where the (user) units never are, so it could never fire; after that it found
# their cgroups, but librespot, shairport-sync, roon and nexusq-uac2-in run all
# the time on an idle box (all four cgroups exist on the Prague Q with nothing
# playing, 2026-10-11), so it fired on every start. A running unit is not a
# stream. The three paths audio can actually take:
#   playback  an output card (NexusQSpeaker, NexusQSPDIF, HDMI) has a playback
#             substream RUNNING/DRAINING - everything PulseAudio plays (Spotify,
#             AirPlay, Roon, USB, Bluetooth) ends here; the sinks suspend when idle
#   usb-in    the UAC2Gadget capture substream is RUNNING - the USB host is
#             streaming and alsaloop is bridging it (nexusq-uac2-in), even while
#             the PulseAudio loopback to the speaker is corked
#   roon-loop a RoonLoop substream is RUNNING (roon.service)
# ALLOW_UNITS names the units whose path is live on purpose: nexusq-uac2-in.service
# allows usb-in, roon.service roon-loop, librespot.service / shairport-sync.service
# (or ALLOW_PLAYBACK=1, for an audio arm) allow playback. An allowed path is not a
# licence to change: the state of every path is fixed at the first snapshot, and
# a path that starts OR stops mid-window aborts the study just the same.
ALLOW_PLAYBACK=${ALLOW_PLAYBACK:-0}
_allow_usb=0; _allow_roon=0
for _a in $ALLOW_UNITS; do
    case "$_a" in
        nexusq-uac2-in.service) _allow_usb=1 ;;
        roon.service) _allow_roon=1 ;;
        librespot.service|shairport-sync.service) ALLOW_PLAYBACK=1 ;;
        *) echo "=== ALLOW_UNITS: $_a is not an audio path the guard knows; ignored" ;;
    esac
done

# substream_live <status-file>: true for RUNNING / DRAINING (builtin read only)
substream_live() {
    [ -r "$1" ] || return 1
    read -r _st _sv < "$1" 2>/dev/null || return 1
    [ "$_st" = "state:" ] || return 1
    case "$_sv" in RUNNING|DRAINING) return 0 ;; esac
    return 1
}

# audio_state: one word per path, e.g. "playback=0 usb-in=1 roon-loop=0"
audio_state() {
    _pb=0; _usb=0; _roon=0
    for _c in "$PROC"/asound/card[0-9]*; do
        [ -r "$_c/id" ] || continue
        read -r _id < "$_c/id" || continue
        case "$_id" in
            NexusQSpeaker|NexusQSPDIF|HDMI)
                for _s in "$_c"/pcm*p/sub*/status; do substream_live "$_s" && _pb=1; done ;;
            UAC2Gadget)
                for _s in "$_c"/pcm*c/sub*/status; do substream_live "$_s" && _usb=1; done ;;
            RoonLoop)
                for _s in "$_c"/pcm*/sub*/status; do substream_live "$_s" && _roon=1; done ;;
        esac
    done
    echo "playback=$_pb usb-in=$_usb roon-loop=$_roon"
}

# playing: prints the first live path that is not allowed, true if there is one
playing() {
    _now=$(audio_state)
    case "$_now" in *playback=1*) [ "$ALLOW_PLAYBACK" = 1 ] || { echo playback; return 0; } ;; esac
    case "$_now" in *usb-in=1*)   [ "$_allow_usb" = 1 ]     || { echo usb-in;   return 0; } ;; esac
    case "$_now" in *roon-loop=1*) [ "$_allow_roon" = 1 ]   || { echo roon-loop; return 0; } ;; esac
    if [ -n "${AUDIO_REF:-}" ] && [ "$_now" != "$AUDIO_REF" ]; then
        echo "allowed path changed: [$AUDIO_REF] -> [$_now]"; return 0
    fi
    return 1
}

# which player units are running (information for run.log, not the guard)
units_running() {
    _r=""
    for _u in librespot.service shairport-sync.service roon.service nexusq-uac2-in.service; do
        for _d in "$SYS/fs/cgroup/system.slice/$_u" "$SYS"/fs/cgroup/user.slice/*/user@*.service/*/"$_u"; do
            [ -d "$_d" ] && { _r="$_r $_u"; break; }
        done
    done
    echo "${_r# }"
}

wait_idle() {
    _left=$1
    while [ "$_left" -gt 0 ]; do
        _step=$GUARD_S; [ "$_left" -lt "$_step" ] && _step=$_left
        napp "$_step"; _left=$((_left - _step))
        if _u=$(playing); then
            echo "!!! ABORT: $_u - audio path changed mid-window, study invalid $(cat "$PROC"/uptime)"
            echo "aborted:$_u" > "$OUT/ABORTED"; exit 1
        fi
    done
}

# renice every process in the housekeeping cgroups, remembering what it was
nice_housekeeping() {
    for _u in $HK_UNITS; do
        _cg=$SYS/fs/cgroup/system.slice/$_u/cgroup.procs
        [ -f "$_cg" ] || continue
        while IFS= read -r _pid; do
            [ -n "$_pid" ] || continue
            # nice is field 19 of /proc/pid/stat, but comm (field 2) may contain
            # spaces or parens — strip through the LAST ')' first, then take 17.
            _old=$(awk '{sub(/^[0-9]+ \(.*\) /, ""); print $17}' "$PROC/$_pid/stat" 2>/dev/null)
            [ -n "$_old" ] || continue
            if renice -n 19 -p "$_pid" >/dev/null 2>&1; then
                RENICED="$RENICED $_pid:$_old"
            fi
        done < "$_cg"
    done
    echo "reniced to 19:$RENICED"
}

# TESTABLE:dmesg_counts - the kernel strings the GPU protocol counts, one awk
# pass over `dmesg`. audio_err is measurement-protocol §4 (its delta must be 0
# with music); the next four are kernel-driver-port Addendum B.8 (all must stay
# 0; rcu_stall matches any flavour: rcu_sched on PREEMPT_NONE, rcu_preempt on
# PREEMPT); lines/first let the analyser see a wrapped ring buffer.
dmesg_counts() {
    awk '
        NR == 1 { first = $0 }
        /XRUN|underrun|McBSP|DMA|TAS571x/                      { audio++ }
        /BUG: sleeping function called from invalid context/   { sleeping++ }
        /using smp_processor_id\(\) in preemptible/            { smp_id++ }
        /scheduling while atomic/                              { sched_atomic++ }
        /rcu_[a-z]+ detected stall/                            { rcu++ }
        /WARNING:|BUG:|Oops|Unable to handle/                  { warn++ }
        END {
            printf "audio_err %d\nsleeping_in_atomic %d\nsmp_processor_id_preemptible %d\n", audio, sleeping, smp_id
            printf "scheduling_while_atomic %d\nrcu_stall %d\nkernel_warn %d\nlines %d\n", sched_atomic, rcu, warn, NR
            sub(/\].*/, "]", first); printf "first %s\n", first
        }'
}

# r: bounded and at the lowest priority, like nexusq-gpu-probe.sh
r() { timeout "$TO" nice -n 19 "$@"; }

# one "name value" line per file in a directory (builtin reads; "-" if absent)
read_files() {
    _dir=$1; shift
    for _f in "$@"; do
        [ -r "$_dir/$_f" ] || { printf '%s -\n' "$_f"; continue; }
        read -r _v < "$_dir/$_f" 2>/dev/null || _v=-
        printf '%s %s\n' "$_f" "$_v"
    done
}

GFX_DEV=$SYS/bus/platform/devices/5600fe00.target-module/power
GENPD=$SYS/kernel/debug/pm_genpd/prm_gfx
PMDBG=$SYS/kernel/debug/pm_debug

# The GPU items of measurement-protocol §3 and kernel-driver-port B.8 that are
# cheap enough to sit at the window edge: builtin reads, one grep per pm_debug
# file, one dmesg + awk.
gpu_snap() {
    printf '@wall %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')"
    # reading pm_debug/time makes the kernel take one power-domain sample
    # (pm §6.1): bookkeeping, and the same in every arm
    printf '@pm_debug_count\n'; grep -E '^(gfx|core|dss|mpu)_pwrdm' "$PMDBG/count" 2>/dev/null
    printf '@pm_debug_time\n';  grep -E '^(gfx|core|dss|mpu)_pwrdm' "$PMDBG/time" 2>/dev/null
    printf '@gfx_rpm\n'
    read_files "$GFX_DEV" runtime_status runtime_active_time runtime_suspended_time
    printf '@genpd_prm_gfx\n'
    read_files "$GENPD" current_state active_time total_idle_time
    printf '@hwmon\n'
    for _h in "$SYS"/class/hwmon/hwmon*; do
        [ -r "$_h/temp1_input" ] || continue
        read -r _n < "$_h/name" 2>/dev/null || _n='?'
        read -r _t < "$_h/temp1_input" 2>/dev/null || _t=-
        printf '%s %s\n' "$_n" "$_t"
    done
    printf '@dmesg_counts\n'; r dmesg 2>/dev/null | dmesg_counts
}

snap() {
    _f=$1
    {
        printf '@uptime %s\n' "$(cat "$PROC"/uptime)"
        printf '@time_in_state\n'; cat "$P"/stats/time_in_state
        printf '@total_trans %s\n' "$(cat "$P"/stats/total_trans)"
        printf '@trans_table\n';   cat "$P"/stats/trans_table
        printf '@proc_stat\n';     grep -E '^(cpu|ctxt|processes|intr )' "$PROC"/stat
        printf '@interrupts\n';    cat "$PROC"/interrupts
        printf '@softirqs\n';      cat "$PROC"/softirqs
        printf '@cpuidle\n'
        for s in "$SYS"/devices/system/cpu/cpu*/cpuidle/state*; do
            read -r _n < "$s/name" 2>/dev/null || _n='?'
            printf '%s usage=%s time=%s name=%s\n' "$s" "$(cat "$s"/usage)" "$(cat "$s"/time)" "$_n"
        done
        printf '@cgroups\n'
        # The user manager's units live FOUR levels down
        # (user.slice/user-N.slice/user@N.service/app.slice/foo.service), so the
        # plain */*.service glob misses every one of them. That gap made the
        # 2026-08-24 USB-audio study report a bare "user.slice 8.72 %" with no
        # breakdown, and PulseAudio — the single largest consumer on the box —
        # had to be attributed by `ps` instead of a kernel counter. Glob the
        # user tree explicitly. Still no extra forks: this only widens the list
        # of paths the one awk/grep per snapshot reads.
        for c in "$SYS"/fs/cgroup/*.slice/*.service "$SYS"/fs/cgroup/*.slice \
                 "$SYS"/fs/cgroup/*.slice/*.slice/*.service \
                 "$SYS"/fs/cgroup/*.slice/*.slice/*.scope \
                 "$SYS"/fs/cgroup/*.slice/*.slice/user@*.service \
                 "$SYS"/fs/cgroup/*.slice/*.slice/user@*.service/*.slice/*.service \
                 "$SYS"/fs/cgroup/*.scope "$SYS"/fs/cgroup; do
            [ -f "$c/cpu.stat" ] || continue
            printf '%s %s\n' "$c" "$(grep -E '^(usage_usec|user_usec|system_usec)' "$c"/cpu.stat | tr '\n' ' ')"
        done
        printf '@thermal\n'
        for z in "$SYS"/class/thermal/thermal_zone*/temp; do printf '%s %s\n' "$z" "$(cat "$z")"; done
        printf '@loadavg %s\n' "$(cat "$PROC"/loadavg)"
        printf '@audio %s\n' "$(audio_state)"
        [ "$GPU" = 1 ] && gpu_snap
    } > "$_f"
}

# The expensive once-per-edge items. They run outside the window (before the
# pre-arm pause, after the post snapshot), so their forks are not in the deltas.
GPU_PROBE_OPTS=${GPU_PROBE_OPTS:-}
edge() {
    _f=$1
    {
        printf '@wall %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')"
        printf '@uptime %s\n' "$(cat "$PROC"/uptime)"
        printf '@hostname %s\n' "$(cat "$PROC"/sys/kernel/hostname 2>/dev/null)"
        printf '@uname %s\n' "$(uname -r)"
        printf '@version %s\n' "$(cat "$PROC"/version 2>/dev/null)"
        _ko=""
        for _k in /lib/modules/"$(uname -r)"/kernel/*/*/*.ko*; do
            [ -f "$_k" ] && { _ko=$_k; break; }
        done
        _vm=""
        [ -n "$_ko" ] && _vm=$(r modinfo -F vermagic "$_ko" 2>/dev/null)
        printf '@vermagic %s\n' "$_vm"
        printf '@preempt\n'
        r zcat "$PROC"/config.gz 2>/dev/null \
            | grep -E '^CONFIG_PREEMPT(_NONE|_VOLUNTARY|_LAZY)?=|^CONFIG_DEBUG_(ATOMIC_SLEEP|PREEMPT)='
        printf '@boot\n'; r systemd-analyze time 2>&1
        printf '@audio %s\n' "$(audio_state)"
        printf '@units_running %s\n' "$(units_running)"
        printf '@gpu_probe %s %s\n' "$GPU_PROBE" "$GPU_PROBE_OPTS"
        if [ -r "$GPU_PROBE" ]; then
            # its own commands are bounded; this bounds the whole probe as well
            # shellcheck disable=SC2086  # GPU_PROBE_OPTS is a word list on purpose
            timeout 120 nice -n 19 sh "$GPU_PROBE" $GPU_PROBE_OPTS 2>&1
            printf '@gpu_probe_exit %s\n' "$?"
        else
            printf 'SKIP gpu_probe not found\n'
        fi
        printf '@dmesg\n'; r dmesg 2>/dev/null
    } > "$_f"
}

# thermal_zone0 at 1 Hz while the study runs (protocol §3 row 8). One builtin
# read and one printf per second, no fork; bounded by an iteration cap and by
# the study's own process, so it cannot outlive a killed run.
thermal_logger() {
    trap - EXIT INT TERM   # the study's restore belongs to the study, not to this child
    _main=$1 _cap=$2 _n=0
    _z=$SYS/class/thermal/thermal_zone0/temp
    while [ "$_n" -lt "$_cap" ] && kill -0 "$_main" 2>/dev/null; do
        read -r _up _ < "$PROC"/uptime
        read -r _t < "$_z" 2>/dev/null || _t=-
        printf '%s %s\n' "$_up" "$_t"
        napp 1
        _n=$((_n + 1))
    done >> "$OUT/thermal_1hz.log"
}

echo "=== guard: ALLOW_PLAYBACK=$ALLOW_PLAYBACK usb-in allowed=$_allow_usb roon-loop allowed=$_allow_roon"
echo "=== audio at start: $(audio_state)   player units running: $(units_running)"
if [ "$GPU" = 1 ]; then
    _cap=$((SETTLE_S + $# * (ARM_S + PRE_S + 300) + 600))
    thermal_logger $$ "$_cap" &
    THERM_PID=$!
    echo "=== thermal logger pid $THERM_PID (cap ${_cap} s)"
fi

napp "$SETTLE_S"
if _u=$(playing); then
    echo "!!! $_u live at start - refusing to measure"
    echo "aborted-at-start:$_u" > "$OUT/ABORTED"; exit 1
fi
# Every path's state is fixed here; an allowed path that changes aborts too.
AUDIO_REF=$(audio_state)
echo "=== audio reference for the windows: $AUDIO_REF"

for spec in "$@"; do
    IFS=: read -r label gov sr up down ign nicemode ratelimit <<EOF
$spec
EOF
    ratelimit=${ratelimit:--}
    echo "--- arm $label gov=$gov sr=$sr up=$up down=$down ign=$ign nice=$nicemode $(cat "$PROC"/uptime)"
    [ "$GPU" = 1 ] && edge "$OUT/arm_${label}_pre.edge"
    [ "$gov"  != - ] && echo "$gov"  > "$P"/scaling_governor
    [ "$sr"   != - ] && echo "$sr"   > "$G"/sampling_rate
    [ "$up"   != - ] && echo "$up"   > "$G"/up_threshold
    [ "$down" != - ] && echo "$down" > "$G"/down_threshold
    [ "$ign"  != - ] && echo "$ign"  > "$G"/ignore_nice_load
    # schedutil's only knob: how often it may re-evaluate. Its default comes from
    # cpuinfo_transition_latency (300 us here), which is aggressive for a CPU
    # whose OPP changes cost a voltage ramp -- worth A/B'ing against a slower one.
    [ "$ratelimit" != - ] && [ -w "$SYS"/devices/system/cpu/cpufreq/schedutil/rate_limit_us ] \
        && echo "$ratelimit" > "$SYS"/devices/system/cpu/cpufreq/schedutil/rate_limit_us
    # ALWAYS unwind the previous arm's renices first. Two consecutive hk19 arms
    # used to append to RENICED without unwinding, so the restore replayed
    # "pid:10" and then "pid:19" for the same pid and the LAST write won — the
    # 2026-08-16 round-2 run left every housekeeping daemon at nice 19.
    unnice
    case "$nicemode" in
        hk19) nice_housekeeping ;;
    esac
    napp "$PRE_S"
    snap "$OUT/arm_${label}_pre.snap"
    wait_idle "$ARM_S"
    snap "$OUT/arm_${label}_post.snap"
    echo "--- arm $label done temp=$(cat "$SYS"/class/thermal/thermal_zone0/temp 2>/dev/null) $(cat "$PROC"/uptime)"
    [ "$GPU" = 1 ] && edge "$OUT/arm_${label}_post.edge"
done

stop_thermal
restore
echo "=== nq-opp-study2 finished $(cat "$PROC"/uptime)"
