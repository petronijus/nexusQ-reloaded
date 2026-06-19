/* userspace/nexusqd/tests/test_fx_pointmorph.c */
#include "test.h"
#include "fx_pointmorph.h"

static void test_cube_blobs(void) {
    struct rtheme t; rtheme_init_rainbow(&t, 0.9f, 1.0f);
    struct jrandom r; jrandom_seed(&r, 1);
    struct fx_pointmorph p; fx_pointmorph_init(&p, &t, &r);
    p.morphing = 0; p.morph_from = 0;     /* cube: points at 0,0,.25,.25,.5,.5,.75,.75 */
    p.theme_position = 0.0f;              /* red */

    struct frame f; fx_pointmorph_render(&p, 1.0f, &f);
    uint8_t px[RING*3]; frame_pack(&f, px);
    /* blob centers at LED 0, 8, 16, 24 (pos*32); doubled points -> saturated red there */
    CHECK(px[0*3] == 255);
    CHECK(px[8*3] == 255 && px[16*3] == 255 && px[24*3] == 255);
    /* between centers (LED 4) -> dark */
    CHECK(px[4*3] < 40);
}

int main(void) { RUN(test_cube_blobs); return REPORT(); }
