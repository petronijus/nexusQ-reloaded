/* userspace/nexusqd/include/fx_circles.h — port of nodes/Circles (LED path) */
#ifndef NEXUSQD_FX_CIRCLES_H
#define NEXUSQD_FX_CIRCLES_H
#include "frame.h"
#include "themecolor.h"
#include "audiocap.h"
#include "jrandom.h"

struct fx_circles {
    const struct rtheme *theme;
    struct jrandom *rng;
    float theme_position;
    int   forward;
    float shift;
};

void fx_circles_init(struct fx_circles *c, const struct rtheme *theme, struct jrandom *rng);
void fx_circles_update(struct fx_circles *c, const struct audio_state *a, float dt);
void fx_circles_render(struct fx_circles *c, float alpha, struct frame *out);
#endif
