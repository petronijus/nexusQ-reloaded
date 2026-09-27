#!/bin/sh
# nq-pulse.sh, the PulseAudio helpers the service launchers share.
#
# wait_for_pulse: roon-nexusq and librespot-nexusq must not touch PulseAudio
# before it answers. pulseaudio.service is Type=simple here (no sd_notify), so
# After= only orders against the fork, and at boot Roon's load-module calls met
# "Connection refused" and failed the unit (until device r114).
#
# pulse_volume_percent: librespot-nexusq passes it as --initial-volume. Without
# it librespot 0.8.0 sets its mixer -- since r117 the Q's one volume -- to 50 %
# at every start. `pactl` is a stub on PATH.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
. "$HERE/../nq-pulse.sh"
PASS=0; FAIL=0
check() { if [ "$1" = "$2" ]; then PASS=$((PASS+1)); echo "  PASS  $3"; else FAIL=$((FAIL+1)); echo "  FAIL  $3 (got '$1', expected '$2')"; fi; }
stub() {  # stub <refusals before it answers>
    echo 0 > "$T/n"
    printf '#!/bin/sh\nn=$(cat %s/n); echo $((n+1)) > %s/n\n[ "$n" -ge %s ] && exit 0\necho "Connection refused" >&2; exit 1\n' "$T" "$T" "$1" > "$T/pactl"
    chmod +x "$T/pactl"
}
volstub() {  # volstub <what get-sink-volume prints> [exit]
    printf '#!/bin/sh\n[ "$1" = get-sink-volume ] || exit 1\nprintf "%%s\\n" "%s"\nexit %s\n' "$1" "${2:-0}" > "$T/pactl"
    chmod +x "$T/pactl"
}
sleep() { :; }            # no real waiting in the test
PATH="$T:$PATH"

echo "=== wait_for_pulse ==="
stub 0; wait_for_pulse 60; check $? 0 "PulseAudio already up: returns at once"
check "$(cat "$T/n")" 1 "  after exactly one pactl call"
stub 5; wait_for_pulse 60; check $? 0 "refused 5 times, then up: waits and returns 0"
check "$(cat "$T/n")" 6 "  having asked 6 times"
stub 1000; wait_for_pulse 60; check $? 1 "never answers: gives up after its tries (systemd restarts the unit)"
check "$(cat "$T/n")" 60 "  having asked exactly 60 times"

echo "=== pulse_volume_percent ==="
volstub 'Volume: front-left: 26214 /  40% / -23.88 dB,   front-right: 26214 /  40% / -23.88 dB'
check "$(pulse_volume_percent)" 40 "stereo at 40 %"
volstub 'Volume: front-left: 19661 /  30% / -31.37 dB,   front-right: 32768 /  50% / -18.06 dB'
check "$(pulse_volume_percent)" 50 "a balance: the loudest channel, as the control reads it"
volstub 'Volume: mono: 65536 / 100% / 0.00 dB'
check "$(pulse_volume_percent)" 100 "mono at 100 %"
volstub 'Volume: front-left: 78643 / 120% / 4.75 dB,   front-right: 78643 / 120% / 4.75 dB'
check "$(pulse_volume_percent)" 120 "above 100 % is reported as is (the launcher caps it)"
volstub 'Volume: front-left: 0 /   0% / -inf dB,   front-right: 0 /   0% / -inf dB'
check "$(pulse_volume_percent)" 0 "silence is 0, not 'unknown'"
volstub '' 1
pulse_volume_percent >/dev/null; check $? 1 "PulseAudio cannot say: status 1, nothing printed"
volstub 'Connection failure: Connection refused' 1
check "$(pulse_volume_percent)" "" "  and no number made up from an error message"

echo "=== the launchers use it ==="
for f in roon-nexusq librespot-nexusq shairport-nexusq; do
    grep -q '^\. /usr/lib/nexusq/nq-pulse\.sh$' "$HERE/../$f"; check $? 0 "$f sources nq-pulse.sh"
    grep -q '^wait_for_pulse()' "$HERE/../$f"; check $? 1 "$f has no copy of its own"
done
grep -q -- '--mixer alsa --alsa-mixer-device nexusq_vol --alsa-mixer-control Master' "$HERE/../librespot-nexusq"
check $? 0 "librespot drives the nexusq_vol control"
grep -q -- '--initial-volume "\$VOL"' "$HERE/../librespot-nexusq"
check $? 0 "  starting at the sink's current volume"
grep -q -- '--initial-volume [0-9]' "$HERE/../librespot-nexusq"
check $? 1 "  never at a fixed one"

echo
echo "================ $PASS passed, $FAIL failed ================"
[ "$FAIL" -eq 0 ]
