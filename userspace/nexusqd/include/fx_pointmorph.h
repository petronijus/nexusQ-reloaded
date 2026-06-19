/* userspace/nexusqd/include/fx_pointmorph.h — port of nodes/PointMorph (LED path) */
#ifndef NEXUSQD_FX_POINTMORPH_H
#define NEXUSQD_FX_POINTMORPH_H
#include "frame.h"
#include "themecolor.h"
#include "audiocap.h"
#include "jrandom.h"

#define PM_MODELS          4
#define PM_MODEL_LED_POINTS 8   /* mLedModels[k].length (pointmorph_model_*_led) */

struct fx_pointmorph {
    const struct rtheme *theme;
    struct jrandom *rng;
    float angle;
    float theme_position;
    int   multi_colored;
    int   morph_from;
    int   morph_to;
    int   morphing;
    float linear_transition;
    float smooth_transition;
    float time_since_last_morph;
};

void fx_pointmorph_init(struct fx_pointmorph *p, const struct rtheme *theme, struct jrandom *rng);
void fx_pointmorph_update(struct fx_pointmorph *p, const struct audio_state *a, float dt);
void fx_pointmorph_render(struct fx_pointmorph *p, float alpha, struct frame *out);
#endif
