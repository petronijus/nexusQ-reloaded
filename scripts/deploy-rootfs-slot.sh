#!/usr/bin/env bash
# deploy-rootfs-slot.sh -- write a BUILT rootfs image into the Q's inactive A/B
# slot over ssh, verify it, and optionally boot it once as a trial.
#
# The A/B split (2026-08-20) made a rootfs update something other than a
# reflash: the inactive slot is written while the unit keeps serving from the
# active one, and a slot that does not come up costs one reboot. But the only
# way to fill a slot was `nq-rootfs-ab populate`, which copies the RUNNING
# rootfs -- the right tool for an apk-upgraded system, no use for a freshly
# built image. This is the other half: build output -> inactive slot, with no
# cable and no fastboot.
#
#   scripts/deploy-rootfs-slot.sh [--try] [--reboot] output/google-steelhead.img
#
#   (no flag)  write + verify the inactive slot, change nothing about booting
#   --try      also arm a one-shot trial of that slot (nq-rootfs-ab try)
#   --reboot   with --try: reboot into it, wait, and report whether the unit's
#              health gate committed it (nq-rootfs-ab autopromote)
#
# What it guarantees, in order:
#   - the host it talks to answers `hostname` = steelhead (never trust an IP);
#   - it only ever writes the slot that is NOT running, and refuses a mounted one;
#   - the bytes on the partition are the image's bytes (sha256, read back);
#   - the filesystem is clean (e2fsck -fp exits 0) before anything else touches it;
#   - the slot keeps ITS OWN label and UUID (an image written to both slots would
#     otherwise carry one UUID twice), and its fstab names that UUID, as
#     `populate` does;
#   - the ext4 is left at the image's size: the image's own first-boot
#     nexusq-resize-rootfs grows it, exactly as after a fastboot flash.
#
# The image must be RAW ext4 (output/google-steelhead.img). A sparse image
# (nexusq-rootfs-*-sparse.img) is refused -- convert it with simg2img first.
#
# Env: NQ_SSH_TARGET (default: the USB gadget's link-local address).
set -euo pipefail

TRY=0; REBOOT=0; IMG=""
for a in "$@"; do
    case "$a" in
        --try) TRY=1 ;;
        --reboot) REBOOT=1 ;;
        -h|--help) sed -n '2,32p' "$0"; exit 0 ;;
        -*) echo "unknown option $a" >&2; exit 2 ;;
        *) IMG=$a ;;
    esac
done
[ -n "$IMG" ] || { echo "usage: $0 [--try] [--reboot] <raw rootfs image>" >&2; exit 2; }
[ -f "$IMG" ] || { echo "no such image: $IMG" >&2; exit 2; }
[ "$REBOOT" = 0 ] || [ "$TRY" = 1 ] || { echo "--reboot needs --try" >&2; exit 2; }

TARGET=${NQ_SSH_TARGET:-root@fe80::1a:11ff:fe00:1%enx021a11000002}
SSH=(ssh -o IdentityAgent=none -o ConnectTimeout=10 -o ServerAliveInterval=15 "$TARGET")
say() { echo "deploy-rootfs-slot: $*"; }
die() { echo "deploy-rootfs-slot: ERROR: $*" >&2; exit 1; }

# --- the image -------------------------------------------------------------
magic=$(od -An -tx4 -N4 "$IMG" | tr -d ' ')
[ "$magic" != "ed26ff3a" ] || die "$IMG is an Android SPARSE image; write the raw one (simg2img $IMG raw.img)"
ext4_magic=$(od -An -tx2 -j $((1024 + 56)) -N2 "$IMG" | tr -d ' ')
[ "$ext4_magic" = "ef53" ] || die "$IMG is not an ext4 filesystem image (superblock magic $ext4_magic)"
SIZE=$(stat -c %s "$IMG")
say "image $IMG: $SIZE bytes, hashing"
SHA=$(sha256sum "$IMG" | cut -d' ' -f1)

# --- the unit --------------------------------------------------------------
host=$("${SSH[@]}" hostname) || die "cannot reach $TARGET"
[ "$host" = steelhead ] || die "$TARGET answers as '$host', not steelhead -- refusing"

status=$("${SSH[@]}" nq-rootfs-ab status) || die "nq-rootfs-ab status failed"
running=$(awk '/running slot/ {print $5; exit}' <<<"$status")
pending=$(awk '/one-shot try/ {print $5; exit}' <<<"$status")
case "$running" in a) slot=b; dev=/dev/mmcblk0p14 ;; b) slot=a; dev=/dev/mmcblk0p13 ;;
    *) die "cannot tell the running slot from: $status" ;; esac
[ "$pending" = none ] || die "a one-shot trial of slot '$pending' is already armed; resolve that first"
say "unit is running slot $running -> writing slot $slot ($dev)"

"${SSH[@]}" "! awk -v d=$dev '\$1 == d {f=1} END {exit !f}' /proc/mounts" \
    || die "$dev is mounted on the unit -- refusing"
part=$("${SSH[@]}" blockdev --getsize64 "$dev")
[ "$SIZE" -le "$part" ] || die "image ($SIZE B) is larger than $dev ($part B)"

# The slot's own identity, kept across the write. A slot that never held a
# filesystem gets the conventional label and a fresh UUID.
old_label=$("${SSH[@]}" "blkid -s LABEL -o value $dev 2>/dev/null" || true)
old_uuid=$("${SSH[@]}" "blkid -s UUID -o value $dev 2>/dev/null" || true)
[ -n "$old_label" ] || old_label=$([ "$slot" = a ] && echo pmOS_root || echo pmOS_root_b)
[ -n "$old_uuid" ] || old_uuid=random
say "slot $slot keeps label=$old_label uuid=$old_uuid"

# --- write -----------------------------------------------------------------
# gzip -1 on the wire: a fresh rootfs is mostly empty blocks, and the link (USB
# gadget, ssh-encrypted) is the bottleneck, not the unit's gunzip.
comp=(gzip -1 -c); command -v pigz >/dev/null && comp=(pigz -1 -c)
say "writing (compressed stream, conv=fsync)"
"${comp[@]}" "$IMG" | "${SSH[@]}" "gzip -dc | dd of=$dev bs=4M conv=fsync 2>/dev/null" \
    || die "write to $dev failed"

say "reading $SIZE bytes back from $dev"
got=$("${SSH[@]}" "head -c $SIZE $dev | sha256sum" | cut -d' ' -f1)
[ "$got" = "$SHA" ] || die "read-back sha256 $got != image $SHA -- slot $slot is NOT usable"
say "sha256 matches ($SHA)"

# -p (preen), required to exit 0: a clean filesystem is only stamped as
# checked, which tune2fs wants before it rewrites a metadata_csum UUID; anything
# e2fsck would have to FIX is a bad image, not something to repair here.
"${SSH[@]}" "e2fsck -f -p $dev >/dev/null 2>&1" || die "e2fsck -fp did not find $dev clean"
"${SSH[@]}" "tune2fs -L '$old_label' -U '$old_uuid' $dev >/dev/null" || die "tune2fs on $dev failed"
new_uuid=$("${SSH[@]}" "blkid -s UUID -o value $dev")

# fstab's / entry must name this slot's filesystem (the initramfs mounts /, so
# it is not load-bearing for the boot, but systemd must not be told / is a
# device it is not running from -- same fix nq-rootfs-ab populate applies).
"${SSH[@]}" sh -s -- "$dev" "$new_uuid" <<'REMOTE' || die "post-write fixups on the slot failed"
set -e
dev=$1; uuid=$2; mnt=/run/nq-deploy-slot
mkdir -p "$mnt"
mount -t ext4 "$dev" "$mnt"
trap 'umount "$mnt" 2>/dev/null || true' EXIT
[ -x "$mnt/sbin/init" ] || [ -L "$mnt/sbin/init" ] || { echo "no /sbin/init in the slot" >&2; exit 1; }
awk -v u="UUID=$uuid" '$2 == "/" && $0 !~ /^[[:space:]]*#/ { $1 = u; print; next } { print }' \
    "$mnt/etc/fstab" > "$mnt/etc/fstab.new"
mv "$mnt/etc/fstab.new" "$mnt/etc/fstab"
grep -q "^UUID=$uuid / " "$mnt/etc/fstab"
sync
REMOTE
say "slot $slot written and verified: label=$old_label uuid=$new_uuid, fstab updated"

[ "$TRY" = 1 ] || { say "done. Boot it once with: nq-rootfs-ab try $slot && systemctl reboot"; exit 0; }

"${SSH[@]}" nq-rootfs-ab try "$slot" >/dev/null || die "nq-rootfs-ab try $slot failed"
say "one-shot trial of slot $slot armed"
[ "$REBOOT" = 1 ] || { say "done. Reboot the unit to boot slot $slot once."; exit 0; }

say "rebooting into slot $slot"
"${SSH[@]}" systemctl reboot || true
sleep 15
for _ in $(seq 60); do "${SSH[@]}" true 2>/dev/null && break; sleep 5; done
host=$("${SSH[@]}" hostname) || die "the unit did not come back within 5 min -- a power cycle returns it to slot $running"
[ "$host" = steelhead ] || die "came back as '$host'"
now=$("${SSH[@]}" nq-rootfs-ab status | awk '/running slot/ {print $5; exit}')
[ "$now" = "$slot" ] || die "the unit came back on slot $now, not $slot -- the trial did not boot (it is safe on $now)"
say "running slot $slot; waiting for the health gate to commit it"
for _ in $(seq 30); do
    committed=$("${SSH[@]}" nq-rootfs-ab status | awk '/committed slot/ {print $5; exit}')
    [ "$committed" = "$slot" ] && { say "slot $slot COMMITTED -- it boots from here on"; exit 0; }
    sleep 10
done
die "slot $slot booted but was not committed within 5 min (see journalctl -u nexusq-rootfs-ab-promote); a reboot returns to slot $running"
