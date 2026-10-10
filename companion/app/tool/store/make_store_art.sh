#!/bin/sh
# Render the store artwork from its sources in this directory:
#   q-mark.svg            -> images/icon.png            512x512, the Q on white
#   feature-graphic.svg   -> images/featureGraphic.png  1024x500
# under fastlane/metadata/android/en-US/, where Google Play (fastlane supply)
# and F-Droid both read it. Both outputs are opaque 24-bit PNGs, as Play asks.
#
# Usage:  tool/store/make_store_art.sh
# Needs:  rsvg-convert (librsvg), ImageMagick 7 (`magick`), the Roboto font.
set -eu

cd "$(dirname "$0")"
APP=$(cd ../.. && pwd)
OUT="$APP/fastlane/metadata/android/en-US/images"

for tool in rsvg-convert magick fc-match; do
	command -v "$tool" >/dev/null || { echo "ERROR: $tool is missing" >&2; exit 1; }
done
# fc-match always answers with something; make sure it is Roboto, or the
# feature graphic's text silently falls back to another face.
case "$(fc-match -f '%{family}' Roboto)" in
	*Roboto*) ;;
	*) echo "ERROR: the Roboto font is not installed" >&2; exit 1 ;;
esac

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$OUT"

# The icon: Play masks it to a rounded square itself, so the mark sits on a
# full white square (the launcher icon's adaptive background), inset to 448 px
# so the ring clears the mask's corners with room to spare.
rsvg-convert -w 448 -h 448 q-mark.svg -o "$WORK/q.png"
magick -size 512x512 xc:white "$WORK/q.png" -gravity center -composite \
	-alpha off -define png:color-type=2 "$OUT/icon.png"

cp feature-graphic.svg "$WORK/"
cp "$APP/assets/device/sphere.png" "$WORK/"
rsvg-convert "$WORK/feature-graphic.svg" -o "$WORK/fg.png"
magick "$WORK/fg.png" -background black -flatten \
	-alpha off -define png:color-type=2 "$OUT/featureGraphic.png"

for f in icon.png featureGraphic.png; do
	echo "wrote $OUT/$f ($(magick identify -format '%wx%h' "$OUT/$f"))"
done
