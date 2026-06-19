/* userspace/nexusqd/tests/test_jrandom.c — verify the java.util.Random port */
#include "test.h"
#include "jrandom.h"

static void test_known_java_values(void) {
    struct jrandom r;
    /* new Random(0).nextInt() == -1155484576 (canonical) */
    jrandom_seed(&r, 0);
    CHECK(jrandom_int(&r) == -1155484576);
    /* new Random(0).nextInt() second value == -723955400 */
    CHECK(jrandom_int(&r) == -723955400);
    /* new Random(0).nextFloat() == 0.7309677f */
    jrandom_seed(&r, 0);
    float f = jrandom_float(&r);
    CHECK(f > 0.730967f && f < 0.730968f);
    /* new Random(0).nextBoolean() == true */
    jrandom_seed(&r, 0);
    CHECK(jrandom_boolean(&r) == 1);
    /* nextInt(bound) in range */
    jrandom_seed(&r, 42);
    for (int i = 0; i < 100; i++) { int v = jrandom_int_bound(&r, 8); CHECK(v >= 0 && v < 8); }
}

int main(void) { RUN(test_known_java_values); return REPORT(); }
