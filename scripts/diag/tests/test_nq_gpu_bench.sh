#!/usr/bin/env bash
# Host test for scripts/diag/nq-gpu-bench's verdict, with a fake nqctl standing
# in for the unit. What it protects: a run that silently fell back to the
# software renderer scores 5, and a slower GPU path scores lower -- both have
# to come out as failures, not as numbers someone has to know to distrust
# (2026-10-13: the first two benchmark runs that evening were llvmpipe without
# anyone asking for it).
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
BENCH="$HERE/../nq-gpu-bench"
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
PASS=0
FAIL=0
check() { # check NAME CONDITION-RESULT
	if [ "$2" = 0 ]; then PASS=$((PASS + 1)); echo "  ok    $1"; else FAIL=$((FAIL + 1)); echo "  FAIL  $1"; fi
}

fake() { # fake RENDERER SCORE [GPU-HZ GPU-HZ] -> a nqctl that answers like the unit would
	cat >"$T/nqctl" <<EOF
#!/bin/sh
[ "\$1" = run ] || exit 1
case "\$2" in
hostname) echo steelhead; exit 0 ;;
esac
cat >/dev/null
echo "NQB-MON 100.0 350000 61000 suspended${3:+ $3}"
echo "NQB-MON 101.0 1200000 72000 active${4:+ $4}"
echo "    GL_RENDERER:    $1"
echo "[build] use-vbo=true: FPS: 140 FrameTime: 7.1 ms"
echo "                                  glmark2 Score: $2 "
echo "NQB-RC 0"
EOF
	chmod +x "$T/nqctl"
}

run() { NQCTL="$T/nqctl" "$BENCH" "$T/out" >"$T/log" 2>&1; }

fake "PowerVR SGX 540" 83
run
check "baseline-level SGX run passes" $?
grep -q "VERDICT   ok" "$T/log"
check "  and says ok" $?
grep -q "GPU runtime-active 50%" "$T/log"
check "  and reports the GPU's awake share" $?
grep -q "gpu MHz" "$T/log"
[ $? = 1 ]
check "  without a GPU clock column, no GPU clock line" $?

# A kernel with GPU DVFS (r31): the monitor's fifth column is devfreq's cur_freq.
fake "PowerVR SGX 540" 83 153600000 384000000
run
check "an SGX run with DVFS passes" $?
grep -q "gpu MHz   153.6:50% 384:50%\|gpu MHz   384:50% 153.6:50%" "$T/log"
check "  and reports the time per GPU clock" $?

fake "PowerVR SGX 540" 60
run
[ $? = 1 ]
check "a score 26 % under the baseline fails" $?
grep -q "REGRESSION" "$T/log"
check "  as a regression" $?

fake "llvmpipe (LLVM 23.1.3, 128 bits)" 5
run
[ $? = 1 ]
check "a software-rendered run fails" $?
grep -q "not rendered on the SGX540" "$T/log"
check "  and says why" $?

echo "nq-gpu-bench: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
