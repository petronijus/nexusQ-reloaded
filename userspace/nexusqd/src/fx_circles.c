/* userspace/nexusqd/src/fx_circles.c — port of nodes/Circles.ledRenderScene */
#include "fx_circles.h"
#include "ledcfg.h"
#include <math.h>

static float led_alpha_at(float offset) {
    return (1.0f / (float)sqrt(10.05309664129015)) * (float)exp((-(offset * offset)) / 3.2f);
}
#define LED_ALPHA_SCALE_FACTOR (1.0f / led_alpha_at(0.0f))

void fx_circles_init(struct fx_circles *c, const struct rtheme *theme, struct jrandom *rng) {
    c->theme = theme; c->rng = rng;
    c->theme_position = jrandom_float(rng);
    c->forward = jrandom_boolean(rng);
    c->shift = 0.0f;
}

void fx_circles_update(struct fx_circles *c, const struct audio_state *a, float dt) {
    if (audiocap_beat_this_frame(a) && jrandom_int_bound(c->rng, 8) == 0)
        c->forward = jrandom_boolean(c->rng);
    float shiftThisFrame = (30.0f * dt) + audiocap_smoothed_beat(a);
    c->shift += c->forward ? shiftThisFrame : -shiftThisFrame;
    c->theme_position = fmodf(c->theme_position + (0.0028f * shiftThisFrame), 1.0f);
}

void fx_circles_render(struct fx_circles *c, float alpha, struct frame *out) {
    float scaledShift = c->shift / 30.0f;
    if (scaledShift < 0.0f)
        scaledShift += (((int)((-scaledShift) / 8.0f)) + 1) * 8;
    float hsv[3]; rtheme_hsv(c->theme, c->theme_position, hsv);
    float rgb[3]; hsv_to_rgb(hsv, rgb);

    struct ledcfg cfg;
    float *buf = ledcfg_buffer(&cfg);
    for (int i = 0; i < RING; i++) {
        float a = LED_ALPHA_SCALE_FACTOR * alpha * led_alpha_at(fmodf(i + scaledShift, 8.0f) - 3.0f);
        put_rgb_scaled(buf, i * 3, rgb, a);
    }
    ledcfg_to_frame(&cfg, out);
}
