#!/usr/bin/env bash
#
# Move the mesa-sgx pin of pmos/nexusq-sgx-mesa to a new upstream commit --
# the update path for the SGX540's GBM/EGL/GLES2 front end.
#
# The aport carries no copy of Mesa. It fetches Maemo Leste's
# leste-upstream-forks/mesa as an archive of ONE commit (_mesa_commit), checks
# it against _mesa_sha512 in unpack() and applies our patches (0001 dma-buf
# import, 0002 GL_EXT_unpack_subimage). This script moves that pin; per run it
#   1. resolves the target -- a 40-hex commit, a branch or tag name, or (no
#      argument) the head of the branch the aport tracks (_mesa_branch);
#   2. downloads that commit's archive and hashes it;
#   3. test-applies the series the way abuild does: the aport's own unpack()
#      and default patch order (sourced from a copy of the APKBUILD carrying
#      the new pin), GNU patch for every *.patch in source=;
#   4. only if that passed, writes commit + sha512 (+ branch) into the
#      APKBUILD. Any failure leaves it untouched and exits non-zero, naming the
#      patch that no longer applies.
# It does not bump pkgrel or write the CHANGELOG: a new pin is a revision of
# its own, and a new Mesa wants the on-device B1/B2 tests
# (docs/gpu-sgx540/b1-b2-desktop-blockers-2026-10-11.md) before it ships.
#
# Usage: scripts/bump-sgx-mesa.sh [--check] [--keep] [<commit>|<branch>|<tag>]
#   --check   test-apply the CURRENT pin; never writes
#   --keep    keep the patched work tree and print its path
#
# Environment (defaults are the real thing; the tests point them elsewhere):
#   NQ_REPO_ROOT     repo root (default: this script's ../)
#   NQ_MESA_REPO     upstream repo (default: git.maemo.org leste-upstream-forks/mesa)
#   NQ_DISTFILES     download cache (default: ${XDG_CACHE_HOME:-~/.cache}/nexusq/distfiles)
#
# Plain bash 3.2 (macOS /bin/bash) compatible.
set -euo pipefail

die() { printf 'bump-sgx-mesa: ERROR: %s\n' "$*" >&2; exit 1; }
say() { printf 'bump-sgx-mesa: %s\n' "$*"; }

check_only=0 keep=0 target=""
while [ $# -gt 0 ]; do
    case "$1" in
        --check) check_only=1 ;;
        --keep) keep=1 ;;
        -h | --help) sed -n '2,/^set -euo/p' "$0" | sed '$d; s/^# \{0,1\}//'; exit 0 ;;
        -*) die "unknown option: $1" ;;
        *) [ -z "$target" ] || die "one target only"; target="$1" ;;
    esac
    shift
done
[ "$check_only" = 1 ] && [ -n "$target" ] && die "--check takes no target: it re-checks the current pin"

ROOT="${NQ_REPO_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
APORT="$ROOT/pmos/nexusq-sgx-mesa"
APKBUILD="$APORT/APKBUILD"
UPSTREAM="${NQ_MESA_REPO:-https://git.maemo.org/leste-upstream-forks/mesa}"
DIST="${NQ_DISTFILES:-${XDG_CACHE_HOME:-$HOME/.cache}/nexusq/distfiles}"
[ -f "$APKBUILD" ] || die "no APKBUILD at $APKBUILD"

PATCH_BIN=""
for p in gpatch patch; do
    if command -v "$p" >/dev/null 2>&1 && "$p" --version 2>/dev/null | grep -q 'GNU patch'; then
        PATCH_BIN="$p"
        break
    fi
done
[ -n "$PATCH_BIN" ] || die "GNU patch not found (macOS: brew install gpatch)"
if command -v sha512sum >/dev/null 2>&1; then
    sha512() { sha512sum "$1" | cut -d' ' -f1; }
else
    sha512() { shasum -a 512 "$1" | cut -d' ' -f1; }
fi
for t in curl git tar gzip; do command -v "$t" >/dev/null 2>&1 || die "$t not found"; done

pin_get() { sed -n "s/^$1=//p" "$2" | head -1; }
cur_branch=$(pin_get _mesa_branch "$APKBUILD")
cur_commit=$(pin_get _mesa_commit "$APKBUILD")
cur_sha=$(pin_get _mesa_sha512 "$APKBUILD")
[ -n "$cur_commit" ] && [ -n "$cur_sha" ] || die "the APKBUILD has no _mesa_commit/_mesa_sha512 line"

# --- 1. resolve the target ----------------------------------------------------------
is_sha() { printf '%s' "$1" | grep -Eqx '[0-9a-f]{40}'; }
new_branch="$cur_branch"
if [ "$check_only" = 1 ]; then
    new_commit="$cur_commit"
elif [ -n "$target" ] && is_sha "$target"; then
    new_commit="$target"
else
    ref="${target:-$new_branch}"
    [ -n "$ref" ] || die "no target given and the APKBUILD names no _mesa_branch"
    # A tag or a branch. An annotated tag's commit is on its peeled line
    # (refs/tags/<t>^{}), which ls-remote prints only in a full listing.
    refs=$(git ls-remote "$UPSTREAM") || die "cannot list $UPSTREAM"
    new_commit=""
    for want in "refs/tags/$ref^{}" "refs/tags/$ref" "refs/heads/$ref"; do
        new_commit=$(printf '%s\n' "$refs" | awk -v r="$want" '$2 == r { print $1; exit }')
        [ -n "$new_commit" ] || continue
        [ "$want" = "refs/heads/$ref" ] && new_branch="$ref"
        break
    done
    is_sha "$new_commit" || die "'$ref' is neither a branch nor a tag of $UPSTREAM"
    say "$ref is at $new_commit"
fi

# --- 2. fetch -----------------------------------------------------------------------
mkdir -p "$DIST"
archive="mesa-sgx-$new_commit.tar.gz"
if [ ! -s "$DIST/$archive" ]; then
    say "downloading $UPSTREAM/archive/$new_commit.tar.gz"
    curl -fsSL --retry 3 -o "$DIST/$archive.part" "$UPSTREAM/archive/$new_commit.tar.gz" \
        || { rm -f -- "$DIST/$archive.part"; die "download failed"; }
    mv "$DIST/$archive.part" "$DIST/$archive"
fi
new_sha=$(sha512 "$DIST/$archive")
if [ "$new_commit" = "$cur_commit" ] && [ "$new_sha" != "$cur_sha" ]; then
    die "the archive of the PINNED commit $cur_commit no longer matches its sha512 -- upstream served different bytes for the same commit; find out why before anything else ($DIST/$archive)"
fi

# --- 3. test-apply, with the aport's own unpack() -----------------------------------
WORK=$(mktemp -d "${TMPDIR:-/tmp}/bump-sgx-mesa.XXXXXX")
cleanup() {
    if [ "$keep" = 1 ]; then say "work tree kept: $WORK"; else rm -rf -- "${WORK:?}"; fi
}
trap cleanup EXIT

candidate="$WORK/APKBUILD"
sed -e "s/^_mesa_commit=.*/_mesa_commit=$new_commit/" \
    -e "s/^_mesa_sha512=.*/_mesa_sha512=$new_sha/" \
    -e "s#^_mesa_branch=.*#_mesa_branch=$new_branch#" \
    "$APKBUILD" > "$candidate"

say "test-applying the series on mesa-sgx ${new_commit:0:12}"
log="$WORK/apply.log"
set +e
# shellcheck disable=SC2034,SC2329,SC2154
(
    set -e
    srcdir="$WORK/src"
    SRCDEST="$DIST"
    mkdir -p "$srcdir"
    msg() { printf '>>> %s\n' "$*"; }
    error() { printf '>>> ERROR: %s\n' "$*" >&2; }
    die() { error "$@"; exit 1; }
    fetch() { :; }
    command -v sha512sum >/dev/null 2>&1 || sha512sum() { shasum -a 512 "$@"; }
    # shellcheck disable=SC1090
    . "$candidate"
    unpack
    cd "$builddir"
    failed=""
    for s in $source; do
        case ${s%%::*} in
            *.patch)
                msg "$s"
                "$PATCH_BIN" -p1 -i "$APORT/$s" || failed="$failed $s"
                ;;
        esac
    done
    [ -z "$failed" ] || { error "The following patches failed to apply:$failed"; exit 1; }
) > "$log" 2>&1
rc=$?
set -e
grep -E 'with fuzz|FAILED|saving rejects|does not match the pinned' "$log" | sed 's/^/  /' >&2 || true
if [ $rc -ne 0 ]; then
    grep -A20 'ERROR' "$log" | sed 's/^/  /' >&2 || true
    die "the series does NOT apply on mesa-sgx $new_commit -- the APKBUILD is unchanged (--keep keeps the tree and the log)"
fi
grep -q 'with fuzz' "$log" && say "WARNING: hunks applied with fuzz (listed above) -- regenerate those patches"
say "series applies cleanly ($(grep -c '^>>> [0-9]\{4\}-' "$log") patches)"

# --- 4. write the pin ---------------------------------------------------------------
if [ "$check_only" = 1 ]; then
    say "OK: the current pin $cur_commit applies (--check, nothing written)"
    exit 0
fi
if [ "$new_commit" = "$cur_commit" ] && [ "$new_branch" = "$cur_branch" ]; then
    say "OK: already pinned to $new_commit, nothing to change"
    exit 0
fi
cat "$candidate" > "$APKBUILD"
say "pinned mesa-sgx ${new_branch:+$new_branch @ }$new_commit"
say "  sha512 $new_sha"
say "next: bump pkgrel (and pkgver if Mesa moved), CHANGELOG, build, run the B1/B2 tests on a unit"
