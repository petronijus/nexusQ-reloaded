/* userspace/nexusqd/tests/test_fx_waveformsolid.c */
#include "test.h"
#include "fx_waveformsolid.h"

static void test_two_arc_colors(void) {
    struct rtheme t; rtheme_init_rainbow(&t, 0.9f, 1.0f);
    struct jrandom r; jrandom_seed(&r, 1);
    struct fx_waveformsolid w; fx_waveformsolid_init(&w, &t, &r);
    w.multi_colored = 0; w.theme_position = 0.0f;

    struct frame f; fx_waveformsolid_render(&w, 1.0f, &f);
    uint8_t p[RING*3]; frame_pack(&f, p);
    /* top arc (24..31) + bottom arc (0..7) = color A (pos 0) = red (255,26,26) */
    CHECK(p[0]==255 && p[1]==26 && p[2]==26);
    CHECK(p[28*3]==255 && p[28*3+1]==26 && p[28*3+2]==26);
    /* middle arc (8..23) = color B (0.5+pos = hue 180) = cyan (26,255,255) */
    CHECK(p[10*3]==26 && p[10*3+1]==255 && p[10*3+2]==255);
}

int main(void) { RUN(test_two_arc_colors); return REPORT(); }
