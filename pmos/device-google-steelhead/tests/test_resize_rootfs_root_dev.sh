#!/usr/bin/env bash
# Tests for how nexusq-resize-rootfs finds the partition to grow.
#
# What is being protected: since the A/B split (2026-08-20) the root is p13 OR
# p14, whichever the initramfs mounted. The script used to say
# ROOT_DEV=/dev/mmcblk0p13, so a rootfs booted from slot B checked slot A's
# filesystem, found it already full, set its once-only flag and left slot B at
# its ~3 GB image size for good. root_device() asks the running system instead:
# the major:minor of / (mountpoint -d /) through /sys/dev/block.
#
# The function is extracted from the script by its TESTABLE marker rather than
# reimplemented, and runs against a fake sysfs laid out like the unit's
# (mmcblk partitions carry extended dev_t numbers, 259:N, not 179:N).
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/../nexusq-resize-rootfs"
PASS=0; FAIL=0

eval "$(sed -n '/^# TESTABLE:root_device$/,/^}/p' "$SCRIPT")"
if ! type root_device >/dev/null 2>&1; then
    echo "could not extract root_device from $SCRIPT — did the TESTABLE marker move?" >&2
    exit 2
fi

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
DEVS="$T/devices/platform/ocp/4809c000.mmc/mmc_host/mmc0/mmc0:0001/block/mmcblk0"
mkdir -p "$T/dev/block"
part() {  # part <name> <devt> <512-byte sectors>
    mkdir -p "$DEVS/$1"
    echo "$3" > "$DEVS/$1/size"
    ln -s "../../devices/platform/ocp/4809c000.mmc/mmc_host/mmc0/mmc0:0001/block/mmcblk0/$1" "$T/dev/block/$2"
}
part mmcblk0p12 259:4 1048576      # cache / nq-persist, 512 MiB
part mmcblk0p13 259:5 13788160     # slot A
part mmcblk0p14 259:6 13788672     # slot B, deliberately a different size

check() {  # check <got> <expected> <why>
    if [ "$1" = "$2" ]; then
        PASS=$((PASS+1)); printf '  \033[32mPASS\033[0m  %-32s %s\n' "$1" "$3"
    else
        FAIL=$((FAIL+1)); printf '  \033[31mFAIL\033[0m  %-32s (expected %s) %s\n' "$1" "$2" "$3"
    fi
}

echo "=== the partition / is on, whichever slot that is ==="
check "$(root_device 259:5 "$T")" "/dev/mmcblk0p13 7059537920" "booted from slot A"
check "$(root_device 259:6 "$T")" "/dev/mmcblk0p14 7059800064" "booted from slot B: its own device AND its own size"

echo "=== no guessing ==="
root_device 259:99 "$T" >/dev/null 2>&1; rc=$?
check "rc=$rc" "rc=1" "an unknown major:minor is an error, not a fallback to p13"

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
