/*
 * alsaloop's poll loop (alsa-utils alsaloop/pcmjob.c, with every patch in
 * pmos/alsa-utils applied) against a capture that stops delivering without
 * stopping: what a UAC2 gadget does when its USB host stops sending.
 *
 * tests/test_alsaloop_stall.py builds this together with the patched pcmjob.c
 * and tests/fake-alsa/alsa/asoundlib.h. This file implements that header: two
 * simulated PCMs on a simulated clock, and a poll() that advances the clock to
 * the first fd that becomes ready or to the timeout - so a pass that returns
 * at once is seen as one that takes no time, which is what a busy loop is.
 *
 * The loop is driven exactly as alsaloop.c's thread_job1() drives it:
 * pcmjob_pollfds_init(), poll() with the loop's timeout, pcmjob_pollfds_handle().
 *
 *   1. the host streams for 1 s: everything captured reaches the playback,
 *      with no playback XRUN and no busy loop;
 *   2. the host stops for 10 s, the capture stays RUNNING with nothing to read:
 *      the loop must sleep (a handful of passes, none of them back to back by
 *      the thousand) and must not touch the playback, which runs dry;
 *   3. the host streams again for 1 s: the playback is recovered once, back to
 *      the target latency, and fed without underrunning again.
 *
 * Exit 0 when all hold; otherwise every failed check is printed.
 */
#include <alsa/asoundlib.h>

#include <limits.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>

#include "alsaloop.h"

#define RATE 48000U
#define CHANNELS 2U
#define FRAME_BYTES 4U
#define BUFFER 3840U /* 80 ms, as nexusq-uac2-in's -t 80000 */
#define PERIOD 960U  /* 20 ms */
#define LATENCY 1920U
#define PLAY_FD 10
#define CAPT_FD 11
#define FOREVER ULLONG_MAX

/* Referenced by pcmjob.c, defined by alsaloop.c and control.c in the real program. */
int verbose;
int workarounds;
int use_syslog;

int pcmjob_poll_timeout(struct loopback *loop) __attribute__((weak));

static unsigned long long now_us;
static int host_streaming;
static int failures;

struct _snd_pcm {
	int fd;
	int capture;
	snd_pcm_state_t state;
	snd_pcm_uframes_t avail_min;
	snd_pcm_uframes_t filled; /* playback: queued; capture: ready to read */
	unsigned long long moved; /* frames read or written by alsaloop */
	unsigned int prepares, starts;
};

static struct _snd_pcm play_pcm = { .fd = PLAY_FD, .capture = 0 };
static struct _snd_pcm capt_pcm = { .fd = CAPT_FD, .capture = 1 };

#define CHECK(cond, ...)                                    \
	do {                                                \
		if (!(cond)) {                              \
			failures++;                         \
			printf("FAIL %s:%d: ", __FILE__, __LINE__); \
			printf(__VA_ARGS__);                \
			printf("\n");                       \
		}                                           \
	} while (0)

static __attribute__((noreturn)) void unmodelled(const char *name)
{
	printf("FAIL the poll loop called %s(), which this test does not model\n", name);
	exit(2);
}

/* ---- the simulated clock ---------------------------------------------- */

static unsigned long long frames_at(unsigned long long us)
{
	return us * RATE / 1000000ULL;
}

/* The first instant at which `frames` more frames have elapsed. */
static unsigned long long time_after_frames(unsigned long long frames)
{
	unsigned long long target = frames_at(now_us) + frames;

	return (target * 1000000ULL + RATE - 1) / RATE;
}

static void advance_to(unsigned long long t)
{
	unsigned long long frames = frames_at(t) - frames_at(now_us);

	now_us = t;
	if (capt_pcm.state == SND_PCM_STATE_RUNNING && host_streaming) {
		capt_pcm.filled += frames;
		if (capt_pcm.filled > BUFFER) {
			capt_pcm.filled = BUFFER;
			capt_pcm.state = SND_PCM_STATE_XRUN;
		}
	}
	if (play_pcm.state == SND_PCM_STATE_RUNNING) {
		if (play_pcm.filled > frames) {
			play_pcm.filled -= frames;
		} else {
			play_pcm.filled = 0;
			play_pcm.state = SND_PCM_STATE_XRUN; /* stop_threshold = buffer_size */
		}
	}
}

static unsigned short ready(const struct _snd_pcm *p)
{
	if (p->state == SND_PCM_STATE_XRUN)
		return POLLERR | (p->capture ? POLLIN : POLLOUT);
	if (p->capture)
		return p->state == SND_PCM_STATE_RUNNING && p->filled >= p->avail_min ? POLLIN : 0;
	if (p->state == SND_PCM_STATE_RUNNING || p->state == SND_PCM_STATE_PREPARED)
		return BUFFER - p->filled >= p->avail_min ? POLLOUT : 0;
	return 0;
}

static unsigned long long when_ready(const struct _snd_pcm *p)
{
	if (ready(p))
		return now_us;
	if (p->state != SND_PCM_STATE_RUNNING)
		return FOREVER;
	if (p->capture)
		return host_streaming ? time_after_frames(p->avail_min - p->filled) : FOREVER;
	return time_after_frames(p->filled - (BUFFER - p->avail_min));
}

static struct _snd_pcm *pcm_of(int fd)
{
	return fd == PLAY_FD ? &play_pcm : fd == CAPT_FD ? &capt_pcm : NULL;
}

/*
 * poll() on the simulated PCMs. Returns 0 when it reached `end` with nothing
 * ready and no timeout: the caller would have blocked for good.
 */
static int fake_poll(struct pollfd *fds, int n, int timeout_ms, unsigned long long end)
{
	unsigned long long t = FOREVER;
	int i;

	for (i = 0; i < n; i++) {
		struct _snd_pcm *p = pcm_of(fds[i].fd);
		unsigned long long w;

		if (!p)
			unmodelled("poll on an unknown fd");
		w = when_ready(p);
		if (w < t)
			t = w;
	}
	if (timeout_ms >= 0 && now_us + (unsigned long long)timeout_ms * 1000ULL < t)
		t = now_us + (unsigned long long)timeout_ms * 1000ULL;
	if (t > end) {
		advance_to(end);
		if (timeout_ms < 0)
			return 0;
	} else {
		advance_to(t);
	}
	for (i = 0; i < n; i++)
		fds[i].revents = ready(pcm_of(fds[i].fd)) & (fds[i].events | POLLERR | POLLHUP);
	return 1;
}

/* ---- the modelled alsa-lib calls ---------------------------------------- */

const char *snd_strerror(int errnum)
{
	return strerror(errnum < 0 ? -errnum : errnum);
}

int snd_output_printf(snd_output_t *output, const char *format, ...)
{
	(void)output;
	(void)format;
	return 0;
}

int snd_pcm_poll_descriptors_count(snd_pcm_t *pcm)
{
	(void)pcm;
	return 1;
}

int snd_pcm_poll_descriptors(snd_pcm_t *pcm, struct pollfd *pfds, unsigned int space)
{
	if (space < 1)
		return 0;
	pfds[0].fd = pcm->fd;
	pfds[0].events = pcm->capture ? POLLIN : POLLOUT;
	pfds[0].revents = 0;
	return 1;
}

int snd_pcm_poll_descriptors_revents(snd_pcm_t *pcm, struct pollfd *pfds, unsigned int nfds,
				     unsigned short *revents)
{
	if (nfds != 1 || pfds[0].fd != pcm->fd) {
		printf("FAIL revents asked for fd %d of the PCM that polls on fd %d\n",
		       nfds ? pfds[0].fd : -1, pcm->fd);
		exit(2);
	}
	*revents = pfds[0].revents;
	return 0;
}

snd_pcm_state_t snd_pcm_state(snd_pcm_t *pcm)
{
	return pcm->state;
}

snd_pcm_sframes_t snd_pcm_avail_update(snd_pcm_t *pcm)
{
	if (pcm->state == SND_PCM_STATE_XRUN)
		return -EPIPE;
	return pcm->capture ? (snd_pcm_sframes_t)pcm->filled : (snd_pcm_sframes_t)(BUFFER - pcm->filled);
}

int snd_pcm_delay(snd_pcm_t *pcm, snd_pcm_sframes_t *delayp)
{
	if (pcm->state == SND_PCM_STATE_XRUN)
		return -EPIPE;
	*delayp = (snd_pcm_sframes_t)pcm->filled;
	return 0;
}

int snd_pcm_prepare(snd_pcm_t *pcm)
{
	pcm->prepares++;
	pcm->state = SND_PCM_STATE_PREPARED;
	pcm->filled = 0;
	return 0;
}

int snd_pcm_start(snd_pcm_t *pcm)
{
	if (pcm->state != SND_PCM_STATE_PREPARED)
		return -EBADFD;
	pcm->starts++;
	pcm->state = SND_PCM_STATE_RUNNING;
	return 0;
}

int snd_pcm_drop(snd_pcm_t *pcm)
{
	pcm->state = SND_PCM_STATE_SETUP;
	pcm->filled = 0;
	return 0;
}

int snd_pcm_resume(snd_pcm_t *pcm)
{
	(void)pcm;
	return -ENOSYS;
}

snd_pcm_sframes_t snd_pcm_readi(snd_pcm_t *pcm, void *buffer, snd_pcm_uframes_t size)
{
	snd_pcm_uframes_t n;

	if (!pcm->capture)
		unmodelled("snd_pcm_readi on the playback");
	if (pcm->state == SND_PCM_STATE_XRUN)
		return -EPIPE;
	n = size < pcm->filled ? size : pcm->filled;
	if (n == 0)
		return -EAGAIN; /* SND_PCM_NONBLOCK */
	memset(buffer, 0x5a, n * FRAME_BYTES);
	pcm->filled -= n;
	pcm->moved += n;
	return (snd_pcm_sframes_t)n;
}

snd_pcm_sframes_t snd_pcm_writei(snd_pcm_t *pcm, const void *buffer, snd_pcm_uframes_t size)
{
	snd_pcm_uframes_t n;

	(void)buffer;
	if (pcm->capture)
		unmodelled("snd_pcm_writei on the capture");
	if (pcm->state == SND_PCM_STATE_XRUN)
		return -EPIPE;
	n = BUFFER - pcm->filled;
	if (n > size)
		n = size;
	if (n == 0)
		return -EAGAIN;
	pcm->filled += n;
	pcm->moved += n;
	return (snd_pcm_sframes_t)n;
}

int snd_pcm_format_set_silence(snd_pcm_format_t format, void *buf, unsigned int samples)
{
	(void)format;
	memset(buf, 0, samples * (FRAME_BYTES / CHANNELS));
	return 0;
}

int snd_pcm_sw_params_current(snd_pcm_t *pcm, snd_pcm_sw_params_t *params)
{
	params->avail_min = pcm->avail_min;
	return 0;
}

int snd_pcm_sw_params_set_avail_min(snd_pcm_t *pcm, snd_pcm_sw_params_t *params, snd_pcm_uframes_t val)
{
	(void)pcm;
	params->avail_min = val;
	return 0;
}

int snd_pcm_sw_params_get_avail_min(const snd_pcm_sw_params_t *params, snd_pcm_uframes_t *val)
{
	*val = params->avail_min;
	return 0;
}

int snd_pcm_sw_params(snd_pcm_t *pcm, snd_pcm_sw_params_t *params)
{
	pcm->avail_min = params->avail_min;
	return 0;
}

/* ---- the rest of the API: never reached from the poll loop ------------- */

#define UNMODELLED(ret, name, ...) \
	ret name(__VA_ARGS__)      \
	{                          \
		unmodelled(#name); \
	}

UNMODELLED(int, snd_pcm_open, snd_pcm_t **a, const char *b, snd_pcm_stream_t c, int d)
UNMODELLED(int, snd_pcm_close, snd_pcm_t *a)
UNMODELLED(int, snd_pcm_info, snd_pcm_t *a, snd_pcm_info_t *b)
UNMODELLED(int, snd_pcm_info_malloc, snd_pcm_info_t **a)
UNMODELLED(void, snd_pcm_info_free, snd_pcm_info_t *a)
UNMODELLED(int, snd_pcm_info_get_card, const snd_pcm_info_t *a)
UNMODELLED(unsigned int, snd_pcm_info_get_device, const snd_pcm_info_t *a)
UNMODELLED(unsigned int, snd_pcm_info_get_subdevice, const snd_pcm_info_t *a)
UNMODELLED(int, snd_pcm_link, snd_pcm_t *a, snd_pcm_t *b)
UNMODELLED(int, snd_pcm_dump, snd_pcm_t *a, snd_output_t *b)
UNMODELLED(const char *, snd_pcm_access_name, const snd_pcm_access_t a)
UNMODELLED(const char *, snd_pcm_format_name, const snd_pcm_format_t a)
UNMODELLED(int, snd_pcm_format_width, snd_pcm_format_t a)
UNMODELLED(int, snd_pcm_format_physical_width, snd_pcm_format_t a)
UNMODELLED(int, snd_pcm_hw_free, snd_pcm_t *a)
UNMODELLED(int, snd_pcm_hw_params, snd_pcm_t *a, snd_pcm_hw_params_t *b)
UNMODELLED(int, snd_pcm_hw_params_any, snd_pcm_t *a, snd_pcm_hw_params_t *b)
UNMODELLED(void, snd_pcm_hw_params_copy, snd_pcm_hw_params_t *a, const snd_pcm_hw_params_t *b)
UNMODELLED(int, snd_pcm_hw_params_get_buffer_size, const snd_pcm_hw_params_t *a, snd_pcm_uframes_t *b)
UNMODELLED(int, snd_pcm_hw_params_get_period_size, const snd_pcm_hw_params_t *a, snd_pcm_uframes_t *b, int *c)
UNMODELLED(int, snd_pcm_hw_params_get_rate, const snd_pcm_hw_params_t *a, unsigned int *b, int *c)
UNMODELLED(int, snd_pcm_hw_params_set_access, snd_pcm_t *a, snd_pcm_hw_params_t *b, snd_pcm_access_t c)
UNMODELLED(int, snd_pcm_hw_params_set_buffer_size_near, snd_pcm_t *a, snd_pcm_hw_params_t *b, snd_pcm_uframes_t *c)
UNMODELLED(int, snd_pcm_hw_params_set_channels, snd_pcm_t *a, snd_pcm_hw_params_t *b, unsigned int c)
UNMODELLED(int, snd_pcm_hw_params_set_format, snd_pcm_t *a, snd_pcm_hw_params_t *b, snd_pcm_format_t c)
UNMODELLED(int, snd_pcm_hw_params_set_period_size_near, snd_pcm_t *a, snd_pcm_hw_params_t *b, snd_pcm_uframes_t *c,
	   int *d)
UNMODELLED(int, snd_pcm_hw_params_set_rate_near, snd_pcm_t *a, snd_pcm_hw_params_t *b, unsigned int *c, int *d)
UNMODELLED(int, snd_pcm_hw_params_set_rate_resample, snd_pcm_t *a, snd_pcm_hw_params_t *b, unsigned int c)
UNMODELLED(int, snd_pcm_sw_params_set_start_threshold, snd_pcm_t *a, snd_pcm_sw_params_t *b, snd_pcm_uframes_t c)
UNMODELLED(int, snd_ctl_open, snd_ctl_t **a, const char *b, int c)
UNMODELLED(int, snd_ctl_close, snd_ctl_t *a)
UNMODELLED(const char *, snd_ctl_name, snd_ctl_t *a)
UNMODELLED(int, snd_ctl_subscribe_events, snd_ctl_t *a, int b)
UNMODELLED(int, snd_ctl_read, snd_ctl_t *a, snd_ctl_event_t *b)
UNMODELLED(int, snd_ctl_poll_descriptors_count, snd_ctl_t *a)
UNMODELLED(int, snd_ctl_poll_descriptors, snd_ctl_t *a, struct pollfd *b, unsigned int c)
UNMODELLED(int, snd_ctl_poll_descriptors_revents, snd_ctl_t *a, struct pollfd *b, unsigned int c, unsigned short *d)
UNMODELLED(int, snd_ctl_ascii_elem_id_parse, snd_ctl_elem_id_t *a, const char *b)
UNMODELLED(unsigned int, snd_ctl_elem_id_get_device, const snd_ctl_elem_id_t *a)
UNMODELLED(const char *, snd_ctl_elem_id_get_name, const snd_ctl_elem_id_t *a)
UNMODELLED(unsigned int, snd_ctl_elem_id_get_subdevice, const snd_ctl_elem_id_t *a)
UNMODELLED(void, snd_ctl_elem_id_set_device, snd_ctl_elem_id_t *a, unsigned int b)
UNMODELLED(void, snd_ctl_elem_id_set_name, snd_ctl_elem_id_t *a, const char *b)
UNMODELLED(void, snd_ctl_elem_id_set_subdevice, snd_ctl_elem_id_t *a, unsigned int b)
UNMODELLED(int, snd_ctl_elem_read, snd_ctl_t *a, snd_ctl_elem_value_t *b)
UNMODELLED(int, snd_ctl_elem_write, snd_ctl_t *a, snd_ctl_elem_value_t *b)
UNMODELLED(int, snd_ctl_elem_value_malloc, snd_ctl_elem_value_t **a)
UNMODELLED(void, snd_ctl_elem_value_free, snd_ctl_elem_value_t *a)
UNMODELLED(void, snd_ctl_elem_value_get_id, const snd_ctl_elem_value_t *a, snd_ctl_elem_id_t *b)
UNMODELLED(void, snd_ctl_elem_value_set_id, snd_ctl_elem_value_t *a, const snd_ctl_elem_id_t *b)
UNMODELLED(void, snd_ctl_elem_value_set_interface, snd_ctl_elem_value_t *a, snd_ctl_elem_iface_t b)
UNMODELLED(int, snd_ctl_elem_value_get_boolean, const snd_ctl_elem_value_t *a, unsigned int b)
UNMODELLED(void, snd_ctl_elem_value_set_boolean, snd_ctl_elem_value_t *a, unsigned int b, long c)
UNMODELLED(long, snd_ctl_elem_value_get_integer, const snd_ctl_elem_value_t *a, unsigned int b)
UNMODELLED(void, snd_ctl_elem_value_set_integer, snd_ctl_elem_value_t *a, unsigned int b, long c)
UNMODELLED(void, snd_ctl_event_elem_get_id, const snd_ctl_event_t *a, snd_ctl_elem_id_t *b)
UNMODELLED(unsigned int, snd_ctl_event_elem_get_mask, const snd_ctl_event_t *a)
UNMODELLED(const char *, snd_ctl_event_elem_get_name, const snd_ctl_event_t *a)
UNMODELLED(snd_ctl_event_type_t, snd_ctl_event_get_type, const snd_ctl_event_t *a)
UNMODELLED(int, control_init, struct loopback *a)
UNMODELLED(int, control_done, struct loopback *a)
UNMODELLED(int, control_event, struct loopback_handle *a, snd_ctl_event_t *b)
UNMODELLED(int, control_id_match, snd_ctl_elem_id_t *a, snd_ctl_elem_id_t *b)

/* ---- the driver ---------------------------------------------------------- */

struct phase {
	unsigned long passes;
	unsigned long longest_burst; /* passes in a row that took no time */
	int blocked;                 /* the loop went to sleep with no timeout */
};

/* As thread_job1(), until `end` or until the loop sleeps for good. */
static struct phase run_until(struct loopback *loop, unsigned long long end)
{
	struct phase ph = { 0 };
	struct pollfd fds[4];
	unsigned long burst = 0;

	while (now_us < end) {
		unsigned long long before = now_us;
		int n, timeout;

		n = pcmjob_pollfds_init(loop, fds);
		if (n < 1 || n > 2) {
			printf("FAIL pcmjob_pollfds_init returned %d\n", n);
			exit(2);
		}
		timeout = pcmjob_poll_timeout ? pcmjob_poll_timeout(loop) : -1;
		if (!fake_poll(fds, n, timeout, end)) {
			ph.blocked = 1;
			break;
		}
		if (pcmjob_pollfds_handle(loop, fds) < 0) {
			printf("FAIL pcmjob_pollfds_handle failed\n");
			exit(2);
		}
		ph.passes++;
		burst = now_us == before ? burst + 1 : 0;
		if (burst > ph.longest_burst)
			ph.longest_burst = burst;
		if (burst >= 100000) {
			printf("FAIL busy loop: %lu passes in a row without poll() waiting, at t=%llu ms\n", burst,
			       now_us / 1000);
			ph.passes = ULONG_MAX;
			break;
		}
	}
	return ph;
}

int main(void)
{
	static char buf[2 * BUFFER * FRAME_BYTES];
	struct loopback_handle play = { 0 }, capt = { 0 };
	struct loopback loop = { 0 };
	struct loopback_handle *h[2] = { &play, &capt };
	struct phase ph;
	unsigned long long moved;
	unsigned int prepares, starts;
	int i;

	for (i = 0; i < 2; i++) {
		h[i]->loopback = &loop;
		h[i]->id = i ? "capture" : "playback";
		h[i]->handle = i ? &capt_pcm : &play_pcm;
		h[i]->format = SND_PCM_FORMAT_S16_LE;
		h[i]->rate = RATE;
		h[i]->channels = CHANNELS;
		h[i]->buffer_size = BUFFER;
		h[i]->period_size = PERIOD;
		h[i]->avail_min = PERIOD;
		h[i]->frame_size = FRAME_BYTES;
		h[i]->pollfd_count = 1;
		h[i]->buf = buf; /* one shared buffer, as pcmjob_start() sets it up */
		h[i]->buf_size = 2 * BUFFER;
		h[i]->sync_point = ULONG_MAX;
		h[i]->pitch = 1.0;
	}
	h[0]->handle->avail_min = PERIOD;
	h[1]->handle->avail_min = PERIOD;
	loop.id = "test";
	loop.play = &play;
	loop.capt = &capt;
	loop.latency = LATENCY;
	loop.sync = SYNC_TYPE_SIMPLE;
	loop.slave = SLAVE_TYPE_OFF;
	loop.pitch = 1.0;
	loop.pollfd_count = 2;

	/* What pcmjob_start() leaves: the playback primed with LATENCY of silence. */
	play_pcm.state = SND_PCM_STATE_RUNNING;
	play_pcm.filled = LATENCY;
	capt_pcm.state = SND_PCM_STATE_RUNNING;
	loop.running = 1;
	host_streaming = 1;

	/* 1. streaming */
	ph = run_until(&loop, 1000000);
	CHECK(ph.passes != ULONG_MAX, "streaming: busy loop");
	CHECK(capt_pcm.moved >= RATE - BUFFER, "streaming: only %llu of %u frames captured", capt_pcm.moved, RATE);
	CHECK(play_pcm.moved + BUFFER >= capt_pcm.moved, "streaming: %llu frames captured, only %llu played",
	      capt_pcm.moved, play_pcm.moved);
	CHECK(play_pcm.prepares == 0, "streaming: the playback ran dry %u time(s)", play_pcm.prepares);
	CHECK(ph.passes == ULONG_MAX || ph.passes <= 300, "streaming: %lu passes for 50 capture periods", ph.passes);
	printf("streaming 1 s: %lu passes, longest burst %lu, %llu frames in, %llu out\n", ph.passes,
	       ph.longest_burst, capt_pcm.moved, play_pcm.moved);

	/* 2. the host stops sending; the gadget capture stays RUNNING, frozen */
	host_streaming = 0;
	prepares = play_pcm.prepares;
	starts = play_pcm.starts;
	moved = play_pcm.moved;
	ph = run_until(&loop, 11000000);
	CHECK(ph.passes != ULONG_MAX, "stalled: busy loop");
	CHECK(ph.passes == ULONG_MAX || ph.passes <= 50, "stalled: %lu passes in 10 s with nothing to copy", ph.passes);
	CHECK(play_pcm.prepares == prepares && play_pcm.starts == starts,
	      "stalled: the playback was re-prepared %u time(s) with nothing to play", play_pcm.prepares - prepares);
	CHECK(play_pcm.moved == moved, "stalled: %llu frames written with nothing captured", play_pcm.moved - moved);
	CHECK(play_pcm.state == SND_PCM_STATE_XRUN, "stalled: the playback did not run dry (state %d)",
	      play_pcm.state);
	printf("stalled 10 s: %lu passes, longest burst %lu%s\n", ph.passes, ph.longest_burst,
	       ph.blocked ? ", then asleep" : "");
	if (ph.passes == ULONG_MAX) {
		printf("%d check(s) failed\n", failures);
		return 1;
	}

	/* 3. the host streams again */
	host_streaming = 1;
	starts = play_pcm.starts;
	moved = play_pcm.moved;
	capt_pcm.moved = 0;
	ph = run_until(&loop, 12000000);
	CHECK(ph.passes != ULONG_MAX, "resumed: busy loop");
	CHECK(play_pcm.starts == starts + 1, "resumed: the playback was restarted %u time(s), not once",
	      play_pcm.starts - starts);
	CHECK(play_pcm.state == SND_PCM_STATE_RUNNING, "resumed: the playback is not running (state %d)",
	      play_pcm.state);
	CHECK(play_pcm.moved - moved + BUFFER >= capt_pcm.moved, "resumed: %llu frames captured, only %llu played",
	      capt_pcm.moved, play_pcm.moved - moved);
	CHECK(capt_pcm.moved >= RATE - 2 * BUFFER, "resumed: only %llu frames captured in 1 s", capt_pcm.moved);
	CHECK(ph.passes == ULONG_MAX || ph.passes <= 300, "resumed: %lu passes for 50 capture periods", ph.passes);
	if (pcmjob_poll_timeout)
		CHECK(pcmjob_poll_timeout(&loop) <= (int)(PERIOD * 1000 / RATE),
		      "resumed: the loop still waits on the capture alone (timeout %d ms)",
		      pcmjob_poll_timeout(&loop));
	printf("resumed 1 s: %lu passes, longest burst %lu, %llu frames in, %llu out\n", ph.passes,
	       ph.longest_burst, capt_pcm.moved, play_pcm.moved - moved);

	if (failures)
		printf("%d check(s) failed\n", failures);
	return failures ? 1 : 0;
}
