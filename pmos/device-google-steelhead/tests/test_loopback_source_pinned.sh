#!/usr/bin/env bash
# The two PulseAudio loopbacks must PIN their capture side.
#
# 2026-09-01, from a live failure: USB audio was silent for a whole listening
# session while every check passed — the unit read `active`, alsaloop was
# running, the gadget's `Capture Rate` said 48000 and the service even logged
# "USB audio live again". PA's stock `module-switch-on-connect` makes each newly
# appeared source the default AND MOVES existing source-outputs onto it, so
# `roon-nexusq` loading `roon_in` dragged the USB loopback off `usb_in`. The amp
# then played Roon's silent loop while the USB host streamed into a source
# nobody read. Mirror-symmetric: USB audio starting stole Roon the same way.
#
# `source_dont_move=true` is the whole fix, and it is one word inside a
# `load-module` line — trivially lost to a refactor, and its loss is INVISIBLE:
# the module stays loaded, so `ensure_modules` (which supervises existence, not
# bindings) still passes, and a move is never logged. Hence this test.
#
# It asserts the flag is on the load-module command ITSELF, not merely somewhere
# in the file — both files explain the flag in a comment, and a test satisfied by
# prose would pass on a file that had lost the code. Seen failing both ways:
# with the flag deleted, and with it moved into a comment only.
#
# The SINK side must stay movable, so that is asserted too: looping into the
# default sink is what makes these inputs follow the output the app selects.
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

for f in nexusq-uac2-in roon-nexusq; do
    src="$HERE/../$f"
    [ -f "$src" ] || { echo "missing $src" >&2; exit 2; }
    cmd="$(loopback_cmd "$src")"

    [ -n "$cmd" ]; check "$f: has a module-loopback load-module line" "$?"

    printf '%s\n' "$cmd" | grep -q 'source_dont_move=true'
    check "$f: pins the capture side (source_dont_move=true on the command)" "$?"

    # A loopback that cannot move its OUTPUT would stop following the app's
    # output choice — the opposite bug, and just as silent.
    if printf '%s\n' "$cmd" | grep -q 'sink_dont_move=true'; then
        check "$f: leaves the sink side movable" 1
    else
        check "$f: leaves the sink side movable" 0
    fi
done

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
