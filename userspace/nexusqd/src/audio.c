/* userspace/nexusqd/src/audio.c */
#define _POSIX_C_SOURCE 200809L
#include "audio.h"
#include <unistd.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <signal.h>
#include <string.h>

float audio_mean_abs(const int16_t *samples, int n) {
    if (n <= 0) return 0.0f;
    double acc = 0.0;
    for (int i = 0; i < n; i++) {
        int v = samples[i];
        if (v < 0) v = -v;
        acc += v / 32768.0;
    }
    return (float)(acc / n);
}

int audio_open(pid_t *pid) {
    if (pid) *pid = -1;
    int pf[2];
    if (pipe(pf) != 0) return -1;
    pid_t p = fork();
    if (p < 0) { close(pf[0]); close(pf[1]); return -1; }
    if (p == 0) {
        /* child: arecord raw S16_LE PCM -> pipe */
        dup2(pf[1], STDOUT_FILENO);
        close(pf[0]); close(pf[1]);
        int dn = open("/dev/null", O_WRONLY);
        if (dn >= 0) { dup2(dn, STDERR_FILENO); close(dn); }
        char rate[16]; snprintf(rate, sizeof rate, "%d", AUDIO_RATE);
        char ch[8];    snprintf(ch,   sizeof ch,   "%d", AUDIO_CHANNELS);
        execlp("arecord", "arecord", "-D", AUDIO_DEVICE, "-f", "S16_LE",
               "-c", ch, "-r", rate, "-t", "raw", "-q", (char *)NULL);
        _exit(127);   /* exec failed */
    }
    close(pf[1]);
    fcntl(pf[0], F_SETFL, O_NONBLOCK);
    /* CLOEXEC: a later child (the long-lived `pactl subscribe`) must not inherit
     * this read end. audio_close() relies on closing it to SIGPIPE arecord as its
     * backstop; a second holder keeps the pipe open and arecord would survive a
     * raced SIGTERM, capturing forever and pinning the sink out of suspend. */
    fcntl(pf[0], F_SETFD, FD_CLOEXEC);
    if (pid) *pid = p;
    return pf[0];
}

void audio_close(int *fd, pid_t *pid) {
    /* SIGTERM first for a deterministic exit, then close the read end as a
     * backstop (arecord dies on its next write via SIGPIPE if the signal raced).
     * The daemon sets signal(SIGCHLD, SIG_IGN), so the child is auto-reaped —
     * only call this while the child is believed alive (the caller uses the
     * EOF/HUP path for an already-exited child) so we never SIGTERM a reused pid. */
    if (pid && *pid > 0) { kill(*pid, SIGTERM); *pid = -1; }
    if (fd  && *fd >= 0) { close(*fd); *fd = -1; }
}

int pa_sink_inputs_active(void) {
    /* Count PA playback streams that are actually FEEDING the sink — that is,
     * sink-inputs which are not corked. If pactl is missing or PulseAudio is
     * down it prints nothing and exits non-zero, so we see 0 — treated (safely)
     * as "no streams". SIGCHLD is SIG_IGN in the daemon, so the child is
     * auto-reaped; we just read to EOF and close.
     *
     * Why not the cheaper `list short` line count it used to be: a CORKED input
     * still appears there. The USB-audio idle fix (nq-uac2-silence) suspends the
     * PA source when the host streams silence, PulseAudio corks module-loopback's
     * sink-input in response, and the sink drops to IDLE — but the old count
     * still saw one input, kept this tap running, and the tap is precisely what
     * holds the sink out of suspend-on-idle. Result: 1.60 % of a core and an
     * amplifier that never powered down. Counting only uncorked inputs closes
     * that, and does the same for any paused stream.
     *
     * `list sink-inputs` (verbose) is the only listing that carries the state, so
     * this counts "Corked: no" occurrences and streams the output rather than
     * buffering it: the verbose form is ~1 KB per input, and a fixed buffer that
     * silently truncated would UNDERCOUNT and switch the visualizer off during
     * real playback. LC_ALL=C keeps the field name untranslated. */
    int pf[2];
    if (pipe(pf) != 0) return 0;
    pid_t p = fork();
    if (p < 0) { close(pf[0]); close(pf[1]); return 0; }
    if (p == 0) {
        dup2(pf[1], STDOUT_FILENO);
        close(pf[0]); close(pf[1]);
        int dn = open("/dev/null", O_WRONLY);
        if (dn >= 0) { dup2(dn, STDERR_FILENO); close(dn); }
        setenv("LC_ALL", "C", 1);   /* keep pactl's output untranslated */
        execlp("pactl", "pactl", "list", "sink-inputs", (char *)NULL);
        _exit(127);
    }
    close(pf[1]);

    struct pa_cork_scan sc;
    pa_cork_scan_init(&sc);
    char buf[4096];
    ssize_t n;
    while ((n = read(pf[0], buf, sizeof buf)) > 0)
        pa_cork_scan_feed(&sc, buf, (size_t)n);
    close(pf[0]);
    return sc.count;
}

/* Streaming "Corked: no" counter. Split out from the fork/exec above so the
 * boundary handling is testable: the verbose listing arrives in arbitrary read
 * chunks, and a needle straddling two of them must still be counted exactly
 * once. Getting that wrong UNDERCOUNTS, which switches the visualizer off
 * during real playback -- a silent, intermittent fault. */
static void count_hit(struct pa_cork_scan *s) { s->count++; }

void pa_cork_scan_init(struct pa_cork_scan *s) {
    s->clen = 0;
    s->count = 0;
}

void pa_cork_scan_feed(struct pa_cork_scan *s, const char *buf, size_t n) {
    static const char NEEDLE[] = "Corked: no";
    const size_t nlen = sizeof(NEEDLE) - 1;
    while (n > 0) {
        /* Work a window at a time: whatever was carried over, plus as much of
         * this chunk as fits. */
        size_t room = PA_CORK_WIN - s->clen;
        size_t take = n < room ? n : room;
        char win[PA_CORK_WIN];
        size_t wlen = s->clen;
        if (wlen) memcpy(win, s->carry, wlen);
        memcpy(win + wlen, buf, take);
        wlen += take;
        for (size_t i = 0; i + nlen <= wlen; ) {
            if (memcmp(win + i, NEEDLE, nlen) == 0) { count_hit(s); i += nlen; }
            else i++;
        }
        s->clen = wlen < nlen - 1 ? wlen : nlen - 1;
        memcpy(s->carry, win + wlen - s->clen, s->clen);
        buf += take;
        n -= take;
    }
}

int pa_subscribe_open(pid_t *pid) {
    /* Same spawn shape as audio_open(): stdout -> non-blocking pipe, stderr ->
     * /dev/null, child auto-reaped via the daemon's SIGCHLD=SIG_IGN. `pactl
     * subscribe` prints one line per PA event and otherwise sleeps in the PA
     * socket — a subscription is not a stream, so it does NOT hold any sink out
     * of suspend. If PulseAudio is down the child exits at once; the caller sees
     * EOF/HUP and falls back to timed polling until a respawn sticks. */
    if (pid) *pid = -1;
    int pf[2];
    if (pipe(pf) != 0) return -1;
    pid_t p = fork();
    if (p < 0) { close(pf[0]); close(pf[1]); return -1; }
    if (p == 0) {
        dup2(pf[1], STDOUT_FILENO);
        close(pf[0]); close(pf[1]);
        int dn = open("/dev/null", O_WRONLY);
        if (dn >= 0) { dup2(dn, STDERR_FILENO); close(dn); }
        /* The caller matches pactl's English event wrapper ("Event 'new' on
         * sink-input #N"). The facility and type tokens are untranslated
         * literals, but the surrounding format string IS in pactl's gettext
         * catalog — a locale leaking into the daemon's environment would drop
         * the word "on" and silently kill every match, degrading the gate to
         * its safety net with no error anywhere. Pin C for the child. */
        setenv("LC_ALL", "C", 1);
        execlp("pactl", "pactl", "subscribe", (char *)NULL);
        _exit(127);
    }
    close(pf[1]);
    fcntl(pf[0], F_SETFL, O_NONBLOCK);
    fcntl(pf[0], F_SETFD, FD_CLOEXEC);   /* see audio_open() */
    if (pid) *pid = p;
    return pf[0];
}
