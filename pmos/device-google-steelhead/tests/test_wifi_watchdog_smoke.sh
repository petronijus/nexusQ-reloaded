#!/usr/bin/env bash
# End-to-end smoke test of nexusq-wifi-watchdog's main loop (device r110).
#
# The parser tests prove each piece reads what the old pipelines read; this runs
# the WHOLE script — as the device runs it, under BusyBox ash — against stubbed
# `iw`, `ip`, `ping` and `nmcli` that answer with captured device output, and
# checks what it writes. It exists because the r110 fork diet moved state out of
# stdout and into variables (LINK_ASSOC, GW, LOSS, NOW, LOG_LINES), and a
# variable set in the wrong place — a subshell, say — fails silently: the loop
# keeps running and logs plausible-looking nonsense.
#
# Usage: pmos/device-google-steelhead/tests/test_wifi_watchdog_smoke.sh
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
command -v docker >/dev/null || { echo "docker required" >&2; exit 2; }

PASS=0; FAIL=0
check() {  # check <name> <output> <expected-marker>
    if printf '%s' "$2" | grep -qE "$3"; then
        PASS=$((PASS+1)); printf '  \033[32mPASS\033[0m  %s\n' "$1"
    else
        FAIL=$((FAIL+1)); printf '  \033[31mFAIL\033[0m  %s\n' "$1"
        printf '%s\n' "$2" | sed 's/^/        /'
    fi
}

run_case() {  # run_case <iw-fixture> <route-fixture> <ping-fixture> <seconds> [extra env]
    docker run --rm -i \
        -v "$HERE/../nexusq-wifi-watchdog":/wd:ro \
        -v "$HERE/fixtures":/fx:ro \
        alpine:3.21 sh -s <<EOF
set -u
mkdir -p /stub /log /run/nq
cat > /stub/iw   <<'S'
#!/bin/sh
cat /fx/$1
S
cat > /stub/ip   <<'S'
#!/bin/sh
cat /fx/$2
S
cat > /stub/ping <<'S'
#!/bin/sh
cat /fx/$3
S
cat > /stub/nmcli <<'S'
#!/bin/sh
echo "30 (disconnected)"
S
chmod +x /stub/*
${5:-}
PATH=/stub:\$PATH NQ_WIFI_INTERVAL=1 NQ_WIFI_HEARTBEAT=1 NQ_LOGDIR=/log NQ_RUNDIR=/run/nq \
    timeout $4 sh /wd >/dev/null 2>&1
echo "--- log"; cat /log/wifi-watchdog.jsonl
echo "--- lines \$(wc -l < /log/wifi-watchdog.jsonl)"
EOF
}

echo "=== 1. a healthy link: ok checks carry the real loss and signal ==="
out=$(run_case iw-link-connected.txt ip-route-default.txt ping-ok.txt 4)
check "a start event is logged"                   "$out" '"ev":"start"'
check "ok check with loss 0 and signal -45"       "$out" '"st":"ok","loss":0,"sig":"-45","fails":0'
check "timestamps are numbers (NOW was set)"      "$out" '^\{"t":[0-9]+,"st":"ok"'

echo "=== 2. a dead link: bad checks count up ==="
out=$(run_case iw-link-connected.txt ip-route-default.txt ping-unreachable.txt 3)
check "loss 100 is a bad check"                   "$out" '"st":"bad","loss":100,"sig":"-45","fails":1'
check "consecutive bad checks accumulate"         "$out" '"st":"bad","loss":100,"sig":"-45","fails":2'

echo "=== 3. associated but no default route: nogw ==="
out=$(run_case iw-link-connected.txt ip-route-none.txt ping-ok.txt 3)
check "no gateway is nogw, not ok"                "$out" '"st":"nogw","sig":"-45","fails":1'

echo "=== 4. not associated: down, and NM's state is read ==="
out=$(run_case iw-link-not-connected.txt ip-route-default.txt ping-ok.txt 3)
check "down with no signal and NM state 30"       "$out" '"st":"down","sig":"\?","nm":"30","downs":1'

echo "=== 5. the size cap still works from the in-memory line count ==="
out=$(run_case iw-link-connected.txt ip-route-default.txt ping-ok.txt 4 \
      'export NQ_WIFI_LOGCAP=6; seq 1 5 | sed "s/.*/{\"old\":&}/" > /log/wifi-watchdog.jsonl')
check "a pre-existing log is counted at start and capped" "$out" '^--- lines [1-6]$'
check "the oldest pre-existing lines were dropped"        "$(printf '%s' "$out" | grep -c '"old":1}' || true)" '^0$'

echo
echo "================ $PASS passed, $FAIL failed ================"
[ "$FAIL" -eq 0 ]
