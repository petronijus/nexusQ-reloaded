/* The ring's layer order, and the one rule that keeps both settings usable.
 *
 * The app offers a colour THEME and a music VISUALISATION as separate choices,
 * so both have to be reachable: the theme is the ring's idle mood, the scene is
 * what it does while music plays.
 *
 * Until 2026-09-07 the manual override that carries the theme sat ABOVE the
 * music layer, so once a theme was set the visualiser could never be seen at
 * all. That went unnoticed for one accidental reason: the theme was forgotten
 * on every boot, so the override was usually inactive. Making the theme
 * persistent (nexusq-control r37) removed the accident and the ring went
 * permanently blue — Petr, the same evening: "prstenec ted neni videt nikdy,
 * musis to prehodit, vizualizace musi bejt nad tematem".
 *
 * What makes putting music on top safe is that the music layer YIELDS: with no
 * audio its render returns -1 and the compositor falls through to the next
 * lower active layer, so the theme owns the ring the moment playback stops.
 * These tests pin that whole arrangement — the order AND the fall-through,
 * because the order alone would be a ring stuck on the visualiser.
 */
#include "test.h"
#include "compositor.h"
#include "frame.h"

/* Stand-ins for the real layers: each paints one identifiable colour, and
 * `yield` models "I have nothing to draw" the way the music and reaction
 * layers really do. */
struct stub { int r, g, b, yield; };

static int stub_render(void *c, double t, struct frame *out) {
    (void)t;
    struct stub *s = c;
    if (s->yield) return -1;
    frame_black(out);
    frame_fill(out, s->r, s->g, s->b);
    return 0;
}

static int first_pixel_r(struct frame *f) {
    uint8_t b[RING * 3];
    frame_pack(f, b);
    return b[0];
}

/* The shipped arrangement: screensaver 5, manual/theme 8, music 9, volume 10. */
#define PRI_SCREENSAVER 5
#define PRI_THEME       8
#define PRI_MUSIC       9
#define PRI_VOLUME      10

static void test_music_is_above_the_theme(void) {
    /* THE regression. Both active, both willing to draw: music must win. */
    struct compositor c = {0};
    struct stub theme = {10, 0, 0, 0}, music = {20, 0, 0, 0};
    comp_add(&c, (struct layer){stub_render, &theme, PRI_THEME, 1});
    comp_add(&c, (struct layer){stub_render, &music, PRI_MUSIC, 1});
    struct frame f;
    comp_render(&c, 0.0, &f);
    CHECK(first_pixel_r(&f) == 20);
}

static void test_the_theme_returns_when_music_yields(void) {
    /* And the other half: silence must not leave the ring on a dead scene.
     * Without the yield, putting music on top would simply invert the bug. */
    struct compositor c = {0};
    struct stub theme = {10, 0, 0, 0}, music = {20, 0, 0, 1 /* no audio */};
    comp_add(&c, (struct layer){stub_render, &theme, PRI_THEME, 1});
    comp_add(&c, (struct layer){stub_render, &music, PRI_MUSIC, 1});
    struct frame f;
    comp_render(&c, 0.0, &f);
    CHECK(first_pixel_r(&f) == 10);
}

static void test_volume_overlay_still_beats_both(void) {
    /* The volume overlay is a transient reaction to a button; it has to sit on
     * top of whatever the ring was doing, music included. */
    struct compositor c = {0};
    struct stub theme = {10, 0, 0, 0}, music = {20, 0, 0, 0}, vol = {30, 0, 0, 0};
    comp_add(&c, (struct layer){stub_render, &theme, PRI_THEME, 1});
    comp_add(&c, (struct layer){stub_render, &music, PRI_MUSIC, 1});
    comp_add(&c, (struct layer){stub_render, &vol, PRI_VOLUME, 1});
    struct frame f;
    comp_render(&c, 0.0, &f);
    CHECK(first_pixel_r(&f) == 30);
}

static void test_it_falls_all_the_way_to_the_screensaver(void) {
    /* Nothing playing and no theme set: the idle screensaver, as before. */
    struct compositor c = {0};
    struct stub ss = {5, 0, 0, 0}, theme = {10, 0, 0, 0}, music = {20, 0, 0, 1};
    comp_add(&c, (struct layer){stub_render, &ss, PRI_SCREENSAVER, 1});
    comp_add(&c, (struct layer){stub_render, &theme, PRI_THEME, 0 /* no theme */});
    comp_add(&c, (struct layer){stub_render, &music, PRI_MUSIC, 1});
    struct frame f;
    comp_render(&c, 0.0, &f);
    CHECK(first_pixel_r(&f) == 5);
}

static void test_an_inactive_layer_is_skipped_even_on_top(void) {
    struct compositor c = {0};
    struct stub theme = {10, 0, 0, 0}, music = {20, 0, 0, 0};
    comp_add(&c, (struct layer){stub_render, &theme, PRI_THEME, 1});
    comp_add(&c, (struct layer){stub_render, &music, PRI_MUSIC, 0 /* inactive */});
    struct frame f;
    comp_render(&c, 0.0, &f);
    CHECK(first_pixel_r(&f) == 10);
}

static void test_everything_yielding_is_black_not_garbage(void) {
    struct compositor c = {0};
    struct stub music = {20, 0, 0, 1};
    comp_add(&c, (struct layer){stub_render, &music, PRI_MUSIC, 1});
    struct frame f;
    frame_fill(&f, 99, 99, 99);
    comp_render(&c, 0.0, &f);
    CHECK(first_pixel_r(&f) == 0);
}

int main(void) {
    RUN(test_music_is_above_the_theme);
    RUN(test_the_theme_returns_when_music_yields);
    RUN(test_volume_overlay_still_beats_both);
    RUN(test_it_falls_all_the_way_to_the_screensaver);
    RUN(test_an_inactive_layer_is_skipped_even_on_top);
    RUN(test_everything_yielding_is_black_not_garbage);
    return REPORT();
}
