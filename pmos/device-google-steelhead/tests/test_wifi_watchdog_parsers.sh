#!/bin/sh
# Tests for the watchdog's fork diet (device r110): parse_link, parse_gw and
# parse_loss replace `iw | grep`, `iw | awk`, `ip | awk` and `ping | grep | grep`
# on every 30 s check. What is being protected is that the watchdog still sees
# exactly what it saw before — a parser that silently read "no gateway" or "100 %
# loss" would make it bounce a healthy link; one that read "associated" on a dead
# link would stop it healing the wedge it exists for.
#
# So every case is DIFFERENTIAL: the old pipeline and the new parser run on the
# same input, and must agree. The inputs under fixtures/ were captured on the
# cottage Q (SSID and BSSID replaced); the rest are the edge shapes.
#
# The functions are extracted by their TESTABLE markers, not reimplemented. Plain
# POSIX sh on purpose: run it under the device's shell too —
#   docker run --rm -v "$PWD:/w" -w /w alpine:3.21 sh pmos/device-google-steelhead/tests/test_wifi_watchdog_parsers.sh
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
WD="$HERE/../nexusq-wifi-watchdog"
FX="$HERE/fixtures"
PASS=0; FAIL=0

for fn in parse_link parse_gw parse_loss; do
    eval "$(sed -n "/^# TESTABLE:$fn\$/,/^}/p" "$WD")"
    command -v "$fn" >/dev/null 2>&1 || {
        echo "could not extract $fn from $WD — did the TESTABLE marker move?" >&2
        exit 2
    }
done

check() {  # check <got> <expected> <why>
    if [ "$1" = "$2" ]; then
        PASS=$((PASS+1)); printf '  PASS  %-22s %s\n' "'$1'" "$3"
    else
        FAIL=$((FAIL+1)); printf '  FAIL  %-22s (expected %s) %s\n' "'$1'" "'$2'" "$3"
    fi
}

# The pipelines the parsers replace, verbatim from r109.
old_assoc()  { printf '%s\n' "$1" | grep -q "Connected to" && echo yes || echo no; }
old_signal() { printf '%s\n' "$1" | awk '/signal:/{print $2; exit}'; }
old_gw()     { printf '%s\n' "$1" | awk '/default/{print $3; exit}'; }
old_loss()   { printf '%s\n' "$1" | grep -oE '[0-9]+% packet loss' | grep -oE '^[0-9]+' || echo 100; }

link_case() {  # link_case <input> <why>
    parse_link "$1"
    check "$LINK_ASSOC" "$(old_assoc "$1")"  "assoc:  $2"
    check "$LINK_SIG"   "$(old_signal "$1")" "signal: $2"
}
loss_case() {  # loss_case <input> <why>
    parse_loss "$1"
    check "$LOSS" "$(old_loss "$1")" "loss:   $2"
}

echo "=== iw dev wlan0 link ==="
link_case "$(cat "$FX/iw-link-connected.txt")"     "associated (captured)"
link_case "$(cat "$FX/iw-link-not-connected.txt")" "not connected (captured shape)"
link_case ""                                        "iw failed / no output"
link_case "$(printf 'Connected to 02:00:00:00:00:02 (on wlan0)\n\tsignal: -83 dBm\n')" "weak signal, two digits"
link_case "$(printf 'Connected to 02:00:00:00:00:03 (on wlan0)\n\tSSID: x\n')" "associated, no signal line yet"

echo "=== ip route show default dev wlan0 ==="
parse_gw "$(cat "$FX/ip-route-default.txt")"
check "$GW" "$(old_gw "$(cat "$FX/ip-route-default.txt")")" "gateway (captured)"
check "$GW" "192.168.50.1"                                  "gateway is the address, not a word"
parse_gw "$(cat "$FX/ip-route-none.txt")"
check "$GW" ""                                              "no default route -> empty (nogw)"
parse_gw "$(printf 'default via 10.0.0.1 proto dhcp metric 600\ndefault via 10.0.0.2 proto dhcp metric 700\n')"
check "$GW" "10.0.0.1"                                      "two default routes -> the first, as awk did"
# The one deliberate difference: a default route with no gateway. awk printed
# its third word; that was never an address, and the watchdog pinged it.
parse_gw "$(printf 'default scope link \n')"
check "$GW" ""                                              "gateway-less default route -> no gateway"

echo "=== ping ==="
loss_case "$(cat "$FX/ping-ok.txt")"          "0 % (captured)"
loss_case "$(cat "$FX/ping-unreachable.txt")" "100 % (captured)"
loss_case "$(cat "$FX/ping-no-summary.txt")"  "no summary line -> 100"
loss_case ""                                   "no output at all -> 100"
loss_case "$(printf '4 packets transmitted, 3 packets received, 25%% packet loss\n')" "25 %"

echo
echo "================ $PASS passed, $FAIL failed ================"
[ "$FAIL" -eq 0 ]
