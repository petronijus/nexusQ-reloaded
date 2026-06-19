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
}
static void test_bad(void) {
    struct ctl_cmd c;
    const char *bad[] = {"", "set 1 2", "set 1 2 999", "theme", "bogus", NULL};
    for (int i = 0; bad[i]; i++) CHECK(ctl_parse(bad[i], &c) == -1);
}
int main(void){ RUN(test_ok); RUN(test_bad); return REPORT(); }
