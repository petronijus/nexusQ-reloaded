#!/bin/sh
# roon-nexusq must not create its PulseAudio source and loopback before
# PulseAudio answers: pulseaudio.service is Type=simple here (no sd_notify), so
# After= only orders against the fork, and at boot the load-module calls met
# "Connection refused" and failed the unit. The function is extracted by its
# TESTABLE marker; `pactl` is a stub that refuses a given number of times.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
eval "$(sed -n '/^# TESTABLE:wait_for_pulse$/,/^}/p' "$HERE/../roon-nexusq")"
command -v wait_for_pulse >/dev/null 2>&1 || { echo "could not extract wait_for_pulse" >&2; exit 2; }
PASS=0; FAIL=0
check() { if [ "$1" = "$2" ]; then PASS=$((PASS+1)); echo "  PASS  $3"; else FAIL=$((FAIL+1)); echo "  FAIL  $3 (got $1, expected $2)"; fi; }
stub() {  # stub <refusals before it answers>
    echo 0 > "$T/n"
    printf '#!/bin/sh\nn=$(cat %s/n); echo $((n+1)) > %s/n\n[ "$n" -ge %s ] && exit 0\necho "Connection refused" >&2; exit 1\n' "$T" "$T" "$1" > "$T/pactl"
    chmod +x "$T/pactl"
}
sleep() { :; }            # no real waiting in the test
PATH="$T:$PATH"
stub 0; wait_for_pulse 60; check $? 0 "PulseAudio already up: returns at once"
check "$(cat "$T/n")" 1 "  after exactly one pactl call"
stub 5; wait_for_pulse 60; check $? 0 "refused 5 times, then up: waits and returns 0"
check "$(cat "$T/n")" 6 "  having asked 6 times"
stub 1000; wait_for_pulse 60; check $? 1 "never answers: gives up after its tries (systemd restarts the unit)"
check "$(cat "$T/n")" 60 "  having asked exactly 60 times"
echo
echo "================ $PASS passed, $FAIL failed ================"
[ "$FAIL" -eq 0 ]
