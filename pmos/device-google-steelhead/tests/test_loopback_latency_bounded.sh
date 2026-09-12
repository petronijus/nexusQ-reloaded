#!/usr/bin/env bash
# Both PulseAudio loopbacks must have a CEILING on their latency.
#
# PulseAudio's module-loopback raises its own buffer whenever it underruns and
# never lowers it again. Six such increases are in this box's journal (120 -> 145
# on 2026-09-02/03), so the one-way climb is real and a ceiling is worth having.
#
# ⚠️ It is NOT, however, what made USB audio sound delayed on 2026-09-06. That
# investigation read 243 ms off a loopback whose source was SUSPENDED — the TV
# holds the stream open and sends silence, `nq-uac2-silence` parks the source,
# and a starved loopback reports a large static figure nobody is hearing. With
# the chain genuinely running the same configuration measures 56 ms. Do not
# reintroduce that reading as evidence of anything: sample latency only with
# `pactl list short sources` showing usb_in RUNNING.
#
# `max_latency_msec` is the ceiling; it is one argument on a load-module line,
# exactly the kind of thing a refactor drops, and losing it is INVISIBLE — the
# module loads, audio plays, and the cost only appears days later as a delay
# nobody can point at a change for. Hence this test.
#
# It asserts the argument is on the load-module command ITSELF, joined across
# line continuations, not merely somewhere in the file: both files explain the
# ceiling in a comment, and a test satisfied by prose would pass on a file that
# had lost the code. Seen failing both ways — with the argument deleted, and
# with it present only in the comment above the call.
#
# It also asserts the ceiling is ABOVE the configured cushion. A ceiling at or
# below the target is not a bound, it is a permanent underrun: the module would
# be pinned at a latency it is simultaneously trying to grow past.
#
# 2026-09-12: the ceiling turned out to bound the WRONG path. The climb seen live
# (usb_in 16 -> 26 -> ... -> 66 ms in one session, "Source minimum latency
# increased to N ms") never touches module-loopback's underrun counter that
# `max_latency_msec` caps; it comes from the alsa SOURCE. PulseAudio's
# timer-scheduled alsa-source raises its own minimum latency by 10 ms every time
# its thread wakes up later than the buffer allowed (increase_watermark), the
# loopback follows via LOOPBACK_MESSAGE_SOURCE_LATENCY_RANGE_CHANGED, and PA's
# own comment says the reverse "never happens". `fixed_latency_range=yes` on the
# alsa-source load is the switch PA provides for exactly this ("disable latency
# range changes on overrun"), so both sources must carry it -- on the command,
# for the same reason as the ceiling.
#
# And the wake-ups are late because nothing on this image runs real-time: musl
# implements sched_setscheduler() as an ENOSYS stub, so alsaloop's own request
# fails ("Scheduler getparam failed" in every start). util-linux `chrt` goes
# through sched_setattr(2) and works, so the alsaloop launch must be wrapped in
# it -- with an RLIMIT_RTTIME so a wedged loop is killed instead of owning a core.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
PASS=0; FAIL=0

# The load-module command for a loopback, joined across its line continuations so
# a wrapped argument list reads as one line.
loopback_cmd() {  # loopback_cmd <file>
    sed -e ':a' -e '/\\$/{N;s/\\\n//;ba' -e '}' "$1" \
        | grep -E 'load-module[[:space:]]+module-loopback'
}

# The load-module command for the alsa SOURCE feeding a loopback, joined the
# same way.
source_cmd() {  # source_cmd <file>
    sed -e ':a' -e '/\\$/{N;s/\\\n//;ba' -e '}' "$1" \
        | grep -E 'load-module[[:space:]]+module-alsa-source'
}

check() {  # check <description> <condition-result>
    if [ "$2" = "0" ]; then
        PASS=$((PASS + 1)); printf 'ok   %s\n' "$1"
    else
        FAIL=$((FAIL + 1)); printf 'FAIL %s\n' "$1"
    fi
}

# Resolve a value that may be written literally or as a shell variable whose
# default is set elsewhere in the file (LOOPLAT/LOOPMAX use ${NAME:-N}).
value_of() {  # value_of <file> <argument-name>
    local f="$1" arg="$2" raw var
    # Anchor the name: `latency_msec` is a SUFFIX of `max_latency_msec`, so an
    # unanchored match would read the ceiling as the cushion depending only on
    # which came first on the line.
    raw="$(loopback_cmd "$f" | grep -oE "(^|[[:space:]])$arg=[^ )]+" \
           | head -1 | cut -d= -f2-)"
    case "$raw" in
        *'$'*)
            # e.g. latency_msec="$LOOPLAT" -> LOOPLAT="${NQ_UAC2_LOOPLAT:-120}"
            var="$(printf '%s' "$raw" | tr -cd 'A-Z_')"
            grep -E "^$var=" "$f" | head -1 | grep -oE ':-[0-9]+' | tr -d ':-' ;;
        *) printf '%s' "$raw" | tr -cd '0-9' ;;
    esac
}

for f in nexusq-uac2-in roon-nexusq; do
    src="$HERE/../$f"
    [ -f "$src" ] || { echo "missing $src" >&2; exit 2; }
    cmd="$(loopback_cmd "$src")"

    [ -n "$cmd" ]; check "$f: has a module-loopback load-module line" "$?"

    printf '%s\n' "$cmd" | grep -q 'max_latency_msec='
    check "$f: bounds the cushion (max_latency_msec on the command)" "$?"

    target="$(value_of "$src" latency_msec)"
    ceiling="$(value_of "$src" max_latency_msec)"
    if [ -n "$target" ] && [ -n "$ceiling" ] && [ "$ceiling" -gt "$target" ] 2>/dev/null; then
        check "$f: ceiling ($ceiling ms) is above the cushion ($target ms)" 0
    else
        check "$f: ceiling ($ceiling ms) is above the cushion ($target ms)" 1
    fi

    scmd="$(source_cmd "$src")"
    [ -n "$scmd" ]; check "$f: has a module-alsa-source load-module line" "$?"
    printf '%s\n' "$scmd" | grep -qE '(^|[[:space:]])fixed_latency_range=(yes|true|1)([[:space:])]|$)'
    check "$f: the source keeps a fixed latency range (fixed_latency_range=yes on the command)" "$?"
done

# The USB hop has a second half the Roon hop cannot have: it owns an alsaloop,
# so a cushion earned by a finished listening session is discarded when the host
# comes back rather than carried into the next one. Both unpark paths must do
# it — the cheap rate-flag one and the measured probe — because a device that
# only resets on one of them still accumulates through the other.
src="$HERE/../nexusq-uac2-in"
grep -q '^reset_loopback()' "$src"
check "nexusq-uac2-in: has a reset_loopback" "$?"

resets="$(grep -c '^[[:space:]]*reset_loopback$' "$src")"
[ "$resets" -ge 2 ]
check "nexusq-uac2-in: resets the cushion on BOTH unpark paths (found $resets)" "$?"

# alsaloop must be launched real-time through util-linux chrt (its own
# sched_setscheduler() is a musl stub), and bounded by RLIMIT_RTTIME so a loop
# that wedges into a spin is killed by the kernel rather than starving a core.
alsaloop_cmd="$(sed -e ':a' -e '/\\$/{N;s/\\\n//;ba' -e '}' "$src" \
    | grep -E '^[[:space:]]*[^#]*[[:space:]]alsaloop[[:space:]]+-C' | head -1)"
[ -n "$alsaloop_cmd" ]; check "nexusq-uac2-in: launches alsaloop" "$?"
printf '%s\n' "$alsaloop_cmd" | grep -qE '(^|[[:space:]])"?\$\{?RT\}?"?[[:space:]]+alsaloop'
check "nexusq-uac2-in: alsaloop is launched through the \$RT wrapper" "$?"
grep -qE '^[[:space:]]*RT="prlimit --rttime=[^"]*chrt -f' "$src"
check "nexusq-uac2-in: \$RT is prlimit --rttime + chrt -f (real-time, bounded)" "$?"

# PulseAudio cannot make its own source threads real-time on this image (Alpine's
# build lacks the sched.h path; rtkit client answers ENOTSUP), so each script
# must hand its freshly loaded source thread to nq-pa-rt, which does what rtkit
# would. Asserted on both files and on the helper's mechanism.
for f in nexusq-uac2-in roon-nexusq; do
    src="$HERE/../$f"
    grep -qE '^[[:space:]]*nq-pa-rt([[:space:]]|$)' "$src"
    check "$f: elevates the PA source thread with nq-pa-rt after loading the source" "$?"
done
helper="$HERE/../nq-pa-rt"
[ -x "$helper" ]; check "nq-pa-rt: exists and is executable" "$?"
grep -qE 'chrt -r -p "\$PRIO"' "$helper"
check "nq-pa-rt: uses chrt -r -p (sched_setattr, not the musl sched_* stubs)" "$?"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
