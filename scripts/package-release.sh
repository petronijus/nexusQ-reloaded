#!/usr/bin/env bash
# Turn a finished build into the three GitHub release assets, with the
# no-secrets gate in front of them so a personal image can never be packaged by
# accident.
#
# Until 2026-08-29 this was prose in HANDOFF.md and retyped by hand every
# release — which is how you eventually ship a rootfs that still has someone's
# WPA PSK in it. It is a script now, and the gate is not optional.
#
# A RELEASE IS BOTH TRACKS. The image assets below reach only someone holding a
# USB cable; everything already in the field updates from the OTA apk repo, and
# the two used to be separate commands nothing tied together. On 2026-08-30
# v1.14.2 shipped device r89 as an image while the repo kept serving r87 — last
# published two days earlier — so no box in the field could even be offered it,
# and every UI said "up to date" because a device cannot be behind a version its
# repo does not carry. So this script now publishes the OTA repo too, and then
# GATES on the two actually matching. The publish is skippable; the gate is not.
#
# Usage: scripts/package-release.sh v1.14.0 [--from-volume] [--no-ota]
#   --from-volume   first copy the artifacts out of the `nexusq-output` docker
#                   volume into output/ (what docker-build.sh writes into)
#   --no-ota        do not publish the OTA repo (the parity gate still runs, so
#                   this only helps when the repo is ALREADY current)
#
# Produces in output/:
#   nexusq-boot-<ver>.img
#   nexusq-rootfs-<ver>-sparse.img.zst   (all-RAW sparse, see raw2simg.py)
#   sha256sums.txt
set -euo pipefail
cd "$(dirname "$0")/.."

VER="${1:-}"
case "$VER" in
    v[0-9]*.[0-9]*.[0-9]*) ;;
    *) echo "usage: $0 v<MAJOR>.<MINOR>.<PATCH> [--from-volume] [--no-ota]" >&2; exit 2 ;;
esac
shift
FROM_VOLUME=0
PUBLISH_OTA=1
for arg in "$@"; do
    case "$arg" in
        --from-volume) FROM_VOLUME=1 ;;
        --no-ota)      PUBLISH_OTA=0 ;;
        *) echo "unknown option: $arg" >&2; exit 2 ;;
    esac
done

OUT=output
mkdir -p "$OUT"

if [ "$FROM_VOLUME" = "1" ]; then
    echo "==> Extracting artifacts from the nexusq-output volume"
    docker run --rm -v nexusq-output:/data -v "$PWD/$OUT:/out" alpine:3.21 \
        sh -c 'cp /data/boot.img /data/google-steelhead.img /out/'
fi

RAW="$OUT/google-steelhead.img"
BOOT="$OUT/boot.img"
for f in "$RAW" "$BOOT"; do
    [ -f "$f" ] || { echo "ERROR: missing $f (build first, or pass --from-volume)" >&2; exit 1; }
done

# THE GATE. Never package what it refuses.
echo "==> Release gate: no baked-in personal access"
scripts/release-preflight-no-secrets.sh "$RAW"

echo "==> Boot image"
cp "$BOOT" "$OUT/nexusq-boot-$VER.img"

echo "==> Sparse rootfs (all-RAW — DONT_CARE would leave stale eMMC blocks)"
SPARSE="$OUT/nexusq-rootfs-$VER-sparse.img"
python3 raw2simg.py "$RAW" "$SPARSE"

echo "==> Compressing the rootfs for distribution"
rm -f "$SPARSE.zst"
zstd -19 -T0 --rm -q "$SPARSE"

echo "==> Checksums"
SHA=sha256sum
command -v sha256sum >/dev/null || SHA="shasum -a 256"
( cd "$OUT" && $SHA "nexusq-boot-$VER.img" "nexusq-rootfs-$VER-sparse.img.zst" > sha256sums.txt )

echo
ls -lh "$OUT/nexusq-boot-$VER.img" "$OUT/nexusq-rootfs-$VER-sparse.img.zst" "$OUT/sha256sums.txt"
cat "$OUT/sha256sums.txt"

# --- the other half of the release -------------------------------------------
if [ "$PUBLISH_OTA" = "1" ]; then
    echo
    echo "==> Publishing the OTA apk repo (the half that reaches the field)"
    scripts/publish-ota-repo.sh
else
    echo
    echo "==> --no-ota: skipping the OTA publish (the parity gate below still runs)"
fi

echo
echo "==> Release gate: the OTA repo actually carries this release"
# Judged against $RAW, the uncompressed rootfs that IS the release — not against
# the build volume the apks came from, which would be circular and would agree
# with itself no matter how far behind the published repo had fallen.
scripts/verify-ota-parity.sh "$RAW"

echo
echo "Both tracks carry $VER. Upload the assets above with:"
echo "  gh release create $VER output/nexusq-boot-$VER.img \\"
echo "      output/nexusq-rootfs-$VER-sparse.img.zst output/sha256sums.txt"
