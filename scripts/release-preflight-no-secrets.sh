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
if ! command -v debugfs >/dev/null; then
    echo "ERROR: debugfs (e2fsprogs) required" >&2
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

# A whole DIRECTORY, not one filename. `gen-wifi-profile.sh` grew multi-site
# support on 2026-08-28 and now writes wifi-<site>.nmconnection alongside the
# plain wifi.nmconnection — a gate that greps for one hardcoded name would wave
# the others through, and every one of them carries the PSK in plain text. The
# rule is: NO connection profile of any name may be in a public image.
check_dir_empty() {
    local dir="$1" what="$2" listing found
    listing=$(debugfs -R "ls -p $dir" "$IMG" 2>/dev/null || true)
    if [ -z "$listing" ]; then
        echo "OK: no $what (no $dir)"
        return 0
    fi
    # debugfs -p output is /inode/perm/uid/gid/name/size/ per entry, one per line.
    found=$(printf '%s\n' "$listing" | awk -F/ 'NF>5 && $6 != "." && $6 != ".." {print $6}')
    if [ -n "$found" ]; then
        echo "FAIL: $what present in the image ($dir):"
        printf '        %s\n' $found
        return 1
    fi
    echo "OK: no $what ($dir is empty)"
}

fail=0
check_dir_empty "/etc/NetworkManager/system-connections" \
    "WiFi profiles (they contain the WPA PSK!)" || fail=1
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
