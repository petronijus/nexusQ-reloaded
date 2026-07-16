#!/usr/bin/env bash
# Generate private/access/wifi.nmconnection — the NetworkManager connection
# profile that docker-build.sh bakes into the image so a clean flash comes up
# on WiFi (the rootfs holds all network config, so every flash wiped it and
# left the device configure-by-hand; bitten 2026-06-28 and 2026-07-02).
#
# The WPA PSK is pulled from 1Password at generation time and the output file
# is GITIGNORED even inside the private overlay — per the "never store
# passwords in files under version control" rule, the secret lives only in
# 1Password, in this machine-local generated file, and (necessarily) in the
# flashed rootfs. Run once per build machine (and re-run if the WiFi password
# ever changes):
#
#     ./scripts/gen-wifi-profile.sh
#
# Requires: op-cache (~/.local/bin/op-cache) with the "Wifi-Router Svatovitska"
# item, uuidgen.
set -euo pipefail
cd "$(dirname "$0")/.."

OUT=private/access/wifi.nmconnection
SSID="Svatovitske-Internety-5g"

if [ ! -d private ]; then
    echo "ERROR: private overlay not cloned (see private/README.md)" >&2
    exit 1
fi

PSK="$("$HOME"/.local/bin/op-cache "Wifi-Router Svatovitska" "wireless network password")"
if [ -z "$PSK" ]; then
    echo "ERROR: could not read the WiFi PSK from 1Password (op-cache)" >&2
    exit 1
fi

# Stable UUID: derive it from the SSID (uuidgen --sha1) so regenerating the
# file on another machine yields the SAME connection UUID — NM treats it as
# one connection, not per-machine duplicates.
UUID=$(uuidgen --sha1 --namespace @dns --name "nexusq-$SSID")

mkdir -p private/access
umask 077
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
# transfers (see the WiFi-join notes).
band=a
# Factory MAC, pinned explicitly. History: NM's randomized MAC made the IP
# wander every boot (2026-07-02); "permanent" then pinned it to the chip's
# OTP MAC 14:7d:c5:3a:35:b5 — but the device's real factory identity is
# f8:8f:ca:20:48:e1 (Google OUI; stock injected it outside the fw path).
# brcmfmac/fw IGNORES the nvram macaddr= (verified live 2026-07-03 by a
# clean driver-reload test).
# NOTE (v1.10.1, 2026-07-16): the factory MAC is now pinned at the DRIVER via
# the DTS (kernel patch 0043, local-mac-address on wifi@1 → brcmf_of_probe
# programs it over OTP), so wlan0's PERMANENT MAC is already f8:8f:ca:20:48:e1
# on every profile — this cloned-mac-address line is now REDUNDANT on v1.10.1+
# (it was the only pin ≤v1.10.0, and reached only THIS baked profile, never the
# one nexusq-setupd created during onboarding). Kept as a harmless belt-and-braces.
cloned-mac-address=F8:8F:CA:20:48:E1

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
echo "Wrote $OUT (uuid=$UUID, psk from 1Password — not shown)."
echo "docker-build.sh will now bake it into the next image."
