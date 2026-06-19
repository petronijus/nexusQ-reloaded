/* userspace/nexusqd/tests/test_themecolor.c — SkHSVToColor + RainbowTheme */
#include "test.h"
#include "themecolor.h"

static int byte_of(float f) { return (int)(f * 255.0f + 0.5f); }

static void test_hsv_red(void) {
    /* HSV(0, 0.9, 1.0) -> v=255, p=t=round(0.1*255)=26 -> (255,26,26) */
    float hsv[3] = { 0.0f, 0.9f, 1.0f }, rgb[3];
    hsv_to_rgb(hsv, rgb);
    CHECK(byte_of(rgb[0]) == 255 && byte_of(rgb[1]) == 26 && byte_of(rgb[2]) == 26);
}

static void test_hsv_green(void) {
    /* HSV(120, 0.9, 1.0) -> (26,255,26) */
    float hsv[3] = { 120.0f, 0.9f, 1.0f }, rgb[3];
    hsv_to_rgb(hsv, rgb);
    CHECK(byte_of(rgb[0]) == 26 && byte_of(rgb[1]) == 255 && byte_of(rgb[2]) == 26);
}

static void test_hsv_gray(void) {
    /* s=0 -> gray = round(v*255) */
    float hsv[3] = { 200.0f, 0.0f, 0.5f }, rgb[3];
    hsv_to_rgb(hsv, rgb);
    int v = byte_of(rgb[0]);
    CHECK(v == 128 && byte_of(rgb[1]) == 128 && byte_of(rgb[2]) == 128);
}

static void test_rainbow_theme(void) {
    struct rtheme t; rtheme_init_rainbow(&t, 0.9f, 1.0f);
    float hsv[3];
    rtheme_hsv(&t, 0.0f, hsv);
    CHECK(hsv[0] == 0.0f && hsv[1] == 0.9f && hsv[2] == 1.0f);
    rtheme_hsv(&t, 0.5f, hsv);
    CHECK(hsv[0] == 180.0f);   /* 360*0.5 */
}

int main(void) {
    RUN(test_hsv_red); RUN(test_hsv_green); RUN(test_hsv_gray); RUN(test_rainbow_theme);
    return REPORT();
}
