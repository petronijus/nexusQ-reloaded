/* nq-healthd — Nexus Q runtime health monitor.
 *
 * A C rewrite of the shell daemon (device pkg r72), field-for-field compatible:
 * the JSONL schema is UNCHANGED, because nexusq-mqtt tails it, Home Assistant
 * renders it and the companion app alarms on it. Any field rename here is an
 * outage over there.
 *
 * WHY C. This daemon runs forever on the device it is judging, so its own cost
 * is a measurement error. The shell version was down to ~6 forks per 5 s tick
 * after the r71 fork diet, but that still measured **3.08 % of a core** on
 * 2026-08-19 — roughly three quarters of ALL idle CPU on the box (total idle
 * busy ≈ 4.1 % of a core). Each fork is also a 16–40 ms burst, which is what
 * used to ramp the governor; that particular harm is now masked by
 * ignore_nice_load=1 + Nice=19, so what this rewrite buys is CPU, heat and
 * wakeups rather than OPP residency. See
 * docs/2026-08-16-idle-700mhz-deep-analysis.md.
 *
 * Every probe the shell forked for is a syscall here:
 *   date            -> clock_gettime + gmtime_r + strftime
 *   od | awk        -> read the frame attr, sum + hash in-process
 *   timeout nexusled-> connect() to nexusqd's control socket
 *   dmesg | grep    -> /dev/kmsg, read incrementally
 *   stat            -> fstat()
 *   ls | wc         -> opendir/readdir
 * The ONLY fork left is `systemctl show`, and only on a unit transition or once
 * per NQ_UNIT_REFRESH_S (300 s default) — the shell's own hard-won rule, kept.
 */
#define _GNU_SOURCE
#include <ctype.h>
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

#define CPUFREQ   "/sys/devices/system/cpu/cpufreq/policy0"
#define TIS       CPUFREQ "/stats/time_in_state"
#define TRANS     CPUFREQ "/stats/total_trans"
#define TZ0       "/sys/class/thermal/thermal_zone0"
#define COOL0     "/sys/class/thermal/cooling_device0"
#define NQ_CGROUP "/sys/fs/cgroup/system.slice/nexusqd.service"
#define LS_CGROUP "/sys/fs/cgroup/user.slice/user-10000.slice/user@10000.service/app.slice/librespot.service"
#define NQ_SOCK   "/run/nexusqd.sock"
#define PSTORE    "/sys/fs/pstore"

static const char *logdir  = "/var/log/nq-health";
static char logpath[512], eventpath[512];
static long interval_s     = 5;
static long unit_refresh_s = 300;
static long dmesg_every    = 6;
static long progress_stale_s = 60;   /* see nq_progress below */
static long maxbytes       = 4L * 1024 * 1024;

/* ---------- small file helpers (no forks, no allocations) ---------------- */

static ssize_t slurp(const char *path, char *buf, size_t n)
{
    int fd = open(path, O_RDONLY | O_CLOEXEC);
    if (fd < 0)
        return -1;
    ssize_t r = read(fd, buf, n - 1);
    close(fd);
    if (r < 0)
        return -1;
    buf[r] = '\0';
    return r;
}

/* First whitespace-delimited token as a long long; def on any failure. */
static long long slurp_ll(const char *path, long long def)
{
    char b[256];
    if (slurp(path, b, sizeof b) < 0)
        return def;
    errno = 0;
    char *end;
    long long v = strtoll(b, &end, 10);
    return (end == b || errno) ? def : v;
}

/* First line, trailing newline stripped. Returns dst. */
static char *slurp_line(const char *path, char *dst, size_t n, const char *def)
{
    char b[512];
    if (slurp(path, b, sizeof b) < 0) {
        snprintf(dst, n, "%s", def);
        return dst;
    }
    char *nl = strchr(b, '\n');
    if (nl)
        *nl = '\0';
    /* Bounded copy, not snprintf("%s"): the source is a 512 B read and some
     * destinations are 32 B, which is fine (truncation is intended) but makes
     * -Wformat-truncation shout. A warning left standing is one that hides the
     * next real one. */
    size_t len = strlen(b);
    if (len >= n)
        len = n - 1;
    memcpy(dst, b, len);
    dst[len] = '\0';
    return dst;
}

/* JSON string escaping, matching the shell's jstr(): quotes and backslashes
 * escaped, control characters dropped. Truncation is silent and deliberate —
 * a health line must never be able to break the log it writes to. */
static void jstr(const char *in, char *out, size_t n)
{
    size_t o = 0;
    for (const unsigned char *p = (const unsigned char *)in; *p && o + 2 < n; p++) {
        if (*p == '"' || *p == '\\') {
            if (o + 3 >= n)
                break;
            out[o++] = '\\';
            out[o++] = (char)*p;
        } else if (*p >= 0x20) {
            out[o++] = (char)*p;
        }
    }
    out[o] = '\0';
}

/* ---------- per-OPP residency: the only honest read on the idle goal ------
 * `freq` is a spot read taken inside this daemon's own busy tick, so it is
 * biased toward whatever the governor picked in response to US: over a 12 h
 * capture it claimed 20.5 % at 350 MHz where the kernel counter said 39.1 %.
 * Residency therefore comes from differencing the kernel's cumulative
 * time_in_state, never from `freq`. */
#define MAX_OPP 16
struct opp_prev { long long khz, ticks; };
static struct opp_prev prev_tis[MAX_OPP];
static int  prev_tis_n;
static long long prev_trans = -1;

static void opp_sample(char *ms_out, size_t ms_n, long long *trans_out)
{
    snprintf(ms_out, ms_n, "{}");
    *trans_out = -1;

    FILE *f = fopen(TIS, "re");
    if (!f)
        return;

    struct opp_prev cur[MAX_OPP];
    int n = 0, reset = 0;
    char json[512];
    size_t jo = 0;
    json[0] = '\0';

    long long khz, ticks;
    while (n < MAX_OPP && fscanf(f, "%lld %lld", &khz, &ticks) == 2) {
        cur[n].khz = khz;
        cur[n].ticks = ticks;
        n++;

        long long p = -1;
        for (int i = 0; i < prev_tis_n; i++)
            if (prev_tis[i].khz == khz) { p = prev_tis[i].ticks; break; }

        if (p < 0)
            reset = 1;                       /* first sample, or a new OPP */
        else if (ticks < p)
            reset = 1;                       /* counters reset under us */
        else
            jo += (size_t)snprintf(json + jo, sizeof json - jo, "%s\"%lld\":%lld",
                                   jo ? "," : "", khz, (ticks - p) * 10);
    }
    fclose(f);

    memcpy(prev_tis, cur, sizeof(struct opp_prev) * (size_t)n);
    prev_tis_n = n;
    /* `{}` on a reset is an honest gap, not a poisoned window. */
    if (!reset && jo)
        snprintf(ms_out, ms_n, "{%s}", json);

    long long tr = slurp_ll(TRANS, -1);
    if (tr >= 0) {
        if (prev_trans >= 0 && tr >= prev_trans)
            *trans_out = tr - prev_trans;
        prev_trans = tr;
    }
}

/* ---------- expected VDD_MPU per OPP (from omap4-steelhead.dts) ---------- */
static long long opp_voltage(long long khz)
{
    switch (khz) {
    case 350000:  return 1025000;
    case 700000:  return 1203000;
    case 920000:  return 1317000;
    case 1200000: return 1380000;
    default:      return 0;
    }
}

/* Regulator dirs are regulator.N with an opaque index; the stable key is the
 * "name" attribute. Resolved once and cached. */
static int reg_dir(const char *want, char *dst, size_t n)
{
    DIR *d = opendir("/sys/class/regulator");
    if (!d)
        return -1;
    struct dirent *e;
    int found = -1;
    while ((e = readdir(d))) {
        if (strncmp(e->d_name, "regulator.", 10) != 0)
            continue;
        char p[512], nm[128];
        snprintf(p, sizeof p, "/sys/class/regulator/%s/name", e->d_name);
        slurp_line(p, nm, sizeof nm, "");
        if (strcmp(nm, want) == 0) {
            snprintf(dst, n, "/sys/class/regulator/%s", e->d_name);
            found = 0;
            break;
        }
    }
    closedir(d);
    return found;
}

/* ---------- cgroup / process helpers ------------------------------------ */

/* First pid in a unit's cgroup, or 0. A populated cgroup IS the definition of
 * "the unit is running", and costs one read — which is why the shell stopped
 * asking systemd every tick. */
static long cg_pid(const char *cgroup)
{
    char p[600], b[256];
    snprintf(p, sizeof p, "%s/cgroup.procs", cgroup);
    if (slurp(p, b, sizeof b) <= 0)
        return 0;
    return strtol(b, NULL, 10);
}

static int cg_has_pid(const char *cgroup, long pid)
{
    char p[600], b[4096];
    snprintf(p, sizeof p, "%s/cgroup.procs", cgroup);
    if (slurp(p, b, sizeof b) <= 0)
        return 0;
    for (char *l = strtok(b, "\n"); l; l = strtok(NULL, "\n"))
        if (strtol(l, NULL, 10) == pid)
            return 1;
    return 0;
}

static int proc_comm_is(long pid, const char *want)
{
    char p[64], b[128];
    snprintf(p, sizeof p, "/proc/%ld/comm", pid);
    if (slurp(p, b, sizeof b) <= 0)
        return 0;
    char *nl = strchr(b, '\n');
    if (nl)
        *nl = '\0';
    return strcmp(b, want) == 0;
}

/* state char + utime+stime, parsed past a comm that may contain ") ". */
static int proc_stat(long pid, char *state, long long *ticks)
{
    char p[64], b[1024];
    snprintf(p, sizeof p, "/proc/%ld/stat", pid);
    if (slurp(p, b, sizeof b) <= 0)
        return 0;
    char *rp = strrchr(b, ')');
    if (!rp || !rp[1])
        return 0;
    char st;
    long long ut, stime;
    /* after "pid (comm) ": state, ppid pgrp session tty tpgid flags
     * minflt cminflt majflt cmajflt utime stime */
    if (sscanf(rp + 2, "%c %*d %*d %*d %*d %*d %*u %*u %*u %*u %*u %lld %lld",
               &st, &ut, &stime) != 3)
        return 0;
    *state = st;
    *ticks = ut + stime;
    return 1;
}

/* The real "is it wedged?" probe: connect to nexusqd's control socket. The
 * shell forked `timeout 3 nexusled status` for this; a connect() answers the
 * same question — the daemon accepts, or it does not. */
static int nexusqd_responds(void)
{
    int fd = socket(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC | SOCK_NONBLOCK, 0);
    if (fd < 0)
        return 0;
    struct sockaddr_un sa = { .sun_family = AF_UNIX };
    snprintf(sa.sun_path, sizeof sa.sun_path, "%s", NQ_SOCK);
    int ok = 0;
    if (connect(fd, (struct sockaddr *)&sa, sizeof sa) == 0) {
        ok = 1;
    } else if (errno == EINPROGRESS) {
        struct pollfd pf = { .fd = fd, .events = POLLOUT };
        if (poll(&pf, 1, 3000) > 0) {
            int err = 0;
            socklen_t el = sizeof err;
            if (getsockopt(fd, SOL_SOCKET, SO_ERROR, &err, &el) == 0 && err == 0)
                ok = 1;
        }
    }
    close(fd);
    return ok;
}

/* ---------- AVR interrupt counter --------------------------------------- */
static long long avr_irq_count(void)
{
    FILE *f = fopen("/proc/interrupts", "re");
    if (!f)
        return 0;
    char line[1024];
    long long sum = 0;
    while (fgets(line, sizeof line, f)) {
        if (!strstr(line, "steelhead-avr"))
            continue;
        char *p = strchr(line, ':');
        if (!p)
            break;
        p++;
        for (;;) {
            while (*p == ' ' || *p == '\t')
                p++;
            /* A per-CPU count is a token that is ENTIRELY digits. Testing only
             * the first character is not enough: the controller column reads
             * "48055000.gpio", which starts with digits and would otherwise be
             * summed in as an interrupt count (it produced avr_irq=48055000
             * against the shell's correct 0). */
            char *q = p;
            while (isdigit((unsigned char)*q))
                q++;
            if (q == p || (*q != ' ' && *q != '\t' && *q != '\n' && *q != '\0'))
                break;
            sum += strtoll(p, &p, 10);
        }
        break;
    }
    fclose(f);
    return sum;
}

/* ---------- LED frame fingerprint --------------------------------------- */
/* The driver's committed frame (kernel patch 0029) is authoritative. One read
 * yields both the brightness sum and a change-sensitive rolling hash; the hash
 * only ever feeds an equality test, so a cryptographic digest would buy
 * nothing. Same arithmetic as the shell's od|awk pass, so led_sum is
 * comparable across the rewrite. */
static void led_frame(const char *attr, long long *sum, long long *hash)
{
    *sum = 0;
    *hash = 0;
    if (!attr || !*attr)
        return;
    int fd = open(attr, O_RDONLY | O_CLOEXEC);
    if (fd < 0)
        return;
    unsigned char b[4096];
    ssize_t r;
    long long s = 0, h = 0;
    while ((r = read(fd, b, sizeof b)) > 0)
        for (ssize_t i = 0; i < r; i++) {
            s += b[i];
            h = (h * 31 + b[i]) % 2147483647LL;
        }
    close(fd);
    *sum = s;
    *hash = h;
}

/* ---------- kernel log errors -------------------------------------------
 * A faithful port of the shell's matcher, ON PURPOSE. It scanned the whole ring
 * with `dmesg | grep -icE` for a fixed pattern list and reported the TOTAL, so
 * that is what this reproduces — priority-based counting would have been
 * cleaner but would have silently redefined a number that nexusq-mqtt publishes
 * and Home Assistant plots (it read 5 here; a "better" rule reset it to 0).
 *
 * The pattern list is known to be somewhat broad; that is a separate argument
 * to have, with the field's consumers, not a thing to change under them.
 *
 * /dev/kmsg is opened fresh per scan because it starts at the OLDEST record —
 * that is how we get a whole-ring recount without forking dmesg. Scans are
 * amortized (every NQ_DMESG_EVERY ticks, 30 s by default). */
static int line_is_error(const char *l)
{
    if (strcasestr(l, "oops") || strcasestr(l, "panic") ||
        strcasestr(l, "call trace") || strcasestr(l, "bug:") ||
        strcasestr(l, "hung task") || strcasestr(l, "rcu_sched stall") ||
        strcasestr(l, "omap_voltage"))
        return 1;
    if (strcasestr(l, "undervolt") || strcasestr(l, "under volt") ||
        strcasestr(l, "under-volt") || strcasestr(l, "brownout") ||
        strcasestr(l, "brown out") || strcasestr(l, "brown-out"))
        return 1;
    const char *p = strcasestr(l, "i2c");
    if (p && (strcasestr(p, "timeout") || strcasestr(p, "fail")))
        return 1;
    p = strcasestr(l, "thermal");
    if (p && (strcasestr(p, "shutdown") || strcasestr(p, "crit")))
        return 1;
    return 0;
}

static long long kmsg_error_count(void)
{
    int fd = open("/dev/kmsg", O_RDONLY | O_NONBLOCK | O_CLOEXEC);
    if (fd < 0)
        return -1;
    char buf[8192];
    long long n = 0;
    ssize_t r;
    for (;;) {
        r = read(fd, buf, sizeof buf - 1);
        if (r > 0) {
            buf[r] = '\0';
            /* "prio,seq,ts,flag;message" — only the message is matched, so a
             * digit in the header can never look like a hit. */
            char *msg = strchr(buf, ';');
            if (msg && line_is_error(msg + 1))
                n++;
            continue;
        }
        if (r < 0 && errno == EPIPE)
            continue;            /* ring wrapped past us; keep reading */
        break;                   /* EAGAIN = end of ring, or a real error */
    }
    close(fd);
    return n;
}

static long pstore_count(void)
{
    DIR *d = opendir(PSTORE);
    if (!d)
        return 0;
    long n = 0;
    struct dirent *e;
    while ((e = readdir(d)))
        if (e->d_name[0] != '.')
            n++;
    closedir(d);
    return n;
}

/* ---------- systemd, the one remaining fork ------------------------------ */
/* Consulted ONLY on a transition (pid unknown/vanished) or once per
 * unit_refresh_s. Polling systemctl every sample used to hold pid 1 at ~3.3 %
 * of a core, and later, while librespot was masked, degenerated into ~600 PAM
 * logins an hour. Both regressions are why this is rationed. */
static int systemd_show(const char *unit, int user_scope,
                        char *active, size_t an, long *mainpid, long *nrestarts)
{
    int pipefd[2];
    if (pipe2(pipefd, O_CLOEXEC) < 0)
        return 0;
    pid_t pid = fork();
    if (pid < 0) {
        close(pipefd[0]);
        close(pipefd[1]);
        return 0;
    }
    if (pid == 0) {
        dup2(pipefd[1], STDOUT_FILENO);
        int null = open("/dev/null", O_WRONLY);
        if (null >= 0)
            dup2(null, STDERR_FILENO);
        if (user_scope)
            execlp("systemctl", "systemctl", "-M", "user@", "--user", "show",
                   "-p", "ActiveState", "-p", "MainPID", "-p", "NRestarts",
                   unit, (char *)NULL);
        else
            execlp("systemctl", "systemctl", "show",
                   "-p", "ActiveState", "-p", "MainPID", "-p", "NRestarts",
                   unit, (char *)NULL);
        _exit(127);
    }
    close(pipefd[1]);
    char out[1024];
    size_t o = 0;
    ssize_t r;
    while (o + 1 < sizeof out && (r = read(pipefd[0], out + o, sizeof out - o - 1)) > 0)
        o += (size_t)r;
    out[o] = '\0';
    close(pipefd[0]);
    int status = 0;
    waitpid(pid, &status, 0);

    int got = 0;
    for (char *l = strtok(out, "\n"); l; l = strtok(NULL, "\n")) {
        if (!strncmp(l, "ActiveState=", 12)) { snprintf(active, an, "%s", l + 12); got = 1; }
        else if (!strncmp(l, "MainPID=", 8))   *mainpid   = strtol(l + 8, NULL, 10);
        else if (!strncmp(l, "NRestarts=", 10)) *nrestarts = strtol(l + 10, NULL, 10);
    }
    return got;
}

/* ---------- log rotation ------------------------------------------------- */
static void rotate_if_big(FILE **outp)
{
    struct stat st;
    if (stat(logpath, &st) == 0 && st.st_size > maxbytes) {
        char old[600];
        snprintf(old, sizeof old, "%s.1", logpath);
        if (rename(logpath, old) == 0 && *outp) {
            /* the open stream still points at the renamed inode — drop it so
             * the next sample reopens a fresh logpath (readers stat logpath) */
            fclose(*outp);
            *outp = NULL;
        }
    }
}

static void emit_event(FILE *ev, long long mono, const char *sev,
                       const char *kind, const char *fmt, ...)
{
    if (!ev)
        return;
    char msg[512], esc[600];
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(msg, sizeof msg, fmt, ap);
    va_end(ap);
    jstr(msg, esc, sizeof esc);
    fprintf(ev, "{\"t_mono\":%lld,\"sev\":\"%s\",\"kind\":\"%s\",\"msg\":\"%s\"}\n",
            mono, sev, kind, esc);
    fflush(ev);
}

int main(int argc, char **argv)
{
    int once = (argc > 1 && !strcmp(argv[1], "--once"));

    const char *e;
    if ((e = getenv("NQ_LOGDIR")))            logdir = e;
    if ((e = getenv("NQ_INTERVAL")))          interval_s = atol(e);
    if ((e = getenv("NQ_UNIT_REFRESH_S")))    unit_refresh_s = atol(e);
    if ((e = getenv("NQ_DMESG_EVERY")))       dmesg_every = atol(e);
    if ((e = getenv("NQ_PROGRESS_STALE_S")))  progress_stale_s = atol(e);
    if (interval_s < 1) interval_s = 1;

    snprintf(logpath, sizeof logpath, "%s/health.jsonl", logdir);
    snprintf(eventpath, sizeof eventpath, "%s/events.jsonl", logdir);

    char vdd_dir[512] = "", abb_dir[512] = "";
    reg_dir("vdd_mpu", vdd_dir, sizeof vdd_dir);
    reg_dir("abb_mpu", abb_dir, sizeof abb_dir);

    /* The committed-frame attr (patch 0029) if the kernel exposes it. */
    const char *frame_attr = NULL;
    if (access("/sys/class/leds/steelhead:rgb:ring/device/frame", R_OK) == 0)
        frame_attr = "/sys/class/leds/steelhead:rgb:ring/device/frame";
    else if (access("/sys/devices/platform/steelhead-avr/frame", R_OK) == 0)
        frame_attr = "/sys/devices/platform/steelhead-avr/frame";

    /* cached unit state — see systemd_show() */
    long nq_pid = 0, nq_restarts = 0, ls_pid = 0, ls_restarts = 0;
    char nq_active[32] = "unknown", ls_active[32] = "unknown";
    long long nq_last_show = -1, ls_last_show = -1;

    long long prev_led_hash = -1, led_stall = 0, tickn = 0;
    long long prev_nq_ticks = -1, nq_last_tick_move = -1;
    int prev_nq_resp = 1;
    long long prev_pstore = -1, prev_derr = -1, derr_cache = -1;

    FILE *out = NULL, *ev = NULL;
    if (!once) {
        mkdir(logdir, 0755);
        ev = fopen(eventpath, "ae");
    }

    for (;;) {
        struct timespec ts;
        clock_gettime(CLOCK_BOOTTIME, &ts);
        long long mono = ts.tv_sec;

        char wall[32];
        time_t now = time(NULL);
        struct tm tmv;
        gmtime_r(&now, &tmv);
        strftime(wall, sizeof wall, "%Y-%m-%dT%H:%M:%SZ", &tmv);

        char gov[32];
        slurp_line(CPUFREQ "/scaling_governor", gov, sizeof gov, "?");
        long long freq = slurp_ll(CPUFREQ "/scaling_cur_freq", 0);

        char opp_ms[512];
        long long opp_trans;
        opp_sample(opp_ms, sizeof opp_ms, &opp_trans);

        long long temp = slurp_ll(TZ0 "/temp", 0);
        long long cool = slurp_ll(COOL0 "/cur_state", -1);

        long long vdd = 0, abb = 0;
        if (*vdd_dir) {
            char p[600];
            snprintf(p, sizeof p, "%s/microvolts", vdd_dir);
            vdd = slurp_ll(p, 0);
        }
        if (*abb_dir) {
            char p[600];
            snprintf(p, sizeof p, "%s/microvolts", abb_dir);
            abb = slurp_ll(p, 0);
        }
        long long vexp = opp_voltage(freq);
        /* Re-read freq and only judge if it did not move under us — a mismatch
         * reported across an OPP change is an artefact, not a fault. */
        long long freq2 = slurp_ll(CPUFREQ "/scaling_cur_freq", -1);
        int vmismatch = 0;
        if (freq2 == freq && vexp > 0 && vdd > 0) {
            long long d = vdd - vexp;
            if (d < 0) d = -d;
            vmismatch = (d > 20000);
        }

        /* --- nexusqd: crash AND hang detection, process-first --- */
        int nq_alive = 0, nq_refresh = 0;
        char nq_state[4] = "-";
        long long nq_ticks = 0;
        if (nq_pid > 0 && proc_comm_is(nq_pid, "nexusqd")) {
            nq_alive = 1;
            snprintf(nq_active, sizeof nq_active, "active");
        } else {
            long cgp = cg_pid(NQ_CGROUP);
            if (cgp > 0 && proc_comm_is(cgp, "nexusqd")) {
                nq_pid = cgp;
                nq_alive = 1;
                snprintf(nq_active, sizeof nq_active, "active");
                nq_refresh = 1;              /* (re)started: pick up NRestarts */
            } else {
                nq_pid = 0;
                snprintf(nq_active, sizeof nq_active, "inactive");
            }
        }
        if (nq_refresh || nq_last_show < 0 || mono - nq_last_show >= unit_refresh_s) {
            char a[32];
            long mp = 0, nr = nq_restarts;
            if (systemd_show("nexusqd.service", 0, a, sizeof a, &mp, &nr)) {
                snprintf(nq_active, sizeof nq_active, "%s", a);
                nq_restarts = nr;
                if (mp > 0 && proc_comm_is(mp, "nexusqd")) {
                    nq_pid = mp;
                    nq_alive = 1;
                }
            }
            nq_last_show = mono;
        }
        if (nq_alive) {
            char st;
            long long tk;
            if (proc_stat(nq_pid, &st, &tk)) {
                nq_state[0] = st;
                nq_state[1] = '\0';
                nq_ticks = tk;
            }
        }
        int nq_resp = nq_alive ? nexusqd_responds() : 0;

        /* nq_progress measured over a WINDOW, not sample-to-sample. r13 cut
         * nexusqd to ~0.165 % of a core (~0.8 USER_HZ ticks per 5 s sample), so
         * a zero delta became the ORDINARY reading for a healthy daemon — and,
         * co-signalled with a guaranteed LED_STALL on a blanked ring, fired a
         * CRIT led_frozen on a healthy device twice. Zero only once CPU time
         * has genuinely stood still for progress_stale_s. */
        int nq_progress = 1;
        if (!nq_alive) {
            prev_nq_ticks = -1;
            nq_last_tick_move = -1;
        } else {
            if (prev_nq_ticks < 0 || nq_ticks != prev_nq_ticks)
                nq_last_tick_move = mono;
            prev_nq_ticks = nq_ticks;
            if (nq_last_tick_move >= 0 && mono - nq_last_tick_move >= progress_stale_s)
                nq_progress = 0;
        }

        /* --- librespot (user unit, uid 10000) --- */
        int ls_refresh = 0;
        long lcg = cg_pid(LS_CGROUP);
        if (lcg > 0) {
            snprintf(ls_active, sizeof ls_active, "active");
            if (ls_pid <= 0 || !cg_has_pid(LS_CGROUP, ls_pid)) {
                ls_pid = lcg;
                ls_refresh = 1;
            }
        } else {
            ls_pid = 0;
            snprintf(ls_active, sizeof ls_active, "inactive");
        }
        if (ls_refresh || ls_last_show < 0 || mono - ls_last_show >= unit_refresh_s) {
            /* Only worth asking once the user manager exists; otherwise pid 1
             * builds and tears down a PAM session for nothing. */
            if (access("/run/user/10000/systemd", F_OK) == 0) {
                char a[32];
                long mp = 0, nr = ls_restarts;
                if (systemd_show("librespot.service", 1, a, sizeof a, &mp, &nr)) {
                    snprintf(ls_active, sizeof ls_active, "%s", a);
                    ls_restarts = nr;
                    if (mp > 0)
                        ls_pid = mp;
                } else if (lcg <= 0) {
                    snprintf(ls_active, sizeof ls_active, "unknown");
                }
            }
            ls_last_show = mono;
        }

        long long avr_irq = avr_irq_count();

        long long led_sum, led_hash;
        led_frame(frame_attr, &led_sum, &led_hash);
        int led_changed = (prev_led_hash < 0 || led_hash != prev_led_hash) ? 1 : 0;
        prev_led_hash = led_hash;
        if (nq_alive && !led_changed)
            led_stall++;
        else
            led_stall = 0;

        if (tickn % dmesg_every == 0 || derr_cache < 0) {
            long long c = kmsg_error_count();
            if (c >= 0)
                derr_cache = c;
        }
        long long derr = derr_cache < 0 ? 0 : derr_cache;
        long long derr_new = (prev_derr < 0 || derr < prev_derr) ? 0 : derr - prev_derr;
        prev_derr = derr;

        long pstore = pstore_count();

        char loadbuf[128];
        slurp_line("/proc/loadavg", loadbuf, sizeof loadbuf, "0");
        char *sp = strchr(loadbuf, ' ');
        if (sp)
            *sp = '\0';

        long long memav = 0;
        {
            FILE *f = fopen("/proc/meminfo", "re");
            if (f) {
                char line[256];
                while (fgets(line, sizeof line, f))
                    if (!strncmp(line, "MemAvailable:", 13)) {
                        memav = strtoll(line + 13, NULL, 10);
                        break;
                    }
                fclose(f);
            }
        }

        /* --- the sample. Schema frozen: nexusq-mqtt, HA and the app read it. */
        char nqa[64], lsa[64], gv[64];
        jstr(nq_active, nqa, sizeof nqa);
        jstr(ls_active, lsa, sizeof lsa);
        jstr(gov, gv, sizeof gv);

        FILE *dst = stdout;
        if (!once) {
            if (tickn % 12 == 0)
                rotate_if_big(&out);
            if (!out)
                out = fopen(logpath, "ae");
            dst = out ? out : stdout;
        }
        fprintf(dst,
                "{\"t_mono\":%lld,\"wall\":\"%s\",\"gov\":\"%s\",\"freq\":%lld,"
                "\"opp_ms\":%s,\"opp_trans\":%lld,\"temp_mC\":%lld,\"cool\":%lld,"
                "\"vdd_uV\":%lld,\"vdd_exp_uV\":%lld,\"vdd_mismatch\":%d,\"abb_uV\":%lld,"
                "\"nq_active\":\"%s\",\"nq_pid\":%ld,\"nq_alive\":%d,\"nq_state\":\"%s\","
                "\"nq_resp\":%d,\"nq_progress\":%d,\"nq_restarts\":%ld,"
                "\"ls_active\":\"%s\",\"ls_restarts\":%ld,\"avr_irq\":%lld,"
                "\"led_sum\":%lld,\"led_changed\":%d,\"led_stall\":%lld,"
                "\"dmesg_err\":%lld,\"dmesg_err_new\":%lld,\"pstore\":%ld,"
                "\"load1\":%s,\"mem_avail_kB\":%lld}\n",
                mono, wall, gv, freq, opp_ms, opp_trans, temp, cool,
                vdd, vexp, vmismatch, abb,
                nqa, nq_pid, nq_alive, nq_state, nq_resp, nq_progress, nq_restarts,
                lsa, ls_restarts, avr_irq,
                led_sum, led_changed, led_stall,
                derr, derr_new, pstore, loadbuf, memav);
        fflush(dst);

        if (once)
            return 0;

        /* --- anomaly events: on transition/threshold, never every sample --- */
        if (nq_alive && !nq_resp && prev_nq_resp)
            emit_event(ev, mono, "crit", "nexusqd_hang",
                       "nexusqd PID %ld alive but control socket unresponsive (state=%s, progress=%d)",
                       nq_pid, nq_state, nq_progress);
        prev_nq_resp = nq_resp;

        if (led_stall >= 6) {
            /* The distress co-signal decides crit vs info: a locked/blanked ring
             * re-commits identical bytes by design, so a stalled frame alone is
             * NOT a fault. */
            if (!nq_resp || !nq_progress)
                emit_event(ev, mono, "crit", "led_frozen",
                           "LED frame unchanged for %lld samples with distressed nexusqd (resp=%d progress=%d) - ring/AVR/nexusqd hang",
                           led_stall, nq_resp, nq_progress);
            else if (led_stall % 60 == 0)
                emit_event(ev, mono, "info", "led_static",
                           "LED frame unchanged for %lld samples, nexusqd healthy (resp=1) - screensaver/blanked",
                           led_stall);
        }
        if (vmismatch)
            emit_event(ev, mono, "warn", "vdd_mismatch",
                       "vdd_mpu %lld uV vs expected %lld uV at %lld kHz", vdd, vexp, freq);
        if (prev_pstore >= 0 && pstore > prev_pstore)
            emit_event(ev, mono, "crit", "pstore_new",
                       "%ld new crash dump(s) in " PSTORE, pstore - prev_pstore);
        prev_pstore = pstore;
        if (derr_new > 0)
            emit_event(ev, mono, "warn", "dmesg_err",
                       "%lld new kernel error line(s)", derr_new);

        tickn++;
        struct timespec sl = { .tv_sec = interval_s, .tv_nsec = 0 };
        nanosleep(&sl, NULL);
    }
}
