#!/usr/bin/env bash
# Tests for nq-persist (device r103): the per-unit state store on the `cache`
# partition, and the r103 .pre-upgrade step that moves the identity file under
# it.
#
# What is being protected: a flash writes boot + userdata and resets everything
# per-unit to the image defaults -- which sources are on, the WiFi profile, the
# ssh host keys, the Bluetooth bonds, the name, the site's NTP server. The store
# ends that. These tests pin that (1) the partition is formatted exactly once
# and never when it is in use or already ours, (2) the store is seeded from the
# running rootfs on the upgrade path, (3) a "flash" (rootfs wiped, store kept)
# comes back with the unit's own state once the bind mounts are up -- and, as
# the control, that the same flash WITHOUT the store loses it, so the assertion
# is known to detect the loss, (4) writes parked under the unmounted mountpoint
# are merged but never clobber the store, (5) the site NTP drop-in puts the site
# first and dedups the fleet list, (6) the sshd host-key list names only keys
# that exist, (7) the usage is inert.
#
# nq-persist uses absolute paths (it runs as root on the device) but honours
# NQ_ROOT / NQ_PERSIST_DEV / NQ_PERSIST_MNT / NQ_RUN, so everything runs inside
# ONE throwaway --privileged container (loop mounts + bind mounts) that plays
# the device, on a loop image that plays the partition.
#
# Usage: pmos/device-google-steelhead/tests/test_persist.sh
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
PKGDIR="$HERE/.."
command -v docker >/dev/null || { echo "docker required" >&2; exit 2; }

# The whole suite is one container run; each case prints PASS/FAIL lines that
# the host tallies. Keeping it in one run means one apk add and one loop image.
out=$(docker run --rm -i --privileged \
    -v "$PKGDIR/nq-persist":/usr/bin/nq-persist:ro \
    -v "$PKGDIR/device-google-steelhead.pre-upgrade":/pre:ro \
    alpine:3.21 sh -s <<'EOF'
set -u
apk add -q --no-progress e2fsprogs blkid openssh-keygen util-linux-misc >/dev/null 2>&1 \
    || { echo "FAIL apk add (network?)"; exit 0; }

pass() { echo "PASS $*"; }
fail() { echo "FAIL $*"; }
check() {  # check <desc> <shell test...>
    d=$1; shift
    if eval "$@"; then pass "$d"; else fail "$d"; fi
}
OUT=/tmp/nq.out
run() {  # run <cmd...>  -> $OUT holds stdout+stderr, $rc the exit code (never eval'd)
    "$@" >"$OUT" 2>&1; rc=$?
}
said() { grep -q -- "$1" "$OUT"; }

export NQ_ROOT=/fake NQ_PERSIST_DEV=/img/cache.img NQ_PERSIST_MNT=/persist NQ_RUN=/fake/run/nexusq
export NQ_USER_OWNER=10000:10000
IMG=$NQ_PERSIST_DEV
mkdir -p /img /persist /fake/run /fake/etc/systemd/timesyncd.conf.d
truncate -s 64M "$IMG"

# ---- the rootfs of a unit in the field (what r102 left behind) -------------
fresh_rootfs() {  # fresh_rootfs <hostname>  -- image defaults: nothing per-unit
    rm -rf /fake/home /fake/etc/NetworkManager /fake/var /fake/etc/ssh /fake/etc/nexusq
    mkdir -p /fake/home/user/.config /fake/etc/NetworkManager/system-connections \
             /fake/var/lib/bluetooth /fake/etc/ssh /fake/etc/nexusq
    printf '%s\n' "$1" > /fake/etc/hostname
    cat > /fake/etc/systemd/timesyncd.conf.d/10-nexusq-ntp-by-ip.conf <<'F'
[Time]
NTP=162.159.200.1 216.239.35.0
FallbackNTP=162.159.200.123 216.239.35.4
F
}
unit_state() {  # the per-unit state a used unit carries
    mkdir -p /fake/home/user/.config/systemd/user/default.target.wants
    ln -s /usr/lib/systemd/user/nexusq-uac2-in.service \
        /fake/home/user/.config/systemd/user/default.target.wants/nexusq-uac2-in.service
    chown -R 10000:10000 /fake/home/user/.config/systemd
    printf '[wifi-security]\npsk=hunter2-not-the-real-one\n' > /fake/etc/NetworkManager/system-connections/wifi.nmconnection
    chmod 600 /fake/etc/NetworkManager/system-connections/wifi.nmconnection
    mkdir -p /fake/var/lib/bluetooth/F8:8F:CA:20:49:E5/AA:BB:CC:DD:EE:FF
    echo "[LinkKey]" > /fake/var/lib/bluetooth/F8:8F:CA:20:49:E5/AA:BB:CC:DD:EE:FF/info
    chmod 700 /fake/var/lib/bluetooth
    ssh-keygen -A -f /fake >/dev/null 2>&1        # -> /fake/etc/ssh/ssh_host_*
    NKEYS=$(ls /fake/etc/ssh/ssh_host_*_key | wc -l)   # 3 on Alpine 3.21's OpenSSH, 4 on the unit's 10.5 (adds mldsa44)
}
has_state() {  # what "the unit is itself again" means, as seen at the rootfs paths
    [ -L /fake/home/user/.config/systemd/user/default.target.wants/nexusq-uac2-in.service ] \
    && grep -q hunter2 /fake/etc/NetworkManager/system-connections/wifi.nmconnection 2>/dev/null \
    && [ -f /fake/var/lib/bluetooth/F8:8F:CA:20:49:E5/AA:BB:CC:DD:EE:FF/info ]
}
bind_all() {   # what the three .mount units do
    mount --bind /persist/user-systemd /fake/home/user/.config/systemd \
    && mount --bind /persist/nm-connections /fake/etc/NetworkManager/system-connections \
    && mount --bind /persist/bluetooth /fake/var/lib/bluetooth
}
unbind_all() {
    umount /fake/home/user/.config/systemd /fake/etc/NetworkManager/system-connections /fake/var/lib/bluetooth 2>/dev/null
    umount /persist 2>/dev/null
}

echo "=== 1. prepare: formats a foreign filesystem once, then leaves ours alone ==="
mkfs.ext4 -q -F "$IMG" >/dev/null 2>&1                      # stock Android's unlabelled ext4 cache
run nq-persist prepare
check "foreign ext4 is formatted (rc=$rc)" "[ $rc -eq 0 ] && said 'formatting as nq-persist'"
check "label is now nq-persist" "[ \"\$(blkid -s LABEL -o value $IMG)\" = nq-persist ]"
uuid1=$(blkid -s UUID -o value "$IMG")
run nq-persist prepare
check "second prepare does not reformat (rc=$rc)" "[ $rc -eq 0 ] && [ \"\$(blkid -s UUID -o value $IMG)\" = $uuid1 ] && said 'is the persist store'"

echo "=== 1b. prepare: refuses a mounted filesystem that is not ours ==="
truncate -s 32M /img/other.img; mkfs.ext4 -q -F /img/other.img >/dev/null 2>&1
mkdir -p /mnt/other && mount -o loop /img/other.img /mnt/other
loopdev=$(awk '$2 == "/mnt/other" {print $1}' /proc/mounts)
run env NQ_PERSIST_DEV=$loopdev nq-persist prepare
check "mounted foreign device is refused (rc=$rc)" "[ $rc -ne 0 ] && said 'refusing to format'"
umount /mnt/other

echo "=== 2. apply: seeds the store from a unit in the field (the upgrade path) ==="
fresh_rootfs steelhead; unit_state
mount -o loop "$IMG" /persist
run nq-persist apply
check "apply succeeds (rc=$rc)" "[ $rc -eq 0 ]"
check "toggle symlink seeded" "[ -L /persist/user-systemd/user/default.target.wants/nexusq-uac2-in.service ]"
check "store's user-systemd owned by 10000" "[ \"\$(stat -c %u:%g /persist/user-systemd)\" = 10000:10000 ]"
check "wifi profile seeded, mode kept" "grep -q hunter2 /persist/nm-connections/wifi.nmconnection && [ \"\$(stat -c %a /persist/nm-connections/wifi.nmconnection)\" = 600 ]"
check "bluetooth bond seeded" "[ -f /persist/bluetooth/F8:8F:CA:20:49:E5/AA:BB:CC:DD:EE:FF/info ]"
check "ssh host keys seeded ($NKEYS)" "[ \"\$(ls /persist/ssh/ssh_host_*_key | wc -l)\" = $NKEYS ]"
check "sshd host-key list rendered with $NKEYS HostKey lines into the store" "[ \"\$(grep -c '^HostKey /persist/ssh/' /fake/run/nexusq/sshd-hostkeys.conf)\" = $NKEYS ]"
check "hostname seeded" "[ \"\$(cat /persist/identity/hostname)\" = steelhead ]"
check "marker written" "grep -q 'nq-persist store v1' /persist/.nq-persist"
check "no site NTP drop-in without a site list" "[ ! -e /fake/run/systemd/timesyncd.conf.d/20-nexusq-site-ntp.conf ]"
fp_before=$(ssh-keygen -lf /persist/ssh/ssh_host_ed25519_key.pub | awk '{print $2}')
run nq-persist apply
check "apply is idempotent (rc=$rc, nothing re-seeded)" "[ $rc -eq 0 ] && ! said seeded"
umount /persist

echo "=== 3. the flash: rootfs wiped, store kept -> the unit is itself again ==="
fresh_rootfs steelhead-fresh                    # a flashed rootfs: image defaults, new hostname, no keys yet
check "control: a fresh rootfs has none of the state" "! has_state"
run nq-persist prepare && mount -o loop "$IMG" /persist && run nq-persist apply
check "prepare+apply after the flash (rc=$rc)" "[ $rc -eq 0 ]"
check "no reformat on the flash path" "[ \"\$(blkid -s UUID -o value $IMG)\" = $uuid1 ]"
check "hostname put back from the store" "[ \"\$(cat /fake/etc/hostname)\" = steelhead ] && said 'hostname applied'"
check "ssh keys NOT regenerated: same ed25519 fingerprint" "[ \"\$(ssh-keygen -lf /persist/ssh/ssh_host_ed25519_key.pub | awk '{print \$2}')\" = $fp_before ]"
check "mountpoints created on the fresh rootfs, user-owned" "[ -d /fake/home/user/.config/systemd ] && [ \"\$(stat -c %u /fake/home/user/.config/systemd)\" = 10000 ]"
bind_all; rc=$?
check "bind mounts succeed (rc=$rc)" "[ $rc -eq 0 ]"
check "USB Audio toggle, WiFi profile and BT bond are back at the rootfs paths" "has_state"
run nq-persist status
check "status reports the three bind mounts as MOUNTED" "[ \"\$(grep -c MOUNTED $OUT)\" = 3 ]"
unbind_all

echo "=== 3b. seen failing: the same flash WITHOUT the store loses the state ==="
fresh_rootfs steelhead-fresh
check "no store -> USB Audio toggle gone after the flash" "! has_state && [ \"\$(cat /fake/etc/hostname)\" = steelhead-fresh ]"

echo "=== 4. parked writes: made under the unmounted mountpoint, merged, never clobbering ==="
fresh_rootfs steelhead
mkdir -p /persist/identity /persist/site
echo '{"name": "Obyvak", "room": "living"}' > /persist/identity/device.json      # what pre-upgrade leaves behind
echo 'SHADOW-MUST-LOSE' > /persist/identity/hostname                             # the store already has a hostname
run nq-persist prepare
check "prepare parks the shadow (rc=$rc)" "[ $rc -eq 0 ] && said parked && [ -f /fake/run/nexusq/persist-shadow/identity/device.json ]"
check "mountpoint emptied before the mount" "[ -z \"\$(ls -A /persist)\" ]"
mount -o loop "$IMG" /persist
run nq-persist apply
check "apply merges the parked identity (rc=$rc)" "[ $rc -eq 0 ] && grep -q Obyvak /persist/identity/device.json"
check "an existing store file is not clobbered by a parked one" "[ \"\$(cat /persist/identity/hostname)\" = steelhead ]"
check "shadow removed after the merge" "[ ! -d /fake/run/nexusq/persist-shadow ]"

echo "=== 5. site NTP: site first, fleet after, dedup, reset line, IP literals only ==="
run nq-persist ntp set 192.168.20.1
f=/fake/run/systemd/timesyncd.conf.d/20-nexusq-site-ntp.conf
check "ntp set renders (rc=$rc)" "[ $rc -eq 0 ] && [ -f $f ]"
check "reset line precedes the list" "[ \"\$(grep -n '^NTP=' $f | head -1)\" = '4:NTP=' ]"
check "site first, fleet after" "grep -qx 'NTP=192.168.20.1 162.159.200.1 216.239.35.0' $f"
nq-persist ntp set 216.239.35.0 10.0.0.5 >/dev/null 2>&1
check "a site server already in the fleet list is not repeated" "grep -qx 'NTP=216.239.35.0 10.0.0.5 162.159.200.1' $f"
run nq-persist ntp set ntp.example.org
check "a hostname is rejected (rc=$rc)" "[ $rc -ne 0 ] && said 'not an IP literal'"
check "rejected set leaves the previous list" "grep -qx 'NTP=216.239.35.0 10.0.0.5 162.159.200.1' $f"
nq-persist ntp clear >/dev/null 2>&1
check "ntp clear removes the drop-in" "[ ! -e $f ] && [ ! -e /persist/site/ntp-servers ]"
check "ntp show says none" "nq-persist ntp show | grep -q 'site NTP: none'"

echo "=== 6. sshd list follows the keys that exist ==="
rm -f /persist/ssh/ssh_host_rsa_key /persist/ssh/ssh_host_rsa_key.pub
nq-persist apply >/dev/null 2>&1
check "removed key drops out of the rendered list" "[ \"\$(grep -c '^HostKey' /fake/run/nexusq/sshd-hostkeys.conf)\" = $((NKEYS - 1)) ] && ! grep -q rsa /fake/run/nexusq/sshd-hostkeys.conf"
rm -f /persist/ssh/ssh_host_*
nq-persist apply >/dev/null 2>&1
check "no keys in store and none on rootfs -> keys generated, not an empty list" "[ \"\$(ls /persist/ssh/ssh_host_*_key | wc -l)\" -ge 3 ] && [ -s /fake/run/nexusq/sshd-hostkeys.conf ]"
umount /persist

echo "=== 6b. apply without the store mounted fails loudly and touches nothing ==="
run nq-persist apply
check "apply refuses an unmounted store (rc=$rc)" "[ $rc -ne 0 ] && said 'not a mountpoint'"

echo "=== 7. usage is inert, exit codes ==="
run nq-persist
check "bare command prints usage, exit 2" "[ $rc -eq 2 ] && said '^usage:'"
run nq-persist help
check "help exits 0" "[ $rc -eq 0 ]"
run nq-persist frobnicate
check "unknown command exits 2" "[ $rc -eq 2 ]"

echo "=== 8. r103 pre-upgrade moves a plain identity under the store, leaves a symlink alone ==="
mkdir -p /etc/nexusq /var/lib/nexusq
echo '{"name": "Sumperak", "room": "cottage"}' > /etc/nexusq/device.json
sh /pre >/dev/null 2>&1; rc=$?
check "pre-upgrade exits 0 (rc=$rc)" "[ $rc -eq 0 ]"
check "plain file moved to the link target path" "[ ! -e /etc/nexusq/device.json ] && grep -q Sumperak /var/lib/nexusq/persist/identity/device.json"
ln -s /var/lib/nexusq/persist/identity/device.json /etc/nexusq/device.json     # what apk installs next
check "the symlink now serves the old name" "grep -q Sumperak /etc/nexusq/device.json"
sh /pre >/dev/null 2>&1
check "a second run leaves the symlink alone" "[ -L /etc/nexusq/device.json ]"

echo "=== 9. r106 pre-upgrade moves plain settings into the store, leaves links alone ==="
echo '{"theme": "rose"}' > /etc/nexusq/theme.json
echo '{"on": false}' > /etc/nexusq/ring.json
echo '{"max": 90, "ambient": true}' > /etc/nexusq/brightness.json
ln -s /var/lib/nexusq/persist/settings/eq.json /etc/nexusq/eq.json               # already migrated
sh /pre >/dev/null 2>&1; rc=$?
check "pre-upgrade exits 0 (rc=$rc)" "[ $rc -eq 0 ]"
check "theme moved to the link target path" "[ ! -e /etc/nexusq/theme.json ] && grep -q rose /var/lib/nexusq/persist/settings/theme.json"
check "ring moved to the link target path" "[ ! -e /etc/nexusq/ring.json ] && grep -q false /var/lib/nexusq/persist/settings/ring.json"
check "brightness moved to the link target path" "[ ! -e /etc/nexusq/brightness.json ] && grep -q ambient /var/lib/nexusq/persist/settings/brightness.json"
check "an existing link is left alone" "[ -L /etc/nexusq/eq.json ]"
check "a setting that was never set stays absent" "[ ! -e /var/lib/nexusq/persist/settings/eq-presets.json ]"
for f in theme.json ring.json eq-presets.json; do                                 # what apk installs next
    ln -s /var/lib/nexusq/persist/settings/$f /etc/nexusq/$f
done
check "the links now serve the old settings" "grep -q rose /etc/nexusq/theme.json && grep -q false /etc/nexusq/ring.json"
check "a never-set link dangles (reads as default)" "[ -L /etc/nexusq/eq-presets.json ] && [ ! -e /etc/nexusq/eq-presets.json ]"

echo "=== 10. settings parked under the unmounted store are merged, and survive a flash ==="
umount /persist 2>/dev/null || true
mkdir -p /persist/settings
echo '{"theme": "warm"}' > /persist/settings/theme.json       # what r106 pre-upgrade leaves on an r102 unit
run nq-persist prepare
check "prepare parks the settings (rc=$rc)" "[ $rc -eq 0 ] && [ -f /fake/run/nexusq/persist-shadow/settings/theme.json ]"
mount "$IMG" /persist
run nq-persist apply
check "apply merges the parked theme (rc=$rc)" "[ $rc -eq 0 ] && grep -q warm /persist/settings/theme.json"
check "apply makes the settings dir" "[ -d /persist/settings ] && [ \"\$(stat -c %a /persist/settings)\" = 755 ]"
run nq-persist status
check "status lists the stored settings" "said 'settings *: .*theme.json'"
# a flash: rootfs wiped, store kept -- the store still holds the theme
rm -rf /fake/etc/nexusq
run nq-persist apply
check "a flash does not touch the stored theme" "grep -q warm /persist/settings/theme.json"
umount /persist
EOF
)
rc=$?
printf '%s\n' "$out" | sed -e 's/^PASS /  \x1b[32mPASS\x1b[0m  /' -e 's/^FAIL /  \x1b[31mFAIL\x1b[0m  /'
pass=$(printf '%s\n' "$out" | grep -c '^PASS ')
fail=$(printf '%s\n' "$out" | grep -c '^FAIL ')
echo
echo "$pass passed, $fail failed (container rc=$rc)"
[ "$fail" -eq 0 ] && [ "$pass" -gt 0 ] && [ "$rc" -eq 0 ]
