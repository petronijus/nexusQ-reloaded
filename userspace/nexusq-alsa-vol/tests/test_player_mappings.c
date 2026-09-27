/* End to end, against a running PulseAudio: the control as the players use it.
 *
 * librespot 0.8.0 (`--mixer alsa --volume-ctrl cubic`, playback/src/mixer/
 * alsamixer.rs + mappings.rs) is reproduced step for step: the dB range it
 * reads (minimum = mute, so it asks the dB of the first step), the cubic
 * mapping with that range, the millibel truncation, set_playback_dB with
 * Round::Floor. What must hold:
 *   - Spotify at N % puts the PulseAudio sink at N % -- the app's number;
 *   - the sink at N % reads back as N % in Spotify, and writing that back
 *     changes nothing (librespot re-reads the mixer at every play);
 *   - there is no switch, so librespot never touches PulseAudio's mute: not
 *     at start (it unmutes any switch it finds), not at Spotify 0;
 *   - the control follows the default sink; events arrive.
 * PulseAudio is read and set with pactl, the way the rest of the Q does. */
#include <alsa/asoundlib.h>
#include <math.h>
#include <poll.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define DEV "nexusq_vol"
static int fails;
#define CHECK(c) do { if (!(c)) { fails++; printf("  FAIL %s:%d: %s\n", __FILE__, __LINE__, #c); } } while (0)

static int sh(const char *cmd)
{
	int r = system(cmd);
	return r;
}

/* the default sink's volume in whole percent (first channel) */
static int pa_percent(void)
{
	FILE *f = popen("pactl get-sink-volume @DEFAULT_SINK@", "r");
	char buf[512] = "";
	size_t n = fread(buf, 1, sizeof buf - 1, f);
	buf[n] = 0;
	pclose(f);
	char *pct = strchr(buf, '%');
	if (!pct)
		return -1;
	char *s = pct;
	while (s > buf && s[-1] >= '0' && s[-1] <= '9')
		s--;
	return atoi(s);
}

static int pa_muted(void)
{
	FILE *f = popen("pactl get-sink-mute @DEFAULT_SINK@", "r");
	char buf[128] = "";
	size_t n = fread(buf, 1, sizeof buf - 1, f);
	buf[n] = 0;
	pclose(f);
	return strstr(buf, "yes") != NULL;
}

static snd_mixer_elem_t *open_master(snd_mixer_t **mixer)
{
	snd_mixer_selem_id_t *sid;
	if (snd_mixer_open(mixer, 0) < 0 || snd_mixer_attach(*mixer, DEV) < 0 ||
	    snd_mixer_selem_register(*mixer, NULL, NULL) < 0 || snd_mixer_load(*mixer) < 0)
		return NULL;
	snd_mixer_selem_id_alloca(&sid);
	snd_mixer_selem_id_set_name(sid, "Master");
	return snd_mixer_find_selem(*mixer, sid);
}

/* librespot opens a NEW mixer for every read and every write
 * (alsamixer.rs: `alsa::mixer::Mixer::new` in volume() and set_volume()), so it
 * always sees the control's current value. A long-lived mixer would read its
 * cache, which follows the sink only once the change event has been handled --
 * asynchronously, a race this test must not take part in. */
static long fresh_db(void)
{
	snd_mixer_t *m;
	long mb = 1;
	snd_mixer_elem_t *e = open_master(&m);
	if (e)
		snd_mixer_selem_get_playback_dB(e, SND_MIXER_SCHN_MONO, &mb);
	snd_mixer_close(m);
	return mb;
}

/* ...and every write, with Round::Floor (dir -1) */
static int fresh_set_db(long mb)
{
	snd_mixer_t *m;
	int r = -1;
	snd_mixer_elem_t *e = open_master(&m);
	if (e)
		r = snd_mixer_selem_set_playback_dB_all(e, mb, -1);
	snd_mixer_close(m);
	return r;
}

/* librespot: volume (0..65535) -> dB it asks for */
static long librespot_target_mb(unsigned int vol, double db_range)
{
	double v = vol / 65535.0;
	double min_norm = pow(10.0, -db_range / 60.0);
	double mapped = pow(v * (1.0 - min_norm) + min_norm, 3);
	if (vol == 65535)
		mapped = 1.0;
	double db = 20.0 * log10(mapped);
	return (long)(float)(db * 100.0f);      /* MilliBel::from_db: f32, truncating */
}

/* librespot: the mixer's dB -> its volume (0..65535) */
static unsigned int librespot_read(double db_range)
{
	long mb = fresh_db();
	double mapped = pow(10.0, (mb / 100.0) / 20.0);
	if (fabs(mapped - 1.0) <= 1e-12)
		return 65535;
	double min_norm = pow(10.0, -db_range / 60.0);
	double v = (cbrt(mapped) - min_norm) / (1.0 - min_norm);
	return (unsigned int)(v * 65535.0);
}

int main(void)
{
	snd_mixer_t *mixer;
	snd_mixer_elem_t *e = open_master(&mixer);
	CHECK(e != NULL);
	if (!e) {
		printf("test_player_mappings: FAIL (no Master on %s)\n", DEV);
		return 1;
	}
	CHECK(snd_mixer_selem_has_playback_volume(e));
	CHECK(!snd_mixer_selem_has_playback_switch(e));

	/* librespot's range probe */
	long min_mb, max_mb, min_raw, max_raw, first_mb;
	CHECK(snd_mixer_selem_get_playback_dB_range(e, &min_mb, &max_mb) == 0);
	snd_mixer_selem_get_playback_volume_range(e, &min_raw, &max_raw);
	CHECK(max_mb == 0);
	CHECK(min_mb == SND_CTL_TLV_DB_GAIN_MUTE);    /* not softvol, minimum is mute */
	CHECK(snd_mixer_selem_ask_playback_vol_dB(e, min_raw + 1, &first_mb) == 0);
	double db_range = fabs((double)(max_mb - first_mb) / 100.0);
	printf("  dB range seen by librespot: %.1f dB (first step %.2f dB)\n", db_range, first_mb / 100.0);
	CHECK(db_range > 150.0);

	/* Spotify N % -> PulseAudio N %, and back, with no drift */
	int bad_fwd = 0, bad_back = 0, drift = 0;
	for (int s = 1; s <= 100; s++) {
		unsigned int vol = (unsigned int)(s / 100.0 * 65535.0);   /* Spotify's % -> u16 */
		CHECK(fresh_set_db(librespot_target_mb(vol, db_range)) == 0);
		int p = pa_percent();
		if (p != s) {
			bad_fwd++;
			printf("  Spotify %d%% -> PulseAudio %d%%\n", s, p);
		}
		unsigned int back = librespot_read(db_range);
		if (abs((int)lround(back * 100.0 / 65535.0) - s) > 0) {
			bad_back++;
			printf("  PulseAudio %d%% -> Spotify %.2f%%\n", p, back * 100.0 / 65535.0);
		}
		/* the re-set librespot does at every play: must not move anything */
		long before;
		snd_mixer_selem_get_playback_volume(e, SND_MIXER_SCHN_MONO, &before);
		fresh_set_db(librespot_target_mb(back, db_range));
		if (pa_percent() != p)
			drift++;
	}
	CHECK(bad_fwd == 0);
	CHECK(bad_back == 0);
	CHECK(drift == 0);

	/* PulseAudio moved by someone else (the knob): the control reads it */
	for (int p = 5; p <= 100; p += 5) {
		char cmd[96];
		snprintf(cmd, sizeof cmd, "pactl set-sink-volume @DEFAULT_SINK@ %d%%", p);
		sh(cmd);
		long mb = fresh_db();
		CHECK(fabs(mb / 100.0 - 60.0 * log10(p / 100.0)) < 0.02);
	}

	/* a muted Q stays muted whatever the player does with the volume: what
	 * librespot does at start (its initial volume) and at Spotify 0 */
	sh("pactl set-sink-volume @DEFAULT_SINK@ 40%");
	sh("pactl set-sink-mute @DEFAULT_SINK@ 1");
	fresh_set_db(librespot_target_mb((unsigned int)(0.40 * 65535), db_range));
	CHECK(pa_muted() == 1);
	CHECK(pa_percent() == 40);
	fresh_set_db(SND_CTL_TLV_DB_GAIN_MUTE);   /* Spotify 0 */
	CHECK(pa_muted() == 1);
	CHECK(pa_percent() == 0);
	sh("pactl set-sink-mute @DEFAULT_SINK@ 0");

	/* events: a change made elsewhere reaches a client that listens */
	snd_ctl_t *ctl;
	CHECK(snd_ctl_open(&ctl, DEV, 0) == 0);
	CHECK(snd_ctl_subscribe_events(ctl, 1) == 0);
	sh("pactl set-sink-volume @DEFAULT_SINK@ 33%");
	struct pollfd pfd[4];
	int nfd = snd_ctl_poll_descriptors(ctl, pfd, 4);
	int got = 0;
	for (int t = 0; t < 20 && !got; t++) {
		if (poll(pfd, nfd, 100) > 0) {
			snd_ctl_event_t *ev;
			snd_ctl_event_alloca(&ev);
			while (snd_ctl_read(ctl, ev) > 0)
				if (snd_ctl_event_elem_get_mask(ev) & SND_CTL_EVENT_MASK_VALUE)
					got = 1;
		}
	}
	CHECK(got);
	/* our own write is not echoed back to us as news */
	snd_ctl_elem_value_t *val;
	snd_ctl_elem_value_alloca(&val);
	snd_ctl_elem_value_set_interface(val, SND_CTL_ELEM_IFACE_MIXER);
	snd_ctl_elem_value_set_name(val, "Master Playback Volume");
	snd_ctl_elem_value_set_integer(val, 0, 1L << 28);
	CHECK(snd_ctl_elem_write(ctl, val) >= 0);
	snd_ctl_close(ctl);

	/* the control follows the default sink */
	sh("pactl set-sink-volume @DEFAULT_SINK@ 40%");
	sh("pactl load-module module-null-sink sink_name=second >/dev/null");
	sh("pactl set-sink-volume second 70%");
	sh("pactl set-default-sink second");
	CHECK(fabs(fresh_db() / 100.0 - 60.0 * log10(0.70)) < 0.02);
	fresh_set_db(librespot_target_mb((unsigned int)(0.25 * 65535), db_range));
	CHECK(pa_percent() == 25);                       /* the new default moved */
	sh("pactl set-default-sink first");
	CHECK(pa_percent() == 40);                       /* the old one did not */

	snd_mixer_close(mixer);
	printf("test_player_mappings: %s (%d failure%s)\n", fails ? "FAIL" : "ok", fails, fails == 1 ? "" : "s");
	return fails != 0;
}
