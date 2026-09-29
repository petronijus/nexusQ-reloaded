#!/bin/sh
# needs: docker  (tools/dev/test-shell.sh runs it in the docker lane, `just test-sh-docker`)
# PulseAudio on the Q must come up WITHOUT module-switch-on-connect.
#
# 2026-09-27, Prague Q: music played and the LED ring showed no visualisation.
# The ring's tap records PA's default source, and the default source was
# `usb_in`: nexusq-uac2-in had loaded that source after the bridge set the
# speaker's monitor at boot, and postmarketOS's postmarketos.pa loads
# module-switch-on-connect, which makes every new source the default and moves
# the tap onto it. zz-nexusq-no-switch-on-connect.pa unloads it.
#
# This runs the drop-in through a real PulseAudio (Alpine edge = the Q's 17.x),
# in the order the stock default.pa includes default.pa.d, beside a stand-in
# for postmarketos.pa. The control run leaves our file out and must still find
# the module loaded, so the test cannot pass on a PulseAudio that never loaded it.
#
#   sh pmos/device-google-steelhead/tests/test_switch_on_connect_off.sh
set -eu
HERE="$(cd "$(dirname "$0")/.." && pwd)"
if [ "${NQS_IN_CONTAINER:-0}" != 1 ]; then
	exec docker run --rm -e NQS_IN_CONTAINER=1 -v "$HERE:/src:ro" \
		"${NQS_IMAGE:-alpine:edge}" sh /src/tests/test_switch_on_connect_off.sh
fi

command -v pactl >/dev/null || apk add -q pulseaudio pulseaudio-utils >/dev/null
adduser -D -u 10000 t >/dev/null 2>&1 || true

# $1: "with" or "without" our drop-in. Prints the loaded module names.
modules() {
	d=/tmp/cfg-$1; rm -rf "$d"; mkdir -p "$d/default.pa.d"
	# the line postmarketos.pa carries
	echo "load-module module-switch-on-connect" > "$d/default.pa.d/postmarketos.pa"
	[ "$1" = with ] && cp /src/zz-nexusq-no-switch-on-connect.pa "$d/default.pa.d/"
	cat > "$d/default.pa" <<-EOF
		load-module module-null-sink sink_name=speaker
		load-module module-native-protocol-unix
		.nofail
		.include $d/default.pa.d
	EOF
	chmod -R a+rX "$d"
	su t -s /bin/sh -c "
		export XDG_RUNTIME_DIR=/tmp/xdg-$1; mkdir -p \$XDG_RUNTIME_DIR
		pulseaudio -D -n -F $d/default.pa --exit-idle-time=-1 --log-target=stderr 2>/tmp/pa-$1.log
		for i in \$(seq 50); do pactl info >/dev/null 2>&1 && break; sleep 0.1; done
		pactl list short modules | cut -f2
		pulseaudio -k"
}

fail=0
without=$(modules without)
if echo "$without" | grep -qx module-switch-on-connect; then
	echo "ok   control: postmarketos.pa alone loads module-switch-on-connect"
else
	echo "FAIL control: the module was never loaded, the test proves nothing"
	cat /tmp/pa-without.log; fail=1
fi
with=$(modules with)
if ! echo "$with" | grep -qx module-native-protocol-unix; then
	echo "FAIL PulseAudio did not start with the drop-in"; cat /tmp/pa-with.log; fail=1
elif echo "$with" | grep -qx module-switch-on-connect; then
	echo "FAIL module-switch-on-connect is still loaded with the drop-in"; fail=1
else
	echo "ok   with the drop-in PulseAudio runs without module-switch-on-connect"
fi
exit $fail
