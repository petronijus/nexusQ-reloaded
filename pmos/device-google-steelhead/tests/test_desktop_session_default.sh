#!/usr/bin/env bash
# needs: docker  (tools/dev/test-shell.sh runs it in the docker lane, `just test-sh-docker`)
# Tests for r127: the default tinydm session becomes lxqt-wayland-nexusq.desktop
# (GPU when the SGX540 is ready, Pixman otherwise) on a fresh image and on a box
# upgraded in the field -- but only where the stock default was still in place.
#
# .post-install/.post-upgrade use absolute paths (they run as root on the
# device), so the cases run in a throwaway container playing the device, like
# test_oomd_off.sh.
#
# Usage: pmos/device-google-steelhead/tests/test_desktop_session_default.sh
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
PKGDIR="$HERE/.."
command -v docker >/dev/null || { echo "docker required" >&2; exit 2; }

PASS=0; FAIL=0
check() {  # check <name> <output> <expected-marker>
    if grep -q -e "$3" <<<"$2"; then
        PASS=$((PASS+1)); printf '  \033[32mPASS\033[0m  %s\n' "$1"
    else
        FAIL=$((FAIL+1)); printf '  \033[31mFAIL\033[0m  %s\n' "$1"
        printf '%s\n' "$2" | sed 's/^/        /'
    fi
}

S=/usr/share/wayland-sessions
SETUP="mkdir -p /var/lib/tinydm $S
touch $S/lxqt-wayland.desktop $S/lxqt-wayland-nexusq.desktop $S/weston-nexusq.desktop"
# shellcheck disable=SC2016  # expands inside the container, not here
SHOW='echo "LINK=$(readlink /var/lib/tinydm/default-session.desktop 2>/dev/null || echo none)"'

run_case() {  # run_case <commands>: in a fresh container, then print the link
    docker run --rm \
        -v "$PKGDIR/device-google-steelhead.post-upgrade":/post-upgrade:ro \
        -v "$PKGDIR/device-google-steelhead.post-install":/post-install:ro \
        alpine:3.21 sh -c "set -u; $SETUP; $1; $SHOW"
}

out=$(run_case "sh /post-install >/dev/null 2>&1")
check "fresh image: .post-install makes the GPU-capable session the default" "$out" "LINK=$S/lxqt-wayland-nexusq.desktop"

out=$(run_case "ln -s $S/lxqt-wayland.desktop /var/lib/tinydm/default-session.desktop; sh /post-upgrade >/dev/null 2>&1")
check "upgrade: the stock default moves to lxqt-wayland-nexusq.desktop" "$out" "LINK=$S/lxqt-wayland-nexusq.desktop"

out=$(run_case "ln -s $S/weston-nexusq.desktop /var/lib/tinydm/default-session.desktop; sh /post-upgrade >/dev/null 2>&1")
check "upgrade: a session picked by hand (weston) is left alone" "$out" "LINK=$S/weston-nexusq.desktop"

out=$(run_case "sh /post-upgrade >/dev/null 2>&1")
check "upgrade: a box without the link gets none" "$out" "LINK=none"

out=$(run_case "ln -s $S/lxqt-wayland.desktop /var/lib/tinydm/default-session.desktop; sh /post-upgrade >/dev/null 2>&1; sh /post-upgrade >/dev/null 2>&1")
check "upgrade twice: idempotent" "$out" "LINK=$S/lxqt-wayland-nexusq.desktop"

echo "  $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
