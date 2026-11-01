#!/usr/bin/env bash
# needs: docker  (tools/dev/test-shell.sh runs it in the docker lane, `just test-sh-docker`)
# nexusq-uac2-in follows the gadget's `Capture Rate` change events (2026-11-01).
#
# The service runs for real under Alpine's busybox sh, the device's shell, with
# its outside world stubbed: alsaloop, PulseAudio and the silence watcher are
# stand-ins, `amixer` reads the host's rate from a file, `alsactl monitor`
# prints the event lines the test appends, and the PCM status files live in a
# directory the test writes (NQ_UAC2_ASOUND). What is checked:
#
#   - the host closes its stream -> parked on the event, within seconds, not
#     after the 12 s hw_ptr window alsaloop used to spin in;
#   - parked on a closed stream -> no `amixer` poll at all; an event on another
#     control of the card does not count;
#   - the host opens it again -> unparked on the event;
#   - the monitor dies -> restarted, and the flag read once to catch up;
#   - the host closes its stream WITHOUT an event -> the hw_ptr park notices,
#     says so, stops trusting the monitor and polls the flag again;
#   - a monitor that cannot run -> given up after three starts, not re-forked;
#   - the unit starts with the host idle and the host's start raises no event
#     -> the slow backstop read unparks and stops trusting the monitor;
#   - parked on the wedge, the monitor dies -> its catch-up read keeps it parked;
#   - SIGTERM -> no stand-in left running.
#
# Usage: pmos/device-google-steelhead/tests/test_uac2_rate_event.sh [script]
#   (default: ../nexusq-uac2-in; another path runs the same cases against it)
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SVC="${1:-$HERE/../nexusq-uac2-in}"
SVC="$(cd "$(dirname "$SVC")" && pwd)/$(basename "$SVC")"
command -v docker >/dev/null || { echo "docker required" >&2; exit 2; }

# shellcheck disable=SC2016  # everything below expands inside the container
DRIVER='
set -u
ST=/st; mkdir -p $ST/asound/UAC2Gadget/pcm0c/sub0 $ST/asound/Loopback/pcm0p/sub0 /stub
echo " 1 [UAC2Gadget     ]: UAC2_Gadget" > $ST/asound/cards
echo "state: RUNNING" > $ST/asound/Loopback/pcm0p/sub0/status
: > $ST/events; : > $ST/amixer.log; : > $ST/alsactl.log; echo 48000 > $ST/rate

cat > /stub/pactl <<EOF
#!/bin/sh
case "\$1" in
load-module) case "\$2" in module-alsa-source) echo 11 ;; module-loopback) echo 12 ;; *) echo 13 ;; esac ;;
list) if [ "\$2" = short ]; then printf "11\tm\n12\tm\n13\tm\n"; else printf "Sink Input #5\n\tOwner Module: 12\n"; fi ;;
esac
exit 0
EOF
cat > /stub/amixer <<EOF
#!/bin/sh
case "\$*" in
*controls*) printf "numid=1,iface=PCM,name=\047Capture Pitch 1000000\047\nnumid=4,iface=PCM,name=\047Capture Rate\047\n" ;;
*cget*) echo cget >> $ST/amixer.log; echo "  : values=\$(cat $ST/rate)" ;;
esac
EOF
cat > /stub/alsactl <<EOF
#!/bin/sh
[ "\$1" = monitor ] || exit 1
echo "start \$2" >> $ST/alsactl.log
[ -f $ST/alsactl.fail ] && exit 1
echo \$\$ > $ST/alsactl.pid
exec tail -n 0 -f $ST/events
EOF
cat > /stub/alsaloop <<EOF
#!/bin/sh
echo \$\$ > $ST/alsaloop.pid
exec sleep 100000
EOF
printf "#!/bin/sh\nexec sleep 100000\n" > /stub/nq-uac2-silence
printf "#!/bin/sh\nexit 0\n" > /stub/nq-pa-rt
chmod +x /stub/*
export PATH=/stub:$PATH NQ_UAC2_ASOUND=$ST/asound

# The host: while $ST/streaming exists, hw_ptr advances.
( n=0; while :; do
    [ -f $ST/streaming ] && n=$((n + 480))
    printf "state: RUNNING\nhw_ptr : %s\n" $n > $ST/s.tmp
    mv $ST/s.tmp $ST/asound/UAC2Gadget/pcm0c/sub0/status
    sleep 0.5
  done ) &

event() { echo "node hw:UAC2Gadget, #$1 (3,0,0,$2,0) VALUE" >> $ST/events; }
alsaloop_up() { [ -f $ST/alsaloop.pid ] && kill -0 "$(cat $ST/alsaloop.pid)" 2>/dev/null; }
monitor_up() { [ -f $ST/alsactl.pid ] && kill -0 "$(cat $ST/alsactl.pid)" 2>/dev/null; }
say() { echo "RESULT $*"; }

if [ "${MODE:-}" = giveup ]; then
    # A monitor that cannot run: given up after three tries, then left alone.
    touch $ST/alsactl.fail $ST/streaming
    sh /svc > $ST/svc.log 2>&1 &
    SVCPID=$!
    sleep 16
    grep -q "Capture Rate monitor keeps dying" $ST/svc.log && say giveup=yes || say giveup=no
    n=$(grep -c "^start" $ST/alsactl.log)
    sleep 9
    say giveup_starts=$n
    [ "$(grep -c "^start" $ST/alsactl.log)" = "$n" ] && say giveup_quiet=yes || say giveup_quiet=no
    kill -TERM $SVCPID
    echo "---- service log"; cat $ST/svc.log
    exit 0
fi

if [ "${MODE:-}" = silent ]; then
    # The unit starts with the host idle, so it parks with no input ever seen and
    # the self-check does not apply; then the host starts and NO event comes.
    echo 0 > $ST/rate
    NQ_UAC2_BACKSTOP_TICKS=5 sh /svc > $ST/svc.log 2>&1 &
    SVCPID=$!
    sleep 16
    grep -q "waiting for its Capture Rate event" $ST/svc.log && say silent_parked=yes || say silent_parked=no
    echo 48000 > $ST/rate; touch $ST/streaming
    sleep 19
    grep -q "no Capture Rate event said so" $ST/svc.log && say backstop=yes || say backstop=no
    alsaloop_up && say backstop_alsaloop=running || say backstop_alsaloop=stopped
    monitor_up && say backstop_monitor=running || say backstop_monitor=stopped
    kill -TERM $SVCPID
    echo "---- service log"; cat $ST/svc.log
    exit 0
fi

if [ "${MODE:-}" = wedge ]; then
    # The host stops sending but keeps its stream open at 48000 Hz; parked on
    # the wedge, the monitor dies. Its catch-up read must not unpark.
    touch $ST/streaming
    NQ_UAC2_PARK_RETRY_S=600 sh /svc > $ST/svc.log 2>&1 &
    SVCPID=$!
    sleep 5
    rm -f $ST/streaming
    sleep 16
    grep -q "host still claims 48000 Hz" $ST/svc.log && say wedge_parked=yes || say wedge_parked=no
    kill "$(cat $ST/alsactl.pid)"
    sleep 5
    grep -q "Capture Rate monitor died, restarting it" $ST/svc.log && say wedge_restart=yes || say wedge_restart=no
    grep -q "USB audio live again" $ST/svc.log && say wedge_unparked=yes || say wedge_unparked=no
    alsaloop_up && say wedge_alsaloop=running || say wedge_alsaloop=stopped
    kill -TERM $SVCPID
    echo "---- service log"; cat $ST/svc.log
    exit 0
fi

touch $ST/streaming
sh /svc > $ST/svc.log 2>&1 &
SVCPID=$!
sleep 5
alsaloop_up && say bridging=yes || say bridging=no

# 1. the host closes its stream, and says so
rm -f $ST/streaming; echo 0 > $ST/rate; event 4 "Capture Rate"
sleep 3
grep -q "host closed the stream (Capture Rate -> 0)" $ST/svc.log && say event_park=yes || say event_park=no
alsaloop_up && say parked_alsaloop=running || say parked_alsaloop=stopped

# 2. parked: nothing is polled, and another control is not the host
: > $ST/amixer.log
event 1 "Capture Pitch 1000000"
sleep 14
say parked_polls=$(grep -c cget $ST/amixer.log)

# 3. the host opens its stream again
echo 48000 > $ST/rate; touch $ST/streaming; event 4 "Capture Rate"
sleep 3
grep -q "host started streaming at 48000 Hz" $ST/svc.log && say event_unpark=yes || say event_unpark=no
alsaloop_up && say unparked_alsaloop=running || say unparked_alsaloop=stopped

# 4. the monitor dies
: > $ST/amixer.log
kill "$(cat $ST/alsactl.pid)"
sleep 5
grep -q "Capture Rate monitor died, restarting it" $ST/svc.log && say monitor_restart=yes || say monitor_restart=no
say monitor_starts=$(grep -c "^start hw:UAC2Gadget$" $ST/alsactl.log)
say resync_reads=$(grep -c cget $ST/amixer.log)

# 5. the host closes its stream without an event
rm -f $ST/streaming; echo 0 > $ST/rate
sleep 18
grep -q "closed its stream without a Capture Rate event" $ST/svc.log && say distrust=yes || say distrust=no
monitor_up && say monitor_after_distrust=running || say monitor_after_distrust=stopped
: > $ST/amixer.log
sleep 13
[ "$(grep -c cget $ST/amixer.log)" -ge 1 ] && say fallback_polled=yes || say fallback_polled=no

# 6. stop
kill -TERM $SVCPID
i=0; while [ $i -lt 30 ] && kill -0 $SVCPID 2>/dev/null; do sleep 0.2; i=$((i + 1)); done
kill -0 $SVCPID 2>/dev/null && say stopped=no || say stopped=yes
monitor_up && say leftover_monitor=yes || say leftover_monitor=no
alsaloop_up && say leftover_alsaloop=yes || say leftover_alsaloop=no
echo "---- service log"; cat $ST/svc.log
'

PASS=0; FAIL=0
out="$(docker run --rm -v "$SVC":/svc:ro alpine:3.21 sh -c "$DRIVER" 2>&1)"
out_giveup="$(docker run --rm -e MODE=giveup -v "$SVC":/svc:ro alpine:3.21 sh -c "$DRIVER" 2>&1)"
out_silent="$(docker run --rm -e MODE=silent -v "$SVC":/svc:ro alpine:3.21 sh -c "$DRIVER" 2>&1)"
out_wedge="$(docker run --rm -e MODE=wedge -v "$SVC":/svc:ro alpine:3.21 sh -c "$DRIVER" 2>&1)"
check() {  # check <name> <expected RESULT line> [output]
    local o="${3:-$out}"
    if grep -qx "RESULT $2" <<<"$o"; then
        PASS=$((PASS+1)); printf '  \033[32mPASS\033[0m  %s\n' "$1"
    else
        FAIL=$((FAIL+1)); printf '  \033[31mFAIL\033[0m  %s (want %s, got %s)\n' "$1" "$2" \
            "$(grep "^RESULT ${2%%=*}=" <<<"$o" | head -1 | sed 's/^RESULT //')"
    fi
}

check "the bridge runs while the host streams"                       "bridging=yes"
check "host closes its stream: parked on the event"                  "event_park=yes"
check "  and alsaloop is stopped within 3 s, not 12"                 "parked_alsaloop=stopped"
check "parked on a closed stream: no amixer poll in 14 s"            "parked_polls=0"
check "host opens its stream: unparked on the event"                 "event_unpark=yes"
check "  and alsaloop runs again"                                    "unparked_alsaloop=running"
check "the monitor dies: it is restarted"                            "monitor_restart=yes"
check "  (two monitor starts in all)"                                "monitor_starts=2"
check "  and the flag is read once to catch up"                      "resync_reads=1"
check "a close without an event: the hw_ptr park says so"            "distrust=yes"
check "  and stops the monitor"                                      "monitor_after_distrust=stopped"
check "  and polls the flag again (at least once in 13 s)"           "fallback_polled=yes"
check "SIGTERM: the service exits"                                   "stopped=yes"
check "  leaving no monitor behind"                                  "leftover_monitor=no"
check "  and no alsaloop"                                            "leftover_alsaloop=no"
check "a monitor that cannot run is given up"                        "giveup=yes" "$out_giveup"
check "  after three starts"                                         "giveup_starts=3" "$out_giveup"
check "  and not re-forked after that"                               "giveup_quiet=yes" "$out_giveup"
check "host idle at start: parked, waiting for the event"            "silent_parked=yes" "$out_silent"
check "host starts, no event: the backstop read notices"             "backstop=yes" "$out_silent"
check "  and unparks"                                                "backstop_alsaloop=running" "$out_silent"
check "  and stops trusting the monitor"                             "backstop_monitor=stopped" "$out_silent"
check "parked on the wedge"                                          "wedge_parked=yes" "$out_wedge"
check "  the monitor dies and is restarted"                          "wedge_restart=yes" "$out_wedge"
check "  its catch-up read does not unpark the wedge"                "wedge_unparked=no" "$out_wedge"
check "  (alsaloop stays parked)"                                    "wedge_alsaloop=stopped" "$out_wedge"

if [ "$FAIL" -ne 0 ]; then
    printf '%s\n' "$out" "$out_giveup" "$out_silent" "$out_wedge" | sed -n '/^---- service log/,/^RESULT/p' | sed 's/^/        /'
fi
echo "  $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
