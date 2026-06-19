/* userspace/nexusqd/include/fx_waveform.h — port of nodes/Waveform (LED path) */
#ifndef NEXUSQD_FX_WAVEFORM_H
#define NEXUSQD_FX_WAVEFORM_H
#include "frame.h"
#include "themecolor.h"
#include "audiocap.h"
#include "jrandom.h"

struct fx_waveform {
    const struct rtheme *theme;
    struct jrandom *rng;
    float theme_position;
    int   multi_colored;
    int   shift_direction;
    int   first_bottom_led;   /* (RING/4)*3 */
    int   first_top_led;      /* ((RING*3)/4)*3 */
    float led_theme_delta;    /* (SAMPLES_PER_SEGMENT*7e-4)/RING */
};

void fx_waveform_init(struct fx_waveform *w, const struct rtheme *theme, struct jrandom *rng);
void fx_waveform_update(struct fx_waveform *w, const struct audio_state *a, float dt);
void fx_waveform_render(struct fx_waveform *w, float alpha, struct frame *out);
#endif
