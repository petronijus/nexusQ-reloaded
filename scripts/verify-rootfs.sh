#!/usr/bin/env bash
# verify-rootfs.sh — prove a built rootfs is actually what we think it is.
#
# A green build exit code is NOT success. v1.5.0 silently shipped an **OpenRC**
# rootfs with no nexusqd and no sshd, and it passed the build AND the checksums;
# the only thing that would have caught it is mounting the image and looking.
# These gates lived as prose in .claude/agents/nexusq-build.md, which is exactly
# why they were skippable — this makes them runnable and exit-coded.
#
# Usage:
#   scripts/verify-rootfs.sh <rootfs.img|rootfs-sparse.img> [boot.img]
#
# Read-only: mounts the image with -o ro and never writes to it. Needs sudo for
# the loop mount (SUDO_PASS via op-cache is picked up automatically if present).
set -uo pipefail

IMG="${1:?usage: verify-rootfs.sh <rootfs.img> [boot.img]}"
BOOTIMG="${2:-}"
MNT="$(mktemp -d)"
RAW=""
PASS=0
FAIL=0

cleanup() {
    mountpoint -q "$MNT" 2>/dev/null && sudo umount "$MNT"
    rmdir "$MNT" 2>/dev/null
    [ -n "$RAW" ] && [ -f "$RAW" ] && rm -f "$RAW"
}
trap cleanup EXIT

say()  { printf '%s\n' "$*"; }
ok()   { PASS=$((PASS+1)); printf '  \033[32mPASS\033[0m  %-52s %s\n' "$1" "${2:-}"; }
bad()  { FAIL=$((FAIL+1)); printf '  \033[31mFAIL\033[0m  %-52s %s\n' "$1" "${2:-}"; }
has()  { [ -e "$MNT/$1" ]; }
chk_has() { if has "$1"; then ok "$2" "$1"; else bad "$2" "missing: $1"; fi; }

# --- sparse -> raw if needed --------------------------------------------------
# Android sparse magic is 0xed26ff3a (little-endian on disk). Read it as a
# number instead of grepping binary, which is locale- and NUL-sensitive.
if [ "$(od -An -tx4 -N4 "$IMG" | tr -d ' ')" = "ed26ff3a" ]; then
    RAW="$(mktemp --suffix=.img)"
    say "sparse image detected, converting -> $RAW"
    simg2img "$IMG" "$RAW" || { say "simg2img failed"; exit 2; }
    IMG="$RAW"
fi

say "=== mounting $IMG read-only ==="
sudo mount -o loop,ro "$IMG" "$MNT" || { say "mount failed"; exit 2; }

say ""
say "=== 1. init system (the v1.5.0 gate) ==="
init_target="$(readlink -f "$MNT/sbin/init" 2>/dev/null || echo '?')"
case "$init_target" in
    *systemd*) ok "/sbin/init is systemd" "${init_target#$MNT}" ;;
    *busybox*) bad "/sbin/init is systemd" "resolves to busybox -> OpenRC image!" ;;
    *)         bad "/sbin/init is systemd" "unresolved: $init_target" ;;
esac
if grep -qE '^(openrc|busybox-openrc|postmarketos-base-openrc)$' \
        <(awk -F: '/^P:/{print $2}' "$MNT/lib/apk/db/installed" 2>/dev/null); then
    bad "no OpenRC packages installed" "openrc present in apk db"
else
    ok "no OpenRC packages installed"
fi
if has etc/runlevels; then bad "no /etc/runlevels"; else ok "no /etc/runlevels"; fi

say ""
say "=== 2. the daemons that must exist ==="
chk_has usr/bin/nexusqd                                              "nexusqd binary"
chk_has usr/lib/systemd/system/multi-user.target.wants/nexusqd.service "nexusqd enabled"
chk_has usr/sbin/sshd                                                "sshd (server)"
chk_has usr/bin/ssh                                                  "ssh (client)"
chk_has usr/bin/nq-healthd                                           "nq-healthd"
chk_has etc/systemd/system/nq-healthd.service                        "nq-healthd unit"
chk_has usr/bin/nexusq-control                                       "nexusq-control"
chk_has usr/bin/nexusq-mqtt                                          "nexusq-mqtt"

say ""
say "=== 3. idle-power set (device r73, 2026-08-16) ==="
chk_has usr/bin/nexusq-cpufreq-tune                                  "cpufreq-tune script"
chk_has etc/systemd/system/nexusq-cpufreq-tune.service               "cpufreq-tune unit"
chk_has etc/systemd/system/multi-user.target.wants/nexusq-cpufreq-tune.service \
                                                                     "cpufreq-tune enabled"
for u in etc/systemd/system/nq-healthd.service \
         etc/systemd/system/nexusq-wifi-watchdog.service \
         etc/systemd/system/nexusq-nfc.service \
         usr/lib/systemd/system/nexusq-mqtt.service \
         usr/lib/systemd/system/nexusq-btagent.service; do
    if [ -f "$MNT/$u" ]; then
        if grep -q '^Nice=19' "$MNT/$u"; then ok "Nice=19 in $(basename "$u")"
        else bad "Nice=19 in $(basename "$u")" "found: $(grep -m1 '^Nice=' "$MNT/$u" || echo none)"; fi
    else
        bad "Nice=19 in $(basename "$u")" "unit missing"
    fi
done
# nexusq-control must NOT be nice'd — it serves the app's volume RPC
if [ -f "$MNT/usr/lib/systemd/system/nexusq-control.service" ]; then
    if grep -q '^Nice=' "$MNT/usr/lib/systemd/system/nexusq-control.service"; then
        bad "nexusq-control NOT nice'd" "$(grep -m1 '^Nice=' "$MNT/usr/lib/systemd/system/nexusq-control.service")"
    else
        ok "nexusq-control NOT nice'd" "(deliberate: app volume RPC)"
    fi
fi
if [ -f "$MNT/usr/bin/nexusq-btagent" ]; then
    if grep -q 'SETUPD_CGROUP' "$MNT/usr/bin/nexusq-btagent"; then
        ok "btagent uses the cgroup test" "no systemctl polling"
    else
        bad "btagent uses the cgroup test" "SETUPD_CGROUP absent -> old r4 code"
    fi
fi

say ""
say "=== 4. streaming / Roon layout ==="
chk_has opt/glibc-rt/bin/bash                                        "glibc-rt present"
if has opt/glibc-rt/opt/RoonBridge; then
    bad "RoonBridge NOT baked" "present — must be lazy-fetched at runtime"
else
    ok "RoonBridge NOT baked"
fi
if compgen -G "$MNT/usr/lib/systemd/*/*wants*/roon.service" >/dev/null 2>&1 \
   || compgen -G "$MNT/etc/systemd/*/*wants*/roon.service" >/dev/null 2>&1; then
    bad "Roon is default-OFF" "an enable symlink exists"
else
    ok "Roon is default-OFF"
fi

say ""
say "=== 5. python3 integrity gate ==="
# The gate takes the .so itself, not a rootfs root — find it inside the image.
# This is the [[sparse-dontcare-stale-emmc-corrupts-flash]] backstop: a
# libpython whose zero-regions came back as device garbage SIGSEGVs on boot.
GATE=scripts/verify-libpython-clean.py
LIBPY="$(find "$MNT/usr/lib" -maxdepth 1 -name 'libpython3*.so*' -type f 2>/dev/null | head -1)"
if [ ! -f "$GATE" ]; then
    say "  (skipped: $GATE not found)"
elif [ -z "$LIBPY" ]; then
    bad "libpython present" "no libpython3*.so under usr/lib"
elif python3 "$GATE" "$LIBPY" >/dev/null 2>&1; then
    ok "libpython clean" "$(basename "$LIBPY")"
else
    bad "libpython clean" "run: python3 $GATE '$LIBPY' --verbose"
fi

say ""
say "=== 6. boot.img ==="
if [ -n "$BOOTIMG" ] && [ -f "$BOOTIMG" ]; then
    sz=$(stat -c %s "$BOOTIMG")
    if [ "$sz" -le $((8*1024*1024)) ]; then
        ok "boot.img <= 8 MB" "$((sz/1024)) KiB"
    else
        bad "boot.img <= 8 MB" "$((sz/1024)) KiB — will fail fastboot with error=-27"
    fi
    # ramdisk size lives at offset 0x10 in the Android boot header
    rd=$(od -An -tu4 -j16 -N4 "$BOOTIMG" | tr -d ' ')
    if [ "${rd:-1}" = "0" ]; then
        ok "boot.img is ramdisk-less" "ramdisk_size=0"
    else
        bad "boot.img is ramdisk-less" "ramdisk_size=$rd — initramfs bundled"
    fi
else
    say "  (no boot.img given — pass it as the 2nd argument to check size/ramdisk)"
fi

say ""
say "================ $PASS passed, $FAIL failed ================"
[ "$FAIL" -eq 0 ]
