#include "brightfade.h"
#include <math.h>

#define GAMMA 2.2

static double lightness(double level) { return pow(level / 255.0, 1.0 / GAMMA); }
static double duty(double l) { return 255.0 * pow(l, GAMMA); }

/* The exact level (not rounded) at `now`. */
static double level_at(const struct brightfade *bf, double now) {
    if (bf->dur <= 0.0) return bf->to;
    double x = (now - bf->start) / bf->dur;
    if (x >= 1.0) return bf->to;
    if (x <= 0.0) return bf->from;
    double s = x * x * (3.0 - 2.0 * x);
    double a = lightness(bf->from), b = lightness(bf->to);
    return duty(a + (b - a) * s);
}

void brightfade_init(struct brightfade *bf, int level) {
    bf->from = bf->to = level;
    bf->start = 0.0;
    bf->dur = 0.0;
    bf->set = 0;
}

int brightfade_set(struct brightfade *bf, int level, int ms, double now) {
    if (level < 0) level = 0;
    if (level > 255) level = 255;
    if (ms < 0) ms = 0;
    if (ms > BRIGHTFADE_MAX_MS) ms = BRIGHTFADE_MAX_MS;
    if (bf->set && level == (int)bf->to) return 0;
    double cur = level_at(bf, now);
    bf->from = cur;
    bf->to = level;
    bf->start = now;
    bf->dur = (bf->set && ms > 0) ? ms / 1000.0 : 0.0;
    bf->set = 1;
    return 1;
}

int brightfade_level(const struct brightfade *bf, double now) {
    return (int)lround(level_at(bf, now));
}

int brightfade_active(const struct brightfade *bf, double now) {
    return bf->dur > 0.0 && now - bf->start < bf->dur;
}
