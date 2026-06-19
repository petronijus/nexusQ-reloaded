/* userspace/nexusqd/src/fx_starfield.c — port of nodes/StarField.ledRenderScene */
#include "fx_starfield.h"
#include "ledcfg.h"
#include <math.h>

static float led_alpha_at(float offset) {
    return (1.0f / (float)sqrt(4.71238898038469)) * (float)exp((-(offset * offset)) / 1.5f);
}
#define LED_ALPHA_SCALE_FACTOR (1.0f / led_alpha_at(0.0f))

static void init_particle_position(struct fx_starfield *s, struct sf_particle *p, float min, float var) {
    p->z = (jrandom_float(s->rng) * var) + min;
    p->x = ((float)jrandom_gaussian(s->rng) / 1.5f) + 0.5f;
    p->y = ((float)jrandom_gaussian(s->rng) / 1.5f) + 0.5f;
}

void fx_starfield_init(struct fx_starfield *s, const struct rtheme *theme, struct jrandom *rng) {
    s->theme = theme; s->rng = rng;
    for (int i = 0; i < SF_PARTICLES; i++) {
        init_particle_position(s, &s->particles[i], 0.0f, 150.0f);
        s->particles[i].theme_offset = jrandom_float(rng);
        s->particles[i].theta = (float)jrandom_int_bound(rng, 360);
    }
    /* onStarted() */
    s->rainbow = jrandom_boolean(rng);
    s->theme_position = jrandom_float(rng);
}

void fx_starfield_update(struct fx_starfield *s, const struct audio_state *a, float dt) {
    float volume = audiocap_volume(a) * 320.0f;
    float smoothed = audiocap_smoothed_beat(a);
    float delta = (5.0f * dt) + (((volume * smoothed) * dt) / 15.0f);
    s->theme_position = fmodf(s->theme_position + (delta / 36.0f), 1.0f);

    int off = audiocap_last_segment_index(a);
    const float *audio = audiocap_buffer(a);
    for (int i = 0; i < SF_PARTICLES; i++) {
        struct sf_particle *p = &s->particles[i];
        p->theta += audio[(off + i) % SAMPLES_PER_SEGMENT] * 15.0f;
        p->theta = fmodf(p->theta, 360.0f);
        if (p->theta < 0.0f) p->theta += ((int)(((-p->theta) / 360.0f) + 1.0f)) * 360;
        p->z -= delta;
        if (p->z < 1.0f) init_particle_position(s, p, 80.0f, 40.0f);
    }
}

static void theme_color06(const struct rtheme *t, float pos, float rgb[3]) {
    float hsv[3]; rtheme_hsv(t, pos, hsv);
    hsv[2] *= 0.6f;                       /* StarField.themeColor: setValue(value*0.6) */
    hsv_to_rgb(hsv, rgb);
}

void fx_starfield_render(struct fx_starfield *s, float alpha, struct frame *out) {
    float rgb[3]; theme_color06(s->theme, s->theme_position, rgb);

    struct ledcfg cfg;
    ledcfg_reset(&cfg);
    float *buf = ledcfg_buffer(&cfg);

    for (int i = 0; i < SF_PARTICLES; i += 16) {
        struct sf_particle *p = &s->particles[i];
        float ledTheta = fmodf(p->theta * (RING / 360.0f), (float)RING);
        if (ledTheta < 0.0f) ledTheta += ((int)(((-ledTheta) / RING) + 1.0f)) * RING;
        for (int j = ((int)ledTheta) - 2; j < 3.0f + ledTheta; j++) {
            float a = LED_ALPHA_SCALE_FACTOR * led_alpha_at(ledTheta - j);
            if (s->rainbow) theme_color06(s->theme, fmodf(s->theme_position + p->theme_offset, 1.0f), rgb);
            float tmp[3]; put_rgb_scaled(tmp, 0, rgb, a);
            int index = ((j + RING) * 3) % (RING * 3);
            buf[index]   = fminf(1.0f, buf[index]   + tmp[0]);
            buf[index+1] = fminf(1.0f, buf[index+1] + tmp[1]);
            buf[index+2] = fminf(1.0f, buf[index+2] + tmp[2]);
        }
    }
    for (int i = 0; i < RING * 3; i++) buf[i] *= alpha;
    ledcfg_to_frame(&cfg, out);
}
