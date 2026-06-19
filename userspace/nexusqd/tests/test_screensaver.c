/* userspace/nexusqd/tests/test_screensaver.c */
#include "test.h"
#include "screensaver.h"

static int near(double a, double b) { double d = a - b; return (d < 0 ? -d : d) < 1e-6; }

static void px(const struct screensaver *ss, double now, uint8_t *p) {
    struct frame f; screensaver_render(ss, now, &f); frame_pack(&f, p);
}

static void test_fade_in(void) {
    struct screensaver ss; screensaver_init(&ss, 0.0);   /* last_audio = -5 */
    CHECK(near(screensaver_alpha(&ss, 0.0), 0.0));        /* elapsed 5 -> sa 0 */
    CHECK(near(screensaver_alpha(&ss, 2.5), 0.5));        /* elapsed 7.5 -> 0.5 */
    CHECK(near(screensaver_alpha(&ss, 5.0), 1.0));        /* elapsed 10 -> 1 */
    CHECK(near(screensaver_alpha(&ss, 100.0), 1.0));      /* clamped */
}

static void test_throb(void) {
    CHECK(near(screensaver_throb(0.0), 1.0));             /* cos(0) */
    CHECK(near(screensaver_throb(5.0), -1.0));            /* cos(pi) */
    CHECK(near(screensaver_throb(10.0), 1.0));            /* period 10 s */
    CHECK(near(screensaver_throb(2.5), 0.0));             /* cos(pi/2) */
}

/* helper: a settled (faded-in) screensaver with audio `elapsed` seconds ago */
static struct screensaver settled(double now, double elapsed) {
    struct screensaver ss;
    ss.last_audio = now - elapsed;
    ss.last_activity = -1.0;
    ss.blank_timeout = SS_BLANK_S;
    return ss;
}

static void test_breath_colors(void) {
    uint8_t p[RING*3];
    /* dim point: throb=1 (now=10), settled (elapsed 10) -> A=0.1 -> #000F14 */
    struct screensaver d = settled(10.0, 10.0);
    px(&d, 10.0, p);
    CHECK(p[0]==0 && p[1]==15 && p[2]==20);              /* round(153*.1)=15, round(204*.1)=20 */
    /* peak: throb=-1 (now=5), settled -> ledAlpha=0.8 -> (0,122,163) */
    struct screensaver k = settled(5.0, 10.0);
    px(&k, 5.0, p);
    CHECK(p[0]==0 && p[1]==122 && p[2]==163);            /* round(153*.8), round(204*.8) */
    /* uniform ring */
    CHECK(p[RING*3-3]==0 && p[RING*3-2]==122 && p[RING*3-1]==163);
}

static void test_lock(void) {
    /* elapsed > 300 -> ledAlpha locks to 0.1 regardless of throb (now=5 => throb -1) */
    struct screensaver ss = settled(5.0, 400.0);
    CHECK(near(screensaver_brightness(&ss, 5.0), 0.1));  /* sa=1, locked 0.1 */
}

static void test_blank(void) {
    /* no activity, elapsed 700 -> blank -> A=0 */
    struct screensaver ss = settled(10.0, 700.0);
    CHECK(near(screensaver_brightness(&ss, 10.0), 0.0));
    uint8_t p[RING*3]; px(&ss, 10.0, p);
    CHECK(p[0]==0 && p[1]==0 && p[2]==0);
    /* recent activity resets blank (but still locked dim): elapsed 700, activity 10 s ago */
    ss.last_activity = 10.0 - 10.0;                      /* now=10, activity at 0 -> since=10 */
    CHECK(near(screensaver_brightness(&ss, 10.0), 0.1)); /* not blank, locked 0.1, sa=1 */
}

int main(void) {
    RUN(test_fade_in); RUN(test_throb); RUN(test_breath_colors);
    RUN(test_lock); RUN(test_blank);
    return REPORT();
}
