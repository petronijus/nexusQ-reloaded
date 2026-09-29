#!/usr/bin/env bash
# needs: docker  (tools/dev/test-shell.sh runs it in the docker lane, `just test-sh-docker`)
# Tests for the first-boot A/B split in nexusq-resize-rootfs (device r112).
#
# What is being protected: the script repartitions the eMMC while slot A is
# MOUNTED as root. Done wrong it grows the root ext4 into slot B, formats over a
# rootfs, or leaves a table the kernel and the disk disagree about. So this runs
# the real script, on a real kernel, against a disk that IS a Nexus Q's as far as
# the partition table goes: a sparse image the size of the eMMC (30777344
# sectors) carrying the factory primary GPT copied off a unit
# (fixtures/gpt-primary-factory.bin — p13 "userdata" to the last sector, no room
# for the backup GPT, i.e. B8), attached as a loop device with partition scanning,
# its p13 formatted and mounted the way a fresh flash leaves it.
#
# The expected result is the layout the Prague unit was split to by hand on
# 2026-08-20, sector for sector:
#   p13 start=3200000  size=13788160  "userdata"
#   p14 start=16988160 size=13789151  "userdata_b"
#   last-lba 30777310 (backup GPT at the real end)
#
# Needs docker with --privileged (loop devices, BLKPG, a mount). The image is
# sparse: it costs a few MB of the Docker VM's disk, not 15 GB.
#
# Usage: pmos/device-google-steelhead/tests/test_ab_split.sh
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
command -v docker >/dev/null || { echo "docker required" >&2; exit 2; }

PASS=0; FAIL=0
check() {  # check <name> <output> <expected-marker (ERE)>
    # A here-string, not a pipe: under pipefail, grep -q quitting at the first
    # match SIGPIPEs a printf still writing a large output, and the check fails.
    if grep -qE -e "$3" <<<"$2"; then
        PASS=$((PASS+1)); printf '  \033[32mPASS\033[0m  %s\n' "$1"
    else
        FAIL=$((FAIL+1)); printf '  \033[31mFAIL\033[0m  %s\n' "$1"
        printf '%s\n' "$2" | sed 's/^/        /' | tail -40
    fi
}

# run_case <fs size for p13, e.g. 2900M or "full"> <script body run after setup>
# Setup leaves: $L (loop device), $ROOT (p13 mounted there), $STATE, and the
# script at /split. Everything is torn down at the end.
run_case() {
    docker run --rm -i --privileged \
        -v "$HERE/../nexusq-resize-rootfs":/split:ro \
        -v "$HERE/../../../userspace/nexusq-rootfs-ab/ab-lib.sh":/usr/lib/nexusq-rootfs-ab/ab-lib.sh:ro \
        -v "$HERE/fixtures/gpt-primary-factory.bin":/gpt.bin:ro \
        alpine:3.21 sh -s <<EOF
set -u
apk add -q util-linux sfdisk partx e2fsprogs e2fsprogs-extra blkid >/dev/null 2>&1
mountpoint -q /dev || true
mount -t devtmpfs devtmpfs /dev 2>/dev/null || true
truncate -s \$((30777344 * 512)) /disk.img
dd if=/gpt.bin of=/disk.img conv=notrunc 2>/dev/null
L=\$(losetup -fP --show /disk.img); N=\${L#/dev/}
i=0; while [ ! -b \${L}p13 ] && [ \$i -lt 50 ]; do sleep 0.1; i=\$((i+1)); done
if [ "$1" = full ]; then mkfs.ext4 -q -L pmOS_root \${L}p13; else mkfs.ext4 -q -L pmOS_root \${L}p13 $1; fi
ROOT=/mnt/root; mkdir -p \$ROOT; mount \${L}p13 \$ROOT
STATE=\$ROOT/var/lib/nexusq; mkdir -p \$STATE
run() { NQ_ROOT_MNT=\$ROOT NQ_STATE_DIR=\$STATE sh /split; echo "rc=\$?"; }
layout() { sfdisk -d \$L 2>/dev/null | grep -E '^last-lba|p13 |p14 ' | sed "s|\$L|D|"; }
$2
umount \$ROOT 2>/dev/null
for p in 13 14; do [ -b \${L}p\$p ] && { e2fsck -fn \${L}p\$p >/dev/null 2>&1; echo "fsck p\$p rc=\$?"; }; done
losetup -d \$L
EOF
}

echo "=== 1. a fresh flash: split to the Prague layout, then grow ==="
out=$(run_case 2900M '
run
echo "kernel p13=$(cat /sys/class/block/${N}p13/size) p14=$(cat /sys/class/block/${N}p14/size 2>/dev/null)"
layout
sfdisk -V $L 2>&1 | sed "s/^/verify: /"
sfdisk -d $L 2>&1 >/dev/null | grep -qi "backup GPT table is corrupt" && echo BACKUP-GPT-CORRUPT || echo BACKUP-GPT-OK
echo "label p14=$(blkid -o value -s LABEL ${L}p14)"
echo "rootsize=$(df -k $ROOT | awk "NR==2{print \$2}")"
[ -f $STATE/.rootfs-resized ] && echo FLAG-SET
[ -f $STATE/.ab-split-pending ] && echo PENDING-LEFT || echo PENDING-CLEARED
[ -s $STATE/gpt-before-ab.sfdisk ] && echo OLD-TABLE-KEPT')
check "exits 0"                                   "$out" '^rc=0$'
check "kernel sees p13 = 13788160 and p14 = 13789151" "$out" '^kernel p13=13788160 p14=13789151$'
check "GPT: p13 start=3200000 size=13788160"      "$out" 'Dp13 : start= *3200000, size= *13788160, .*name="userdata"'
check "GPT: p14 start=16988160 size=13789151"     "$out" 'Dp14 : start= *16988160, size= *13789151, .*name="userdata_b"'
check "GPT: last-lba 30777310 (B8 fixed)"         "$out" '^last-lba: 30777310$'
check "GPT verifies"                              "$out" '^verify: No errors detected'
check "the backup GPT is valid now (B8 gone)"     "$out" '^BACKUP-GPT-OK$'
check "slot B is ext4 labelled pmOS_root_b"       "$out" '^label p14=pmOS_root_b$'
check "root grew to fill the new slot A (> 6 GiB)" "$out" '^rootsize=6[0-9]{6}$'
check "once-only flag set"                        "$out" '^FLAG-SET$'
check "pending marker cleared"                    "$out" '^PENDING-CLEARED$'
check "the original table is kept for recovery"   "$out" '^OLD-TABLE-KEPT$'
check "slot A fsck clean"                         "$out" '^fsck p13 rc=0$'
check "slot B fsck clean"                         "$out" '^fsck p14 rc=0$'

echo "=== 2. idempotent: a second run changes nothing ==="
out=$(run_case 2900M '
run >/dev/null
before=$(layout; blkid -o value -s UUID ${L}p14)
rm -f $STATE/.rootfs-resized          # as if the unit condition had not guarded it
run
after=$(layout; blkid -o value -s UUID ${L}p14)
[ "$before" = "$after" ] && echo UNCHANGED || { echo CHANGED; echo "$before"; echo "$after"; }')
check "second run exits 0"                        "$out" '^rc=0$'
check "table and slot B untouched"                "$out" '^UNCHANGED$'

echo "=== 3. the kernel does not take the new layout: never grow into slot B ==="
out=$(run_case 2900M '
mkdir -p /stub; printf "#!/bin/sh\nexit 1\n" > /stub/resizepart; chmod +x /stub/resizepart
PATH=/stub:$PATH run
echo "fs after failed run=$(dumpe2fs -h ${L}p13 2>/dev/null | awk -F: "/Block count/{gsub(/ /,\"\",\$2);print \$2}")"
[ -f $STATE/.rootfs-resized ] && echo FLAG-SET || echo FLAG-NOT-SET
# "reboot": the kernel reads the table from disk
umount $ROOT; losetup -d $L; L=$(losetup -fP --show /disk.img); N=${L#/dev/}
i=0; while [ ! -b ${L}p14 ] && [ $i -lt 50 ]; do sleep 0.1; i=$((i+1)); done
mount ${L}p13 $ROOT
run
echo "after reboot: kernel p13=$(cat /sys/class/block/${N}p13/size) label p14=$(blkid -o value -s LABEL ${L}p14)"
echo "rootsize=$(df -k $ROOT | awk "NR==2{print \$2}")"')
check "failed run exits non-zero"                 "$out" '^rc=1$'
check "the root ext4 was NOT grown"               "$out" '^fs after failed run=742400$'
check "flag not set, so the next boot runs again" "$out" '^FLAG-NOT-SET$'
check "next boot formats slot B"                  "$out" 'after reboot: kernel p13=13788160 label p14=pmOS_root_b'
check "next boot grows slot A"                    "$out" '^rootsize=6[0-9]{6}$'
check "and exits 0"                               "$out" '^rc=0$'

echo "=== 4. a unit whose root already fills p13 (flashed before r112): no split ==="
out=$(run_case full '
run
layout')
check "exits 0"                                   "$out" '^rc=0$'
check "no slot B is created"                      "$(printf '%s' "$out" | grep -c 'Dp14' || true)" '^0$'
check "p13 left at its factory size"              "$out" 'Dp13 : start= *3200000, size= *27577344'

echo
echo "================ $PASS passed, $FAIL failed ================"
[ "$FAIL" -eq 0 ]
