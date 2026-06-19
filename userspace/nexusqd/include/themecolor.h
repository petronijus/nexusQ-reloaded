/* userspace/nexusqd/include/themecolor.h
 * Port of utils/Color + utils/RainbowTheme + utils/PaletteTheme.
 *
 * Color.setHsv -> android.graphics.Color.HSVToColor (Skia SkHSVToColor: rounds to
 * 0..255 bytes) -> /255 floats. We reproduce SkHSVToColor exactly so the float RGB
 * matches; the LED path then re-quantizes via round(255*f) (LedController.toByte).
 *
 * ColorTheme.themeColor(pos, color) yields an HSV triple [hue_deg, sat, val]; the
 * default theme is RainbowTheme(0.9, 1.0). We expose the HSV (not just RGB) so
 * StarField's `color.setValue(value*0.6)` can be reproduced (re-quantize after
 * scaling V on the cached HSV). */
#ifndef NEXUSQD_THEMECOLOR_H
#define NEXUSQD_THEMECOLOR_H

#define THEME_MAX_COLORS 16

struct rtheme {
    int   palette;           /* 0 = RainbowTheme, 1 = PaletteTheme */
    float sat, val;          /* RainbowTheme(saturation, value) */
    int   ncolors;           /* PaletteTheme */
    float hue_rad[THEME_MAX_COLORS];  /* palette hue in radians (temp[0]/180*PI) */
    float pal_sat[THEME_MAX_COLORS];
    float pal_val[THEME_MAX_COLORS];
    float sat_factor, val_factor;
};

void rtheme_init_rainbow(struct rtheme *t, float saturation, float value);
/* colors: packed RGB bytes [r,g,b]*n (n<=16). Mirrors PaletteTheme(int[] colors,...) */
void rtheme_init_palette(struct rtheme *t, const unsigned char *rgb, int n,
                         float saturation_factor, float value_factor);
/* themeColor(position) -> out_hsv = {hue_deg, sat, val} */
void rtheme_hsv(const struct rtheme *t, float position, float out_hsv[3]);

/* SkHSVToColor: hsv={hue_deg,sat,val} -> rgb floats in [0,1] (via 0..255 rounding) */
void hsv_to_rgb(const float hsv[3], float out_rgb[3]);

#endif
