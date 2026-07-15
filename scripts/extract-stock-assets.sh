#!/usr/bin/env bash
# Extract the ORIGINAL Nexus Q companion-app imagery from the decompiled stock
# APK (private/nexusq-original — Google copyright, NEVER committed) into the
# Flutter app's gitignored assets/stock/. Public builds without private/ get
# the in-app icon fallbacks (lib/setup/stock_assets.dart).
#
# NOTE on filenames: the want-lists below were reconciled against the actual
# apktool output (2026-07-13) and differ from the original research inventory
# in two spots:
#   - wifi lock icons are named ic_wifi_lock_signal_N.png (lock/signal order
#     swapped vs. the naively-guessed ic_wifi_signal_lock_N.png)
#   - the kitchen room icon is ic_menu_location_kitchenroom.png (not
#     ic_menu_location_kitchen.png)
# Density dirs are suffixed -v4 (drawable-xhdpi-v4, not drawable-xhdpi).
set -euo pipefail
cd "$(dirname "$0")/.."

SRC="${1:-private/nexusq-original/companion/apktool/res}"
DEST="companion/app/assets/stock"

if [ ! -d "$SRC" ]; then
    echo "extract-stock-assets: $SRC not found — building WITHOUT stock assets (fallback icons)."
    mkdir -p "$DEST/drawable" "$DEST/raw"
    touch "$DEST/drawable/.keep" "$DEST/raw/.keep"
    exit 0
fi

# Prefer the highest density available for each drawable.
pick() { # pick <basename.png> -> echoes the source path or nothing
    for d in drawable-xhdpi-v4 drawable-hdpi-v4 drawable-mdpi-v4 drawable; do
        [ -f "$SRC/$d/$1" ] && { echo "$SRC/$d/$1"; return 0; }
    done
    return 1
}

mkdir -p "$DEST/drawable" "$DEST/raw"
missing=0

want_drawables=(
    setup_static.png ic_q_welcome.png ic_splash_drop.png
    cables_diagram_01.png cables_diagram_02.png
    ic_bt_config.png
)
for i in $(seq -w 0 35); do want_drawables+=("q0$i.png"); done
for w in 1 2 3 4; do
    want_drawables+=("ic_wifi_signal_$w.png" "ic_wifi_lock_signal_$w.png")
done
for room in bedroom kitchenroom livingroom bathroom closet diningroom familyroom garage mediaroom office; do
    want_drawables+=("ic_menu_location_$room.png")
done

for f in "${want_drawables[@]}"; do
    if src=$(pick "$f"); then cp "$src" "$DEST/drawable/$f"
    else echo "  missing drawable: $f"; missing=$((missing+1)); fi
done

want_raw=(theme_blue theme_cool theme_smoke theme_spectrum theme_warm theme_trackinfo theme_off q_outro.mp4 polaris.ogg)
for f in "${want_raw[@]}"; do
    if [ -f "$SRC/raw/$f" ]; then cp "$SRC/raw/$f" "$DEST/raw/$f"
    else echo "  missing raw: $f"; missing=$((missing+1)); fi
done

touch "$DEST/drawable/.keep" "$DEST/raw/.keep"

echo "extract-stock-assets: done ($(find "$DEST" -type f | wc -l) files, $missing missing)"
