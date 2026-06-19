/* userspace/nexusqd/src/reaction.c */
#include "reaction.h"

static int clampi(int v, int lo, int hi) { return v < lo ? lo : v > hi ? hi : v; }

double reaction_end_brightness(int volume) {
    int v = clampi(volume, 0, 100);
    return 0.1 + (v / 100.0) * 0.9;
}

double reaction_brightness(const struct reaction *rx, double now) {
    double eb = reaction_end_brightness(rx->volume);
    if (rx->animate) {
        double e = now - rx->anim_start;
        if (e < 0) e = 0;
        if (e < RX_ANIM_S) {
            double t = e / RX_ANIM_S;                    /* 0..1 */
            double eased = 1.0 - (1.0 - t) * (1.0 - t);  /* DecelerateInterpolator, factor 1 */
            return eased * eb;
        }
    }
    return eb;
}

void reaction_render(const struct reaction *rx, double now, struct frame *out) {
    double b = reaction_brightness(rx, now);
    /* (int) truncation matches Java float->int and reproduces the RE hex table */
    int g  = (int)(RX_COLOR_G * b);
    int bl = (int)(RX_COLOR_B * b);
    frame_fill(out, RX_COLOR_R, g, bl);
}

void reaction_on_volume(struct reaction *rx, int volume, double now) {
    int was_active = reaction_overlay_active(rx, now);
    rx->volume = clampi(volume, 0, 100);
    rx->animate = !was_active;          /* fade-in only when coming from idle */
    if (!was_active) rx->anim_start = now;
    rx->last_event = now;
}

int reaction_overlay_active(const struct reaction *rx, double now) {
    if (rx->last_event <= 0) return 0;
    return (now - rx->last_event) < RX_TIMEOUT_S ? 1 : 0;
}

void reaction_mute_led(int muted, int *r, int *g, int *b) {
    double a = muted ? 0.2 : 0.7;
    *r = (int)(RX_COLOR_R * a);
    *g = (int)(RX_COLOR_G * a);
    *b = (int)(RX_COLOR_B * a);
}

void reaction_default_color(int *r, int *g, int *b) {
    *r = (int)(RX_COLOR_R * 0.1);
    *g = (int)(RX_COLOR_G * 0.1);
    *b = (int)(RX_COLOR_B * 0.1);
}
