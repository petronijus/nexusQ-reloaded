/* userspace/nexusqd/include/music.h
 * Wraps the 5 ported music-reactive scenes (RenderEngine.mScenes order:
 * Waveform, WaveformSolid, Circles, PointMorph, StarField) behind one
 * index-dispatched interface. The default theme is RainbowTheme(0.9, 1.0) and a
 * single shared jrandom (mirrors RenderEngine's shared mRandom). */
#ifndef NEXUSQD_MUSIC_H
#define NEXUSQD_MUSIC_H
#include <stdint.h>
#include "frame.h"
#include "audiocap.h"
#include "themecolor.h"
#include "jrandom.h"
#include "fx_waveform.h"
#include "fx_waveformsolid.h"
#include "fx_circles.h"
#include "fx_pointmorph.h"
#include "fx_starfield.h"

#define MUSIC_NSCENES 5

struct music {
    struct rtheme  theme;
    struct jrandom rng;
    int scene;                    /* 0..MUSIC_NSCENES-1 (RenderEngine order) */
    struct fx_waveform      waveform;
    struct fx_waveformsolid waveformsolid;
    struct fx_circles       circles;
    struct fx_pointmorph    pointmorph;
    struct fx_starfield     starfield;
};

void music_init(struct music *m, uint64_t seed);          /* RainbowTheme(0.9,1.0), all scenes */
void music_set_scene(struct music *m, int scene);         /* clamp 0..4 */
int  music_scene(const struct music *m);
void music_update(struct music *m, const struct audio_state *a, float dt);  /* active scene only */
void music_render(struct music *m, float alpha, struct frame *out);
#endif
