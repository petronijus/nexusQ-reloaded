#!/usr/bin/env bash
# Tests for scripts/capture-unit-apk-state.sh, with a fake `ssh` on PATH that
# plays a unit: it answers `hostname` and `cat` of the two apk files.
#
# Usage: scripts/tests/test-capture-unit-apk-state.sh
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
CAPTURE="$HERE/../capture-unit-apk-state.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  \033[32mPASS\033[0m  %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  \033[31mFAIL\033[0m  %s\n' "$1"; [ -n "${2:-}" ] && printf '%s\n' "$2" | sed 's/^/        /'; }

mkdir -p "$WORK/bin"
cat > "$WORK/bin/ssh" <<'SH'
#!/bin/sh
# fake ssh: like the real one, the remote command is the arguments after the target
case "$*" in
    *" hostname") echo "$FAKE_HOSTNAME" ;;
    *" cat /lib/apk/db/installed") printf 'P:nexusq-control\nV:0.1.0-r73\n\nP:librespot\nV:0.8.0-r0\n\n' ;;
    *" cat /etc/apk/world") printf 'device-google-steelhead\n' ;;
    *" cat /etc/apk/repositories") printf 'http://dl-cdn.alpinelinux.org/alpine/edge/main\n' ;;
    *) exit 127 ;;
esac
SH
chmod +x "$WORK/bin/ssh"

run() {  # run <fake-hostname> <args...>
    local h="$1"; shift
    out=$(PATH="$WORK/bin:$PATH" FAKE_HOSTNAME="$h" UNIT_STATE_DIR="$WORK/units" "$CAPTURE" "$@" 2>&1); rc=$?
}

echo "capture-unit-apk-state"

run steelhead root@unit steelhead
if [ "$rc" -eq 0 ] && grep -q '^P:librespot' "$WORK/units/steelhead/lib/apk/db/installed" \
        && grep -qx device-google-steelhead "$WORK/units/steelhead/etc/apk/world" \
        && grep -q 'edge/main' "$WORK/units/steelhead/etc/apk/repositories" \
        && grep -q '^steelhead (captured .*, 2 packages)$' "$WORK/units/steelhead/LABEL"; then
    ok "the unit's installed db, world, repositories and a dated label are recorded under its hostname"
else bad "a capture from the right unit did not record its state (rc=$rc)" "$out"; fi

run nexus-q-sumperak root@unit steelhead
if [ "$rc" -eq 1 ] && grep -q "is 'nexus-q-sumperak', not 'steelhead'" <<<"$out" && [ ! -e "$WORK/units/nexus-q-sumperak" ]; then
    ok "a unit whose hostname is not the expected one is refused and nothing is recorded"
else bad "a wrong unit was recorded (rc=$rc)" "$out"; fi

run steelhead root@unit 'bad/name'
if [ "$rc" -eq 2 ]; then ok "an expected hostname that is not a hostname is a usage error"
else bad "a malformed hostname was accepted (rc=$rc)" "$out"; fi

echo "  $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
