/*
 * A stand-in for alsa-lib's <alsa/asoundlib.h>, just big enough to compile
 * alsa-utils' alsaloop/pcmjob.c on any host (macOS has no alsa-lib).
 *
 * The prototypes follow alsa-lib 1.2's new hw_params API, the one pcmjob.c is
 * written against. The objects are plain structs instead of opaque handles so
 * that tests/alsaloop_stall_test.c can model a PCM: it defines every function
 * declared here, simulating the few the poll loop reaches and aborting in the
 * rest, so a test that strays into an unmodelled call fails loudly.
 */
#ifndef NQ_FAKE_ASOUNDLIB_H
#define NQ_FAKE_ASOUNDLIB_H

/* What the real header pulls in, and pcmjob.c relies on. */
#include <alloca.h>
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/time.h>
#include <sys/types.h>
#include <unistd.h>

typedef unsigned long snd_pcm_uframes_t;
typedef long snd_pcm_sframes_t;
typedef struct timeval snd_timestamp_t;

typedef enum _snd_pcm_state {
	SND_PCM_STATE_OPEN = 0,
	SND_PCM_STATE_SETUP,
	SND_PCM_STATE_PREPARED,
	SND_PCM_STATE_RUNNING,
	SND_PCM_STATE_XRUN,
	SND_PCM_STATE_DRAINING,
	SND_PCM_STATE_PAUSED,
	SND_PCM_STATE_SUSPENDED,
	SND_PCM_STATE_DISCONNECTED,
} snd_pcm_state_t;

typedef enum _snd_pcm_stream {
	SND_PCM_STREAM_PLAYBACK = 0,
	SND_PCM_STREAM_CAPTURE,
} snd_pcm_stream_t;

typedef enum _snd_pcm_access {
	SND_PCM_ACCESS_MMAP_INTERLEAVED = 0,
	SND_PCM_ACCESS_MMAP_NONINTERLEAVED,
	SND_PCM_ACCESS_MMAP_COMPLEX,
	SND_PCM_ACCESS_RW_INTERLEAVED,
	SND_PCM_ACCESS_RW_NONINTERLEAVED,
} snd_pcm_access_t;

typedef enum _snd_pcm_format {
	SND_PCM_FORMAT_UNKNOWN = -1,
	SND_PCM_FORMAT_S8 = 0,
	SND_PCM_FORMAT_U8,
	SND_PCM_FORMAT_S16_LE,
	SND_PCM_FORMAT_S16_BE,
	SND_PCM_FORMAT_U16_LE,
	SND_PCM_FORMAT_U16_BE,
	SND_PCM_FORMAT_S24_LE,
	SND_PCM_FORMAT_S24_BE,
	SND_PCM_FORMAT_U24_LE,
	SND_PCM_FORMAT_U24_BE,
	SND_PCM_FORMAT_S32_LE,
	SND_PCM_FORMAT_S32_BE,
	SND_PCM_FORMAT_S16 = SND_PCM_FORMAT_S16_LE,
	SND_PCM_FORMAT_S32 = SND_PCM_FORMAT_S32_LE,
} snd_pcm_format_t;

#define SND_PCM_NONBLOCK 0x00000001
#define SND_CTL_NONBLOCK 0x0001

typedef enum _snd_ctl_elem_iface {
	SND_CTL_ELEM_IFACE_CARD = 0,
	SND_CTL_ELEM_IFACE_HWDEP,
	SND_CTL_ELEM_IFACE_MIXER,
	SND_CTL_ELEM_IFACE_PCM,
} snd_ctl_elem_iface_t;

typedef enum _snd_ctl_event_type {
	SND_CTL_EVENT_ELEM = 0,
} snd_ctl_event_type_t;

#define SND_CTL_EVENT_MASK_REMOVE (~0U)
#define SND_CTL_EVENT_MASK_VALUE (1 << 0)

/* Modelled by the test. */
typedef struct _snd_pcm snd_pcm_t;
typedef struct _snd_pcm_sw_params {
	snd_pcm_uframes_t avail_min;
	snd_pcm_uframes_t start_threshold;
} snd_pcm_sw_params_t;

/* Never reached by the poll loop: sized only so that alloca works. */
typedef struct _snd_pcm_hw_params { int unused; } snd_pcm_hw_params_t;
typedef struct _snd_pcm_info { int unused; } snd_pcm_info_t;
typedef struct _snd_ctl snd_ctl_t;
typedef struct _snd_ctl_elem_id { int unused; } snd_ctl_elem_id_t;
typedef struct _snd_ctl_elem_info { int unused; } snd_ctl_elem_info_t;
typedef struct _snd_ctl_elem_value { int unused; } snd_ctl_elem_value_t;
typedef struct _snd_ctl_event { int unused; } snd_ctl_event_t;
typedef struct _snd_output snd_output_t;

#define NQ_FAKE_ALLOCA(ptr) do { *(ptr) = alloca(sizeof(**(ptr))); memset(*(ptr), 0, sizeof(**(ptr))); } while (0)
#define snd_pcm_hw_params_alloca(ptr) NQ_FAKE_ALLOCA(ptr)
#define snd_pcm_sw_params_alloca(ptr) NQ_FAKE_ALLOCA(ptr)
#define snd_ctl_elem_id_alloca(ptr) NQ_FAKE_ALLOCA(ptr)
#define snd_ctl_event_alloca(ptr) NQ_FAKE_ALLOCA(ptr)

const char *snd_strerror(int errnum);
int snd_output_printf(snd_output_t *output, const char *format, ...);

int snd_pcm_open(snd_pcm_t **pcm, const char *name, snd_pcm_stream_t stream, int mode);
int snd_pcm_close(snd_pcm_t *pcm);
int snd_pcm_info(snd_pcm_t *pcm, snd_pcm_info_t *info);
int snd_pcm_info_malloc(snd_pcm_info_t **ptr);
void snd_pcm_info_free(snd_pcm_info_t *obj);
int snd_pcm_info_get_card(const snd_pcm_info_t *obj);
unsigned int snd_pcm_info_get_device(const snd_pcm_info_t *obj);
unsigned int snd_pcm_info_get_subdevice(const snd_pcm_info_t *obj);
int snd_pcm_link(snd_pcm_t *pcm1, snd_pcm_t *pcm2);
int snd_pcm_dump(snd_pcm_t *pcm, snd_output_t *out);
const char *snd_pcm_access_name(const snd_pcm_access_t access);
const char *snd_pcm_format_name(const snd_pcm_format_t format);
int snd_pcm_format_width(snd_pcm_format_t format);
int snd_pcm_format_physical_width(snd_pcm_format_t format);
int snd_pcm_format_set_silence(snd_pcm_format_t format, void *buf, unsigned int samples);

int snd_pcm_hw_free(snd_pcm_t *pcm);
int snd_pcm_hw_params(snd_pcm_t *pcm, snd_pcm_hw_params_t *params);
int snd_pcm_hw_params_any(snd_pcm_t *pcm, snd_pcm_hw_params_t *params);
void snd_pcm_hw_params_copy(snd_pcm_hw_params_t *dst, const snd_pcm_hw_params_t *src);
int snd_pcm_hw_params_get_buffer_size(const snd_pcm_hw_params_t *params, snd_pcm_uframes_t *val);
int snd_pcm_hw_params_get_period_size(const snd_pcm_hw_params_t *params, snd_pcm_uframes_t *val, int *dir);
int snd_pcm_hw_params_get_rate(const snd_pcm_hw_params_t *params, unsigned int *val, int *dir);
int snd_pcm_hw_params_set_access(snd_pcm_t *pcm, snd_pcm_hw_params_t *params, snd_pcm_access_t access);
int snd_pcm_hw_params_set_buffer_size_near(snd_pcm_t *pcm, snd_pcm_hw_params_t *params, snd_pcm_uframes_t *val);
int snd_pcm_hw_params_set_channels(snd_pcm_t *pcm, snd_pcm_hw_params_t *params, unsigned int val);
int snd_pcm_hw_params_set_format(snd_pcm_t *pcm, snd_pcm_hw_params_t *params, snd_pcm_format_t val);
int snd_pcm_hw_params_set_period_size_near(snd_pcm_t *pcm, snd_pcm_hw_params_t *params, snd_pcm_uframes_t *val,
					   int *dir);
int snd_pcm_hw_params_set_rate_near(snd_pcm_t *pcm, snd_pcm_hw_params_t *params, unsigned int *val, int *dir);
int snd_pcm_hw_params_set_rate_resample(snd_pcm_t *pcm, snd_pcm_hw_params_t *params, unsigned int val);

int snd_pcm_sw_params(snd_pcm_t *pcm, snd_pcm_sw_params_t *params);
int snd_pcm_sw_params_current(snd_pcm_t *pcm, snd_pcm_sw_params_t *params);
int snd_pcm_sw_params_get_avail_min(const snd_pcm_sw_params_t *params, snd_pcm_uframes_t *val);
int snd_pcm_sw_params_set_avail_min(snd_pcm_t *pcm, snd_pcm_sw_params_t *params, snd_pcm_uframes_t val);
int snd_pcm_sw_params_set_start_threshold(snd_pcm_t *pcm, snd_pcm_sw_params_t *params, snd_pcm_uframes_t val);

int snd_pcm_poll_descriptors_count(snd_pcm_t *pcm);
int snd_pcm_poll_descriptors(snd_pcm_t *pcm, struct pollfd *pfds, unsigned int space);
int snd_pcm_poll_descriptors_revents(snd_pcm_t *pcm, struct pollfd *pfds, unsigned int nfds,
				     unsigned short *revents);
snd_pcm_state_t snd_pcm_state(snd_pcm_t *pcm);
snd_pcm_sframes_t snd_pcm_avail_update(snd_pcm_t *pcm);
int snd_pcm_delay(snd_pcm_t *pcm, snd_pcm_sframes_t *delayp);
int snd_pcm_prepare(snd_pcm_t *pcm);
int snd_pcm_start(snd_pcm_t *pcm);
int snd_pcm_drop(snd_pcm_t *pcm);
int snd_pcm_resume(snd_pcm_t *pcm);
snd_pcm_sframes_t snd_pcm_readi(snd_pcm_t *pcm, void *buffer, snd_pcm_uframes_t size);
snd_pcm_sframes_t snd_pcm_writei(snd_pcm_t *pcm, const void *buffer, snd_pcm_uframes_t size);

int snd_ctl_open(snd_ctl_t **ctl, const char *name, int mode);
int snd_ctl_close(snd_ctl_t *ctl);
const char *snd_ctl_name(snd_ctl_t *ctl);
int snd_ctl_subscribe_events(snd_ctl_t *ctl, int subscribe);
int snd_ctl_read(snd_ctl_t *ctl, snd_ctl_event_t *event);
int snd_ctl_poll_descriptors_count(snd_ctl_t *ctl);
int snd_ctl_poll_descriptors(snd_ctl_t *ctl, struct pollfd *pfds, unsigned int space);
int snd_ctl_poll_descriptors_revents(snd_ctl_t *ctl, struct pollfd *pfds, unsigned int nfds,
				     unsigned short *revents);
int snd_ctl_ascii_elem_id_parse(snd_ctl_elem_id_t *dst, const char *str);
unsigned int snd_ctl_elem_id_get_device(const snd_ctl_elem_id_t *obj);
const char *snd_ctl_elem_id_get_name(const snd_ctl_elem_id_t *obj);
unsigned int snd_ctl_elem_id_get_subdevice(const snd_ctl_elem_id_t *obj);
void snd_ctl_elem_id_set_device(snd_ctl_elem_id_t *obj, unsigned int val);
void snd_ctl_elem_id_set_name(snd_ctl_elem_id_t *obj, const char *val);
void snd_ctl_elem_id_set_subdevice(snd_ctl_elem_id_t *obj, unsigned int val);
int snd_ctl_elem_read(snd_ctl_t *ctl, snd_ctl_elem_value_t *data);
int snd_ctl_elem_write(snd_ctl_t *ctl, snd_ctl_elem_value_t *data);
int snd_ctl_elem_value_malloc(snd_ctl_elem_value_t **ptr);
void snd_ctl_elem_value_free(snd_ctl_elem_value_t *obj);
void snd_ctl_elem_value_get_id(const snd_ctl_elem_value_t *obj, snd_ctl_elem_id_t *ptr);
void snd_ctl_elem_value_set_id(snd_ctl_elem_value_t *obj, const snd_ctl_elem_id_t *ptr);
void snd_ctl_elem_value_set_interface(snd_ctl_elem_value_t *obj, snd_ctl_elem_iface_t val);
int snd_ctl_elem_value_get_boolean(const snd_ctl_elem_value_t *obj, unsigned int idx);
void snd_ctl_elem_value_set_boolean(snd_ctl_elem_value_t *obj, unsigned int idx, long val);
long snd_ctl_elem_value_get_integer(const snd_ctl_elem_value_t *obj, unsigned int idx);
void snd_ctl_elem_value_set_integer(snd_ctl_elem_value_t *obj, unsigned int idx, long val);
void snd_ctl_event_elem_get_id(const snd_ctl_event_t *obj, snd_ctl_elem_id_t *ptr);
unsigned int snd_ctl_event_elem_get_mask(const snd_ctl_event_t *obj);
const char *snd_ctl_event_elem_get_name(const snd_ctl_event_t *obj);
snd_ctl_event_type_t snd_ctl_event_get_type(const snd_ctl_event_t *obj);

#endif
