/* userspace/nexusqd/tests/test_fx_circles.c */
#include "test.h"
#include "fx_circles.h"

static void test_render(void) {
    struct rtheme t; rtheme_init_rainbow(&t, 0.9f, 1.0f);
    struct jrandom r; jrandom_seed(&r, 1);
    struct fx_circles c; fx_circles_init(&c, &t, &r);
    c.theme_position = 0.0f; c.shift = 0.0f;        /* deterministic: red, no shift */

    struct frame f; fx_circles_render(&c, 1.0f, &f);
    uint8_t p[RING*3]; frame_pack(&f, p);
    /* peak band where (i % 8) == 3 -> LED 3 full red (255,26,26) */
    CHECK(p[3*3] == 255 && p[3*3+1] == 26 && p[3*3+2] == 26);
    CHECK(p[11*3] == 255 && p[19*3] == 255 && p[27*3] == 255);
    /* trough where (i%8)==7 (offset 4) -> dim */
    CHECK(p[7*3] < 40);
}

int main(void) { RUN(test_render); return REPORT(); }
