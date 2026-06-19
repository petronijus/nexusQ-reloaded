/* userspace/nexusqd/tests/test_reaction.c */
#include "test.h"
#include "reaction.h"

static int near(double a, double b) { double d = a - b; return (d < 0 ? -d : d) < 1e-9; }

static void test_end_brightness(void) {
    CHECK(near(reaction_end_brightness(0), 0.1));
    CHECK(near(reaction_end_brightness(100), 1.0));
    CHECK(near(reaction_end_brightness(50), 0.55));
    CHECK(near(reaction_end_brightness(150), 1.0));   /* clamps */
}

static void px(const struct reaction *rx, double t, uint8_t *p) {
    struct frame f; reaction_render(rx, t, &f); frame_pack(&f, p);
}

static void test_static_colors(void) {
    struct reaction rx = {0};
    uint8_t p[RING*3];
    /* volume 100 static -> #0099CC */
    reaction_on_volume(&rx, 100, 10.0); rx.animate = 0;
    px(&rx, 10.0, p); CHECK(p[0]==0x00 && p[1]==0x99 && p[2]==0xCC);
    /* volume 0 -> #000F14 (matches mDefaultColor) */
    reaction_on_volume(&rx, 0, 20.0); rx.animate = 0;
    px(&rx, 20.0, p); CHECK(p[0]==0 && p[1]==15 && p[2]==20);
    /* volume 50 -> #005470 (0,84,112) */
    reaction_on_volume(&rx, 50, 30.0); rx.animate = 0;
    px(&rx, 30.0, p); CHECK(p[0]==0 && p[1]==84 && p[2]==112);
    /* volume 25 -> #003142 (0,49,66) */
    reaction_on_volume(&rx, 25, 40.0); rx.animate = 0;
    px(&rx, 40.0, p); CHECK(p[0]==0 && p[1]==49 && p[2]==66);
    /* whole ring uniform (last LED == first) */
    CHECK(p[RING*3-3]==0 && p[RING*3-2]==49 && p[RING*3-1]==66);
}

static void test_mute_led(void) {
    int r,g,b;
    reaction_mute_led(1, &r,&g,&b); CHECK(r==0 && g==30  && b==40);   /* #001E28 */
    reaction_mute_led(0, &r,&g,&b); CHECK(r==0 && g==107 && b==142);  /* #006B8E */
}

static void test_default_color(void) {
    int r,g,b; reaction_default_color(&r,&g,&b);
    CHECK(r==0 && g==15 && b==20);   /* #000F14 */
}

static void test_overlay_timeout(void) {
    struct reaction rx = {0};
    CHECK(reaction_overlay_active(&rx, 5.0) == 0);   /* fresh -> inactive */
    reaction_on_volume(&rx, 50, 100.0);
    CHECK(rx.animate == 1);                            /* first change animates */
    CHECK(reaction_overlay_active(&rx, 100.5) == 1);  /* within 1 s */
    CHECK(reaction_overlay_active(&rx, 101.5) == 0);  /* after 1 s */
    reaction_on_volume(&rx, 60, 100.4);               /* change while active */
    CHECK(rx.animate == 0);                            /* no re-animate */
}

static void test_fade_in(void) {
    struct reaction rx = {0};
    reaction_on_volume(&rx, 100, 0.0);                /* animate, anim_start=0 */
    CHECK(reaction_brightness(&rx, 0.0) < 0.01);      /* starts near black */
    CHECK(reaction_brightness(&rx, RX_ANIM_S + 0.05) > 0.999);  /* settles to endBrightness */
    double b1 = reaction_brightness(&rx, 0.05);
    double b2 = reaction_brightness(&rx, 0.15);
    CHECK(b2 > b1);                                    /* monotonic rise */
    /* decelerate: more progress is made early than late (eased > linear at midpoint) */
    double mid = reaction_brightness(&rx, RX_ANIM_S * 0.5);
    CHECK(mid > 0.5 * reaction_end_brightness(100));
}

int main(void) {
    RUN(test_end_brightness); RUN(test_static_colors); RUN(test_mute_led);
    RUN(test_default_color); RUN(test_overlay_timeout); RUN(test_fade_in);
    return REPORT();
}
