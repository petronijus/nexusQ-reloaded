#!/bin/sh
# Build ctl_nexusq_vol and test it against a real PulseAudio, in an Alpine
# container (the same libc, alsa-lib and PulseAudio the Q runs). No device.
#
#   sh userspace/nexusq-alsa-vol/tests/run-integration.sh
set -eu
HERE="$(cd "$(dirname "$0")/.." && pwd)"
# A local image with the dependencies already in it saves the download on
# every run (make one: see README.md); plain alpine:3.22 works too.
if [ "${NQV_IN_CONTAINER:-0}" != 1 ]; then
	img="${NQV_IMAGE:-nexusq-alsa-vol-test:alpine3.22}"
	docker image inspect "$img" >/dev/null 2>&1 || img=alpine:3.22
	exec docker run --rm -e NQV_IN_CONTAINER=1 -v "$HERE:/src:ro" "$img" sh /src/tests/run-integration.sh
fi

command -v pactl >/dev/null ||
	apk add -q build-base pkgconf alsa-lib-dev pulseaudio pulseaudio-dev pulseaudio-utils >/dev/null
cp -r /src /w && cd /w
make -s test
# Built the way the APKBUILD builds it: CFLAGS on the make command line, which
# overrides the Makefile's own CFLAGS. The first packaged build came out
# non-PIC that way (a TEXTREL abuild refused) while a plain `make` was fine.
make -s CFLAGS="-Os -fstack-clash-protection -Wformat -Werror=format-security"
if readelf -d libasound_module_ctl_nexusq_vol.so | grep -q TEXTREL; then
	echo "FAIL: the plugin has text relocations (built without -fPIC)"; exit 1
fi
readelf -W --dyn-syms libasound_module_ctl_nexusq_vol.so | grep -q ' _snd_ctl_nexusq_vol_open$' ||
	{ echo "FAIL: _snd_ctl_nexusq_vol_open is not exported"; exit 1; }
echo "plugin: PIC, entry point exported"
make -s install PLUGINDIR=/usr/lib/alsa-lib
# the definition as the package ships it
install -Dm644 60-nexusq-vol.conf /etc/alsa/conf.d/60-nexusq-vol.conf
cc -O2 -Wall -Wextra -Werror -o /w/test_player_mappings tests/test_player_mappings.c \
	$(pkg-config --cflags --libs alsa) -lm

# PulseAudio refuses to run as root outside system mode: a user, like the Q's.
adduser -D -u 10000 t >/dev/null
chown -R t /w
su t -s /bin/sh -c '
	export XDG_RUNTIME_DIR=/tmp/xdg; mkdir -p $XDG_RUNTIME_DIR
	pulseaudio -D --exit-idle-time=-1 -n \
		-L "module-null-sink sink_name=first" -L module-native-protocol-unix \
		--log-target=stderr 2>/tmp/pa.log
	for i in $(seq 50); do pactl info >/dev/null 2>&1 && break; sleep 0.1; done
	pactl set-default-sink first
	pactl set-sink-volume first 50%
	/w/test_player_mappings
'
