/* userspace/nq-healthd/tests/test_memory.c
 *
 * The memory record added in device r125 (mem.jsonl, and anon_kB/shmem_kB in
 * health.jsonl) exists to answer "whose memory is growing?" after days of
 * uptime. Pinned here: the box figures come from the right meminfo lines, a
 * unit's figure is its cgroup's "anon" line and not "inactive_anon" or
 * "active_anon", every service in both slices is found without a list, a
 * mount or a service without memory accounting is left out rather than
 * reported as zero, a template's instances in a sub-slice and the user
 * manager's session and background services are found too, a user service
 * named like a system one does not shadow it, and the line is one
 * well-formed record.
 *
 * The source is #included so the statics are reachable, with main() renamed
 * out of the way and every path pointed at fixtures. */
#define main healthd_main_unused
#define CG_ROOT TEST_CGROOT
#define MEMINFO TEST_MEMINFO
#include "nq-healthd.c"
#undef main

#include <stdio.h>

static int fails;
#define CHECK(cond) do { if (!(cond)) { fails++; \
    printf("  FAIL %s:%d: %s\n", __FILE__, __LINE__, #cond); } } while (0)

static void sh(const char *c) { if (system(c)) {} }
static void put(const char *p, const char *v) { FILE *f = fopen(p, "w"); if (f) { fputs(v, f); fclose(f); } }

/* A memory.stat in the kernel's own order: anon first, then file, ... and the
 * LRU lines, two of which end in "anon". */
static void memstat(const char *dir, long long anon_bytes)
{
    char c[700], p[650], v[512];
    snprintf(c, sizeof c, "mkdir -p '%s'", dir);
    sh(c);
    snprintf(p, sizeof p, "%s/memory.stat", dir);
    snprintf(v, sizeof v,
             "anon %lld\nfile 4894720\nkernel 487424\nsock 0\nshmem 4096\n"
             "anon_thp 0\ninactive_anon 999424\nactive_anon 7777777\n",
             anon_bytes);
    put(p, v);
}

static void test_meminfo(void)
{
    long long av, an, sm;
    unlink(TEST_MEMINFO);
    meminfo_sample(&av, &an, &sm);
    CHECK(av == 0 && an == 0 && sm == 0);                 /* unreadable: zeros */
    put(TEST_MEMINFO,
        "MemTotal:         997404 kB\nMemFree:          100000 kB\n"
        "MemAvailable:     757892 kB\nBuffers:            1000 kB\n"
        "Active(anon):      70000 kB\nAnonPages:        140744 kB\n"
        "Mapped:            50000 kB\nShmem:             27608 kB\n"
        "ShmemHugePages:        0 kB\n");
    meminfo_sample(&av, &an, &sm);
    CHECK(av == 757892);
    CHECK(an == 140744);                                  /* not Active(anon) */
    CHECK(sm == 27608);                                   /* not ShmemHugePages */
}

static void test_cg_anon(void)
{
    sh("rm -rf '" TEST_CGROOT "'");
    CHECK(cg_anon_kB(TEST_CGROOT "/nope") == -1);         /* no cgroup */
    memstat(TEST_CGROOT "/a", 15417344);
    CHECK(cg_anon_kB(TEST_CGROOT "/a") == 15056);
    /* only the LRU lines: the leading "anon" line is the only one that counts */
    put(TEST_CGROOT "/a/memory.stat", "file 1\ninactive_anon 999424\nactive_anon 7777777\n");
    CHECK(cg_anon_kB(TEST_CGROOT "/a") == -1);
    put(TEST_CGROOT "/a/memory.stat", "inactive_anon 999424\nanon 2048\n");
    CHECK(cg_anon_kB(TEST_CGROOT "/a") == 2);
}

static void test_units(void)
{
    char out[4200];
    sh("rm -rf '" TEST_CGROOT "'");
    memstat(CG_ROOT "/system.slice", 53604352);
    memstat(CG_ROOT "/user.slice", 85073920);
    memstat(CG_ROOT "/init.scope", 4480000);
    memstat(CG_ROOT "/system.slice/nexusq-control.service", 15417344);
    memstat(CG_ROOT "/system.slice/dbus-broker.service", 1302528);
    memstat(CG_ROOT "/system.slice/var-lib-bluetooth.mount", 0);
    sh("mkdir -p '" CG_ROOT "/system.slice/system-modprobe.slice'");
    sh("mkdir -p '" CG_ROOT "/system.slice/no-accounting.service'");
    memstat(CG_ROOT "/system.slice/system-getty.slice/getty@tty1.service", 409600);
    memstat(CG_APP "roon.service", 61423616);
    memstat(CG_USERMGR "/session.slice/dbus-broker.service", 241664);
    memstat(CG_USERMGR "/session.slice/gvfs-daemon.service", 442368);
    memstat(CG_USERMGR "/init.scope", 135168);
    mem_units(out, sizeof out);

    CHECK(out[0] == '{' && out[strlen(out) - 1] == '}');
    CHECK(strstr(out, "\"system.slice\":52348") != NULL);
    CHECK(strstr(out, "\"user.slice\":83080") != NULL);
    CHECK(strstr(out, "\"init.scope\":4375") != NULL);
    CHECK(strstr(out, "\"nexusq-control\":15056") != NULL);
    CHECK(strstr(out, "\"roon\":59984") != NULL);         /* found, not listed */
    CHECK(strstr(out, "\"dbus-broker\":1272") != NULL);   /* the system one */
    CHECK(strstr(out, "\"user/dbus-broker\":236") != NULL);
    CHECK(strstr(out, "\"getty@tty1\":400") != NULL);   /* in a sub-slice */
    CHECK(strstr(out, "\"gvfs-daemon\":432") != NULL);  /* session.slice */
    CHECK(strstr(out, "init.scope\":132") == NULL);      /* a scope, not a service */
    CHECK(strstr(out, "var-lib-bluetooth") == NULL);      /* a mount, not a service */
    CHECK(strstr(out, "modprobe") == NULL);
    CHECK(strstr(out, "no-accounting") == NULL);          /* no memory.stat: absent */
    CHECK(strstr(out, ".service") == NULL);
}

static void test_line(void)
{
    char out[4800];
    put(TEST_MEMINFO, "MemAvailable: 757892 kB\nAnonPages: 140744 kB\nShmem: 27608 kB\n");
    mem_line(out, sizeof out, 275000, "2026-10-03T19:44:08Z", "0b5c\"x");
    CHECK(!strncmp(out, "{\"t_mono\":275000,\"wall\":\"2026-10-03T19:44:08Z\",", 47));
    CHECK(strstr(out, "\"boot_id\":\"0b5c\\\"x\"") != NULL); /* escaped */
    CHECK(strstr(out, "\"mem_avail_kB\":757892,\"anon_kB\":140744,\"shmem_kB\":27608,") != NULL);
    CHECK(strstr(out, "\"unit_anon_kB\":{\"system.slice\":") != NULL);
    size_t n = strlen(out);
    CHECK(n > 3 && !strcmp(out + n - 3, "}}\n"));
    CHECK(strchr(out, '\n') == out + n - 1);              /* exactly one line */
}

int main(void)
{
    test_meminfo();
    test_cg_anon();
    test_units();
    test_line();
    printf(fails ? "test_memory: FAILED (%d)\n" : "test_memory: OK\n", fails);
    return fails ? 1 : 0;
}
