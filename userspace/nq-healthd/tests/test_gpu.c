/* userspace/nq-healthd/tests/test_gpu.c
 *
 * gpu_sample(): the fields that tell whether the SGX540 sleeps as it should
 * (device r129). The GPU's target module is runtime-suspended whenever nothing
 * renders; a regression that keeps it awake (the openpvrsgx probe reference,
 * APM broken, a client holding a context) shows only as gpu_active_ms growing
 * by the whole interval, and only nq-health-report turns that into a finding.
 *
 * The source is #included with main() renamed and the three sysfs roots
 * pointed at a fixture tree shaped like the unit's. */
#define main healthd_main_unused
#include "nq-healthd.c"
#undef main

#include <stdio.h>
#include <sys/stat.h>

static int fails;
#define CHECK(cond) do { if (!(cond)) { fails++; \
    printf("  FAIL %s:%d: %s\n", __FILE__, __LINE__, #cond); } } while (0)

static void put(const char *path, const char *v)
{
    FILE *f = fopen(path, "w");
    if (f) { fputs(v, f); fclose(f); }
}
static void rmrf(const char *p) { char c[512]; snprintf(c, sizeof c, "rm -rf '%s'", p); if (system(c)) {} }

static void fixture(void)
{
    rmrf(TEST_GPUROOT);
    mkdir(TEST_GPUROOT, 0755);
    mkdir(GPU_PM, 0755);
    mkdir(HDMI_CONN, 0755);
}

/* Idle with the driver loaded: suspended, the active counter does not move. */
static void test_suspended_gpu_reports_zero_active(void)
{
    fixture();
    mkdir(GPU_MOD, 0755);
    put(GPU_PM "/runtime_status", "suspended\n");
    put(GPU_PM "/runtime_active_time", "813449\n");
    put(HDMI_CONN "/enabled", "enabled\n");
    put(HDMI_CONN "/dpms", "On\n");

    long long prev = -1;
    struct gpu_reading g;
    gpu_sample(&g, &prev);
    CHECK(g.drv == 1);
    CHECK(strcmp(g.rpm, "suspended") == 0);
    CHECK(g.active_ms == -1);           /* first sample: no interval yet */
    CHECK(g.hdmi_on == 1);
    gpu_sample(&g, &prev);
    CHECK(g.active_ms == 0);
}

/* Rendering: the counter grows by what the GPU was awake in the interval. */
static void test_active_ms_is_the_interval_delta(void)
{
    fixture();
    mkdir(GPU_MOD, 0755);
    put(GPU_PM "/runtime_status", "active\n");
    put(GPU_PM "/runtime_active_time", "1000\n");
    long long prev = -1;
    struct gpu_reading g;
    gpu_sample(&g, &prev);
    put(GPU_PM "/runtime_active_time", "5980\n");
    gpu_sample(&g, &prev);
    CHECK(strcmp(g.rpm, "active") == 0);
    CHECK(g.active_ms == 4980);
    /* A re-probed module restarts its counter: no negative interval. */
    put(GPU_PM "/runtime_active_time", "10\n");
    gpu_sample(&g, &prev);
    CHECK(g.active_ms == 0);
}

/* A kernel without the GPU node and a unit with HDMI off or blanked. */
static void test_absent_gpu_and_hdmi_off(void)
{
    rmrf(TEST_GPUROOT);
    mkdir(TEST_GPUROOT, 0755);
    long long prev = -1;
    struct gpu_reading g;
    gpu_sample(&g, &prev);
    CHECK(g.drv == 0);
    CHECK(strcmp(g.rpm, "none") == 0);
    CHECK(g.active_ms == -1);
    CHECK(g.hdmi_on == 0);

    mkdir(HDMI_CONN, 0755);
    put(HDMI_CONN "/enabled", "enabled\n");
    put(HDMI_CONN "/dpms", "Off\n");     /* blanked: nothing is shown */
    gpu_sample(&g, &prev);
    CHECK(g.hdmi_on == 0);
    put(HDMI_CONN "/enabled", "disabled\n");
    put(HDMI_CONN "/dpms", "On\n");
    gpu_sample(&g, &prev);
    CHECK(g.hdmi_on == 0);
}

/* devfreq's trans_stat, byte for byte as drivers/devfreq/devfreq.c prints it
 * (6.18): a header, one row per OPP with the current one starred, the
 * cumulative ms at the end of each row, then the transition total. */
static void stat_file_c(long long ms0, long long ms1, long long ms2, int total, int c02)
{
    char b[1024];
    snprintf(b, sizeof b,
             "     From  :   To\n"
             "           : 153600000 307200000 384000000   time(ms)\n"
             "* 153600000:         0         3%10d%10lld\n"
             "  307200000:         2         0         4%10lld\n"
             "  384000000:         2         3         0%10lld\n"
             "Total transition : %d\n", c02, ms0, ms1, ms2, total);
    put(GPU_DEVFREQ "/trans_stat", b);
}

static void stat_file(long long ms0, long long ms1, long long ms2, int total)
{
    stat_file_c(ms0, ms1, ms2, total, 1);
}

/* GPU DVFS (kernel r31): the current OPP and the residency per OPP. */
static void test_devfreq_residency(void)
{
    fixture();
    mkdir(GPU_DEVFREQ, 0755);
    prev_gpu_tis_n = 0;
    prev_gpu_trans = -1;
    put(GPU_DEVFREQ "/cur_freq", "384000000\n");
    stat_file(120000, 3500, 800, 15);

    long long prev = -1;
    struct gpu_reading g;
    gpu_sample(&g, &prev);
    CHECK(g.freq == 384000000);
    CHECK(strcmp(g.freq_ms, "{}") == 0);    /* first sample: no interval */
    CHECK(g.trans == -1);

    stat_file(122000, 4500, 2800, 21);
    gpu_sample(&g, &prev);
    CHECK(strcmp(g.freq_ms, "{\"153600000\":2000,\"307200000\":1000,\"384000000\":2000}") == 0);
    CHECK(g.trans == 6);

    /* After 11.6 days at one OPP the time has eleven digits and runs into the
     * last count column ("         1" + "1000000000"): read at its column. */
    prev_gpu_tis_n = 0;
    prev_gpu_trans = -1;
    stat_file_c(1000000000LL, 4500, 2800, 21, 1);
    gpu_sample(&g, &prev);
    stat_file_c(1000002500LL, 4500, 2800, 22, 2);   /* one more 153.6 -> 384 */
    gpu_sample(&g, &prev);
    CHECK(strcmp(g.freq_ms, "{\"153600000\":2500,\"307200000\":0,\"384000000\":0}") == 0);
    CHECK(g.trans == 1);

    /* The counters went backwards (devfreq re-registered): an honest gap. */
    stat_file(10, 0, 0, 0);
    gpu_sample(&g, &prev);
    CHECK(strcmp(g.freq_ms, "{}") == 0);
    CHECK(g.trans == -1);
}

/* A kernel without GPU DVFS: no devfreq directory. */
static void test_no_devfreq(void)
{
    fixture();
    prev_gpu_tis_n = 0;
    prev_gpu_trans = -1;
    long long prev = -1;
    struct gpu_reading g;
    gpu_sample(&g, &prev);
    gpu_sample(&g, &prev);
    CHECK(g.freq == -1);
    CHECK(strcmp(g.freq_ms, "{}") == 0);
    CHECK(g.trans == -1);
}

int main(void)
{
    test_suspended_gpu_reports_zero_active();
    test_active_ms_is_the_interval_delta();
    test_absent_gpu_and_hdmi_off();
    test_devfreq_residency();
    test_no_devfreq();
    rmrf(TEST_GPUROOT);
    if (fails) {
        printf("test_gpu: %d failure(s)\n", fails);
        return 1;
    }
    printf("test_gpu: all passed\n");
    return 0;
}
