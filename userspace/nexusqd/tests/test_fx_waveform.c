/* userspace/nexusqd/tests/test_fx_waveform.c */
#include "test.h"
#include "fx_waveform.h"

static void test_solid(void) {
    struct rtheme t; rtheme_init_rainbow(&t, 0.9f, 1.0f);
    struct jrandom r; jrandom_seed(&r, 1);
    struct fx_waveform w; fx_waveform_init(&w, &t, &r);
    w.multi_colored = 0; w.theme_position = 0.0f;     /* solid red */

    struct frame f; fx_waveform_render(&w, 1.0f, &f);
    uint8_t p[RING*3]; frame_pack(&f, p);
    /* SOLID -> every LED is the theme color at pos 0 = (255,26,26) */
    CHECK(p[0]==255 && p[1]==26 && p[2]==26);
    CHECK(p[20*3]==255 && p[20*3+1]==26 && p[20*3+2]==26);
    CHECK(p[RING*3-3]==255);
}

static void test_multicolor_fills_all(void) {
    struct rtheme t; rtheme_init_rainbow(&t, 0.9f, 1.0f);
    struct jrandom r; jrandom_seed(&r, 1);
    struct fx_waveform w; fx_waveform_init(&w, &t, &r);
    w.multi_colored = 1; w.theme_position = 0.0f;
    struct frame f; fx_waveform_render(&w, 1.0f, &f);
    uint8_t p[RING*3]; frame_pack(&f, p);
    /* gradient: every LED lit (no black gap), colors vary around the ring */
    int lit = 0; for (int i = 0; i < RING; i++) if (p[i*3]||p[i*3+1]||p[i*3+2]) lit++;
    CHECK(lit == RING);
}

int main(void) { RUN(test_solid); RUN(test_multicolor_fills_all); return REPORT(); }
