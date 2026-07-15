/* userspace/nexusqd/include/spinner.h */
#ifndef NEXUSQD_SPINNER_H
#define NEXUSQD_SPINNER_H
#include "frame.h"
/* Setup-mode "rotating dot": a single head LED in the given color with an
 * 8-LED exponential tail, revolving at rev_per_s. Pure function of t
 * (monotonic seconds) so it is host-testable and stateless. rev_per_s <= 0
 * falls back to the default so old callers / bad input keep spinning. */
#define SPIN_REV_PER_S 0.75
#define SPIN_TAIL 8
void spinner_render(const int rgb[3], double t, double rev_per_s, struct frame *out);
#endif
