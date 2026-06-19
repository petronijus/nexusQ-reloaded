/* userspace/nexusqd/tests/test_keys.c */
#include "test.h"
#include "keys.h"
#include <string.h>
/* Build one input_event record at buf using the host's native struct layout
 * (long sec; long usec; u16 type; u16 code; s32 value) — self-consistent with
 * keys_decode's INPUT_EVENT_SIZE on both 64-bit host and 32-bit ARM target. */
static void put(uint8_t *b, int type, int code, int value) {
    long s = 1, u = 2; memcpy(b, &s, sizeof(long)); memcpy(b+sizeof(long), &u, sizeof(long));
    uint16_t t = type, c = code; int32_t v = value;
    memcpy(b+2*sizeof(long), &t, 2); memcpy(b+2*sizeof(long)+2, &c, 2);
    memcpy(b+2*sizeof(long)+4, &v, 4);
}
static void test_decode(void) {
    uint8_t buf[INPUT_EVENT_SIZE*3];
    put(buf,                    EV_KEY, KEY_MUTE, 1);
    put(buf+INPUT_EVENT_SIZE,   EV_KEY, KEY_MUTE, 0);
    put(buf+2*INPUT_EVENT_SIZE, EV_KEY, KEY_VOLUMEUP, 2);   /* autorepeat -> ignored */
    struct keyev ev[8];
    int n = keys_decode(buf, sizeof(buf), ev, 8);
    CHECK(n == 2);
    CHECK(ev[0].code == KEY_MUTE && ev[0].down == 1);
    CHECK(ev[1].code == KEY_MUTE && ev[1].down == 0);
}
int main(void){ RUN(test_decode); return REPORT(); }
