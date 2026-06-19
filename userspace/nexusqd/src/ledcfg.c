/* userspace/nexusqd/src/ledcfg.c — see ledcfg.h */
#include "ledcfg.h"
#include <math.h>

void ledcfg_reset(struct ledcfg *c) {
    c->solid = 1;
    c->solid_color[0] = c->solid_color[1] = c->solid_color[2] = 0.0f;
    for (int i = 0; i < RING * 3; i++) c->buf[i] = 0.0f;
}

float *ledcfg_solid(struct ledcfg *c) {
    c->solid = 1;
    return c->solid_color;
}

float *ledcfg_buffer(struct ledcfg *c) {
    c->solid = 0;
    return c->buf;
}

static int to_byte(float f) {
    int v = (int)floorf(255.0f * f + 0.5f);   /* Math.round(255*f) */
    if (v < 0) v = 0;
    if (v > 255) v = 255;
    return v;
}

void ledcfg_to_frame(const struct ledcfg *c, struct frame *out) {
    if (c->solid) {
        frame_fill(out, to_byte(c->solid_color[0]), to_byte(c->solid_color[1]), to_byte(c->solid_color[2]));
    } else {
        for (int i = 0; i < RING; i++)
            frame_set(out, i, to_byte(c->buf[i*3]), to_byte(c->buf[i*3+1]), to_byte(c->buf[i*3+2]));
    }
}

void put_rgb_scaled(float *buffer, int off, const float rgb[3], float alpha) {
    buffer[off]     = rgb[0] * alpha;
    buffer[off + 1] = rgb[1] * alpha;
    buffer[off + 2] = rgb[2] * alpha;
}
