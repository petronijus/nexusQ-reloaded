#!/bin/sh
# Tests for the checks `nq-rootfs-ab split --auto` makes before it reboots a unit
# into the maintenance image, which init-split repeats on the unmounted fs
# (nexusq-rootfs-ab r3): never while something plays (audio_busy), never when
# the ext4 would not go into slot A with its reserve (ab_fits, ab-lib.sh). The
# numbers are the cottage unit's, from its first automatic attempt on
# 2026-09-26, which the first version of the rule refused. The functions are
# extracted by their TESTABLE markers, not reimplemented.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
for pair in audio_busy:nq-rootfs-ab ab_fits:ab-lib.sh; do
    fn=${pair%%:*}; file=${pair#*:}
    eval "$(sed -n "/^# TESTABLE:$fn\$/,/^}/p" "$HERE/../$file")"
    command -v "$fn" >/dev/null 2>&1 || { echo "could not extract $fn" >&2; exit 2; }
done
PASS=0; FAIL=0
check() { if [ "$1" = "$2" ]; then PASS=$((PASS+1)); echo "  PASS  $3"; else FAIL=$((FAIL+1)); echo "  FAIL  $3 (got $1, expected $2)"; fi; }
yes_no() { if "$@"; then echo yes; else echo no; fi; }

T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
sub() { mkdir -p "$T/$1"; printf '%s\n' "$2" > "$T/$1/status"; }
sub card0/pcm0p/sub0 "state: SETUP"
sub card0/pcm1p/sub0 "closed"
sub card1/pcm0c/sub0 "state: RUNNING"          # a CAPTURE stream is not playback
check "$(yes_no audio_busy "$T")" no "idle: nothing playing (a running capture does not count)"
sub card1/pcm0p/sub0 "state: RUNNING
owner_pid   : 718"
check "$(yes_no audio_busy "$T")" yes "a running playback substream is busy"
check "$(yes_no audio_busy "$T/nonexistent")" no "no ALSA at all is not busy"

SLOT=1723520; RES=262144   # slot A and 1 GiB, in 4 KiB blocks
check "$(ab_fits 1611267 1411685 $SLOT $RES)" ok \
    "the cottage WITH its 2.6 GB of caches fits (the first rule, minimum + reserve, refused it)"
check "$(ab_fits 980000 780000 $SLOT $RES)" ok "the cottage without its caches: fits"
check "$(ab_fits 1800000 900000 $SLOT $RES)" "min1800000-over-slot1723520" \
    "resize2fs's own minimum over the slot always refuses, whatever is used"
check "$(ab_fits 1400000 1461376 $SLOT $RES)" ok "exactly at the reserve still fits"
check "$(ab_fits 1400000 1461377 $SLOT $RES)" "used1461377-plus-reserve262144-over-slot1723520" "one block over refuses"
echo
echo "================ $PASS passed, $FAIL failed ================"
[ "$FAIL" -eq 0 ]
