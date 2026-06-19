/* userspace/nexusqd/include/fx_starfield.h — port of nodes/StarField (LED path) */
#ifndef NEXUSQD_FX_STARFIELD_H
#define NEXUSQD_FX_STARFIELD_H
#include "frame.h"
#include "themecolor.h"
#include "audiocap.h"
#include "jrandom.h"

#define SF_PARTICLES 100

struct sf_particle { float theme_offset, theta, x, y, z; };

struct fx_starfield {
    const struct rtheme *theme;
    struct jrandom *rng;
    int   rainbow;
    float theme_position;
    struct sf_particle particles[SF_PARTICLES];
};

void fx_starfield_init(struct fx_starfield *s, const struct rtheme *theme, struct jrandom *rng);
void fx_starfield_update(struct fx_starfield *s, const struct audio_state *a, float dt);
void fx_starfield_render(struct fx_starfield *s, float alpha, struct frame *out);
#endif
