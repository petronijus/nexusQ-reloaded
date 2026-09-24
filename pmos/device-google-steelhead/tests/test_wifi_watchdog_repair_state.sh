#!/usr/bin/env bash
# Tests for the repair count nexusq-wifi-watchdog hands to nexusq-mqtt.
#
# What is being protected: since firmware r3 (2026-09-23) the BCM4330 wedge the
# heals were built for is gone, so any repair the watchdog still has to make is
# a failure worth seeing in Home Assistant, not something to fix quietly in a
# log. The watchdog writes the count to /run/nexusq/wifi-watchdog.json, and three
# things must hold for that to be trustworthy:
#   - a restarted watchdog continues the count (a crash-restart must not wipe
#     the evidence of the repairs before it);
#   - the file is always one whole, valid JSON document;
#   - a repair only counts as successful when wlan0 came back associated AND
#     usable, with the same loss threshold the watchdog uses to call a check bad.
#
# The functions are extracted from the script by their TESTABLE markers rather
# than reimplemented, so a change to the script that is not reflected here fails
# here.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
WD="$HERE/../nexusq-wifi-watchdog"
PASS=0; FAIL=0

for fn in repairs_in repair_ok write_state; do
    eval "$(sed -n "/^# TESTABLE:$fn\$/,/^}/p" "$WD")"
    if ! type "$fn" >/dev/null 2>&1; then
        echo "could not extract $fn from $WD — did the TESTABLE marker move?" >&2
        exit 2
    fi
done

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
F="$T/wifi-watchdog.json"

check() {  # check <got> <expected> <why>
    if [ "$1" = "$2" ]; then
        PASS=$((PASS+1)); printf '  \033[32mPASS\033[0m  %-40s %s\n' "$1" "$3"
    else
        FAIL=$((FAIL+1)); printf '  \033[31mFAIL\033[0m  %-40s (expected %s) %s\n' "$1" "$2" "$3"
    fi
}

# field <file> <key>: the value of one key, read by a real JSON parser.
field() {
    python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(json.dumps(d.get(sys.argv[2])))' "$1" "$2" 2>/dev/null \
        || echo INVALID-JSON
}

echo "=== the count survives a watchdog restart ==="
check "$(repairs_in "$F")" 0                 "no file yet (first start this boot) -> 0"
write_state "$F" 0
check "$(repairs_in "$F")" 0                 "the start marker says 0"
write_state "$F" 3 heal true 1234
check "$(repairs_in "$F")" 3                 "after three repairs a restart resumes at 3"
write_state "$F" 12 reconnect false 99999
check "$(repairs_in "$F")" 12                "two-digit counts are read whole"
printf 'garbage\n' > "$F"
check "$(repairs_in "$F")" 0                 "an unreadable file starts over rather than breaking the loop"

echo "=== the file is one valid JSON document ==="
write_state "$F" 0
check "$(field "$F" repairs)"     0          "start marker: repairs"
check "$(field "$F" last_kind)"   null       "start marker carries no last repair"
write_state "$F" 2 reconnect false 4567
check "$(field "$F" repairs)"     2          "repairs"
check "$(field "$F" last_kind)"   '"reconnect"' "last_kind is a string"
check "$(field "$F" last_ok)"     false      "last_ok is a JSON boolean"
check "$(field "$F" last_uptime)" 4567       "last_uptime is a number"
check "$(ls "$T" | tr '\n' ' ')" "wifi-watchdog.json " "no tempfile is left behind"

echo "=== a repair is ok only when the link came back usable ==="
check "$(repair_ok yes 0 75)"   true         "associated, no loss"
check "$(repair_ok yes 50 75)"  true         "associated, loss under the bad threshold"
check "$(repair_ok yes 75 75)"  false        "loss AT the threshold is what the watchdog calls bad"
check "$(repair_ok yes 100 75)" false        "associated but still dead"
check "$(repair_ok no 0 75)"    false        "not associated at all"

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
