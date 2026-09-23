/* userspace/nq-healthd/tests/test_cstate.c
 *
 * cstate_sample() and qos_limit_us() are how the field fleet shows whether the
 * deep C-states actually run: whether they are armed, what they cost in
 * residency, and whether a CPU-latency QoS request is vetoing them (a 170 us
 * request from the Bluetooth UART did exactly that, unnoticed, for weeks --
 * docs/2026-09-20-sleep-states-design.md 4m).
 *
 * The source is #included so these statics are reachable, with main() renamed
 * out of the way and the sysfs root and QoS device pointed at fixtures. */
#define main healthd_main_unused
#define CPUIDLE_ROOT TEST_CPUROOT
#define QOS_DEV      TEST_QOS
#include "nq-healthd.c"
#undef main

#include <stdio.h>
#include <sys/stat.h>

static int fails;
#define CHECK(cond) do { if (!(cond)) { fails++; \
    printf("  FAIL %s:%d: %s\n", __FILE__, __LINE__, #cond); } } while (0)

static void rmrf(const char *p) { char c[512]; snprintf(c, sizeof c, "rm -rf '%s'", p); if (system(c)) {} }
static void mkp(const char *p) { char c[512]; snprintf(c, sizeof c, "mkdir -p '%s'", p); if (system(c)) {} }
static void put(const char *p, const char *v) { FILE *f = fopen(p, "w"); if (f) { fputs(v, f); fclose(f); } }

/* One state of one CPU: name, cumulative usage and time (us), disable flag. */
static void state(int cpu, int st, const char *name, long long usage, long long time_us, int disable)
{
    char d[256], p[300], v[64];
    snprintf(d, sizeof d, TEST_CPUROOT "/cpu%d/cpuidle/state%d", cpu, st);
    mkp(d);
    snprintf(p, sizeof p, "%s/name", d);    snprintf(v, sizeof v, "%s\n", name); put(p, v);
    snprintf(p, sizeof p, "%s/usage", d);   snprintf(v, sizeof v, "%lld\n", usage); put(p, v);
    snprintf(p, sizeof p, "%s/time", d);    snprintf(v, sizeof v, "%lld\n", time_us); put(p, v);
    snprintf(p, sizeof p, "%s/disable", d); snprintf(v, sizeof v, "%d\n", disable); put(p, v);
}

/* Steelhead's three states on both CPUs, with the same counters on each. */
static void box(long long c1u, long long c1t, long long c2u, long long c2t,
                long long c3u, long long c3t, int c2dis, int c3dis)
{
    for (int c = 0; c < 2; c++) {
        state(c, 0, "C1", c1u, c1t, 0);
        state(c, 1, "C2", c2u, c2t, c2dis);
        state(c, 2, "C3", c3u, c3t, c3dis);
    }
}

static char ms[300], nn[300], armed[64];
static void sample(void) { cstate_sample(ms, sizeof ms, nn, sizeof nn, armed, sizeof armed); }

static void reset_state(void) { prev_cst_n = 0; rmrf(TEST_CPUROOT); }

/* The first sample has nothing to difference against: an honest gap. */
static void test_first_sample_is_a_gap(void) {
    reset_state();
    box(100, 1000000, 0, 0, 0, 0, 1, 1);
    sample();
    CHECK(!strcmp(ms, "{}"));
    CHECK(!strcmp(nn, "{}"));
}

/* Residency is the DIFFERENCE, summed over both CPUs, in ms per state name. */
static void test_window_is_differenced_and_summed(void) {
    reset_state();
    box(100, 1000000, 10, 500000, 0, 0, 0, 1);
    sample();
    box(150, 1400000, 30, 2500000, 0, 0, 0, 1);   /* +50/+400 ms C1, +20/+2000 ms C2 per CPU */
    sample();
    CHECK(!strcmp(ms, "{\"C1\":800,\"C2\":4000,\"C3\":0}"));
    CHECK(!strcmp(nn, "{\"C1\":100,\"C2\":40,\"C3\":0}"));
}

/* Only deep states count as armed, and only when their disable is 0. */
static void test_armed_lists_enabled_deep_states(void) {
    reset_state();
    box(1, 1, 1, 1, 1, 1, 1, 1);
    sample();
    CHECK(!strcmp(armed, ""));
    box(1, 1, 1, 1, 1, 1, 0, 1);
    sample();
    CHECK(!strcmp(armed, "C2"));
    box(1, 1, 1, 1, 1, 1, 0, 0);
    sample();
    CHECK(!strcmp(armed, "C2,C3"));
}

/* A counter going backwards (e.g. CPU re-registered) must not produce a huge
 * or negative window; it resets the baseline instead. */
static void test_counter_reset_is_a_gap(void) {
    reset_state();
    box(500, 5000000, 50, 900000, 0, 0, 0, 1);
    sample();
    box(10, 100000, 1, 1000, 0, 0, 0, 1);
    sample();
    CHECK(!strcmp(ms, "{}"));
    box(20, 300000, 2, 3000, 0, 0, 0, 1);
    sample();
    CHECK(!strcmp(ms, "{\"C1\":400,\"C2\":4,\"C3\":0}"));
}

/* An offline CPU has no cpuidle directory; the online one still reports. */
static void test_offline_cpu_is_skipped(void) {
    reset_state();
    state(0, 0, "C1", 10, 100000, 0);
    state(0, 1, "C2", 1, 1000, 0);
    sample();
    state(0, 0, "C1", 20, 300000, 0);
    state(0, 1, "C2", 3, 5000, 0);
    sample();
    CHECK(!strcmp(ms, "{\"C1\":200,\"C2\":4}"));
    CHECK(!strcmp(nn, "{\"C1\":10,\"C2\":2}"));
}

/* The QoS device returns the current limit as a native s32. */
static void test_qos_is_read_as_s32(void) {
    FILE *f = fopen(TEST_QOS, "wb");
    int v = 170;
    if (f) { fwrite(&v, sizeof v, 1, f); fclose(f); }
    CHECK(qos_limit_us() == 170);
    unlink(TEST_QOS);
    CHECK(qos_limit_us() == -1);
}

int main(void)
{
    test_first_sample_is_a_gap();
    test_window_is_differenced_and_summed();
    test_armed_lists_enabled_deep_states();
    test_counter_reset_is_a_gap();
    test_offline_cpu_is_skipped();
    test_qos_is_read_as_s32();
    rmrf(TEST_CPUROOT);
    printf("test_cstate: %s (%d failure%s)\n", fails ? "FAILED" : "ok", fails, fails == 1 ? "" : "s");
    return fails ? 1 : 0;
}
