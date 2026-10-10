#!/usr/bin/env python3
"""Build the launcher icon from the ORIGINAL Nexus Q app's "Q" mark.

The source is tool/store/q-mark.svg: the original app's launcher icon (only
ever shipped as a bitmap of at most 96x96) redrawn as a vector, measured from
that bitmap, so the icon stays sharp at every size. The store icon is rendered
from the same SVG (tool/store/make_store_art.sh). This script produces the two
inputs flutter_launcher_icons needs:
  assets/icon/icon.png             1024² on white (full-bleed; iOS/legacy/macOS/web)
  assets/icon/icon_foreground.png  1024² Q inset in the adaptive safe zone (transparent)

(Our own clean ring mark instead: tool/make_icon.py.)

Requires Pillow and rsvg-convert (librsvg).  Run:  python3 tool/make_icon_original.py
then:  dart run flutter_launcher_icons
"""

import io
import os
import subprocess

from PIL import Image

S = 1024


def render(svg, size):
    png = subprocess.run(
        ["rsvg-convert", "-w", str(size), "-h", str(size), svg],
        check=True,
        capture_output=True,
    ).stdout
    return Image.open(io.BytesIO(png)).convert("RGBA")


def main():
    here = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    svg = os.path.join(here, "tool", "store", "q-mark.svg")
    out = os.path.join(here, "assets", "icon")
    os.makedirs(out, exist_ok=True)

    # full-bleed: the (transparent-centred) Q on white, matching the original
    # light background; RGB so iOS gets no alpha.
    full = Image.new("RGBA", (S, S), (255, 255, 255, 255))
    full.alpha_composite(render(svg, S))
    full.convert("RGB").save(os.path.join(out, "icon.png"))

    # adaptive foreground: Q inset to ~70% (safe zone) on transparent; the
    # adaptive background is white (set in pubspec).
    inset = int(S * 0.70)
    fg = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    fg.alpha_composite(render(svg, inset), ((S - inset) // 2, (S - inset) // 2))
    fg.save(os.path.join(out, "icon_foreground.png"))

    print("wrote", os.path.join(out, "icon.png"), "+ icon_foreground.png (from tool/store/q-mark.svg)")


if __name__ == "__main__":
    main()
