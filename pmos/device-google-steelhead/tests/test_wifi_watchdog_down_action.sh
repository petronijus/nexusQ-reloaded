#!/usr/bin/env bash
# Tests for the not-associated decision in nexusq-wifi-watchdog.
#
# What is being protected: on 2026-08-30 the watchdog's heal ran `nmcli device
# disconnect wlan0` and then a `nmcli device connect wlan0` that FAILED (empty
# scan cache after a brcmf_escan_timeout). `device disconnect` blocks
# NetworkManager's autoconnect until the next explicit connect, and the old
# watchdog treated every not-associated state as "NM owns re-association" — so a
# healthy box sat in state 30/disconnected for six days, logging `down` 16 536
# times and doing nothing about it. This table is the rule that ends that: a
# plainly disconnected device is OURS to reconnect after a threshold, while
# every state NM is actually working on, or has no device for, stays untouched.
#
# The function is extracted from the script by its TESTABLE marker rather than
# reimplemented, so a change to the script that is not reflected here fails here.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
WD="$HERE/../nexusq-wifi-watchdog"
PASS=0; FAIL=0

eval "$(sed -n '/^# TESTABLE:down_action/,/^}/p' "$WD")"
if ! type down_action >/dev/null 2>&1; then
    echo "could not extract down_action from $WD — did the TESTABLE marker move?" >&2
    exit 2
fi

check() {  # check <nm-state> <downs> <threshold> <expected> <why>
    local got; got="$(down_action "$1" "$2" "$3")"
    if [ "$got" = "$4" ]; then
        PASS=$((PASS+1)); printf '  \033[32mPASS\033[0m  nm=%-4s downs=%-2s thr=%s -> %-9s %s\n' "$1" "$2" "$3" "$got" "$5"
    else
        FAIL=$((FAIL+1)); printf '  \033[31mFAIL\033[0m  nm=%-4s downs=%-2s thr=%s -> %-9s (expected %s) %s\n' "$1" "$2" "$3" "$got" "$4" "$5"
    fi
}

echo "=== plainly disconnected: the stranded case this exists for ==="
check 30 1 4 wait      "first sight — give NM's own autoconnect its chance"
check 30 3 4 wait      "still under the threshold"
check 30 4 4 reconnect "threshold reached — autoconnect is blocked, we connect"
check 30 9 4 reconnect "and keeps asking until the cooldown lets it run"
check 120 4 4 reconnect "'failed' is what NM shows for a beat before 30; same answer"

echo "=== not ours: no device to connect ==="
check 10 99 4 leave    "unmanaged — NM is not driving wlan0 at all"
check 20 99 4 leave    "unavailable — radio off or driver gone; connecting fights it"
check ''  99 4 leave   "NM not answering — do not act on a blank"
check 0   99 4 leave   "unknown"

echo "=== not ours: NM is already (re)connecting ==="
check 40 99 4 leave    "prepare"
check 50 99 4 leave    "config — associating right now"
check 60 99 4 leave    "need-auth"
check 70 99 4 leave    "ip-config — associated, DHCP running (the nogw wedge is the assoc branch's job)"
check 110 99 4 leave   "deactivating — a heal or a user is mid-flight"

echo "=== the threshold is a parameter, not a constant ==="
check 30 2 2 reconnect "a lower threshold reconnects sooner"
check 30 2 3 wait      "and a higher one waits"

echo
echo "================ $PASS passed, $FAIL failed ================"
[ "$FAIL" -eq 0 ]
