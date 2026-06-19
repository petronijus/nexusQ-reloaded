/* userspace/nexusqd/include/reaction.h */
#ifndef NEXUSQD_REACTION_H
#define NEXUSQD_REACTION_H
#include "frame.h"

/* Volume/mute reaction layer (Plan 2b) — pixel-perfect reproduction of the
 * factory ICS TungstenLEDService SystemStatusReceiver behavior documented in
 * docs/2026-06-19-volume-mute-RE.md.
 *
 * Volume is encoded as the UNIFORM brightness of the whole ring in the single
 * color mColor=#0099CC (no arc, no LED count). The dedicated mute LED is driven
 * separately (the kernel `mute` sysfs attr), not through the ring frame. */

#define RX_COLOR_R 0x00            /* mColor = #0099CC */
#define RX_COLOR_G 0x99
#define RX_COLOR_B 0xCC
#define RX_ANIM_S      0.336       /* 21 frames x 16 ms decelerate change-in fade */
#define RX_TIMEOUT_S   1.0         /* overlay relinquishes 1000 ms after last change */

struct reaction {
    int    volume;       /* 0..100 master-volume percentage */
    int    animate;      /* 1 = the first-change fade-in is in progress */
    double anim_start;   /* monotonic seconds when the fade-in began */
    double last_event;   /* monotonic seconds of the last volume change */
};

/* endBrightness = 0.1 + (volume/100)*0.9  (FloatEvaluator linear lerp) */
double reaction_end_brightness(int volume);
/* instantaneous ring brightness 0..1 at `now` (handles the decelerate fade-in) */
double reaction_brightness(const struct reaction *rx, double now);
/* fill `out` with the uniform volume-ring color at `now` */
void reaction_render(const struct reaction *rx, double now, struct frame *out);
/* register a volume change to `volume` at `now` (clamps 0..100); the fade-in
 * only plays when coming from an idle ring (subsequent changes jump to static) */
void reaction_on_volume(struct reaction *rx, int volume, double now);
/* 1 if the volume overlay should own the ring at `now`, else 0 */
int reaction_overlay_active(const struct reaction *rx, double now);
/* dedicated mute LED color: muted = mColor*0.2 (#001E28), unmuted = *0.7 (#006B8E) */
void reaction_mute_led(int muted, int *r, int *g, int *b);
/* idle/default ring color mDefaultColor = mColor*0.1 = #000F14 */
void reaction_default_color(int *r, int *g, int *b);
#endif
