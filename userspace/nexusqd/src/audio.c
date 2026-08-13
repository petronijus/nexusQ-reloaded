/* userspace/nexusqd/src/audio.c */
#define _POSIX_C_SOURCE 200809L
#include "audio.h"
#include <unistd.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <signal.h>

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
    /* Count PA playback streams without a shell: fork/exec `pactl list short
     * sink-inputs`, read its stdout, count non-empty lines. If pactl is missing
     * or PulseAudio is down it prints nothing on stdout and exits non-zero, so
     * we see 0 lines — treated (safely) as "no streams". SIGCHLD is SIG_IGN in
     * the daemon, so the child is auto-reaped; we just read to EOF and close. */
    int pf[2];
    if (pipe(pf) != 0) return 0;
    pid_t p = fork();
    if (p < 0) { close(pf[0]); close(pf[1]); return 0; }
    if (p == 0) {
        dup2(pf[1], STDOUT_FILENO);
        close(pf[0]); close(pf[1]);
        int dn = open("/dev/null", O_WRONLY);
        if (dn >= 0) { dup2(dn, STDERR_FILENO); close(dn); }
        setenv("LC_ALL", "C", 1);   /* keep pactl's output untranslated (see below) */
        execlp("pactl", "pactl", "list", "short", "sink-inputs", (char *)NULL);
        _exit(127);
    }
    close(pf[1]);
    char buf[8192];
    int total = 0;
    ssize_t n;
    while (total < (int)sizeof buf &&
           (n = read(pf[0], buf + total, sizeof buf - (size_t)total)) > 0)
        total += (int)n;
    close(pf[0]);   /* if output overflowed the buffer, this SIGPIPEs pactl */
    /* count non-empty lines (each sink-input is one line) */
    int count = 0;
    for (int i = 0; i < total; ) {
        int j = i;
        while (j < total && buf[j] != '\n') j++;
        if (j > i) count++;
        i = j + 1;
    }
    return count;
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
