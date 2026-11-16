#!/usr/bin/env bash
# capture-unit-apk-state.sh — record a unit's apk state for the OTA install gate.
#
# scripts/ota-repo-gate.sh simulates each unit's System update against the repo
# about to be published (check 4). It needs what the unit really has installed:
# the last image built on the volume holds exactly the versions being published
# after a full build, so it proves nothing, and it never looks like the cottage
# unit, which may sit on an older release for weeks. This copies a unit's
# /lib/apk/db/installed, /etc/apk/world and /etc/apk/repositories (the gate
# simulates with the unit's own upstream repositories) over ssh into
#   private/units/<hostname>/  (the gitignored personal overlay)
# with a LABEL naming the unit and the capture time. publish-ota-repo.sh hands
# every state there to the gate. Capture again after a unit changes (an update,
# a flash); the gate prints each state's age.
#
# Usage: scripts/capture-unit-apk-state.sh <ssh-target> <expected-hostname>
#   e.g. scripts/capture-unit-apk-state.sh root@192.168.20.246 steelhead
# The unit's hostname is read FIRST and must match: a reachable address proves
# nothing (addresses have moved between devices). Read-only on the unit.
set -euo pipefail

[ "$#" -eq 2 ] || { echo "usage: $0 <ssh-target> <expected-hostname>" >&2; exit 2; }
TARGET="$1"
WANT="$2"
case "$WANT" in *[!a-zA-Z0-9.-]*|"") echo "ERROR: '$WANT' is not a hostname" >&2; exit 2 ;; esac

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT_ROOT="${UNIT_STATE_DIR:-$REPO_ROOT/private/units}"
SSH=(ssh -o ConnectTimeout=8 -o BatchMode=yes -o ServerAliveInterval=5 -o ServerAliveCountMax=3 "$TARGET")
# macOS (where releases are cut too) has no `timeout`; Homebrew's coreutils
# calls it gtimeout. Without either, ssh's own connect and keep-alive limits hold.
if command -v timeout >/dev/null 2>&1; then TO=(timeout 30)
elif command -v gtimeout >/dev/null 2>&1; then TO=(gtimeout 30)
else TO=(); fi

got=$(${TO[@]+"${TO[@]}"} "${SSH[@]}" hostname) || { echo "ERROR: could not reach $TARGET" >&2; exit 1; }
if [ "$got" != "$WANT" ]; then
    echo "ERROR: $TARGET is '$got', not '$WANT' — refusing to record it as $WANT" >&2
    exit 1
fi

tmp="$(mktemp -d "${OUT_ROOT%/*}/.unit-state.XXXXXX" 2>/dev/null || mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/lib/apk/db" "$tmp/etc/apk"
${TO[@]+"${TO[@]}"} "${SSH[@]}" cat /lib/apk/db/installed > "$tmp/lib/apk/db/installed"
${TO[@]+"${TO[@]}"} "${SSH[@]}" cat /etc/apk/world > "$tmp/etc/apk/world"
${TO[@]+"${TO[@]}"} "${SSH[@]}" cat /etc/apk/repositories > "$tmp/etc/apk/repositories"
grep -q '^P:' "$tmp/lib/apk/db/installed" || { echo "ERROR: $TARGET returned no installed packages" >&2; exit 1; }
n=$(grep -c '^P:' "$tmp/lib/apk/db/installed")
when=$(date '+%Y-%m-%d %H:%M %Z')
echo "$WANT (captured $when, $n packages)" > "$tmp/LABEL"

mkdir -p "$OUT_ROOT"
dest="$OUT_ROOT/$WANT"
if [ -e "$dest" ]; then
    # The previous capture goes to the trash, never overwritten in place.
    # gio (Linux desktops), trash-put (trash-cli), /usr/bin/trash (macOS 14+).
    gio trash "$dest" 2>/dev/null || trash-put "$dest" 2>/dev/null || /usr/bin/trash "$dest" 2>/dev/null \
        || { echo "ERROR: could not move the old $dest to the trash" >&2; exit 1; }
fi
mv "$tmp" "$dest"
trap - EXIT
echo "recorded $(cat "$dest/LABEL") in $dest"
