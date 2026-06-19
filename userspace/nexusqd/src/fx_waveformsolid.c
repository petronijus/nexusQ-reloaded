/* userspace/nexusqd/src/fx_waveformsolid.c — port of nodes/WaveformSolid.ledRenderScene */
#include "fx_waveformsolid.h"
#include "ledcfg.h"
#include <math.h>

void fx_waveformsolid_init(struct fx_waveformsolid *w, const struct rtheme *theme, struct jrandom *rng) {
    w->theme = theme; w->rng = rng;
    w->theme_position = jrandom_float(rng);
    w->multi_colored = jrandom_boolean(rng);
    w->shift_direction = jrandom_boolean(rng);
    w->first_bottom_led = (RING / 4) * 3;
    w->first_top_led = ((RING * 3) / 4) * 3;
    w->led_theme_delta = 1.0f / RING;
}

void fx_waveformsolid_update(struct fx_waveformsolid *w, const struct audio_state *a, float dt) {
    float shift = audiocap_smoothed_beat(a) * 0.05f * dt;
    if (w->shift_direction) {
        w->theme_position = fmodf(w->theme_position + shift, 1.0f);
    } else {
        float tp = w->theme_position - shift;
        if (tp < 0.0f) tp += 1.0f;
        w->theme_position = tp;
    }
}

static void color_at(const struct rtheme *t, float pos, float alpha, float out[3]) {
    float hsv[3]; rtheme_hsv(t, pos, hsv);
    float rgb[3]; hsv_to_rgb(hsv, rgb);
    out[0] = rgb[0] * alpha; out[1] = rgb[1] * alpha; out[2] = rgb[2] * alpha;
}

void fx_waveformsolid_render(struct fx_waveformsolid *w, float alpha, struct frame *out) {
    struct ledcfg cfg;
    float *buf = ledcfg_buffer(&cfg);
    float tp = w->theme_position;
    float rgb[3];
    if (w->multi_colored) {
        for (int i = 0; i < RING * 3; i += 3) {
            tp = fmodf(w->led_theme_delta + tp, 1.0f);
            color_at(w->theme, tp, alpha, rgb); buf[i]=rgb[0]; buf[i+1]=rgb[1]; buf[i+2]=rgb[2];
        }
        ledcfg_to_frame(&cfg, out);
        return;
    }
    color_at(w->theme, tp, alpha, rgb);
    for (int i = w->first_top_led; i < RING * 3; i += 3) { buf[i]=rgb[0]; buf[i+1]=rgb[1]; buf[i+2]=rgb[2]; }
    for (int i = 0; i < w->first_bottom_led; i += 3)      { buf[i]=rgb[0]; buf[i+1]=rgb[1]; buf[i+2]=rgb[2]; }
    color_at(w->theme, fmodf(0.5f + tp, 1.0f), alpha, rgb);
    for (int i = w->first_bottom_led; i < w->first_top_led; i += 3) { buf[i]=rgb[0]; buf[i+1]=rgb[1]; buf[i+2]=rgb[2]; }
    ledcfg_to_frame(&cfg, out);
}
