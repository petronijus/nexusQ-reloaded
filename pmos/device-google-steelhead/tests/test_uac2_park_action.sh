#!/usr/bin/env bash
# Tests for the park-state decision in nexusq-uac2-in.
#
# This table is the whole safety of the 2026-08-30 change that replaced the
# duty-cycled alsaloop probe with a read of the gadget's `Capture Rate` control.
# The probe cost about 8 pp of 350 MHz residency and drove 99 % of all time above
# 350 MHz; the flag costs a fork every 12 s. But the flag answers a subtly
# different question — "is the host's stream OPEN", not "is audio ARRIVING" — and
# those come apart in exactly the failure that started all of this: a host that
# holds the stream open at 48000 Hz and sends nothing for 28 hours.
#
# So the rule is not "non-zero means wake up". It depends on WHY we parked, and a
# naive version flaps forever in the wedge case. That is what this pins down.
#
# The function is extracted from the service by its TESTABLE marker rather than
# reimplemented, so a change to the service that is not reflected here fails here.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SVC="$HERE/../nexusq-uac2-in"
PASS=0; FAIL=0

eval "$(sed -n '/^# TESTABLE:park_action/,/^}/p' "$SVC")"
if ! command -v park_action >/dev/null 2>&1 && ! type park_action >/dev/null 2>&1; then
    echo "could not extract park_action from $SVC — did the TESTABLE marker move?" >&2
    exit 2
fi

check() {  # check <park_rate> <cur_rate> <expected> <why>
    local got; got="$(park_action "$1" "$2")"
    if [ "$got" = "$3" ]; then
        PASS=$((PASS+1)); printf '  \033[32mPASS\033[0m  park_rate=%-6s now=%-6s -> %-7s %s\n' "$1" "$2" "$got" "$4"
    else
        FAIL=$((FAIL+1)); printf '  \033[31mFAIL\033[0m  park_rate=%-6s now=%-6s -> %-7s (expected %s) %s\n' "$1" "$2" "$got" "$3" "$4"
    fi
}

echo "=== parked because the host CLOSED the stream (park_rate 0) ==="
check 0 0     stay   "host still gone — the cheap steady state, no fork, no bridge"
check 0 48000 unpark "host came back — this is the win: 12 s instead of a 30 s probe"
check 0 44100 unpark "any rate counts, not just the one we last saw"

echo "=== parked mid-stream: the host claimed to send and did not (the 28 h wedge) ==="
check 48000 48000 probe  "MUST NOT unpark on the flag alone — that is the flapping loop"
check 48000 44100 probe  "a different non-zero rate is still just a claim; measure it"
check 48000 0     closed "the host finally let go — the flag is trustworthy again"

echo "=== the wedge must not be able to masquerade as the cheap case ==="
# Re-entering the wedge after it resolved: park_rate goes back to 0 via `closed`,
# so a later re-park at a non-zero rate must again demand measurement.
check 0     48000 unpark "after 'closed' reset park_rate to 0, a real start unparks"
check 96000 96000 probe  "and a fresh wedge at any rate still probes"

echo
echo "================ $PASS passed, $FAIL failed ================"
[ "$FAIL" -eq 0 ]
