#include "test.h"
#include "frame.h"

static void test_pack_len_and_order(void) {
    struct frame f; frame_black(&f); frame_fill(&f, 1, 2, 3);
    uint8_t b[RING*3]; frame_pack(&f, b);
    CHECK(b[0] == 1 && b[1] == 2 && b[2] == 3);
    CHECK(b[RING*3-1] == 3);
}
static void test_set_and_clamp(void) {
    struct frame f; frame_black(&f); frame_set(&f, 5, 999, -5, 256);
    uint8_t b[RING*3]; frame_pack(&f, b);
    CHECK(b[15] == 255 && b[16] == 0 && b[17] == 255);
    CHECK(b[0] == 0);
}
static void test_set_range_bounds(void) {
    struct frame f; frame_black(&f);
    uint8_t rgb[5][3] = {{1,1,1},{1,1,1},{1,1,1},{1,1,1},{1,1,1}};
    CHECK(frame_set_range(&f, 30, 5, rgb) == -1);   /* 30+5 > 32 */
    CHECK(frame_set_range(&f, 0, 2, rgb) == 0);
}
static void test_blend_half(void) {
    struct frame a, b; frame_black(&a); frame_black(&b); frame_fill(&b, 100, 200, 0);
    frame_blend(&a, &b, 0.5);
    uint8_t o[RING*3]; frame_pack(&a, o);
    CHECK(o[0] == 50 && o[1] == 100 && o[2] == 0);
}
int main(void) {
    RUN(test_pack_len_and_order); RUN(test_set_and_clamp);
    RUN(test_set_range_bounds); RUN(test_blend_half);
    return REPORT();
}
