/* userspace/nexusqd/src/audio.c */
#define _POSIX_C_SOURCE 200809L
#include "audio.h"
#include <unistd.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>

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

int audio_open(void) {
    int pf[2];
    if (pipe(pf) != 0) return -1;
    pid_t pid = fork();
    if (pid < 0) { close(pf[0]); close(pf[1]); return -1; }
    if (pid == 0) {
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
    return pf[0];
}
