#!/usr/bin/env bash
# Release pre-flight: refuse to publish a rootfs image with baked-in personal
# access. Since 2026-07-02 docker-build.sh bakes ssh authorized_keys and the
# WiFi NM profile (with the WPA PSK in plain text!) into personal builds from
# the private overlay. Releases upload the rootfs image to public GitHub, so a
# personally-built image MUST NEVER be released — build release artifacts with
# PUBLIC_RELEASE=1 ./docker-build.sh and verify with this script.
#
# Usage: scripts/release-preflight-no-secrets.sh [rootfs.img]
#   default image: output/google-steelhead.img (the raw ext4 rootfs)
# Exit 0 = clean, exit 1 = PERSONAL DATA FOUND (abort the release).
set -euo pipefail
cd "$(dirname "$0")/.."

IMG="${1:-output/google-steelhead.img}"
if [ ! -f "$IMG" ]; then
    echo "ERROR: rootfs image not found: $IMG" >&2
    exit 1
fi
# The gate reads ext4 with debugfs, which macOS does not have. Rather than make
# the gate a Linux-only step (and therefore a step that gets skipped on the
# machine that happens to be doing the release), re-run ourselves inside a
# throwaway container. Guarded against recursion: inside, debugfs exists.
if ! command -v debugfs >/dev/null; then
    if command -v docker >/dev/null; then
        echo "debugfs absent -> running the gate in a container"
        exec docker run --rm \
            -v "$(cd "$(dirname "$IMG")" && pwd):/img:ro" \
            -v "$(cd "$(dirname "$0")/.." && pwd)/scripts:/scripts:ro" \
            alpine:3.21 sh -c \
            "apk add --no-cache --quiet bash e2fsprogs-extra >/dev/null && \
             bash /scripts/$(basename "$0") /img/$(basename "$IMG")"
    fi
    echo "ERROR: debugfs (e2fsprogs) required, and no docker to borrow it from" >&2
    exit 1
fi

# debugfs reads the ext4 image without mounting (no root needed). "stat" on a
# missing path prints "File not found by ext2_lookup" to stderr.
check_absent() {
    local path="$1" what="$2"
    if debugfs -R "stat $path" "$IMG" 2>&1 | grep -q "Inode:"; then
        echo "FAIL: $what present in the image ($path) — this is a PERSONAL build."
        return 1
    fi
    echo "OK: no $what ($path)"
}

# A machine-id in the image is not a secret, but it IS an identity, and shipping
# one hands every unit flashed from a given release the SAME sd_id128 — colliding
# application IDs, colliding DHCP client identifiers, colliding journal
# directories. systemd treats absent OR zero-length as "first boot" and generates
# a fresh one, which is the state we want; anything else fails.
check_absent_or_empty() {
    local path="$1" what="$2" st
    st=$(debugfs -R "stat $path" "$IMG" 2>&1)
    if ! printf '%s\n' "$st" | grep -q "Inode:"; then
        echo "OK: no $what ($path)"
        return 0
    fi
    # ONLY the "User: ... Size: N" line. debugfs also prints a "Fragment:
    # Address: 0  Number: 0  Size: 0" line, and a naive /Size: 0$/ matches THAT
    # on every inode -- which waved a 32-byte machine-id through as "zero-length"
    # when this check was first written.
    if printf '%s\n' "$st" | awk '/^User:/ {found=1; if ($NF == 0) ok=1} END {exit !(found && ok)}'; then
        echo "OK: $what is zero-length — systemd regenerates it on first boot ($path)"
        return 0
    fi
    echo "FAIL: $what is baked into the image ($path) — every unit would share it."
    return 1
}

# A directory that must ship EMPTY. /var/log/journal has to exist (its presence is
# what makes journald persistent) but anything inside it is one particular
# machine's logs, and /etc/ssh holds host PRIVATE keys — a released image that
# carries them lets anyone impersonate every Q flashed from it.
check_dir_empty() {
    local dir="$1" what="$2" pat="${3:-.}" listing names
    listing=$(debugfs -R "ls -p $dir" "$IMG" 2>/dev/null || true)
    names=$(printf '%s\n' "$listing" | awk -F/ 'NF>5 && $6 != "." && $6 != ".." {print $6}' \
            | grep -E "$pat" || true)
    if [ -z "$names" ]; then
        echo "OK: $what is empty ($dir)"
        return 0
    fi
    echo "FAIL: $what is NOT empty ($dir): $(printf '%s ' $names)"
    return 1
}

# Not one filename, and not the whole directory either — the PROPERTY that
# matters. `gen-wifi-profile.sh` grew multi-site support on 2026-08-28 and now
# writes wifi-<site>.nmconnection beside the plain one, so a check that greps
# for a single hardcoded name waves the rest through. But the device package
# also ships eth-direct/eth-lan BY DESIGN, and those are wired profiles with no
# secret in them — failing on those would just teach everyone to skip the gate.
#
# So: read every connection profile and refuse the ones that actually leak —
# any stored secret, or any WiFi profile (its SSID is personal even when the
# key is stored elsewhere).
check_connections() {
    local dir="/etc/NetworkManager/system-connections" listing names f body bad=0
    listing=$(debugfs -R "ls -p $dir" "$IMG" 2>/dev/null || true)
    names=$(printf '%s\n' "$listing" | awk -F/ 'NF>5 && $6 != "." && $6 != ".." {print $6}')
    if [ -z "$names" ]; then
        echo "OK: no NetworkManager connection profiles at all"
        return 0
    fi
    for f in $names; do
        body=$(debugfs -R "cat $dir/$f" "$IMG" 2>/dev/null || true)
        if printf '%s\n' "$body" | grep -Eqi '^[[:space:]]*(psk|password|wep-key[0-9]?|private-key-password|pin)[[:space:]]*='; then
            echo "FAIL: $f stores a secret (this is what must never reach GitHub)"
            bad=1
        elif printf '%s\n' "$body" | grep -Eqi '^[[:space:]]*type[[:space:]]*=[[:space:]]*(wifi|802-11-wireless)'; then
            echo "FAIL: $f is a WiFi profile — personal, even with no key in it"
            bad=1
        else
            echo "OK: $f carries no secret (wired profile shipped by the device package)"
        fi
    done
    return $bad
}

fail=0
check_connections || fail=1
check_absent "/root/.ssh/authorized_keys" "root ssh authorized_keys" || fail=1
check_absent "/etc/skel/.ssh/authorized_keys" "skel ssh authorized_keys" || fail=1
check_absent "/home/user/.ssh/authorized_keys" "user ssh authorized_keys" || fail=1
# The MQTT broker config is a per-home SECRET in the same class as the WiFi PSK:
# host, username and a plaintext password for the household broker. It is baked
# into personal images (docker-build.sh Phase 10) precisely because a flash wipes
# it, which on 2026-09-16 left the Q with its telemetry dead and nothing saying
# so. The moment it became bakeable it also became leakable, so it is gated here
# in the SAME change that started baking it -- a credential path without a gate
# in front of it is how a public rootfs ends up carrying someone's broker login.
check_absent "/etc/nexusq/mqtt.json" "MQTT broker config (host/user/password)" || fail=1
# --- first-boot identity: nothing that makes two units the same unit ----------
# Added 2026-09-16 after issue #4 reported a baked machine-id. The image turned
# out to be clean (two units, two different ids) and the reporter's "someone
# else's boots" were their own, misdated by the dead RTC -- but NOTHING in the
# release path actually asserted any of this, so the only honest answer to the
# report was to go and look at the artifact. Now the gate answers it.
check_absent_or_empty "/etc/machine-id" "systemd machine-id" || fail=1
check_absent "/var/lib/dbus/machine-id" "D-Bus machine-id" || fail=1
check_absent "/var/lib/systemd/random-seed" "systemd random seed" || fail=1
check_dir_empty "/var/log/journal" "the persistent journal" || fail=1
check_dir_empty "/etc/ssh" "ssh HOST KEYS" '^ssh_host_' || fail=1

if [ "$fail" -ne 0 ]; then
    cat >&2 <<'MSG'

ABORTING RELEASE. Rebuild clean artifacts first:
    PUBLIC_RELEASE=1 ./docker-build.sh
(then flash your own device from a separate personal build).
MSG
    exit 1
fi
echo "Release image is clean of baked-in access."
