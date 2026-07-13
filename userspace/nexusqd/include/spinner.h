/* userspace/nexusqd/include/spinner.h */
#ifndef NEXUSQD_SPINNER_H
#define NEXUSQD_SPINNER_H
#include "frame.h"
/* Setup-mode "rotating dot": a single head LED in the given color with an
 * 8-LED exponential tail, revolving at SPIN_REV_PER_S. Pure function of t
 * (monotonic seconds) so it is host-testable and stateless. */
#define SPIN_REV_PER_S 0.75
#define SPIN_TAIL 8
void spinner_render(const int rgb[3], double t, struct frame *out);
#endif
