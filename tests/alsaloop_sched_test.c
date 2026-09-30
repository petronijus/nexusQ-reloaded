/* tests/alsaloop_sched_test.c: alsaloop's setscheduler() as patched by
 * pmos/alsa-utils/0001, against a fake pthread scheduling API.
 * tests/test_alsaloop_sched.py extracts the function into setscheduler.inc. */
#define _GNU_SOURCE
#include <errno.h>
#include <pthread.h>
#include <sched.h>
#include <stdio.h>
#include <string.h>
#include <syslog.h>

static int fails;
#define CHECK(c) do { if (!(c)) { fails++; printf("  FAIL %s:%d: %s\n", __FILE__, __LINE__, #c); } } while (0)

static int verbose;
static int n_log;
static char last_log[256];
#define logit(prio, ...) do { (void)(prio); n_log++; snprintf(last_log, sizeof(last_log), __VA_ARGS__); } while (0)

static struct { int policy, prio, get_err, set_err; } thread_now;
static int set_calls, set_policy, set_prio;

static int fake_getschedparam(pthread_t t, int *policy, struct sched_param *p)
{
	(void)t;
	if (thread_now.get_err)
		return thread_now.get_err;
	*policy = thread_now.policy;
	p->sched_priority = thread_now.prio;
	return 0;
}

static int fake_setschedparam(pthread_t t, int policy, const struct sched_param *p)
{
	(void)t;
	set_calls++;
	set_policy = policy;
	set_prio = p->sched_priority;
	return thread_now.set_err;
}

#define pthread_getschedparam fake_getschedparam
#define pthread_setschedparam fake_setschedparam
#include "setscheduler.inc"

static void start(int policy, int prio)
{
	memset(&thread_now, 0, sizeof(thread_now));
	thread_now.policy = policy;
	thread_now.prio = prio;
	set_calls = n_log = verbose = 0;
	last_log[0] = 0;
}

int main(void)
{
	/* nexusq-uac2-in: chrt -f 10. The thread keeps FIFO 10, silently. */
	start(SCHED_FIFO, 10);
	setscheduler();
	CHECK(set_calls == 0);
	CHECK(n_log == 0);

	start(SCHED_RR, 5);
	setscheduler();
	CHECK(set_calls == 0);

#ifdef SCHED_RESET_ON_FORK
	/* chrt -R: the kernel reports the flag in the policy */
	start(SCHED_FIFO | SCHED_RESET_ON_FORK, 10);
	setscheduler();
	CHECK(set_calls == 0);
#endif

	/* verbose says what it kept */
	start(SCHED_FIFO, 10);
	verbose = 1;
	setscheduler();
	CHECK(set_calls == 0);
	CHECK(n_log == 1 && strstr(last_log, "keeping") && strstr(last_log, "FIFO") && strstr(last_log, "10"));

	/* an ordinary thread asks for Round Robin at the top, as upstream always did */
	start(SCHED_OTHER, 0);
	setscheduler();
	CHECK(set_calls == 1 && set_policy == SCHED_RR && set_prio == sched_get_priority_max(SCHED_RR));
	CHECK(n_log == 0);

	/* denied (no RLIMIT_RTPRIO): quiet unless verbose, as upstream */
	start(SCHED_OTHER, 0);
	thread_now.set_err = EPERM;
	setscheduler();
	CHECK(set_calls == 1 && n_log == 0);

	/* the read itself failing is still a warning, now with the reason */
	start(SCHED_OTHER, 0);
	thread_now.get_err = ESRCH;
	setscheduler();
	CHECK(set_calls == 0);
	CHECK(n_log == 1 && strstr(last_log, "getparam failed") && strstr(last_log, strerror(ESRCH)));

	printf(fails ? "FAILED (%d)\n" : "OK\n", fails);
	return fails != 0;
}
