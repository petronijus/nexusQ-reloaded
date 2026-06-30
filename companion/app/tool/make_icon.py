#!/usr/bin/env python3
"""Generate the nexusQ-reloaded app icon — our own mark in the Nexus Q visual
language (a glowing Holo-Blue sphere outline + equatorial LED arc on black),
matching the app's GlowingRing hero. NOT the original Google "Q" logo (that is a
Google trademark; kept reference-only in private/).

Outputs (committed as source art):
  assets/icon/icon.png             1024² full-bleed, black bg — iOS/macOS/web/legacy Android
  assets/icon/icon_foreground.png  1024² transparent, ring inset in the adaptive safe zone

Requires Pillow.  Run:  python3 tool/make_icon.py
"""
import math
import os
from PIL import Image, ImageDraw, ImageFilter

S = 1024
ACCENT = (51, 181, 229)      # #33B5E5 Holo Blue
SS = 4                        # supersample for crisp anti-aliased strokes


def draw_ring(size, radius_frac, bg):
    """Render the ring at `size`, ring radius = radius_frac*size, onto `bg`
    (an RGBA tuple, alpha 0 = transparent). Returns an RGBA image."""
    n = size * SS
    img = Image.new("RGBA", (n, n), bg)
    cx = cy = n / 2
    r = radius_frac * n

    def arc_layer(width, alpha, start, end):
        layer = Image.new("RGBA", (n, n), (0, 0, 0, 0))
        d = ImageDraw.Draw(layer)
        box = [cx - r, cy - r, cx + r, cy + r]
        d.arc(box, start, end, fill=ACCENT + (alpha,), width=width)
        return layer

    glow = Image.new("RGBA", (n, n), (0, 0, 0, 0))
    # 1) full dim sphere-silhouette circle
    glow = Image.alpha_composite(glow, arc_layer(int(0.006 * n), 90, 0, 360))
    # 2) bright equatorial arc, centered on the bottom (90°), ~150° sweep
    sweep = 150
    start, end = 90 - sweep / 2, 90 + sweep / 2
    bright = arc_layer(int(0.014 * n), 255, start, end)
    # glow halo: blurred copy of the bright arc + circle
    halo = Image.alpha_composite(arc_layer(int(0.02 * n), 200, 0, 360),
                                 arc_layer(int(0.03 * n), 255, start, end))
    halo = halo.filter(ImageFilter.GaussianBlur(radius=0.02 * n))

    out = Image.alpha_composite(img, halo)
    out = Image.alpha_composite(out, glow)
    out = Image.alpha_composite(out, bright)
    return out.resize((size, size), Image.LANCZOS)


def main():
    here = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    out_dir = os.path.join(here, "assets", "icon")
    os.makedirs(out_dir, exist_ok=True)

    # full-bleed, black background, ring ~0.36 of the canvas
    full = draw_ring(S, 0.36, (0, 0, 0, 255))
    full.convert("RGB").save(os.path.join(out_dir, "icon.png"))

    # adaptive foreground: transparent, ring inset (~0.27) for the safe zone
    fg = draw_ring(S, 0.27, (0, 0, 0, 0))
    fg.save(os.path.join(out_dir, "icon_foreground.png"))

    print("wrote", os.path.join(out_dir, "icon.png"), "and icon_foreground.png")


if __name__ == "__main__":
    main()
