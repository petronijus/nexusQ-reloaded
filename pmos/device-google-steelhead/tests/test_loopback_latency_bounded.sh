#!/usr/bin/env bash
# Both PulseAudio loopbacks must have a CEILING on their latency.
#
# 2026-09-06, from a live complaint ("je tam delay na usb audio"): the USB hop
# was carrying 243 ms against the 120 it is configured with, and the Roon hop
# 347 against 250. Neither had drifted in the last two minutes — sampled while
# idle, both were rock steady — because the number is not a drift, it is an
# ACCUMULATION. PulseAudio's module-loopback raises its own buffer whenever it
# underruns and never lowers it again, and `nexusq-uac2-in` had been up since
# 2026-09-01 with zero restarts. Five days of small, individually reasonable
# increases is a fifth of a second of lip-sync error, and the journal only ever
# admitted to the first 25 ms of it (120 -> 145, six logged steps).
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
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
PASS=0; FAIL=0

# The load-module command for a loopback, joined across its line continuations so
# a wrapped argument list reads as one line.
loopback_cmd() {  # loopback_cmd <file>
    sed -e ':a' -e '/\\$/{N;s/\\\n//;ba' -e '}' "$1" \
        | grep -E 'load-module[[:space:]]+module-loopback'
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

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
