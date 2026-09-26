#!/bin/sh
# Tests for the librespot audio-cache cap (librespot-nexusq, device r112).
#
# The cap is 5 GiB but must never leave the rootfs slot with less than 1.5 GiB
# free: since every unit has two ~6.6 GB slots, a fixed 5 GiB next to a ~2.5 GB
# system would fill a slot, and a full root breaks apk upgrades and kernel OTA
# staging. The inputs below are the two units as measured on 2026-09-26.
#
# The function is extracted by its TESTABLE marker, not reimplemented.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
eval "$(sed -n '/^# TESTABLE:cache_limit_mib$/,/^}/p' "$HERE/../librespot-nexusq")"
command -v cache_limit_mib >/dev/null 2>&1 || { echo "could not extract cache_limit_mib" >&2; exit 2; }
CACHE_MAX_MIB=5120 CACHE_RESERVE_MIB=1536 CACHE_MIN_MIB=128
PASS=0; FAIL=0
check() {
    if [ "$1" = "$2" ]; then PASS=$((PASS+1)); printf '  PASS  %-6s %s\n' "$1" "$3"
    else FAIL=$((FAIL+1)); printf '  FAIL  %-6s (expected %s) %s\n' "$1" "$2" "$3"; fi
}
GiB=1048576   # KiB
check "$(cache_limit_mib $((73 * GiB / 10)) $((2 * GiB)))" 5120 "cottage before the split: 7.3 GiB free, 2.0 GiB cached -> the full 5 GiB"
check "$(cache_limit_mib $((34 * GiB / 10)) $((2 * GiB / 10)))" 2150 "Prague slot: 3.4 GiB free, 0.2 GiB cached -> leaves 1.5 GiB free"
check "$(cache_limit_mib $((1 * GiB)) 0)" 128 "almost full slot -> the floor, never zero or negative"
check "$(cache_limit_mib 0 0)" 128 "df failed (0) -> still a usable floor"
check "$(cache_limit_mib $((10 * GiB)) $((4 * GiB)))" 5120 "plenty of room never exceeds 5 GiB"
echo
echo "================ $PASS passed, $FAIL failed ================"
[ "$FAIL" -eq 0 ]
