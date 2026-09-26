#!/usr/bin/env bash
# Tests for r110: systemd-oomd stays off, on a fresh image AND on a box upgraded
# in the field.
#
# Why three mechanisms are needed, and so three things are checked:
#   * 20-nexusq-oomd-off.preset decides every later `systemctl preset` pass — but
#     only if it sorts before 90-systemd.preset, which enables oomd;
#   * .post-install removes the enable links systemd's own configure already made
#     before the preset existed (a fresh image);
#   * .post-upgrade reaches a box that took an earlier image, where oomd is
#     enabled and running and neither of the above ever runs.
#
# .post-upgrade uses absolute paths (it runs as root on the device), so its cases
# run in a throwaway container playing the device, like test_access_migration.sh.
#
# Usage: pmos/device-google-steelhead/tests/test_oomd_off.sh
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
PKGDIR="$HERE/.."
command -v docker >/dev/null || { echo "docker required" >&2; exit 2; }

PASS=0; FAIL=0
check() {  # check <name> <output> <expected-marker>
    if printf '%s' "$2" | grep -q "$3"; then
        PASS=$((PASS+1)); printf '  \033[32mPASS\033[0m  %s\n' "$1"
    else
        FAIL=$((FAIL+1)); printf '  \033[31mFAIL\033[0m  %s\n' "$1"
        printf '%s\n' "$2" | sed 's/^/        /'
    fi
}

run_case() {  # run_case <script-body>
    docker run --rm -i \
        -v "$PKGDIR/device-google-steelhead.post-upgrade":/post:ro \
        alpine:3.21 sh -s <<EOF
set -u
$1
EOF
}

# A box as an earlier image left it: oomd's three enable links, plus an
# unrelated enabled unit that must survive untouched.
ENABLED='
mkdir -p /etc/systemd/system/multi-user.target.wants /etc/systemd/system/sockets.target.wants
ln -s /usr/lib/systemd/system/systemd-oomd.service /etc/systemd/system/multi-user.target.wants/systemd-oomd.service
ln -s /usr/lib/systemd/system/systemd-oomd.socket  /etc/systemd/system/sockets.target.wants/systemd-oomd.socket
ln -s /usr/lib/systemd/system/systemd-oomd.service /etc/systemd/system/dbus-org.freedesktop.oom1.service
ln -s /usr/lib/systemd/system/sshd.service         /etc/systemd/system/multi-user.target.wants/sshd.service
'
LEFT='
n=0
for f in /etc/systemd/system/multi-user.target.wants/systemd-oomd.service \
         /etc/systemd/system/sockets.target.wants/systemd-oomd.socket \
         /etc/systemd/system/dbus-org.freedesktop.oom1.service; do
    [ -L "$f" ] && { echo "STILL $f"; n=$((n+1)); }
done
echo "oomd-links-left $n"
[ -L /etc/systemd/system/multi-user.target.wants/sshd.service ] && echo SSHD-KEPT
'

echo "=== 1. the preset wins over 90-systemd.preset ==="
P="$PKGDIR/20-nexusq-oomd-off.preset"
first=$(printf '%s\n' "$(basename "$P")" 90-systemd.preset | LC_ALL=C sort | head -1)
check "sorts before 90-systemd.preset (first match wins)" "$first" "^20-nexusq-oomd-off.preset$"
rules=$(grep -vE '^\s*(#|$)' "$P")
check "disables the service" "$rules" "^disable systemd-oomd.service$"
check "disables the socket" "$rules" "^disable systemd-oomd.socket$"
AB=$(cat "$PKGDIR/APKBUILD")
check "is in the APKBUILD's source list" "$AB" "^	20-nexusq-oomd-off.preset$"
check "is installed into system-preset" "$AB" \
    '"$pkgdir"/usr/lib/systemd/system-preset/20-nexusq-oomd-off.preset'
check "has a checksum entry" "$AB" "^SKIP  20-nexusq-oomd-off.preset$"

echo "=== 1b. systemd's ManagedOOM defaults are shadowed, or oomd comes back ==="
# PID 1 turns ManagedOOMMemoryPressure=kill (systemd's 10-oomd-defaults.conf on
# user@.service, -.slice, system.slice) into Wants=systemd-oomd.service: disabled
# or not, the first user session started it again (cottage Q, device r110).
for d in 'user@.service.d' '-.slice.d' 'system.slice.d'; do
    check "APKBUILD shadows $d/10-oomd-defaults.conf" "$AB" \
        "^	for _d in \"user@.service.d\" \"-.slice.d\" \"system.slice.d\"; do\$"
done
check "each shadow is a /dev/null symlink in /etc" "$AB" \
    'ln -sf /dev/null "\$pkgdir/etc/systemd/system/\$_d/10-oomd-defaults.conf"'

echo "=== 2. a fresh image: .post-install removes all three enable links ==="
pi=$(cat "$PKGDIR/device-google-steelhead.post-install")
for l in multi-user.target.wants/systemd-oomd.service \
         sockets.target.wants/systemd-oomd.socket \
         dbus-org.freedesktop.oom1.service; do
    check "post-install removes $l" "$pi" "/etc/systemd/system/$l"
done

echo "=== 3. an upgrade outside a booted systemd removes the links by hand ==="
out=$(run_case "$ENABLED
sh /post; echo \"rc \$?\"
$LEFT")
check "exits 0" "$out" "^rc 0$"
check "all three oomd links gone" "$out" "oomd-links-left 0"
check "an unrelated enabled unit is untouched" "$out" "SSHD-KEPT"

echo "=== 4. an upgrade on a live box asks systemd: disable --now, both units ==="
out=$(run_case "$ENABLED
mkdir -p /run/systemd/system /fakebin
printf '#!/bin/sh\necho \"\$*\" >> /tmp/systemctl.log\n' > /fakebin/systemctl
chmod +x /fakebin/systemctl
PATH=/fakebin:\$PATH sh /post; echo \"rc \$?\"
cat /tmp/systemctl.log")
check "exits 0" "$out" "^rc 0$"
check "reloads PID 1 first, so the /etc drop-in shadows take effect" "$out" \
    "^daemon-reload$"
check "calls disable --now on the service and the socket" "$out" \
    "^disable --now systemd-oomd.service systemd-oomd.socket$"
check "in that order" "$(printf '%s\n' "$out" | grep -E '^(daemon-reload|disable)' | head -1)" \
    "^daemon-reload$"

echo "=== 5. a failing systemctl never fails the upgrade ==="
out=$(run_case "$ENABLED
mkdir -p /run/systemd/system /fakebin
printf '#!/bin/sh\nexit 1\n' > /fakebin/systemctl
chmod +x /fakebin/systemctl
PATH=/fakebin:\$PATH sh /post 2>&1; echo \"rc \$?\"")
check "exits 0" "$out" "^rc 0$"
check "says so on stderr" "$out" "could not disable systemd-oomd"

echo "=== 6. idempotent: a box with oomd already off is a clean no-op ==="
out=$(run_case "
sh /post; echo \"rc1 \$?\"
sh /post; echo \"rc2 \$?\"")
check "first run exits 0" "$out" "^rc1 0$"
check "second run exits 0" "$out" "^rc2 0$"

echo "=== 7. the first-boot unit's link: apk's .apk-new replaces the preset's ==="
# (Kept in this file because it is the same script and the same container.)
out=$(run_case "
mkdir -p /etc/systemd/system/sysinit.target.wants
ln -s /etc/systemd/system/nexusq-resize-rootfs.service /etc/systemd/system/sysinit.target.wants/nexusq-resize-rootfs.service
ln -s ../nexusq-resize-rootfs.service /etc/systemd/system/sysinit.target.wants/nexusq-resize-rootfs.service.apk-new
sh /post; echo \"rc \$?\"
ls /etc/systemd/system/sysinit.target.wants/
echo \"target \$(readlink /etc/systemd/system/sysinit.target.wants/nexusq-resize-rootfs.service)\"")
check "exits 0" "$out" "^rc 0$"
check "no .apk-new left for systemd to trip over" "$(printf '%s' "$out" | grep -c 'apk-new' || true)" "^0$"
check "the link is the package's" "$out" "^target ../nexusq-resize-rootfs.service$"

echo
echo "================ $PASS passed, $FAIL failed ================"
[ "$FAIL" -eq 0 ]
