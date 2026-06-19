/* userspace/nexusqd/tests/test_themes.c */
#include "test.h"
#include "themes.h"
static const char *SPEC =
  "{\"engine\":{},\"options\":{\"display\":1,\"led\":1,"
  "\"colors\":[\"#AA66CC\",\"#FF4444\",\"#0099cc\"]},\"metaOption\":{\"mode\":1}}";
static const char *OFF =
  "{\"options\":{\"display\":0,\"led\":0,\"colors\":[\"#000000\"]},\"metaOption\":{\"mode\":1}}";
static void test_parse(void) {
    struct theme t;
    CHECK(theme_parse(&t, "spectrum", SPEC) == 0);
    CHECK(t.n_colors == 3);
    CHECK(t.colors[0][0]==0xAA && t.colors[0][1]==0x66 && t.colors[0][2]==0xCC);
    CHECK(t.colors[2][2]==0xcc);
    CHECK(t.led == 1 && t.mode == 1);
}
static void test_off(void) {
    struct theme t;
    CHECK(theme_parse(&t, "off", OFF) == 0);
    CHECK(t.led == 0 && t.n_colors == 1 && t.colors[0][0]==0);
}
int main(void){ RUN(test_parse); RUN(test_off); return REPORT(); }
