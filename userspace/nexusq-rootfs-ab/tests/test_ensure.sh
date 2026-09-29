#!/bin/sh
# needs: docker  (tools/dev/test-shell.sh runs it in the docker lane, `just test-sh-docker`)
# Tests for `nq-rootfs-ab ensure --auto`, the storage check after every OTA
# (nexusq-rootfs-ab r4, 2026-09-26).
#
# What is being protected: the check runs every 30 min for the life of the unit,
# so between updates it must cost nothing (one stat, no child process), and after
# every OTA it must run in full -- the online half first, the offline split only
# if slot B is still missing, and that at most once per OTA. The heavy halves are
# tested elsewhere (test_ab_split.sh, test_init_split.sh); here the online half is
# a stub that records each call, and sysfs and the apk database are fixtures.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
# The unit runs this under BusyBox (stat -c, flock); so does the test. Off Linux,
# re-run inside Alpine rather than against the host's BSD tools.
if [ "$(uname -s)" != Linux ] && [ -z "${NQ_TEST_IN_CONTAINER:-}" ]; then
    command -v docker >/dev/null || { echo "docker required off Linux" >&2; exit 2; }
    exec docker run --rm -e NQ_TEST_IN_CONTAINER=1 -v "$HERE/..:/ab:ro" alpine:3.21 \
        sh /ab/tests/test_ensure.sh
fi
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
PASS=0; FAIL=0
check() { if [ "$1" = "$2" ]; then PASS=$((PASS+1)); echo "  PASS  $3"; else FAIL=$((FAIL+1)); echo "  FAIL  $3 (got '$1', expected '$2')"; fi; }

mkdir -p "$T/db" "$T/state" "$T/sys/mmcblk0" "$T/bin"
echo "P:device-google-steelhead" > "$T/db/installed"; : > "$T/db/lock"
printf '#!/bin/sh\necho call >> %s/resize.calls\n' "$T" > "$T/bin/resize"; chmod +x "$T/bin/resize"
export NQ_AB_APKDB="$T/db" NQ_AB_STATE="$T/state" NQ_AB_SYSBLOCK="$T/sys" NQ_AB_RESIZE="$T/bin/resize"
calls() { wc -l < "$T/resize.calls" 2>/dev/null | tr -d ' ' || echo 0; }
AB="$HERE/../nq-rootfs-ab"

# the pure pieces
eval "$(sed -n '/^# TESTABLE:apk_generation$/,/^}/p;/^# TESTABLE:done_for$/,/^}/p' "$AB")"
g1=$(apk_generation "$T/db/installed")
check "$(apk_generation "$T/nonexistent")" none "no apk db -> 'none', never an empty token"
printf '2026-09-26T10:00:00Z %s\n' "$g1" > "$T/rec"
check "$(done_for "$T/rec" "$g1" && echo y || echo n)" y "a record naming this generation is done"
check "$(done_for "$T/rec" other && echo y || echo n)" n "another generation is not"
check "$(done_for "$T/none" "$g1" && echo y || echo n)" n "no record is not"
printf '2026-09-26T10:37:31Z auto\n' > "$T/rec"
check "$(done_for "$T/rec" "$g1" && echo y || echo n)" n "an old two-field record (r2/r3 builds) never matches"

echo "=== a split unit: one full check, then nothing until the next OTA ==="
mkdir -p "$T/sys/mmcblk0p14"                       # slot B exists
sh "$AB" ensure --auto >/dev/null 2>&1
check "$(calls)" 1 "first run: the online half runs"
check "$(awk '{print $NF}' "$T/state/storage-ok")" "$g1" "and the generation it checked is recorded"
sh "$AB" ensure --auto >/dev/null 2>&1
sh "$AB" ensure --auto >/dev/null 2>&1
check "$(calls)" 1 "same system state: two more runs call nothing"
sleep 1; echo "P:nexusq-control" >> "$T/db/installed"   # an OTA: the apk db changes
sh "$AB" ensure --auto >/dev/null 2>&1
check "$(calls)" 2 "after an OTA the check runs in full again"
check "$(awk '{print $NF}' "$T/state/storage-ok")" "$(apk_generation "$T/db/installed")" "and records the new generation"
sh "$AB" ensure >/dev/null 2>&1
check "$(calls)" 3 "without --auto (by hand) it always runs"

echo "=== apk busy: wait, change nothing ==="
rm -f "$T/state/storage-ok"; sleep 1; echo x >> "$T/db/installed"
flock "$T/db/lock" sh "$AB" ensure --auto >/dev/null 2>&1   # holds the lock around the run
check "$(calls)" 3 "while apk holds its lock nothing runs"
check "$([ -f "$T/state/storage-ok" ] && echo recorded || echo none)" none "and nothing is recorded"

echo "=== no slot B after the online half: on to the offline split ==="
rmdir "$T/sys/mmcblk0p14"
out=$(sh "$AB" ensure --auto 2>&1)
check "$(calls)" 4 "the online half runs first"
check "$([ -f "$T/state/storage-ok" ] && echo recorded || echo none)" none "storage is NOT recorded as ok"
case "$out" in *"cannot tell which slot"*|*"not running from slot A"*) r="split" ;; *) r="$out" ;; esac
check "$r" split "and it goes on into split (which, off-device, stops at its own slot check)"

echo
echo "================ $PASS passed, $FAIL failed ================"
[ "$FAIL" -eq 0 ]
