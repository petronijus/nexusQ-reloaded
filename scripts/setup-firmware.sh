#!/usr/bin/env bash
# Stage non-redistributable firmware blobs into the build tree (gitignored).
# These proprietary blobs (recovered from the device's Android vendor partition)
# can't be shipped publicly, so they live either in the private overlay
# (./private) or you extract them from your own device. Run this before
# ./docker-build.sh if you want Bluetooth / tuned WiFi in the image.
set -euo pipefail
cd "$(dirname "$0")/.."

# blob (relative path is identical under private/ and in the build tree)
BLOBS=(firmware/bcm4330.hcd firmware/bcmdhd.cal)

missing=0
for b in "${BLOBS[@]}"; do
    if [ -f "private/$b" ]; then
        install -Dm644 "private/$b" "$b"
        echo "Staged $b from the private overlay (gitignored)."
    else
        echo "MISSING: private/$b" >&2
        missing=1
    fi
done

if [ "$missing" -ne 0 ]; then
    cat >&2 <<'MSG'

Some blobs are not in the private overlay. Either:
  - clone the private overlay:  git clone <nexusQ-reloaded-private> private
  - or extract them from your device's Android vendor partition:
      adb pull /system/vendor/firmware/bcmdhd.cal firmware/bcmdhd.cal
      (and the BCM4330 BT .hcd) -- see firmware/README.md.
MSG
    exit 1
fi
echo "Firmware staged."
