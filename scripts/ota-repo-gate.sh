#!/usr/bin/env bash
# ota-repo-gate.sh — refuse an OTA repo that a unit could not install as published.
#
# scripts/publish-ota-repo.sh takes the newest build of each package in
# pmos/ota-packages.list from the build volume. A package with no build there
# used to be skipped without a word: librespot entered the list with r100 on
# 2026-11-14, was never built on the publishing volume, and device r133 (which
# depends on it) was about to be published without it on 2026-11-16. A unit then
# resolves `librespot` to Alpine's own 0.8.0-r0 (the very build the override
# exists to replace) or, for a package nobody else carries, holds the device
# package back while `apk` still exits 0 (the 2026-08-23 holdback trap).
#
# So before anything is pushed, this gate checks the staged repo:
#   0. every upstream repository answers. apk 3 only WARNS about one that does
#      not and resolves without it, so a CDN hiccup on edge/main would blind
#      check 3 to exactly the Alpine builds our overrides replace; a unit's own
#      `upgrade` refuses outright in that state, so the gate refuses too.
#   1. complete: every package in the list is in the repo.
#   2. installable: `apk add --simulate` of everything the repo carries, on an
#      empty armv7 root against a unit's upstream repositories, with the
#      image-only packages (pmos/image-only-packages.list) installed as on a unit.
#   3. ours wins: that simulation picked exactly the version the repo carries for
#      each of its packages, not a newer one from upstream.
#   4. for each --unit-root: that unit's own update. Its apk state (captured
#      from the unit by scripts/capture-unit-apk-state.sh into private/units/,
#      or an image's) runs a System update's exact command, `apk upgrade
#      --available --ignore linux-google-steelhead` (nexusq-control
#      _ota_upgrade_args). It must succeed, and every package the repo carries
#      that the unit has must END at the repo's version: an upgrade that keeps
#      the old one because a dependency cannot move is the holdback trap, rc 0.
#      A carried package the update would remove, or roll back (the build volume
#      behind what the unit runs), is refused too. This sees what the empty root
#      cannot: conflicts with installed packages outside our closure, purges, a
#      package left behind. The same update runs first against upstream alone:
#      a unit that cannot take edge as it stands is reported, not judged, so
#      upstream churn never blocks a publish (a hotfix included).
# The checks run in a container: scripts/ota-repo-gate-container.sh.
# Signatures are not this gate's business (publish-ota-repo.sh checks every apk
# against the fleet key before indexing), so the simulations run untrusted.
#
# Usage: ota-repo-gate.sh [--unit-root <dir>]... <repo-dir> <ota-packages.list> [<name>=<version>...]
#   --unit-root <dir> a unit's apk state: <dir>/lib/apk/db/installed,
#                     <dir>/etc/apk/world, and <dir>/LABEL naming it (optional)
#   <repo-dir>        the staged tree: <repo-dir>/armv7/*.apk + APKINDEX.tar.gz
#   <name>=<version>  a package every unit has from its image that the repo does
#                     not carry, at the oldest version still in the field
# Env:
#   OTA_GATE_REPOS  upstream repositories, one per line, in a unit's order
#                   (default: a unit's /etc/apk/repositories without ours, as read
#                   on the Prague Q 2026-11-16). An entry starting with / is a
#                   local directory, mounted read-only at the same path (tests).
#   OTA_GATE_IMAGE  the container the simulations run in (default alpine:edge:
#                   apk 3, as on the units, which run edge); pulled first so the
#                   resolver does not age, and its apk-tools upgraded to edge's,
#                   unless OTA_GATE_PULL=0 (the tests, which run offline).
# Exit: 0 pass, 1 refused, 2 usage.
set -euo pipefail

usage() { echo "usage: $0 [--unit-root <dir>]... <repo-dir> <ota-packages.list> [<name>=<version>...]" >&2; exit 2; }
HERE="$(cd "$(dirname "$0")" && pwd)"

UNITS=()
while [ "${1:-}" = "--unit-root" ]; do
    [ "$#" -ge 2 ] || usage
    [ -f "$2/lib/apk/db/installed" ] && [ -f "$2/etc/apk/world" ] || {
        echo "ERROR: $2 holds no apk database (lib/apk/db/installed, etc/apk/world)" >&2; exit 2; }
    UNITS+=("$(cd "$2" && pwd)")
    shift 2
done
[ "$#" -ge 2 ] || usage
[ -d "$1/armv7" ] || { echo "ERROR: $1/armv7 does not exist" >&2; exit 2; }
REPO_DIR="$(cd "$1" && pwd)"
LIST="$2"
shift 2
[ -f "$REPO_DIR/armv7/APKINDEX.tar.gz" ] || { echo "ERROR: $REPO_DIR/armv7 has no APKINDEX.tar.gz" >&2; exit 2; }
[ -f "$LIST" ] || { echo "ERROR: no package list at $LIST" >&2; exit 2; }

PROVIDES=""
for pv in "$@"; do
    case "$pv" in
        ?*=?*) PROVIDES="$PROVIDES $pv" ;;
        *) echo "ERROR: '$pv' is not <name>=<version>" >&2; exit 2 ;;
    esac
done

LISTED="$(sed 's/#.*//' "$LIST" | tr -d '[:blank:]' | grep -v '^$' | tr '\n' ' ')"
[ -n "$LISTED" ] || { echo "ERROR: $LIST lists no packages" >&2; exit 2; }

REPOS="${OTA_GATE_REPOS:-http://mirror.postmarketos.org/postmarketos/extra-repos/systemd/main
http://mirror.postmarketos.org/postmarketos/main
http://dl-cdn.alpinelinux.org/alpine/edge/main
http://dl-cdn.alpinelinux.org/alpine/edge/community
http://dl-cdn.alpinelinux.org/alpine/edge/testing}"

IMAGE="${OTA_GATE_IMAGE:-alpine:edge}"
PULL="${OTA_GATE_PULL:-1}"
[ "$PULL" = "0" ] || docker pull -q "$IMAGE" >/dev/null

mounts=(-v "$REPO_DIR:/ours:ro" -v "$HERE/ota-repo-gate-container.sh:/gate.sh:ro")
# A unit is named by its LABEL file, else by its directory.
labels=""
i=0
for u in ${UNITS[@]+"${UNITS[@]}"}; do
    mounts+=(-v "$u:/units/$i:ro")
    if [ -f "$u/LABEL" ]; then l=$(head -1 "$u/LABEL"); else l=$(basename "$u"); fi
    labels="$labels$i	$l
"
    i=$((i + 1))
done
while IFS= read -r r; do
    case "$r" in /*) mounts+=(-v "$r:$r:ro") ;; esac
done <<<"$REPOS"

docker run --rm "${mounts[@]}" \
    -e LISTED="$LISTED" -e PROVIDES="$PROVIDES" -e REPOS="$REPOS" -e PULL="$PULL" -e LABELS="$labels" \
    "$IMAGE" sh /gate.sh
