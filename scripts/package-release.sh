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
#   sha256sums-<ver>.txt
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

# ...and the install guide has to be about THIS release. INSTALL.md went four
# releases stale while looking maintained -- it kept gaining correct new sections
# bolted onto a v1.11.0-era spine, because nothing in the release process owned
# it, and the artifact filenames it tells people to flash were the wrong ones.
echo "==> Release gate: the install guide names this release"
GUIDE_VER="$(sed -n 's/^<!-- RELEASE: \(v[0-9][^ ]*\) -->$/\1/p' INSTALL.md | head -1)"
if [ -z "$GUIDE_VER" ]; then
    echo "ERROR: INSTALL.md has no '<!-- RELEASE: vX.Y.Z -->' marker on its first line," >&2
    echo "       so this gate cannot tell which release it documents. Add one." >&2
    exit 1
fi
if [ "$GUIDE_VER" != "$VER" ]; then
    echo "ERROR: INSTALL.md documents $GUIDE_VER but you are cutting $VER." >&2
    echo "       Update the marker AND the artifact filenames it tells people to" >&2
    echo "       flash (nexusq-boot-$VER.img, nexusq-rootfs-$VER-sparse.img.zst)," >&2
    echo "       then re-run. A guide naming last-but-four's files is worse than none." >&2
    exit 1
fi
echo "  INSTALL.md marker says $GUIDE_VER"

# ...and the marker alone is not the guide. v1.16.0 shipped with the marker
# correctly reading v1.16.0 while the sentence under the title still said "This
# guide describes release v1.15.2", naming the wrong kernel and the wrong device
# revision -- the marker gate passed and the prose was a release behind, which is
# the exact failure mode the marker was introduced to stop. So check the prose and
# every artifact name the guide tells a first-timer to download.
guide_needs() {
    grep -qF "$1" INSTALL.md && return 0
    echo "ERROR: INSTALL.md never mentions '$1'." >&2
    echo "       The marker says $VER, so the body has to as well: a guide whose" >&2
    echo "       filenames do not exist in the release is a broken first install." >&2
    return 1
}
guide_fail=0
guide_needs "This guide describes release \`$VER\`" || guide_fail=1
guide_needs "nexusq-boot-$VER.img"                   || guide_fail=1
guide_needs "nexusq-rootfs-$VER-sparse.img.zst"      || guide_fail=1
guide_needs "sha256sums-$VER.txt"                    || guide_fail=1
[ "$guide_fail" -eq 0 ] || exit 1
echo "  INSTALL.md body names $VER and all three artifacts"

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
# VERSIONED, like every release up to v1.15.2 -- and like INSTALL.md says. This
# line wrote a bare sha256sums.txt until 2026-09-16, so v1.16.0 published one
# asset the guide does not name and six releases of muscle memory do not expect;
# download two releases into one directory and they silently overwrite each other.
( cd "$OUT" && $SHA "nexusq-boot-$VER.img" "nexusq-rootfs-$VER-sparse.img.zst" > "sha256sums-$VER.txt" )

echo
ls -lh "$OUT/nexusq-boot-$VER.img" "$OUT/nexusq-rootfs-$VER-sparse.img.zst" "$OUT/sha256sums-$VER.txt"
cat "$OUT/sha256sums-$VER.txt"

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
echo "      output/nexusq-rootfs-$VER-sparse.img.zst output/sha256sums-$VER.txt"
