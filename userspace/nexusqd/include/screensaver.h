/* userspace/nexusqd/include/screensaver.h */
#ifndef NEXUSQD_SCREENSAVER_H
#define NEXUSQD_SCREENSAVER_H
#include "frame.h"

/* Idle LED screensaver (Plan 3) — pixel-perfect port of the factory ICS
 * ParticleScreensaver LED path (docs/2026-06-19-particle-screensaver-RE.md).
 * The 40-particle field is HDMI/GL only; on the ring the screensaver renders a
 * uniform solid mColor=#0099CC that BREATHES:
 *   A      = screensaverAlpha * ledAlpha
 *   ledAlpha = lock ? 0.1 : 0.1 + 0.35*(1 - throb)
 *   throb  = cos(2*PI * fmod(t,10)/10)          (10 s breath, [-1,1])
 *   ring   = round(255 * channel * A), channel = (0, 0.6, 0.8); linear, no gamma
 * lock after 300 s without audio; blank after `blank_timeout` s without activity. */

#define SS_TWO_PI    6.2831855f   /* matches the original float 2*PI constant */
#define SS_FADEIN_S  5.0          /* screensaverAlpha 0->1 ramp (BaseScreensaver) */
#define SS_LOCK_S    300.0        /* ledAlpha locks to 0.1 after this without audio */
#define SS_THROB_S   10.0         /* breath period */
#define SS_BLANK_S   600.0        /* default aah:blank_screensaver_timeout_s */

struct screensaver {
    double last_audio;     /* monotonic s; elapsedSecondsWithoutAudio = now - last_audio */
    double last_activity;  /* monotonic s of last volume/mute activity; <0 = none */
    double blank_timeout;  /* seconds; <0 = never blank */
};

/* start the screensaver at `now` (elapsedSecondsWithoutAudio starts at 5, like glInit) */
void   screensaver_init(struct screensaver *ss, double now);
/* audio activity at `now` — resets the no-audio (lock) timer. (Plan 3b hook.) */
void   screensaver_on_audio(struct screensaver *ss, double now);
/* volume/mute activity at `now` — resets the blank timer */
void   screensaver_on_activity(struct screensaver *ss, double now);
/* screensaverAlpha (fade-in) 0..1 at `now` */
double screensaver_alpha(const struct screensaver *ss, double now);
/* breath value cos(2*PI*fmod(now,10)/10), range [-1,1] */
double screensaver_throb(double now);
/* total ring brightness A = screensaverAlpha*ledAlpha (0 when blanked) */
double screensaver_brightness(const struct screensaver *ss, double now);
/* fill `out` with the uniform breathing ring color at `now` */
void   screensaver_render(const struct screensaver *ss, double now, struct frame *out);
#endif
