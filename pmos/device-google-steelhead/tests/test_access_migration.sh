#!/usr/bin/env bash
# Tests for the r90 -> r91 access migration (.pre-upgrade / .post-upgrade).
#
# What is being protected: up to r90 the package OWNED /root/.ssh/authorized_keys,
# /etc/skel/.ssh/authorized_keys and the NetworkManager WiFi profile. r91 ships
# none of them, and apk REMOVES files that leave a package's file list — so
# without these two scripts, upgrading a box in the field deletes its WiFi profile
# and its root authorized_keys in one transaction. Offline and locked out; for the
# cottage unit that is a car journey. This is the only test that stands between
# that and a published package.
#
# The scripts use absolute paths (they run as root on the device), so the whole
# thing runs inside a throwaway container that plays the part of the device.
#
# Usage: pmos/device-google-steelhead/tests/test_access_migration.sh
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
PKGDIR="$HERE/.."
command -v docker >/dev/null || { echo "docker required" >&2; exit 2; }

run_case() {  # run_case <name> <script-body>
    docker run --rm -i \
        -v "$PKGDIR/device-google-steelhead.pre-upgrade":/pre:ro \
        -v "$PKGDIR/device-google-steelhead.post-upgrade":/post:ro \
        alpine:3.21 sh -s <<EOF
set -u
PSK_LINE='psk=hunter2-not-the-real-one'
$2
EOF
}

PASS=0; FAIL=0
check() {  # check <name> <output> <expected-marker>
    if printf '%s' "$2" | grep -q "$3"; then
        PASS=$((PASS+1)); printf '  \033[32mPASS\033[0m  %s\n' "$1"
    else
        FAIL=$((FAIL+1)); printf '  \033[31mFAIL\033[0m  %s\n' "$1"
        printf '%s\n' "$2" | sed 's/^/        /'
    fi
}

# Sets up a device that looks like it is running r90.
SETUP='
mkdir -p /root/.ssh /etc/skel/.ssh /etc/NetworkManager/system-connections
echo "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAI_fake_key petr@desktop" > /root/.ssh/authorized_keys
cp /root/.ssh/authorized_keys /etc/skel/.ssh/authorized_keys
printf "[wifi-security]\nkey-mgmt=wpa-psk\n%s\n" "$PSK_LINE" \
    > /etc/NetworkManager/system-connections/wifi.nmconnection
chmod 600 /root/.ssh/authorized_keys /etc/skel/.ssh/authorized_keys \
          /etc/NetworkManager/system-connections/wifi.nmconnection
chmod 700 /root/.ssh /etc/skel/.ssh
'
# What apk does between the two scripts: remove the files that left the file list.
APK_REMOVES='
rm -f /root/.ssh/authorized_keys /etc/skel/.ssh/authorized_keys \
      /etc/NetworkManager/system-connections/wifi.nmconnection
'

echo "=== 1. the real upgrade: r90 files survive r91 ==="
out=$(run_case survive "$SETUP
sh /pre 2>/dev/null
$APK_REMOVES
sh /post 2>/dev/null
ok=1
for f in /root/.ssh/authorized_keys /etc/skel/.ssh/authorized_keys \\
         /etc/NetworkManager/system-connections/wifi.nmconnection; do
    [ -s \"\$f\" ] || { echo \"MISSING \$f\"; ok=0; }
done
grep -q \"\$PSK_LINE\" /etc/NetworkManager/system-connections/wifi.nmconnection || { echo 'PSK LOST'; ok=0; }
[ \"\$ok\" = 1 ] && echo ALLRESTORED")
check "all three files survive the upgrade" "$out" "ALLRESTORED"

echo "=== 2. modes survive — a 0644 profile is silently ignored by NM ==="
out=$(run_case modes "$SETUP
sh /pre 2>/dev/null
$APK_REMOVES
sh /post 2>/dev/null
stat -c '%a %n' /etc/NetworkManager/system-connections/wifi.nmconnection /root/.ssh/authorized_keys
stat -c 'DIR %a' /root/.ssh")
check "wifi profile restored 0600" "$out" "600 /etc/NetworkManager"
check "root authorized_keys restored 0600" "$out" "600 /root/.ssh/authorized_keys"
check "/root/.ssh restored 0700" "$out" "DIR 700"

echo "=== 3. the stash is cleaned up on success ==="
out=$(run_case cleanup "$SETUP
sh /pre 2>/dev/null
$APK_REMOVES
sh /post 2>/dev/null
[ -d /var/lib/nexusq/access-migration ] && echo STASH-LEFT || echo STASH-GONE")
check "stash removed once everything is restored" "$out" "STASH-GONE"

echo "=== 4. a package that DOES ship a file must win — never clobber apk ==="
out=$(run_case nocloober "$SETUP
sh /pre 2>/dev/null
$APK_REMOVES
echo 'ssh-ed25519 AAAA_NEW_FROM_PACKAGE newer@key' > /root/.ssh/authorized_keys
sh /post 2>/dev/null
grep -q NEW_FROM_PACKAGE /root/.ssh/authorized_keys && echo PACKAGE-WINS || echo CLOBBERED")
check "a file the new package installed is not overwritten" "$out" "PACKAGE-WINS"

echo "=== 5. a public build (no access on the box) is a clean no-op ==="
out=$(run_case public '
mkdir -p /root/.ssh
sh /pre 2>/dev/null; rc1=$?
sh /post 2>/dev/null; rc2=$?
echo "rc $rc1 $rc2"
[ -d /var/lib/nexusq ] && echo STASH-CREATED || echo NO-STASH')
check "nothing to stash exits 0 and creates nothing" "$out" "rc 0 0"
check "no stray /var/lib/nexusq on a box with no access" "$out" "NO-STASH"

echo "=== 6. running post-upgrade twice must not resurrect deleted files ==="
# i.e. the stash really is gone, so a later legitimate deletion stays deleted.
out=$(run_case idempotent "$SETUP
sh /pre 2>/dev/null
$APK_REMOVES
sh /post 2>/dev/null
rm -f /root/.ssh/authorized_keys
sh /post 2>/dev/null
[ -e /root/.ssh/authorized_keys ] && echo RESURRECTED || echo STAYS-DELETED")
check "a second post-upgrade does not restore from a consumed stash" "$out" "STAYS-DELETED"

echo
echo "================ $PASS passed, $FAIL failed ================"
[ "$FAIL" -eq 0 ]
