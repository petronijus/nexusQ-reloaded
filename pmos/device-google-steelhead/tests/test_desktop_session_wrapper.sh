#!/bin/sh
# nexusq-desktop-session (device r127): which renderer the HDMI desktop gets.
# GPU only when sgx-env says ready; the GPU labwc reached through PATH; Pixman
# when not ready, after a GPU session that failed within 30 s (recorded per
# kernel + mesa-sgx build), and straight away once that record matches.
# startlxqtwayland and date are stubs; sgx-env is a fixture.
set -u
here=$(cd "$(dirname "$0")" && pwd)
wrapper="$here/../nexusq-desktop-session"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
fails=0

mkdir -p "$work/bin" "$work/gpubin" "$work/home"
: >"$work/sgx_dri.so"
printf '#!/bin/sh\nexit 0\n' >"$work/gpubin/labwc"
chmod +x "$work/gpubin/labwc"

# startlxqtwayland stub: logs renderer + whether the GPU labwc is first on
# PATH, exits with the code in $work/rc (or 0).
cat >"$work/bin/startlxqtwayland" <<'S'
#!/bin/sh
case $PATH in "$NQ_SGX_GPU_BIN":*) gpu=gpu ;; *) gpu=nogpu ;; esac
echo "${WLR_RENDERER:-unset} $gpu" >>"$WORK/calls"
exit "$(cat "$WORK/rc" 2>/dev/null || echo 0)"
S
# date stub: +%s returns a counter advanced by $WORK/step on each call.
cat >"$work/bin/date" <<'S'
#!/bin/sh
t=$(cat "$WORK/now" 2>/dev/null || echo 1000)
echo $((t + $(cat "$WORK/step" 2>/dev/null || echo 0))) >"$WORK/now"
echo "$t"
S
chmod +x "$work/bin/startlxqtwayland" "$work/bin/date"

ready() {  # ready yes|no: the sgx-env fixture
	if [ "$1" = yes ]; then
		echo 'nq_sgx_ready() { return 0; }' >"$work/sgx-env"
	else
		echo 'nq_sgx_ready() { return 1; }' >"$work/sgx-env"
	fi
}

run() {
	rm -f "$work/calls"
	WORK=$work HOME="$work/home" XDG_STATE_HOME="$work/home/.state" \
		NQ_SGX_ENV="$work/sgx-env" NQ_SGX_GPU_BIN="$work/gpubin" NQ_SGX_DRI="$work/sgx_dri.so" \
		PATH="$work/bin:$PATH" sh "$wrapper" >/dev/null 2>&1
	echo $? >"$work/exit"
}

check() {  # check <name> <expected calls, ";"-separated>
	got=$(tr '\n' ';' <"$work/calls" 2>/dev/null)
	if [ "$got" = "$2" ]; then echo "PASS $1"; else echo "FAIL $1: got '$got' want '$2'"; fails=$((fails + 1)); fi
}

marker="$work/home/.state/nexusq/gpu-session-failed"

ready no
run
check "not ready: Pixman, no GPU labwc on PATH" "pixman nogpu;"

ready yes
echo 0 >"$work/rc"
run
check "ready: the GPU labwc is first on PATH" "unset gpu;"
[ ! -e "$marker" ] || { echo "FAIL a clean GPU session left a failure record"; fails=$((fails + 1)); }

echo 1 >"$work/rc"
echo 0 >"$work/step"
run
check "GPU session failing within 30 s: falls back to Pixman at once" "unset gpu;pixman nogpu;"
if [ -s "$marker" ]; then echo "PASS the failure is recorded"; else echo "FAIL no failure record"; fails=$((fails + 1)); fi

echo 0 >"$work/rc"
run
check "recorded failure for this build: Pixman without trying the GPU" "pixman nogpu;"

touch -d '2001-01-01' "$work/sgx_dri.so"
run
check "a new mesa-sgx build: the GPU is tried again" "unset gpu;"

rm -f "$marker"
echo 1 >"$work/rc"
echo 100 >"$work/step"
run
check "a GPU session that ran >30 s and then failed is not a failed start" "unset gpu;"
[ ! -e "$marker" ] || { echo "FAIL a long session was recorded as a failed start"; fails=$((fails + 1)); }

[ $fails -eq 0 ] && echo "PASS all" || echo "FAIL $fails"
exit $((fails != 0))
