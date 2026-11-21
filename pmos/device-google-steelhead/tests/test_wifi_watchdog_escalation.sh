#!/usr/bin/env bash
# Tests for the repair ladder in nexusq-wifi-watchdog.
#
# What is being protected: on 2026-11-18 08:02 the BCM4330 stopped answering on
# its SDIO bus. The watchdog noticed within two minutes and then spent three
# days (~1 200 reconnects, every one `assoc:no`) repeating the only thing it
# knew — an nmcli bounce — against a chip no nmcli call can reach. The ladder
# below is what ends that: soft repairs first, then a power-cycle of the chip,
# then (only when nothing else can reach the box, and never in a loop) a reboot.
#
# The functions are extracted from the script by their TESTABLE markers rather
# than reimplemented, so a change to the script that is not reflected here
# fails here.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
WD="$HERE/../nexusq-wifi-watchdog"
PASS=0; FAIL=0

for fn in escalation reboot_allowed other_route; do
    eval "$(sed -n "/^# TESTABLE:$fn\$/,/^}/p" "$WD")"
    if ! type "$fn" >/dev/null 2>&1; then
        echo "could not extract $fn from $WD — did the TESTABLE marker move?" >&2
        exit 2
    fi
done

check() {  # check <expected> <why> <got...>   (got is the command's stdout)
    local expected="$1" why="$2" got="$3"
    if [ "$got" = "$expected" ]; then
        PASS=$((PASS+1)); printf '  \033[32mPASS\033[0m  %-12s %s\n' "$got" "$why"
    else
        FAIL=$((FAIL+1)); printf '  \033[31mFAIL\033[0m  %-12s (expected %s) %s\n' "$got" "$expected" "$why"
    fi
}

echo "=== escalation: failed repairs in a row, chip resets tried (defaults 2 / 2) ==="
check soft   "first repair of an outage"                    "$(escalation 0 0)"
check soft   "one failure is not yet a pattern"             "$(escalation 1 0)"
check reset  "two nmcli repairs failed: the chip itself"    "$(escalation 2 0)"
check reset  "still failing, first reset did not take"      "$(escalation 3 1)"
check reboot "two resets failed too"                        "$(escalation 4 2)"
check reboot "and it stays on the last rung"                "$(escalation 9 5)"

echo "=== escalation: the thresholds are parameters ==="
check reset  "reset after 1 failure"                        "$(escalation 1 0 1 2)"
check soft   "reset after 3 failures: not yet at 2"         "$(escalation 2 0 3 2)"
check reboot "reboot after 1 failed reset"                  "$(escalation 2 1 2 1)"

echo "=== reboot_allowed: (uptime-s other-route reboots-in-a-row) ==="
check yes         "an hour up, nothing else reaches it, first reboot"   "$(reboot_allowed 3600 no 0)"
check yes         "third reboot of three is still the last allowed"     "$(reboot_allowed 3600 no 2)"
check other-route "ethernet carries the box: wlan0 is not worth a reboot" "$(reboot_allowed 3600 yes 0)"
check young       "booted 5 minutes ago: a slow boot, not a wedge"      "$(reboot_allowed 300 no 0)"
check limit       "already rebooted 3 times without ever recovering"    "$(reboot_allowed 3600 no 3)"
check other-route "other-route wins over limit (reported first)"        "$(reboot_allowed 3600 yes 9)"
check yes         "custom minimum uptime"                               "$(reboot_allowed 100 no 0 60 3)"
check limit       "custom maximum"                                      "$(reboot_allowed 3600 no 1 600 1)"

echo "=== other_route: only a default route over another interface counts ==="
check no  "no default route at all"        "$(other_route '')"
check no  "wlan0 only"                     "$(other_route 'default via 192.168.20.1 dev wlan0 proto dhcp metric 600')"
check yes "ethernet default"               "$(other_route 'default via 192.168.20.1 dev eth0 proto dhcp metric 100')"
check yes "ethernet next to wlan0"         "$(other_route $'default via 192.168.20.1 dev eth0 metric 100\ndefault via 192.168.20.1 dev wlan0 metric 600')"
check no  "a non-default route is ignored" "$(other_route '172.16.43.0/24 dev usb0 proto kernel scope link src 172.16.43.1')"
check yes "the USB gadget as default route" "$(other_route 'default via 172.16.43.2 dev usb0')"

echo
echo "passed $PASS, failed $FAIL"
[ "$FAIL" -eq 0 ]
