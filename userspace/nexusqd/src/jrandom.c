/* userspace/nexusqd/src/jrandom.c — see jrandom.h */
#include "jrandom.h"
#include <math.h>

#define MASK48 ((1ULL << 48) - 1)
#define MULT   0x5DEECE66DULL
#define ADD    0xBULL

void jrandom_seed(struct jrandom *r, uint64_t seed) {
    r->seed = (seed ^ MULT) & MASK48;
    r->have_next_gaussian = 0;
    r->next_gaussian = 0.0;
}

int jrandom_next(struct jrandom *r, int bits) {
    r->seed = (r->seed * MULT + ADD) & MASK48;
    return (int)((int32_t)(r->seed >> (48 - bits)));
}

float jrandom_float(struct jrandom *r) {
    return jrandom_next(r, 24) / (float)(1 << 24);
}

double jrandom_double(struct jrandom *r) {
    int64_t hi = (int64_t)jrandom_next(r, 26);
    int64_t lo = (int64_t)jrandom_next(r, 27);
    return ((hi << 27) + lo) * (1.0 / (double)(1LL << 53));
}

int jrandom_int(struct jrandom *r) { return jrandom_next(r, 32); }

int jrandom_int_bound(struct jrandom *r, int n) {
    if ((n & -n) == n)   /* power of two */
        return (int)(((int64_t)n * (int64_t)jrandom_next(r, 31)) >> 31);
    int bits, val;
    do {
        bits = jrandom_next(r, 31);
        val = bits % n;
    } while (bits - val + (n - 1) < 0);
    return val;
}

int jrandom_boolean(struct jrandom *r) { return jrandom_next(r, 1) != 0; }

double jrandom_gaussian(struct jrandom *r) {
    if (r->have_next_gaussian) {
        r->have_next_gaussian = 0;
        return r->next_gaussian;
    }
    double v1, v2, s;
    do {
        v1 = 2.0 * jrandom_double(r) - 1.0;
        v2 = 2.0 * jrandom_double(r) - 1.0;
        s = v1 * v1 + v2 * v2;
    } while (s >= 1.0 || s == 0.0);
    double multiplier = sqrt(-2.0 * log(s) / s);
    r->next_gaussian = v2 * multiplier;
    r->have_next_gaussian = 1;
    return v1 * multiplier;
}
