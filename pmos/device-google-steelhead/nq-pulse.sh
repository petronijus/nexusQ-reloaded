# nq-pulse.sh -- PulseAudio helpers shared by the Nexus Q's service launchers
# (roon-nexusq, librespot-nexusq). Sourced, not run: `. /usr/lib/nexusq/nq-pulse.sh`.
# The functions are pure shell over `pactl`, so tests stub pactl on PATH
# (tests/test_nq_pulse.sh).

# wait_for_pulse [tries]: 0 once `pactl info` answers, 1 after <tries>
# half-second attempts (default 60 = 30 s), so systemd's Restart= takes over.
# pulseaudio.service is Type=simple here (this PulseAudio build has no
# sd_notify), so a unit ordered After= it starts when PA has FORKED, not when it
# listens. At boot that met "Connection refused" (Roon until device r114).
wait_for_pulse() {
	_n=0
	while [ "$_n" -lt "${1:-60}" ]; do
		pactl info >/dev/null 2>&1 && return 0
		_n=$((_n + 1))
		sleep 0.5
	done
	return 1
}

# pulse_volume_percent: the default sink's volume in whole percent -- the
# loudest channel, as the nexusq_vol control reads it -- or nothing (status 1)
# when PulseAudio cannot say. The mute flag is not part of it.
pulse_volume_percent() {
	pactl get-sink-volume @DEFAULT_SINK@ 2>/dev/null |
		grep -o '[0-9][0-9]*%' | tr -d '%' | sort -n | tail -n 1 | grep .
}
