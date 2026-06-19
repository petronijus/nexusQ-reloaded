/* userspace/nexusqd/src/music.c */
#include "music.h"

void music_init(struct music *m, uint64_t seed) {
    rtheme_init_rainbow(&m->theme, 0.9f, 1.0f);   /* RenderEngine default RainbowTheme(0.9,1.0) */
    jrandom_seed(&m->rng, seed);
    /* construct scenes in RenderEngine.mScenes order, sharing the one Random */
    fx_waveform_init(&m->waveform, &m->theme, &m->rng);
    fx_waveformsolid_init(&m->waveformsolid, &m->theme, &m->rng);
    fx_circles_init(&m->circles, &m->theme, &m->rng);
    fx_pointmorph_init(&m->pointmorph, &m->theme, &m->rng);
    fx_starfield_init(&m->starfield, &m->theme, &m->rng);
    m->scene = 0;
}

void music_set_scene(struct music *m, int scene) {
    if (scene < 0) scene = 0;
    if (scene >= MUSIC_NSCENES) scene = MUSIC_NSCENES - 1;
    m->scene = scene;
}

int music_scene(const struct music *m) { return m->scene; }

void music_update(struct music *m, const struct audio_state *a, float dt) {
    switch (m->scene) {
        case 0: fx_waveform_update(&m->waveform, a, dt); break;
        case 1: fx_waveformsolid_update(&m->waveformsolid, a, dt); break;
        case 2: fx_circles_update(&m->circles, a, dt); break;
        case 3: fx_pointmorph_update(&m->pointmorph, a, dt); break;
        case 4: fx_starfield_update(&m->starfield, a, dt); break;
        default: break;
    }
}

void music_render(struct music *m, float alpha, struct frame *out) {
    switch (m->scene) {
        case 0: fx_waveform_render(&m->waveform, alpha, out); break;
        case 1: fx_waveformsolid_render(&m->waveformsolid, alpha, out); break;
        case 2: fx_circles_render(&m->circles, alpha, out); break;
        case 3: fx_pointmorph_render(&m->pointmorph, alpha, out); break;
        case 4: fx_starfield_render(&m->starfield, alpha, out); break;
        default: frame_black(out); break;
    }
}
