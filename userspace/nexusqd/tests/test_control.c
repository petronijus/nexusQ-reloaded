/* userspace/nexusqd/tests/test_control.c */
#include "test.h"
#include "control.h"
#include <string.h>
static void test_ok(void) {
    struct ctl_cmd c;
    CHECK(ctl_parse("theme spectrum", &c) == 0 && c.kind == CTL_THEME && !strcmp(c.name,"spectrum"));
    CHECK(ctl_parse("set 255 0 128", &c) == 0 && c.kind == CTL_SET && c.rgb[0]==255 && c.rgb[2]==128);
    CHECK(ctl_parse("mute 0 64 0", &c) == 0 && c.kind == CTL_MUTE && c.rgb[1]==64);
    CHECK(ctl_parse("off", &c) == 0 && c.kind == CTL_OFF);
    CHECK(ctl_parse("status", &c) == 0 && c.kind == CTL_STATUS);
    CHECK(ctl_parse("mtoggle", &c) == 0 && c.kind == CTL_MTOGGLE);
    CHECK(ctl_parse("auto", &c) == 0 && c.kind == CTL_AUTO);
    CHECK(ctl_parse("vol 0", &c) == 0 && c.kind == CTL_VOL && c.value == 0);
    CHECK(ctl_parse("vol 100", &c) == 0 && c.kind == CTL_VOL && c.value == 100);
    CHECK(ctl_parse("vol 55", &c) == 0 && c.kind == CTL_VOL && c.value == 55);
    CHECK(ctl_parse("scene 0", &c) == 0 && c.kind == CTL_SCENE && c.value == 0);
    CHECK(ctl_parse("scene 4", &c) == 0 && c.kind == CTL_SCENE && c.value == 4);
    CHECK(ctl_parse("brightness 0", &c) == 0 && c.kind == CTL_BRIGHTNESS && c.value == 0);
    CHECK(ctl_parse("brightness 255", &c) == 0 && c.kind == CTL_BRIGHTNESS && c.value == 255);
    CHECK(ctl_parse("brightness 128", &c) == 0 && c.kind == CTL_BRIGHTNESS && c.value == 128);
    /* spin R G B: default speed 0 (daemon default rate) */
    CHECK(ctl_parse("spin 0 153 204", &c) == 0 && c.kind == CTL_SPIN
          && c.rgb[1]==153 && c.speed == 0.0);
    /* spin R G B [rev_per_s]: explicit speed parsed as a float */
    CHECK(ctl_parse("spin 0 200 0 1.5", &c) == 0 && c.kind == CTL_SPIN
          && c.rgb[1]==200 && c.speed == 1.5);
    CHECK(ctl_parse("spin 204 0 0 0.4", &c) == 0 && c.kind == CTL_SPIN
          && c.rgb[0]==204 && c.speed == 0.4);
}
static void test_bad(void) {
    struct ctl_cmd c;
    const char *bad[] = {"", "set 1 2", "set 1 2 999", "theme", "bogus",
                         "vol", "vol 101", "vol -1", "vol x", "vol 5 5", "mtoggle x",
                         "scene", "scene 5", "scene -1", "scene x",
                         "spin 0 153", "spin 0 153 204 x", "spin 0 153 204 0",
                         "spin 0 153 204 -1", "spin 0 153 204 99", NULL};
    for (int i = 0; bad[i]; i++) CHECK(ctl_parse(bad[i], &c) == -1);
}
int main(void){ RUN(test_ok); RUN(test_bad); return REPORT(); }
