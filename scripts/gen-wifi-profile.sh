#!/usr/bin/env bash
# Generate private/access/wifi*.nmconnection — the NetworkManager connection
# profiles that docker-build.sh bakes into the image so a clean flash comes up
# on WiFi (the rootfs holds all network config, so every flash wiped it and
# left the device configure-by-hand; bitten 2026-06-28 and 2026-07-02).
#
# The WPA PSK is pulled from 1Password at generation time and the output files
# are GITIGNORED even inside the private overlay — per the "never store
# passwords in files under version control" rule, the secret lives only in
# 1Password, in these machine-local generated files, and (necessarily) in the
# flashed rootfs. Run once per build machine (and re-run if a WiFi password
# ever changes):
#
#     ./scripts/gen-wifi-profile.sh
#
# MULTIPLE NETWORKS (2026-08-28): a second Nexus Q lives at the cottage, so the
# image now carries a profile per site. NM keeps them all and autoconnects to
# whichever is in range, which also means ONE image serves both devices. Add a
# site by appending to NETWORKS below — SSID and the 1Password item that holds
# its PSK.
#
# ⚠️ Only the PRIMARY profile (the first entry) is baked by the current build:
# APKBUILD's `source=` is a fixed, checksummed list with a single
# wifi.nmconnection. The extra wifi-<slug>.nmconnection files are written for
# image INJECTION (and for the build wiring to pick up once APKBUILD grows a
# per-site source entry). See HANDOFF.
#
# Requires: op-cache (~/.local/bin/op-cache) with the items named below.

set -euo pipefail
cd "$(dirname "$0")/.."

# site SSID | 1Password item holding its PSK   (FIRST = primary, see above)
NETWORKS="Svatovitske-Internety-5g|Wifi-Router Svatovitska
Sumperak-Internety|Wifi-Router Sumperak"

if [ ! -d private ]; then
    echo "ERROR: private overlay not cloned (see private/README.md)" >&2
    exit 1
fi

# Stable UUID derived from the SSID, so regenerating on another machine yields
# the SAME connection UUID — NM treats it as one connection, not per-machine
# duplicates. `uuidgen --sha1` is GNU-only; macOS ships the BSD uuidgen, which
# only makes random v4 UUIDs and would break that guarantee silently. Python's
# uuid5 is the identical computation (SHA-1 over the DNS namespace).
uuid5() {
    if uuidgen --sha1 --namespace @dns --name "$1" 2>/dev/null; then
        return 0
    fi
    python3 -c 'import uuid,sys; print(uuid.uuid5(uuid.NAMESPACE_DNS, sys.argv[1]))' "$1"
}

mkdir -p private/access
umask 077

primary=1
while IFS='|' read -r SSID ITEM; do
    [ -n "$SSID" ] || continue

    PSK="$("$HOME"/.local/bin/op-cache "$ITEM" "wireless network password")"
    if [ -z "$PSK" ]; then
        echo "ERROR: could not read the WiFi PSK for '$ITEM' from 1Password (op-cache)" >&2
        exit 1
    fi

    UUID=$(uuid5 "nexusq-$SSID")
    SLUG=$(printf '%s' "$SSID" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9' '-' | sed 's/-*$//')
    OUT="private/access/wifi-$SLUG.nmconnection"

    cat > "$OUT" <<EOF
[connection]
id=$SSID
uuid=$UUID
type=wifi
autoconnect=true
autoconnect-priority=10

[wifi]
ssid=$SSID
mode=infrastructure
# 5 GHz only: 2.4 GHz shares the BCM4330 with Bluetooth and stalls under bulk
# transfers (see the WiFi-join notes). Verified per site before adding it here:
# the AP must publish this SSID on a NON-DFS channel (36/40/44/48), because the
# Q's brcmfmac never joins a DFS channel (that is the whole "missing 5 GHz"
# finding of 2026-08-23, which turned out to be channel 100, not distance).
band=a
# permanent = use whatever the driver reports, never override it. Matches
# eth-lan/eth-direct, which have always done this.
#
# History, and why a hardcoded value here is a BUG and not belt-and-braces:
# this line used to pin f8:8f:ca:20:48:e1 because NM's randomized MAC made the
# IP wander every boot (2026-07-02). Since v1.10.1 the factory MAC is pinned at
# the DRIVER via the DTS (kernel patch 0043), which made the line redundant --
# and on 2026-08-28 a SECOND Nexus Q showed it is worse than redundant. That Q
# was given its own per-unit MAC in its DTB, booted with it correctly, and then
# NM overrode it right back to the first unit's address, because this profile
# said so. Two boxes, one MAC, no error anywhere. `permanent` cannot do that.
cloned-mac-address=permanent

[wifi-security]
key-mgmt=wpa-psk
psk=$PSK

[ipv4]
method=auto

[ipv6]
method=auto
addr-gen-mode=default
EOF
    chmod 600 "$OUT"
    echo "Wrote $OUT (ssid=$SSID, uuid=$UUID, psk from 1Password — not shown)."

    if [ "$primary" = 1 ]; then
        cp "$OUT" private/access/wifi.nmconnection
        chmod 600 private/access/wifi.nmconnection
        echo "  also copied to private/access/wifi.nmconnection (the one docker-build.sh bakes)"
        primary=0
    fi
done <<EOF
$NETWORKS
EOF
