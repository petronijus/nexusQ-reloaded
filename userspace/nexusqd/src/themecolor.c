/* userspace/nexusqd/src/themecolor.c — see themecolor.h */
#include "themecolor.h"
#include <math.h>

#define PI_F 3.1415927f

static int sk_round(float x) { return (int)floorf(x + 0.5f); }   /* SkScalarRoundToInt */

/* android RGBToHSV (Skia SkRGBToHSV): rgb 0..255 -> h[0,360), s[0,1], v[0,1] */
static void rgb_to_hsv(int r, int g, int b, float hsv[3]) {
    int maxc = r > g ? (r > b ? r : b) : (g > b ? g : b);
    int minc = r < g ? (r < b ? r : b) : (g < b ? g : b);
    int delta = maxc - minc;
    float v = maxc / 255.0f;
    float s = maxc == 0 ? 0.0f : (float)delta / maxc;
    float h;
    if (delta == 0) {
        h = 0.0f;
    } else if (maxc == r) {
        h = (g - b) / (float)delta;
    } else if (maxc == g) {
        h = 2.0f + (b - r) / (float)delta;
    } else {
        h = 4.0f + (r - g) / (float)delta;
    }
    h *= 60.0f;
    if (h < 0.0f) h += 360.0f;
    hsv[0] = h; hsv[1] = s; hsv[2] = v;
}

void rtheme_init_rainbow(struct rtheme *t, float saturation, float value) {
    t->palette = 0; t->sat = saturation; t->val = value; t->ncolors = 0;
}

void rtheme_init_palette(struct rtheme *t, const unsigned char *rgb, int n,
                         float saturation_factor, float value_factor) {
    t->palette = 1;
    t->sat_factor = saturation_factor; t->val_factor = value_factor;
    if (n > THEME_MAX_COLORS) n = THEME_MAX_COLORS;
    t->ncolors = n;
    float tmp[3];
    for (int i = 0; i < n; i++) {
        rgb_to_hsv(rgb[i*3], rgb[i*3+1], rgb[i*3+2], tmp);
        t->hue_rad[i] = (tmp[0] / 180.0f) * PI_F;   /* PaletteTheme stores hue in radians */
        t->pal_sat[i] = tmp[1];
        t->pal_val[i] = tmp[2];
    }
}

void rtheme_hsv(const struct rtheme *t, float position, float out_hsv[3]) {
    if (!t->palette) {                       /* RainbowTheme.themeColor */
        out_hsv[0] = 360.0f * position;
        out_hsv[1] = t->sat;
        out_hsv[2] = t->val;
        return;
    }
    /* PaletteTheme.themeColor: circular hue interpolation between two palette stops */
    int n = t->ncolors;
    float scaled = fmodf(n * position, (float)n);
    int rounded = (int)scaled;
    int i1 = rounded;
    int i2 = (rounded + 1) % n;
    float w1 = (rounded + 1) - scaled;
    float w2 = 1.0f - w1;
    double hX = cos(t->hue_rad[i1]) * w1 + cos(t->hue_rad[i2]) * w2;
    double hY = sin(t->hue_rad[i1]) * w1 + sin(t->hue_rad[i2]) * w2;
    float hue = (float)(atan2(hY, hX) * 180.0 / PI_F);
    if (hue < 0.0f) hue += 360.0f;
    float sat = t->pal_sat[i1] * w1 + t->pal_sat[i2] * w2;
    float val = t->pal_val[i1] * w1 + t->pal_val[i2] * w2;
    out_hsv[0] = hue;
    out_hsv[1] = t->sat_factor * sat;
    out_hsv[2] = t->val_factor * val;
}

void hsv_to_rgb(const float hsv[3], float out_rgb[3]) {
    float s = hsv[1] < 0 ? 0 : hsv[1] > 1 ? 1 : hsv[1];   /* SkScalarPin */
    float v = hsv[2] < 0 ? 0 : hsv[2] > 1 ? 1 : hsv[2];
    int v_byte = sk_round(v * 255.0f);
    int r, g, b;
    if (s < (1.0f / 4096.0f)) {                            /* SkScalarNearlyZero */
        r = g = b = v_byte;
    } else {
        float hx = (hsv[0] < 0.0f || hsv[0] >= 360.0f) ? 0.0f : (hsv[0] / 60.0f);
        float w = floorf(hx);
        float f = hx - w;
        int p = sk_round((1.0f - s) * v * 255.0f);
        int q = sk_round((1.0f - (s * f)) * v * 255.0f);
        int tt = sk_round((1.0f - (s * (1.0f - f))) * v * 255.0f);
        switch ((unsigned)w) {
            case 0:  r = v_byte; g = tt;     b = p;      break;
            case 1:  r = q;      g = v_byte; b = p;      break;
            case 2:  r = p;      g = v_byte; b = tt;     break;
            case 3:  r = p;      g = q;      b = v_byte; break;
            case 4:  r = tt;     g = p;      b = v_byte; break;
            default: r = v_byte; g = p;      b = q;      break;
        }
    }
    out_rgb[0] = r / 255.0f;
    out_rgb[1] = g / 255.0f;
    out_rgb[2] = b / 255.0f;
}
