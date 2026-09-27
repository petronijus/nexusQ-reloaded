#ifndef BRIGHTFADE_H
#define BRIGHTFADE_H
/* The global ring brightness, with an optional timed transition between levels
 * (`brightness N [ms]` on the control socket).
 *
 * The fade runs in PERCEIVED lightness, not in PWM duty: the LEDs' light output
 * is linear in the duty, the eye is not, and a linear 200 -> 50 duty ramp looks
 * like a slow start followed by a drop at the end. Lightness is duty^(1/2.2),
 * eased with a smoothstep so the transition has no visible start or stop.
 *
 * The first level after the daemon starts is applied at once, whatever fade it
 * asks for: the daemon starts at full brightness, and fading down from that on
 * every boot or restart would be a flash, not a transition. */

#define BRIGHTFADE_MAX_MS 60000

struct brightfade {
    double from, to;    /* levels 0..255 */
    double start;       /* monotonic seconds */
    double dur;         /* seconds; 0 = no fade in progress */
    int set;            /* a level has been received since start */
};

void brightfade_init(struct brightfade *bf, int level);
/* Aim at `level`, reaching it `ms` after `now` (0 = at once). A new target in
 * the middle of a fade starts from where the ring is at `now`, so a reversal
 * never jumps. Returns 0 when the target is unchanged (a no-op), 1 otherwise. */
int brightfade_set(struct brightfade *bf, int level, int ms, double now);
/* The level to render at `now`, 0..255. */
int brightfade_level(const struct brightfade *bf, double now);
/* Is a transition still in progress at `now`? (The ring must animate.) */
int brightfade_active(const struct brightfade *bf, double now);
#endif
