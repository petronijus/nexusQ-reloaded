#!/usr/bin/env bash
# needs: docker  (tools/dev/test-shell.sh runs it in the docker lane, `just test-sh-docker`)
# Tests for init-split, the maintenance initramfs that gives a unit ALREADY IN
# THE FIELD its slot B (nexusq-rootfs-ab r2, 2026-09-26) -- and for the normal
# boot after it, which finishes the job.
#
# What is being protected: init-split shrinks the ext4 that fills p13 and rewrites
# the partition table, unattended, on units whose owners never asked for it (the
# OTA starts it). So every path must end in a unit that boots: split and whole, or
# exactly as it was. This runs the real init, on a real kernel, against a disk
# that is a Nexus Q's as far as the table goes -- the factory primary GPT copied
# off a unit (pmos/device-google-steelhead/tests/fixtures/gpt-primary-factory.bin)
# on a sparse image the size of the eMMC, attached as a loop device -- with p13
# formatted to fill the partition the way a unit that has been running looks.
#
# NQ_SPLIT_DISK points the init at the loop device and NQ_SPLIT_REBOOT replaces
# `reboot -f`; as PID 1 on the unit it has no environment, so those are only
# ever the defaults there. The "normal boot" is the real nexusq-resize-rootfs
# against the re-attached loop device.
#
# Usage: userspace/nexusq-rootfs-ab/tests/test_init_split.sh   (docker, --privileged)
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../../.." && pwd)"
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

# run_case <env for the init> <script body run after the init>
# Setup: a "running unit" -- p13 ext4 filling the partition, with the resize
# flag set and some files, like any unit flashed before r112. Then the init.
run_case() {
    docker run --rm -i --privileged \
        -v "$HERE/../init-split":/init-split:ro \
        -v "$HERE/../ab-lib.sh":/lib/ab-lib.sh:ro \
        -v "$HERE/../ab-lib.sh":/usr/lib/nexusq-rootfs-ab/ab-lib.sh:ro \
        -v "$REPO/pmos/device-google-steelhead/nexusq-resize-rootfs":/resize:ro \
        -v "$REPO/pmos/device-google-steelhead/tests/fixtures/gpt-primary-factory.bin":/gpt.bin:ro \
        alpine:3.21 sh -s <<EOF
set -u
apk add -q util-linux sfdisk partx e2fsprogs e2fsprogs-extra blkid >/dev/null 2>&1
mount -t devtmpfs devtmpfs /dev 2>/dev/null || true
truncate -s \$((30777344 * 512)) /disk.img
dd if=/gpt.bin of=/disk.img conv=notrunc 2>/dev/null
L=\$(losetup -fP --show /disk.img); N=\${L#/dev/}
i=0; while [ ! -b \${L}p13 ] && [ \$i -lt 50 ]; do sleep 0.1; i=\$((i+1)); done
dd if=/dev/urandom of=\${L}p9 bs=1M count=8 2>/dev/null     # "slot A's kernel"
mkfs.ext4 -q -L pmOS_root \${L}p13                          # fills p13: a unit in the field
mkdir -p /mnt/root && mount \${L}p13 /mnt/root
mkdir -p /mnt/root/var/lib/nexusq /mnt/root/home/user
touch /mnt/root/var/lib/nexusq/.rootfs-resized
dd if=/dev/urandom of=/mnt/root/home/user/data.bin bs=1M count=64 2>/dev/null
md5sum /mnt/root/home/user/data.bin | cut -d' ' -f1 > /data.md5
umount /mnt/root
layout() { sfdisk -d \$L 2>/dev/null | grep -E '^last-lba|p13 |p14 ' | sed "s|\$L|D|"; }
fsblocks() { dumpe2fs -h \$1 2>/dev/null | awk -F: '/^Block count/{gsub(/ /,"",\$2);print \$2}'; }
p13state() {
    mount \${L}p13 /mnt/root
    echo "result=\$(cat /mnt/root/var/lib/nexusq/ab-migrate.result 2>/dev/null | cut -d' ' -f1)"
    [ -f /mnt/root/var/lib/nexusq/.ab-split-pending ] && echo PENDING || echo NO-PENDING
    [ -f /mnt/root/var/lib/nexusq/.rootfs-resized ] && echo RESIZED-FLAG || echo NO-RESIZED-FLAG
    [ "\$(md5sum /mnt/root/home/user/data.bin | cut -d' ' -f1)" = "\$(cat /data.md5)" ] && echo DATA-INTACT || echo DATA-CHANGED
    umount /mnt/root
}
reattach() {   # the reboot: the kernel reads the table from disk
    losetup -d \$L; L=\$(losetup -fP --show /disk.img); N=\${L#/dev/}
    i=0; while [ ! -b \${L}p13 ] && [ \$i -lt 50 ]; do sleep 0.1; i=\$((i+1)); done
    sleep 0.5
}
$1 NQ_SPLIT_DISK=\$N NQ_SPLIT_REBOOT=true sh /init-split > /init.out 2>&1
echo "init rc=\$?"
$2
losetup -d \$L 2>/dev/null
EOF
}

echo "=== 1. a unit in the field: shrink, split, then the normal boot finishes ==="
out=$(run_case "" '
echo "fs=$(fsblocks ${L}p13)"
e2fsck -fn ${L}p13 >/dev/null 2>&1; echo "fsck p13 rc=$?"
layout
p13state
[ "$(cmp -n 8388608 ${L}p8 ${L}p9 && echo same)" = same ] && echo TRIAL-SLOT-RESTORED
reattach
mount ${L}p13 /mnt/root
NQ_ROOT_MNT=/mnt/root NQ_STATE_DIR=/mnt/root/var/lib/nexusq sh /resize; echo "resize rc=$?"
echo "after boot: label p14=$(blkid -o value -s LABEL ${L}p14)"
[ -f /mnt/root/var/lib/nexusq/.ab-split-pending ] && echo PENDING-LEFT || echo PENDING-CLEARED
[ -f /mnt/root/var/lib/nexusq/.rootfs-resized ] && echo FLAG-SET
umount /mnt/root
e2fsck -fn ${L}p14 >/dev/null 2>&1; echo "fsck p14 rc=$?"')
check "the init ends in its reboot (rc 0)"            "$out" '^init rc=0$'
check "the ext4 is shrunk to exactly slot A (1723520 blocks)" "$out" '^fs=1723520$'
check "and it is clean"                                "$out" '^fsck p13 rc=0$'
check "GPT: p13 start=3200000 size=13788160"          "$out" 'Dp13 : start= *3200000, size= *13788160'
check "GPT: p14 start=16988160 size=13789151 userdata_b" "$out" 'Dp14 : start= *16988160, size= *13789151, .*name="userdata_b"'
check "GPT: last-lba 30777310 (B8 fixed)"             "$out" '^last-lba: 30777310$'
check "result ok recorded on p13"                     "$out" '^result=ok$'
check "pending marker left for the normal boot"       "$out" '^PENDING$'
check "resize flag removed so the normal boot runs"   "$out" '^NO-RESIZED-FLAG$'
check "user data intact across the shrink"            "$out" '^DATA-INTACT$'
check "trial slot restored from slot A (single-shot)" "$out" '^TRIAL-SLOT-RESTORED$'
check "normal boot: resize-rootfs exits 0"            "$out" '^resize rc=0$'
check "normal boot formats slot B as pmOS_root_b"     "$out" '^after boot: label p14=pmOS_root_b$'
check "and clears the pending marker"                 "$out" '^PENDING-CLEARED$'
check "and sets the resize flag"                      "$out" '^FLAG-SET$'
check "slot B is clean"                               "$out" '^fsck p14 rc=0$'

echo "=== 2. it does not fit: nothing is changed ==="
out=$(run_case "NQ_SPLIT_HEADROOM_MIB=20000" '
echo "fs=$(fsblocks ${L}p13)"
layout
p13state
grep -o "result: [^ ]*" /init.out')
check "the init still reboots cleanly"                "$out" '^init rc=0$'
check "result names the reason"                       "$out" 'result=failed:does-not-fit'
check "the ext4 is untouched (still fills p13)"        "$out" '^fs=3447168$'
check "the table is untouched (p13 to the end, no p14)" "$out" 'Dp13 : start= *3200000, size= *27577344'
check "no slot B"                                     "$(printf '%s' "$out" | grep -c 'Dp14' || true)" '^0$'
check "no pending marker"                             "$out" '^NO-PENDING$'
check "the resize flag is left as it was"             "$out" '^RESIZED-FLAG$'

echo "=== 3. the shrink fails: the table is untouched, the next boot grows back ==="
# The init sets its own PATH, so the failing resize2fs has to BE the binary:
# the real one moves aside and the stand-in only passes `-P` through to it.
out=$(run_case "mv /usr/sbin/resize2fs /usr/sbin/resize2fs.real; printf '#!/bin/sh\ncase \"\$1\" in -P) exec /usr/sbin/resize2fs.real \"\$@\";; esac\nexit 1\n' > /usr/sbin/resize2fs; chmod +x /usr/sbin/resize2fs;" '
layout
p13state
mv /usr/sbin/resize2fs.real /usr/sbin/resize2fs
reattach
mount ${L}p13 /mnt/root
NQ_ROOT_MNT=/mnt/root NQ_STATE_DIR=/mnt/root/var/lib/nexusq sh /resize; echo "resize rc=$?"
f=none; [ -f /mnt/root/var/lib/nexusq/.rootfs-resized ] && f=set
umount /mnt/root
p=none; [ -b ${L}p14 ] && p=present
echo "back: fs=$(fsblocks ${L}p13) p14=$p flag=$f"')
check "the init still reboots cleanly"                "$out" '^init rc=0$'
check "result names the reason"                       "$out" 'result=failed:resize2fs'
check "the table is untouched"                        "$out" 'Dp13 : start= *3200000, size= *27577344'
check "resize flag removed: the next boot grows back over p13" "$out" '^NO-RESIZED-FLAG$'
check "user data intact"                              "$out" '^DATA-INTACT$'
check "normal boot: resize-rootfs exits 0"            "$out" '^resize rc=0$'
check "normal boot: the unit is exactly as it was (ext4 fills p13, no p14, flag set)" "$out" '^back: fs=3447168 p14=none flag=set$'

echo "=== 4. already split: refuses at once ==="
# Set up a unit that is already split (table with p14, a slot-A-sized ext4).
out=$(run_case "sfdisk -d \$L 2>/dev/null | grep -v '^last-lba' | sed 's/size= *27577344/size=13788160/' > /t; echo \"\${L}p14 : start=16988160, size=13789151, name=\\\"userdata_b\\\"\" >> /t; sfdisk -q -f \$L < /t >/dev/null 2>&1; reattach; mkfs.ext4 -q -F \${L}p13; mount \${L}p13 /mnt/root; mkdir -p /mnt/root/var/lib/nexusq /mnt/root/home/user; cp /dev/null /mnt/root/home/user/data.bin; umount /mnt/root;" '
grep -o "result: [^ ]*" /init.out
p13state')
check "result: p14 exists"                            "$out" 'result: failed:p14-exists'
check "no pending marker"                             "$out" '^NO-PENDING$'
check "the result is still recorded on p13"           "$out" '^result=failed:p14-exists$'

echo
echo "================ $PASS passed, $FAIL failed ================"
[ "$FAIL" -eq 0 ]
