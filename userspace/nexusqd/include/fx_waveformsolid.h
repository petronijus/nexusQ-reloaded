/* userspace/nexusqd/include/fx_waveformsolid.h — port of nodes/WaveformSolid (LED path) */
#ifndef NEXUSQD_FX_WAVEFORMSOLID_H
#define NEXUSQD_FX_WAVEFORMSOLID_H
#include "frame.h"
#include "themecolor.h"
#include "audiocap.h"
#include "jrandom.h"

struct fx_waveformsolid {
    const struct rtheme *theme;
    struct jrandom *rng;
    float theme_position;
    int   multi_colored;
    int   shift_direction;
    int   first_bottom_led;   /* (RING/4)*3 */
    int   first_top_led;      /* ((RING*3)/4)*3 */
    float led_theme_delta;    /* 1/RING */
};

void fx_waveformsolid_init(struct fx_waveformsolid *w, const struct rtheme *theme, struct jrandom *rng);
void fx_waveformsolid_update(struct fx_waveformsolid *w, const struct audio_state *a, float dt);
void fx_waveformsolid_render(struct fx_waveformsolid *w, float alpha, struct frame *out);
#endif
