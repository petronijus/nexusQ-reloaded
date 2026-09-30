/* userspace/nexusqd/tests/test_keys.c */
#include "test.h"
#include "keys.h"
#include <string.h>
#include <unistd.h>
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

/* a stand-in for keys_open_node: counts calls, "finds" the node once present */
struct fake { int calls, present; };
static int fake_open(void *ctx) {
    struct fake *f = ctx; f->calls++;
    return f->present ? dup(0) : -1;   /* a real fd, so keywatch_lost can close it */
}
static void test_keywatch_absent_backs_off(void) {
    struct keywatch kw; keywatch_init(&kw);
    struct fake f = { 0, 0 };
    CHECK(keywatch_tick(&kw, 0.0, fake_open, &f) == 0 && f.calls == 1);
    CHECK(keywatch_tick(&kw, 0.4, fake_open, &f) == 0 && f.calls == 1);   /* not due */
    CHECK(keywatch_tick(&kw, 0.5, fake_open, &f) == 0 && f.calls == 2);   /* 0.5 s */
    CHECK(keywatch_tick(&kw, 1.4, fake_open, &f) == 0 && f.calls == 2);
    CHECK(keywatch_tick(&kw, 1.5, fake_open, &f) == 0 && f.calls == 3);   /* then 1 s */
    double t = 1.5;
    for (int i = 0; i < 20; i++) { t += 100; keywatch_tick(&kw, t, fake_open, &f); }
    CHECK(kw.backoff == KEYS_RETRY_MAX_S);                                /* capped */
    CHECK(kw.retry_at == t + KEYS_RETRY_MAX_S);
}
static void test_keywatch_late_driver(void) {
    /* the AVR probes after nexusqd started: the keys must still be found */
    struct keywatch kw; keywatch_init(&kw);
    struct fake f = { 0, 0 };
    CHECK(keywatch_tick(&kw, 0.0, fake_open, &f) == 0 && kw.fd < 0);
    f.present = 1;
    CHECK(keywatch_tick(&kw, 0.5, fake_open, &f) == 1 && kw.fd >= 0);    /* reported once */
    int calls = f.calls;
    CHECK(keywatch_tick(&kw, 99.0, fake_open, &f) == 0 && f.calls == calls);   /* held, no rescan */
    keywatch_lost(&kw, 100.0);
}
static void test_keywatch_lost_node_comes_back(void) {
    struct keywatch kw; keywatch_init(&kw);
    struct fake f = { 0, 0 };
    for (double t = 0; t < 60; t += 0.25) keywatch_tick(&kw, t, fake_open, &f);   /* long absence */
    f.present = 1;
    keywatch_tick(&kw, 1000.0, fake_open, &f);
    CHECK(kw.fd >= 0);
    keywatch_lost(&kw, 2000.0);                                           /* driver reloaded */
    CHECK(kw.fd < 0);
    CHECK(keywatch_tick(&kw, 2000.1, fake_open, &f) == 0);                /* old node going away */
    f.present = 0;                                                        /* driver still probing */
    CHECK(keywatch_tick(&kw, 2000.5, fake_open, &f) == 0);
    f.present = 1;
    CHECK(keywatch_tick(&kw, 2001.0, fake_open, &f) == 1 && kw.fd >= 0);  /* 0.5 s on, not 8 s */
    keywatch_lost(&kw, 2002.0);
}
int main(void){
    RUN(test_decode); RUN(test_keywatch_absent_backs_off); RUN(test_keywatch_late_driver);
    RUN(test_keywatch_lost_node_comes_back);
    return REPORT();
}
