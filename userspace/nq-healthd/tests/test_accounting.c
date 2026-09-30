/* userspace/nq-healthd/tests/test_accounting.c
 *
 * The CPU accounting added in device r119 (busy_ms, forks, irqs, unit_us,
 * nq_renders/nq_ctl, ambient_wakes/tap_fixes) is what answers "did this change
 * cost anything at idle?" from health.jsonl alone, without an ssh session on
 * the box (a session is itself the biggest load an idle Q sees). Pinned here:
 * each figure is a per-interval delta, a first sample or a counter reset is an
 * honest gap rather than a huge number, a unit that is not running is left out
 * rather than reported as zero, and the two daemons' own counters are read
 * the way they write them.
 *
 * The source is #included so the statics are reachable, with main() renamed
 * out of the way and every path pointed at fixtures. */
#define main healthd_main_unused
#define PROC_STAT     TEST_PROCSTAT
#define CG_ROOT       TEST_CGROOT
#define CONTROL_STATS TEST_CTLSTATS
#define NQ_SOCK       TEST_NQSOCK
#include "nq-healthd.c"
#undef main

#include <signal.h>
#include <stdio.h>
#include <sys/wait.h>

static int fails;
#define CHECK(cond) do { if (!(cond)) { fails++; \
    printf("  FAIL %s:%d: %s\n", __FILE__, __LINE__, #cond); } } while (0)

static void sh(const char *c) { if (system(c)) {} }
static void put(const char *p, const char *v) { FILE *f = fopen(p, "w"); if (f) { fputs(v, f); fclose(f); } }

static void procstat_n(long long user, long long nice, long long sys, long long idle, long long intr, long long procs)
{
    char b[512];
    snprintf(b, sizeof b,
             "cpu  %lld %lld %lld %lld 5 0 0 0 0 0\n"
             "cpu0 1 0 1 1 0 0 0 0 0 0\n"
             "intr %lld 0 0 17 0 4\n"
             "ctxt 999\nbtime 1\nprocesses %lld\nprocs_running 1\n",
             user, nice, sys, idle, intr, procs);
    put(TEST_PROCSTAT, b);
}

static void procstat(long long user, long long sys, long long idle, long long intr, long long procs)
{
    procstat_n(user, 0, sys, idle, intr, procs);
}

static void test_cpu_sample(void)
{
    long long busy, nice, forks, irqs;
    long hz = sysconf(_SC_CLK_TCK);
    procstat(100, 50, 1000, 5000, 300);
    cpu_sample(&busy, &nice, &forks, &irqs);
    CHECK(busy == -1 && nice == -1 && forks == -1 && irqs == -1);   /* first sample: a gap */
    procstat(103, 52, 1400, 5120, 307);                  /* 5 ticks busy, 400 idle */
    cpu_sample(&busy, &nice, &forks, &irqs);
    CHECK(busy == 5 * 1000 / hz);
    CHECK(nice == 0);
    CHECK(forks == 7);
    CHECK(irqs == 120);
    procstat(1, 1, 1, 1, 1);                             /* counters went backwards */
    cpu_sample(&busy, &nice, &forks, &irqs);
    CHECK(busy == -1 && nice == -1 && forks == -1 && irqs == -1);
}

/* nice_ms: the niced part of busy_ms, which ignore_nice_load keeps at 350 MHz */
static void test_nice_share(void)
{
    long long busy, nice, forks, irqs;
    long hz = sysconf(_SC_CLK_TCK);
    procstat_n(100, 40, 50, 1000, 1, 1);
    cpu_sample(&busy, &nice, &forks, &irqs);
    procstat_n(102, 70, 51, 1100, 1, 1);                 /* 30 niced of 33 busy ticks */
    cpu_sample(&busy, &nice, &forks, &irqs);
    CHECK(busy == 33 * 1000 / hz);
    CHECK(nice == 30 * 1000 / hz);
}

/* an event names its wall clock: t_mono restarts at every boot */
static void test_event_wall(void)
{
    FILE *f = tmpfile();
    emit_event(f, 7537, "2026-09-29T23:37:02Z", "warn", "vdd_mismatch", "x %d", 1);
    rewind(f);
    char line[256] = {0};
    CHECK(fgets(line, sizeof line, f) != NULL);
    CHECK(strstr(line, "\"t_mono\":7537") != NULL);
    CHECK(strstr(line, "\"wall\":\"2026-09-29T23:37:02Z\"") != NULL);
    CHECK(strstr(line, "\"msg\":\"x 1\"") != NULL);
    fclose(f);
}

static void cpustat(const char *dir, long long usec)
{
    char d[400], p[450], v[64];
    snprintf(d, sizeof d, "mkdir -p '%s'", dir); sh(d);
    snprintf(p, sizeof p, "%s/cpu.stat", dir);
    snprintf(v, sizeof v, "usage_usec %lld\nuser_usec 1\nsystem_usec 1\n", usec);
    put(p, v);
}

static void test_unit_sample(void)
{
    char out[1100];
    sh("rm -rf '" TEST_CGROOT "'");
    cpustat(CG_SYS "nexusq-control.service", 1000);
    cpustat(CG_SYS "nexusqd.service", 5000);
    cpustat(CG_APP "pulseaudio.service", 70);
    unit_sample(out, sizeof out);
    CHECK(!strcmp(out, "{}"));                           /* first sample: a gap */

    cpustat(CG_SYS "nexusq-control.service", 1250);
    cpustat(CG_SYS "nexusqd.service", 5000);
    cpustat(CG_APP "pulseaudio.service", 90);
    cpustat(CG_APP "librespot.service", 400);            /* started since */
    unit_sample(out, sizeof out);
    CHECK(strstr(out, "\"nexusq-control\":250") != NULL);
    CHECK(strstr(out, "\"nexusqd\":0") != NULL);         /* idle is 0, not absent */
    CHECK(strstr(out, "\"pulseaudio\":20") != NULL);
    CHECK(strstr(out, "librespot") == NULL);             /* no previous value yet */
    CHECK(strstr(out, "roon") == NULL);                  /* not running: left out */

    cpustat(CG_SYS "nexusq-control.service", 10);         /* restarted: reset */
    cpustat(CG_APP "librespot.service", 450);
    unit_sample(out, sizeof out);
    CHECK(strstr(out, "nexusq-control") == NULL);
    CHECK(strstr(out, "\"librespot\":50") != NULL);
    CHECK(out[0] == '{' && out[strlen(out) - 1] == '}');
}

static void test_control_stats(void)
{
    long long w, f;
    unlink(TEST_CTLSTATS);
    control_stats(&w, &f);
    CHECK(w == -1 && f == -1);                           /* an older bridge */
    put(TEST_CTLSTATS, "ambient_wakes 17\ntap_fixes 2\n");
    control_stats(&w, &f);
    CHECK(w == 17 && f == 2);
}

/* A stand-in nexusqd: answers one `debug` with the line the real one prints. */
static pid_t fake_nexusqd(void)
{
    unlink(TEST_NQSOCK);
    int s = socket(AF_UNIX, SOCK_STREAM, 0);
    struct sockaddr_un sa = { .sun_family = AF_UNIX };
    snprintf(sa.sun_path, sizeof sa.sun_path, "%s", TEST_NQSOCK);
    if (bind(s, (struct sockaddr *)&sa, sizeof sa) || listen(s, 1))
        return -1;
    pid_t pid = fork();
    if (pid == 0) {
        int c = accept(s, NULL, NULL);
        char in[64] = {0};
        if (read(c, in, sizeof in - 1) > 0 && !strncmp(in, "debug", 5)) {
            const char *r = "up=3553.0 loops=72859 renders=71159 spin=61 ready=1816 "
                            "ctl=193 keys=0 rearm=0 frame_int=0.050\n";
            if (write(c, r, strlen(r)) < 0) {}
        }
        close(c);
        _exit(0);
    }
    close(s);
    return pid;
}

static void test_nexusqd_counters(void)
{
    unlink(TEST_NQSOCK);
    nexusqd_counters();
    CHECK(nq_renders == -1 && nq_ctl == -1);             /* nobody listening */
    pid_t pid = fake_nexusqd();
    CHECK(pid > 0);
    nexusqd_counters();
    waitpid(pid, NULL, 0);
    CHECK(nq_renders == 71159);                          /* not loops=, not spin= */
    CHECK(nq_ctl == 193);
    unlink(TEST_NQSOCK);
}

int main(void)
{
    signal(SIGPIPE, SIG_IGN);
    test_cpu_sample();
    test_nice_share();
    test_event_wall();
    test_unit_sample();
    test_control_stats();
    test_nexusqd_counters();
    printf(fails ? "test_accounting: FAILED (%d)\n" : "test_accounting: OK\n", fails);
    return fails ? 1 : 0;
}
