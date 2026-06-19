/* userspace/nexusqd/src/fx_pointmorph.c — port of nodes/PointMorph.ledRenderScene
 * LED models from private/nexusq-original/visualizer/pointmorph_model_*_led
 * (cube, sphere, spiral, stackedcircles), each 8 ring positions in [0,1]. */
#include "fx_pointmorph.h"
#include "ledcfg.h"
#include <math.h>

static const float LED_MODELS[PM_MODELS][PM_MODEL_LED_POINTS] = {
    { 0.0f, 0.0f, 0.25f, 0.25f, 0.5f, 0.5f, 0.75f, 0.75f },              /* cube */
    { 0.0f, 0.0f, 0.125f, 0.25f, 0.5f, 0.625f, 0.75f, 0.875f },          /* sphere */
    { 0.125f, 0.125f, 0.375f, 0.375f, 0.625f, 0.625f, 0.875f, 0.875f },  /* spiral */
    { 0.0f, 0.0f, 0.03125f, 0.03125f, 0.5f, 0.5f, 0.53125f, 0.53125f },  /* stackedcircles */
};

static float led_alpha_at(float offset) {
    return (1.0f / (float)sqrt(3.141592653589793)) * (float)exp((-(offset * offset)) / 1.0f);
}
#define LED_ALPHA_SCALE_FACTOR (1.0f / led_alpha_at(0.0f))

static int next_int_excluding(struct jrandom *r, int n, int exclude) {
    int next = jrandom_int_bound(r, n - 1);
    return next == exclude ? n - 1 : next;
}

void fx_pointmorph_init(struct fx_pointmorph *p, const struct rtheme *theme, struct jrandom *rng) {
    p->theme = theme; p->rng = rng;
    p->angle = 0.0f;
    p->morphing = 0; p->linear_transition = 0; p->smooth_transition = 0; p->time_since_last_morph = 0;
    /* onStarted() */
    p->theme_position = jrandom_float(rng);
    p->multi_colored = jrandom_boolean(rng);
    p->morph_from = jrandom_int_bound(rng, PM_MODELS);
    p->morph_to = p->morph_from;
}

void fx_pointmorph_update(struct fx_pointmorph *p, const struct audio_state *a, float dt) {
    if (!p->morphing) {
        if (PM_MODELS > 1 && jrandom_float(p->rng) * 20.0f < p->time_since_last_morph) {
            p->morphing = 1;
            p->morph_to = next_int_excluding(p->rng, PM_MODELS, p->morph_from);
            p->linear_transition = 0.0f;
            p->smooth_transition = 0.0f;
            p->time_since_last_morph = 0.0f;
        } else {
            p->time_since_last_morph += dt;
        }
    } else {
        p->linear_transition += dt * 2.0f;
        if (p->linear_transition >= 3.141592653589793) {
            p->morphing = 0;
            p->morph_from = p->morph_to;
        }
        p->smooth_transition = (1.0f - (float)cos(p->linear_transition)) / 2.0f;
    }
    float step = audiocap_smoothed_beat(a) * dt * audiocap_volume(a);
    p->angle += (15.0f * dt) + (160.0f * step);
    p->theme_position = fmodf(p->theme_position + (0.4f * step), 1.0f);
}

void fx_pointmorph_render(struct fx_pointmorph *p, float alpha, struct frame *out) {
    float hsv[3]; rtheme_hsv(p->theme, p->theme_position, hsv);
    float rgb[3]; hsv_to_rgb(hsv, rgb);

    struct ledcfg cfg;
    ledcfg_reset(&cfg);
    float *buf = ledcfg_buffer(&cfg);   /* zeroed by reset */

    for (int i = 0; i < PM_MODEL_LED_POINTS; i++) {
        float pos = p->morphing
            ? (1.0f - p->smooth_transition) * LED_MODELS[p->morph_from][i] + p->smooth_transition * LED_MODELS[p->morph_to][i]
            : LED_MODELS[p->morph_from][i];
        float pos2 = pos * RING;
        /* original: themeColor((themePosition + (i/modelLedPoints))%1) — i/modelLedPoints is
         * INTEGER division (always 0 for i<8), so multiColored is a no-op here. */
        for (int j = ((int)pos2) - 1; j < 3.0f + pos2; j++) {
            float ga = LED_ALPHA_SCALE_FACTOR * led_alpha_at(pos2 - j);
            float tmp[3]; put_rgb_scaled(tmp, 0, rgb, ga);
            int index = ((j + RING) * 3) % (RING * 3);
            buf[index]   = fminf(1.0f, buf[index]   + tmp[0]);
            buf[index+1] = fminf(1.0f, buf[index+1] + tmp[1]);
            buf[index+2] = fminf(1.0f, buf[index+2] + tmp[2]);
        }
    }
    for (int i = 0; i < RING * 3; i++) buf[i] *= alpha;
    ledcfg_to_frame(&cfg, out);
}
