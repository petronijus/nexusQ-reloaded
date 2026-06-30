#!/usr/bin/env python3
"""Build the launcher icon from the ORIGINAL Nexus Q app icon (the "Q" mark).

The source (`icon.png`, the Google app's launcher icon, max 96x96 RGBA) lives in
the gitignored private/ overlay — Google-copyrighted. This script upscales it to
1024 and produces the two inputs flutter_launcher_icons needs:
  assets/icon/icon.png             1024² on white (full-bleed; iOS/legacy/macOS/web)
  assets/icon/icon_foreground.png  1024² Q inset in the adaptive safe zone (transparent)

(A fresh clone without the private overlay can't run this — like the firmware
blobs. To use our own clean mark instead, run tool/make_icon.py.)

Requires Pillow.  Run:  python3 tool/make_icon_original.py
"""
import os
from PIL import Image

SRC = ("/Users/petronijus/Documents/Dev/nexusQ-reloaded/private/nexusq-original/"
       "companion/apktool/res/drawable-xhdpi-v4/icon.png")
S = 1024


def main():
    here = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    out = os.path.join(here, "assets", "icon")
    os.makedirs(out, exist_ok=True)

    q = Image.open(SRC).convert("RGBA").resize((S, S), Image.LANCZOS)

    # full-bleed: flatten the (rounded/transparent) Q onto white, matching the
    # original light background; RGB so iOS gets no alpha.
    full = Image.new("RGBA", (S, S), (255, 255, 255, 255))
    full.alpha_composite(q)
    full.convert("RGB").save(os.path.join(out, "icon.png"))

    # adaptive foreground: Q inset to ~70% (safe zone) on transparent; the
    # adaptive background is white (set in pubspec).
    inset = int(S * 0.70)
    fg = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    fg.alpha_composite(q.resize((inset, inset), Image.LANCZOS), ((S - inset) // 2, (S - inset) // 2))
    fg.save(os.path.join(out, "icon_foreground.png"))

    print("wrote", os.path.join(out, "icon.png"), "+ icon_foreground.png (from original Q)")


if __name__ == "__main__":
    main()
