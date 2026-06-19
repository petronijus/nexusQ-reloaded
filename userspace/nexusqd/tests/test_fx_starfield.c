/* userspace/nexusqd/tests/test_fx_starfield.c */
#include "test.h"
#include "fx_starfield.h"

static void test_blobs_at_theta0(void) {
    struct rtheme t; rtheme_init_rainbow(&t, 0.9f, 1.0f);
    struct jrandom r; jrandom_seed(&r, 1);
    struct fx_starfield s; fx_starfield_init(&s, &t, &r);
    s.rainbow = 0; s.theme_position = 0.0f;
    for (int i = 0; i < SF_PARTICLES; i++) s.particles[i].theta = 0.0f;

    struct frame f; fx_starfield_render(&s, 1.0f, &f);
    uint8_t p[RING*3]; frame_pack(&f, p);
    /* 7 sampled particles all at theta 0 -> additive blob saturates LED 0 red channel
     * (theme value*0.6: HSV(0,0.9,0.6) -> (153,15,15), summed+clamped -> r=255) */
    CHECK(p[0] == 255);
    CHECK(p[0] > p[1] && p[1] == p[2]);   /* reddish */
    /* opposite side (LED 16) untouched */
    CHECK(p[16*3] == 0 && p[16*3+1] == 0 && p[16*3+2] == 0);
}

int main(void) { RUN(test_blobs_at_theta0); return REPORT(); }
