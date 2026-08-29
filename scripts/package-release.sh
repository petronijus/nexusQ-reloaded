#!/usr/bin/env bash
# Turn a finished build into the three GitHub release assets, with the
# no-secrets gate in front of them so a personal image can never be packaged by
# accident.
#
# Until 2026-08-29 this was prose in HANDOFF.md and retyped by hand every
# release — which is how you eventually ship a rootfs that still has someone's
# WPA PSK in it. It is a script now, and the gate is not optional.
#
# Usage: scripts/package-release.sh v1.14.0 [--from-volume]
#   --from-volume   first copy the artifacts out of the `nexusq-output` docker
#                   volume into output/ (what docker-build.sh writes into)
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
    *) echo "usage: $0 v<MAJOR>.<MINOR>.<PATCH> [--from-volume]" >&2; exit 2 ;;
esac
FROM_VOLUME=0
[ "${2:-}" = "--from-volume" ] && FROM_VOLUME=1

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
