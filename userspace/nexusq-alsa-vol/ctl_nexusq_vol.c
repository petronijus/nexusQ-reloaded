/*
 * ctl_nexusq_vol.c -- ALSA control plugin `nexusq_vol`: the Nexus Q's one volume.
 *
 * The Q has one volume, the active output's PulseAudio sink: the app, the dome
 * knob and Home Assistant all move it. The players had a second one of their
 * own: librespot and shairport-sync each attenuate samples in software before
 * PulseAudio, because neither will drive a mixer control that has no dB scale,
 * and the stock PulseAudio control plugin (alsa-plugins ctl_pulse) has none
 * (docs/2026-09-23-unified-volume.md §3). This plugin is that control with the
 * dB scale: "Master Playback Volume", mapped onto the CURRENT default sink (@DEFAULT_SINK@, so it follows an output switch;
 * ctl_pulse binds to whatever was default when it was opened). With it,
 * `librespot --mixer alsa` and shairport-sync's `mixer_control_name` both move
 * the one PulseAudio volume, and neither player is patched.
 *
 * The scale. A player asks for dB. PulseAudio's software volume is cubic in
 * amplitude: amplitude = (v / PA_VOLUME_NORM)^3, i.e. dB = 60 log10(v / NORM).
 * The integer this control exposes is LINEAR IN AMPLITUDE:
 *
 *     raw = RAW_MAX * (v / NORM)^3          v = NORM * cbrt(raw / RAW_MAX)
 *
 * so the TLV is an exact SND_CTL_TLVT_DB_LINEAR (mute at 0, 0 dB at RAW_MAX)
 * and every dB a player asks for lands on the PulseAudio volume with that same
 * dB. RAW_MAX is 2^30, which keeps the smallest step at -180.6 dB. librespot
 * takes the control's range for its cubic mapping's floor, and a floor that
 * deep makes Spotify's percentage and the app's percentage the same number
 * (tests/test_player_mappings.c).
 *
 * Cost at idle: nothing. PulseAudio pushes sink changes; the plugin only
 * subscribes when a client asks for events, and never polls.
 *
 * Configuration (asound.conf):
 *     ctl.nexusq_vol { type nexusq_vol }
 *     # optional: sink "<name>"   (default @DEFAULT_SINK@)
 *     #           server "<pa server>"
 */

#include <errno.h>
#include <math.h>
#include <poll.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <sys/eventfd.h>
#include <unistd.h>

#include <alsa/asoundlib.h>
#include <alsa/control_external.h>
#include <pulse/pulseaudio.h>

#include "nexusq_vol_scale.h"

/* Volume only, deliberately no "Master Playback Switch": mute is the Q's
 * (the app, the knob, Home Assistant), not a player's. librespot 0.8.0 flips a
 * mixer's switch on at EVERY start with a non-zero volume (alsamixer.rs
 * set_volume: "Enabling playback (unsetting mute)"), so a muted Q would come
 * unmuted at boot or at any librespot restart. Without a switch, Spotify at 0
 * is simply the lowest volume, and PulseAudio's mute is left alone. */
#define VOL_NAME "Master Playback Volume"
enum { KEY_VOL = 0, N_KEYS = 1 };

/* Mute below the first step, 0 dB at RAW_MAX, linear in amplitude between. */
static const unsigned int vol_tlv[] = {
	SND_CTL_TLVT_DB_LINEAR, 2 * sizeof(unsigned int),
	(unsigned int)SND_CTL_TLV_DB_GAIN_MUTE, 0,
};

typedef struct {
	snd_ctl_ext_t ext;

	pa_threaded_mainloop *ml;
	pa_context *ctx;
	char *server;
	char *sink;             /* "@DEFAULT_SINK@" unless configured */

	/* the last picture of the sink, and whether it moved since read_event */
	pa_volume_t vol;
	int have;
	int updated;
	int subscribed;
	int efd;                /* poll_fd: readable while `updated` is set */

	/* the result of the info request in flight */
	int info_ok;
	pa_cvolume cv;
} nqv_t;

/* --- PulseAudio plumbing -------------------------------------------------- */

static void ctx_state_cb(pa_context *c, void *u)
{
	nqv_t *q = u;
	(void)c;
	pa_threaded_mainloop_signal(q->ml, 0);
}

/* Wait for an operation; the callbacks signal the mainloop. Gives up when the
 * context dies, so a PulseAudio restart makes the call fail instead of hang. */
static int wait_op(nqv_t *q, pa_operation *o)
{
	if (!o)
		return -EIO;
	while (pa_operation_get_state(o) == PA_OPERATION_RUNNING) {
		if (!PA_CONTEXT_IS_GOOD(pa_context_get_state(q->ctx))) {
			pa_operation_cancel(o);
			pa_operation_unref(o);
			return -EIO;
		}
		pa_threaded_mainloop_wait(q->ml);
	}
	pa_operation_unref(o);
	return 0;
}

static void notify_changed(nqv_t *q)
{
	q->updated = 1;
	if (q->subscribed && q->efd >= 0) {
		uint64_t one = 1;
		ssize_t w = write(q->efd, &one, sizeof one);
		(void)w;        /* EAGAIN = already readable: that is the point */
	}
}

/* Take a fresh sink picture into the cache; flag it if the volume moved. */
static void absorb(nqv_t *q, const pa_sink_info *i)
{
	pa_volume_t v = pa_cvolume_max(&i->volume);
	int moved = q->have && v != q->vol;
	q->vol = v;
	q->cv = i->volume;
	q->have = 1;
	if (moved)
		notify_changed(q);
}

static void sink_info_cb(pa_context *c, const pa_sink_info *i, int eol, void *u)
{
	nqv_t *q = u;
	(void)c;
	if (eol) {
		pa_threaded_mainloop_signal(q->ml, 0);
		return;
	}
	if (i) {
		absorb(q, i);
		q->info_ok = 1;
	}
}

static void success_cb(pa_context *c, int ok, void *u)
{
	nqv_t *q = u;
	(void)c;
	(void)ok;
	pa_threaded_mainloop_signal(q->ml, 0);
}

/* A sink or the server changed (the default sink moving is a server change):
 * re-read the sink, which flags and signals what moved. Runs on the mainloop
 * thread; it must not wait, so the request is fire-and-forget. */
static void event_cb(pa_context *c, pa_subscription_event_type_t t, uint32_t idx, void *u)
{
	nqv_t *q = u;
	(void)t;
	(void)idx;
	pa_operation *o = pa_context_get_sink_info_by_name(c, q->sink, sink_info_cb, q);
	if (o)
		pa_operation_unref(o);
}

static void disconnect(nqv_t *q)
{
	if (q->ctx) {
		pa_context_set_state_callback(q->ctx, NULL, NULL);
		pa_context_set_subscribe_callback(q->ctx, NULL, NULL);
		pa_context_disconnect(q->ctx);
		pa_context_unref(q->ctx);
		q->ctx = NULL;
	}
}

static int do_subscribe(nqv_t *q)
{
	pa_context_set_subscribe_callback(q->ctx, event_cb, q);
	pa_operation *o = pa_context_subscribe(q->ctx,
		PA_SUBSCRIPTION_MASK_SINK | PA_SUBSCRIPTION_MASK_SERVER, success_cb, q);
	return wait_op(q, o);
}

/* Connected and ready, reconnecting once if PulseAudio went away (restarted,
 * or not up yet when the player opened the control). Mainloop lock held. */
static int ensure_connected(nqv_t *q)
{
	if (q->ctx && pa_context_get_state(q->ctx) == PA_CONTEXT_READY)
		return 0;
	disconnect(q);
	q->ctx = pa_context_new(pa_threaded_mainloop_get_api(q->ml), "nexusq-vol");
	if (!q->ctx)
		return -ENOMEM;
	pa_context_set_state_callback(q->ctx, ctx_state_cb, q);
	if (pa_context_connect(q->ctx, q->server, PA_CONTEXT_NOFLAGS, NULL) < 0) {
		disconnect(q);
		return -ECONNREFUSED;
	}
	for (;;) {
		pa_context_state_t s = pa_context_get_state(q->ctx);
		if (s == PA_CONTEXT_READY)
			break;
		if (!PA_CONTEXT_IS_GOOD(s)) {
			disconnect(q);
			return -ECONNREFUSED;
		}
		pa_threaded_mainloop_wait(q->ml);
	}
	if (q->subscribed && do_subscribe(q) < 0)
		return -EIO;
	return 0;
}

/* Read the sink now (mainloop lock held). */
static int refresh(nqv_t *q)
{
	int err = ensure_connected(q);
	if (err < 0)
		return err;
	q->info_ok = 0;
	err = wait_op(q, pa_context_get_sink_info_by_name(q->ctx, q->sink, sink_info_cb, q));
	if (err < 0)
		return err;
	return q->info_ok ? 0 : -ENODEV;   /* no default sink (yet) */
}

/* --- the control ---------------------------------------------------------- */

static int nqv_elem_count(snd_ctl_ext_t *ext)
{
	(void)ext;
	return N_KEYS;
}

static int nqv_elem_list(snd_ctl_ext_t *ext, unsigned int offset, snd_ctl_elem_id_t *id)
{
	(void)ext;
	snd_ctl_elem_id_set_interface(id, SND_CTL_ELEM_IFACE_MIXER);
	if (offset != KEY_VOL)
		return -EINVAL;
	snd_ctl_elem_id_set_name(id, VOL_NAME);
	return 0;
}

static snd_ctl_ext_key_t nqv_find_elem(snd_ctl_ext_t *ext, const snd_ctl_elem_id_t *id)
{
	(void)ext;
	unsigned int numid = snd_ctl_elem_id_get_numid(id);
	if (numid > 0 && numid <= N_KEYS)
		return numid - 1;
	const char *name = snd_ctl_elem_id_get_name(id);
	if (strcmp(name, VOL_NAME) == 0)
		return KEY_VOL;
	return SND_CTL_EXT_KEY_NOT_FOUND;
}

/* Mono on purpose: the players set one level, and a write scales the sink's
 * channels together, so a balance set in PulseAudio survives it. */
static int nqv_get_attribute(snd_ctl_ext_t *ext, snd_ctl_ext_key_t key,
			     int *type, unsigned int *acc, unsigned int *count)
{
	(void)ext;
	if (key != KEY_VOL)
		return -EINVAL;
	*type = SND_CTL_ELEM_TYPE_INTEGER;
	*acc = SND_CTL_EXT_ACCESS_READWRITE | SND_CTL_EXT_ACCESS_TLV_READ;
	*count = 1;
	return 0;
}

static int nqv_get_integer_info(snd_ctl_ext_t *ext, snd_ctl_ext_key_t key,
				long *imin, long *imax, long *istep)
{
	(void)ext;
	if (key != KEY_VOL)
		return -EINVAL;
	*imin = 0;
	*imax = NQV_RAW_MAX;
	*istep = 0;
	return 0;
}

static int nqv_read_integer(snd_ctl_ext_t *ext, snd_ctl_ext_key_t key, long *value)
{
	nqv_t *q = ext->private_data;
	pa_threaded_mainloop_lock(q->ml);
	int err = refresh(q);
	if (err == 0) {
		if (key == KEY_VOL)
			*value = nqv_pa_to_raw(q->vol);
		else
			err = -EINVAL;
	}
	pa_threaded_mainloop_unlock(q->ml);
	return err;
}

static int nqv_write_integer(snd_ctl_ext_t *ext, snd_ctl_ext_key_t key, long *value)
{
	nqv_t *q = ext->private_data;
	pa_operation *o = NULL;
	int changed = 0;

	pa_threaded_mainloop_lock(q->ml);
	int err = refresh(q);
	if (err < 0)
		goto out;
	if (key != KEY_VOL) {
		err = -EINVAL;
		goto out;
	}
	pa_volume_t want = nqv_raw_to_pa(*value);
	if (want == q->vol)
		goto out;
	pa_cvolume cv = q->cv;
	if (pa_cvolume_max(&cv) == PA_VOLUME_MUTED)
		pa_cvolume_set(&cv, cv.channels ? cv.channels : 1, want);
	else
		pa_cvolume_scale(&cv, want);
	o = pa_context_set_sink_volume_by_name(q->ctx, q->sink, &cv, success_cb, q);
	err = wait_op(q, o);
	if (err == 0) {
		changed = 1;
		/* our own write is not news for our own event stream */
		int keep = q->updated;
		refresh(q);
		q->updated = keep;
	}
out:
	pa_threaded_mainloop_unlock(q->ml);
	return err < 0 ? err : changed;
}

static void nqv_subscribe_events(snd_ctl_ext_t *ext, int subscribe)
{
	nqv_t *q = ext->private_data;
	pa_threaded_mainloop_lock(q->ml);
	int want = !!(subscribe & SND_CTL_EVENT_MASK_VALUE);
	if (want && !q->subscribed) {
		q->subscribed = 1;
		if (ensure_connected(q) == 0) {
			refresh(q);           /* the baseline changes are measured from */
			do_subscribe(q);
		}
	} else if (!want && q->subscribed) {
		q->subscribed = 0;
		if (q->ctx && pa_context_get_state(q->ctx) == PA_CONTEXT_READY) {
			pa_context_set_subscribe_callback(q->ctx, NULL, NULL);
			wait_op(q, pa_context_subscribe(q->ctx, PA_SUBSCRIPTION_MASK_NULL,
							success_cb, q));
		}
	}
	pa_threaded_mainloop_unlock(q->ml);
}

static int nqv_read_event(snd_ctl_ext_t *ext, snd_ctl_elem_id_t *id, unsigned int *event_mask)
{
	nqv_t *q = ext->private_data;
	int err = -EAGAIN;
	pa_threaded_mainloop_lock(q->ml);
	if (q->subscribed && q->updated) {
		nqv_elem_list(ext, KEY_VOL, id);
		q->updated = 0;
		*event_mask = SND_CTL_EVENT_MASK_VALUE;
		err = 1;
	}
	if (!q->updated) {
		uint64_t n;
		ssize_t r = read(q->efd, &n, sizeof n);   /* no longer readable */
		(void)r;
	}
	pa_threaded_mainloop_unlock(q->ml);
	return err;
}

static int nqv_poll_revents(snd_ctl_ext_t *ext, struct pollfd *pfd, unsigned int nfds,
			    unsigned short *revents)
{
	nqv_t *q = ext->private_data;
	(void)pfd;
	(void)nfds;
	pa_threaded_mainloop_lock(q->ml);
	*revents = (q->subscribed && q->updated) ? POLLIN : 0;
	pa_threaded_mainloop_unlock(q->ml);
	return 0;
}

static void nqv_free(nqv_t *q)
{
	if (q->ml) {
		pa_threaded_mainloop_lock(q->ml);
		disconnect(q);
		pa_threaded_mainloop_unlock(q->ml);
		pa_threaded_mainloop_stop(q->ml);
		pa_threaded_mainloop_free(q->ml);
	}
	if (q->efd >= 0)
		close(q->efd);
	free(q->server);
	free(q->sink);
	free(q);
}

static void nqv_close(snd_ctl_ext_t *ext)
{
	nqv_free(ext->private_data);
}

static const snd_ctl_ext_callback_t nqv_callback = {
	.elem_count = nqv_elem_count,
	.elem_list = nqv_elem_list,
	.find_elem = nqv_find_elem,
	.get_attribute = nqv_get_attribute,
	.get_integer_info = nqv_get_integer_info,
	.read_integer = nqv_read_integer,
	.write_integer = nqv_write_integer,
	.subscribe_events = nqv_subscribe_events,
	.read_event = nqv_read_event,
	.poll_revents = nqv_poll_revents,
	.close = nqv_close,
};

SND_CTL_PLUGIN_DEFINE_FUNC(nexusq_vol)
{
	snd_config_iterator_t i, next;
	const char *server = NULL, *sink = NULL;
	int err;

	(void)root;
	snd_config_for_each(i, next, conf) {
		snd_config_t *n = snd_config_iterator_entry(i);
		const char *id;
		if (snd_config_get_id(n, &id) < 0)
			continue;
		if (!strcmp(id, "comment") || !strcmp(id, "type") || !strcmp(id, "hint"))
			continue;
		if (!strcmp(id, "server") || !strcmp(id, "sink")) {
			const char *v;
			if (snd_config_get_string(n, &v) < 0) {
				SNDERR("nexusq_vol: %s must be a string", id);
				return -EINVAL;
			}
			if (*v)
				*(!strcmp(id, "server") ? &server : &sink) = v;
			continue;
		}
		SNDERR("nexusq_vol: unknown field %s", id);
		return -EINVAL;
	}

	nqv_t *q = calloc(1, sizeof *q);
	if (!q)
		return -ENOMEM;
	q->efd = eventfd(0, EFD_NONBLOCK | EFD_CLOEXEC);
	q->server = server ? strdup(server) : NULL;
	q->sink = strdup(sink ? sink : "@DEFAULT_SINK@");
	q->ml = pa_threaded_mainloop_new();
	if (q->efd < 0 || !q->sink || !q->ml || (server && !q->server)) {
		err = -ENOMEM;
		goto fail;
	}
	if (pa_threaded_mainloop_start(q->ml) < 0) {
		err = -EIO;
		goto fail;
	}
	/* Connect now, so a player that opens the control learns at once whether
	 * there is a PulseAudio to control -- not at its first volume change. */
	pa_threaded_mainloop_lock(q->ml);
	err = refresh(q);
	pa_threaded_mainloop_unlock(q->ml);
	if (err < 0) {
		SNDERR("nexusq_vol: no PulseAudio sink to control (%s)", snd_strerror(err));
		goto fail;
	}

	q->ext.version = SND_CTL_EXT_VERSION;
	q->ext.card_idx = 0;
	strncpy(q->ext.id, "nexusq_vol", sizeof q->ext.id - 1);
	strncpy(q->ext.driver, "Nexus Q volume", sizeof q->ext.driver - 1);
	strncpy(q->ext.name, "Nexus Q volume", sizeof q->ext.name - 1);
	strncpy(q->ext.longname, "The Nexus Q's volume (the PulseAudio default sink)",
		sizeof q->ext.longname - 1);
	strncpy(q->ext.mixername, "Nexus Q volume", sizeof q->ext.mixername - 1);
	q->ext.poll_fd = q->efd;
	q->ext.callback = &nqv_callback;
	q->ext.private_data = q;
	q->ext.tlv.p = vol_tlv;

	err = snd_ctl_ext_create(&q->ext, name, mode);
	if (err < 0)
		goto fail;
	*handlep = q->ext.handle;
	return 0;

fail:
	nqv_free(q);
	return err;
}

SND_CTL_PLUGIN_SYMBOL(nexusq_vol);
