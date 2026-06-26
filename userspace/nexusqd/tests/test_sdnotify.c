/* userspace/nexusqd/tests/test_sdnotify.c */
#define _GNU_SOURCE
#include "test.h"
#include "sdnotify.h"

#include <string.h>
#include <stdlib.h>
#include <unistd.h>
#include <stddef.h>
#include <stdio.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <sys/time.h>

/* Bind a DGRAM AF_UNIX socket the way systemd's notify socket would exist.
 * abstract!=0 => Linux abstract namespace (leading NUL), matching a "@name". */
static int make_sock(const char *name, int abstract)
{
    int fd = socket(AF_UNIX, SOCK_DGRAM, 0);
    CHECK(fd >= 0);
    struct sockaddr_un sa;
    memset(&sa, 0, sizeof sa);
    sa.sun_family = AF_UNIX;
    socklen_t len;
    if (abstract) {
        sa.sun_path[0] = '\0';
        strcpy(sa.sun_path + 1, name);
        len = (socklen_t)(offsetof(struct sockaddr_un, sun_path) + 1 + strlen(name));
    } else {
        unlink(name);
        strcpy(sa.sun_path, name);
        len = (socklen_t)(offsetof(struct sockaddr_un, sun_path) + strlen(name) + 1);
    }
    CHECK(bind(fd, (struct sockaddr *)&sa, len) == 0);
    /* never let a missed datagram hang the test run */
    struct timeval tv = { 2, 0 };
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof tv);
    return fd;
}

static int recv_eq(int fd, const char *want)
{
    char buf[128];
    ssize_t r = recv(fd, buf, sizeof buf - 1, 0);
    if (r < 0) return 0;
    buf[r] = '\0';
    return strcmp(buf, want) == 0;
}

/* No NOTIFY_SOCKET => must be a harmless no-op (manual / non-systemd runs). */
static void test_noenv(void)
{
    unsetenv("NOTIFY_SOCKET");
    sdnotify_send("WATCHDOG=1");
    CHECK(1);   /* reached here without crashing */
}

/* Filesystem socket path. */
static void test_fs(void)
{
    char path[80];
    snprintf(path, sizeof path, "/tmp/nqd-sdnotify-%d.sock", (int)getpid());
    int fd = make_sock(path, 0);
    setenv("NOTIFY_SOCKET", path, 1);

    sdnotify_send("READY=1");
    CHECK(recv_eq(fd, "READY=1"));
    sdnotify_send("WATCHDOG=1");
    CHECK(recv_eq(fd, "WATCHDOG=1"));

    close(fd);
    unlink(path);
}

/* Abstract socket ("@name") — the form systemd usually hands out. */
static void test_abstract(void)
{
    char name[64];
    snprintf(name, sizeof name, "nqd-sdnotify-abs-%d", (int)getpid());
    int fd = make_sock(name, 1);
    char env[80];
    snprintf(env, sizeof env, "@%s", name);
    setenv("NOTIFY_SOCKET", env, 1);

    sdnotify_send("WATCHDOG=1");
    CHECK(recv_eq(fd, "WATCHDOG=1"));

    close(fd);
}

/* Empty / NULL state must not send anything (and must not crash). */
static void test_empty_state(void)
{
    char path[80];
    snprintf(path, sizeof path, "/tmp/nqd-sdnotify-e-%d.sock", (int)getpid());
    int fd = make_sock(path, 0);
    setenv("NOTIFY_SOCKET", path, 1);
    sdnotify_send("");
    sdnotify_send(NULL);
    /* nothing should have arrived within the 2s timeout */
    char buf[16];
    CHECK(recv(fd, buf, sizeof buf, 0) < 0);
    close(fd);
    unlink(path);
}

int main(void)
{
    RUN(test_noenv);
    RUN(test_fs);
    RUN(test_abstract);
    RUN(test_empty_state);
    return REPORT();
}
