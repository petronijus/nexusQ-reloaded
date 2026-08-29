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

if [ "$fail" -ne 0 ]; then
    cat >&2 <<'MSG'

ABORTING RELEASE. Rebuild clean artifacts first:
    PUBLIC_RELEASE=1 ./docker-build.sh
(then flash your own device from a separate personal build).
MSG
    exit 1
fi
echo "Release image is clean of baked-in access."
