#!/usr/bin/env bash
# Stage non-redistributable firmware blobs into the build tree (gitignored).
# These proprietary blobs (recovered from the device's Android system/vendor
# partitions) can't be shipped publicly, so they live either in the private
# overlay (./private) or you extract them from the stock factory image. Run this
# before ./docker-build.sh if you want WiFi / Bluetooth in the image.
set -euo pipefail
cd "$(dirname "$0")/.."

# blob (relative path is identical under private/ and in the build tree) and the
# md5 of the ONE correct steelhead copy. A right-named wrong blob is the trap
# here: a different board's BCM4330B1 patchram shipped for weeks (fixed
# 2026-07-14), and the linux-firmware WiFi blob wedged unicast RX (2026-09-23).
# docker-build.sh checks the same sums before it stages anything.
BLOBS=(
    "firmware/bcm4330.hcd    7e5bb859e33142e94052c76fba23b9e6"
    "firmware/bcmdhd.cal     f222187eb4c97e47b0f173a270001563"
    "firmware/fw_bcmdhd.bin  658765a665299744947e99e1f1986d19"
)

missing=0
for entry in "${BLOBS[@]}"; do
    read -r b want <<<"$entry"
    if [ ! -f "private/$b" ]; then
        echo "MISSING: private/$b" >&2
        missing=1
        continue
    fi
    got=$(md5sum "private/$b" | cut -d' ' -f1)
    if [ "$got" != "$want" ]; then
        echo "WRONG BLOB: private/$b has md5 $got, expected $want" >&2
        missing=1
        continue
    fi
    install -Dm644 "private/$b" "$b"
    echo "Staged $b from the private overlay (gitignored, md5 verified)."
done

if [ "$missing" -ne 0 ]; then
    cat >&2 <<'MSG'

Some blobs are missing or wrong in the private overlay. Either:
  - clone the private overlay:  git clone <nexusQ-reloaded-private> private
  - or extract them from the stock factory image (tungsten-ian67k system.img,
    unsparsed to system.raw.img with simg2img):
      debugfs -R "dump /vendor/firmware/fw_bcmdhd.bin firmware/fw_bcmdhd.bin" system.raw.img
      debugfs -R "dump /vendor/firmware/bcm4330.hcd   firmware/bcm4330.hcd"   system.raw.img
      debugfs -R "dump /etc/wifi/bcmdhd.cal           firmware/bcmdhd.cal"    system.raw.img
    -- see firmware/README.md.
MSG
    exit 1
fi
echo "Firmware staged."
