/* userspace/nexusqd/include/jrandom.h
 * Bit-faithful port of java.util.Random — the visualizer effects use it for their
 * per-start choices (nextFloat/nextBoolean/nextInt) and StarField's nextGaussian.
 * The original seeded `new Random()` from the clock, so the choices were never
 * reproducible run-to-run; we reproduce the ALGORITHM/distribution and let the
 * caller seed (deterministic in tests). */
#ifndef NEXUSQD_JRANDOM_H
#define NEXUSQD_JRANDOM_H
#include <stdint.h>

struct jrandom {
    uint64_t seed;
    int      have_next_gaussian;
    double   next_gaussian;
};

void   jrandom_seed(struct jrandom *r, uint64_t seed);
int    jrandom_next(struct jrandom *r, int bits);     /* internal LCG step */
float  jrandom_float(struct jrandom *r);              /* [0,1) */
double jrandom_double(struct jrandom *r);             /* [0,1) */
int    jrandom_int(struct jrandom *r);                /* full 32-bit */
int    jrandom_int_bound(struct jrandom *r, int n);   /* [0,n) */
int    jrandom_boolean(struct jrandom *r);            /* 0/1 */
double jrandom_gaussian(struct jrandom *r);           /* N(0,1), java polar method */
#endif
