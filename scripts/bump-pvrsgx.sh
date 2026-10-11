#!/usr/bin/env bash
#
# Move the openpvrsgx pin of pmos/linux-google-steelhead to a new upstream
# commit -- the update path for the PowerVR SGX540 kernel driver.
#
# The kernel aport does not carry a copy of the driver. It fetches the
# openpvrsgx kernel tree as a GitHub archive of ONE commit (_pvrsgx_commit),
# checks it against _pvrsgx_sha512, copies drivers/gpu/drm/pvrsgx into the
# 6.18 tree in prepare() and applies our patches on top (0063 hooks the
# directory into DRM, 0064-0073 fix it). That keeps upstream's fixes reachable
# instead of freezing them in kernel/patches, and this script is how they are
# reached: per run it
#   1. resolves the target -- a 40-hex commit, a branch name, or (no argument)
#      the head of the branch the aport tracks (_pvrsgx_branch);
#   2. downloads that commit's archive and hashes it;
#   3. test-applies the WHOLE series the way abuild does: a pristine
#      linux-$pkgver tree, the aport's own unpack() and prepare() (sourced from
#      a copy of the APKBUILD carrying the new pin, so the file list and the
#      patch order are the aport's, not a second copy kept here), GNU patch for
#      every *.patch in source=;
#   4. optionally runs `make ARCH=arm olddefconfig` with steelhead_defconfig on
#      that tree and checks the SGX symbols survive it (they are dropped
#      silently when an upstream Kconfig renames them);
#   5. only if all of that passed, writes commit + sha512 (+ branch) into the
#      APKBUILD. Any failure leaves the APKBUILD untouched and exits non-zero,
#      naming the patch that no longer applies.
# It does not bump pkgrel or write the CHANGELOG: a new pin is a kernel
# revision of its own, and the script says so when it is done.
#
# A patch that no longer applies: regenerate it against the new tree (the
# work tree is kept with --keep), then re-run.
#
# Usage: scripts/bump-pvrsgx.sh [--check] [--keep] [--no-kconfig] [<commit>|<branch>]
#   --check       test-apply the CURRENT pin; never writes (a cheap re-check
#                 after editing one of our patches)
#   --keep        keep the patched work tree and print its path
#   --no-kconfig  skip step 4 (it needs a host cc, make, flex and bison)
#
# Environment (defaults are the real thing; the tests point them elsewhere):
#   NQ_REPO_ROOT       repo root (default: this script's ../)
#   NQ_PVRSGX_REPO     upstream repo (default: github openpvrsgx-devgroup/linux_openpvrsgx)
#   NQ_KERNEL_MIRROR   where linux-$pkgver.tar.xz lives (default: cdn.kernel.org v6.x)
#   NQ_DISTFILES       download cache (default: ${XDG_CACHE_HOME:-~/.cache}/nexusq/distfiles)
#
# Plain bash 3.2 (macOS /bin/bash) compatible.
set -euo pipefail

die() { printf 'bump-pvrsgx: ERROR: %s\n' "$*" >&2; exit 1; }
say() { printf 'bump-pvrsgx: %s\n' "$*"; }

check_only=0 keep=0 kconfig=1 target=""
while [ $# -gt 0 ]; do
    case "$1" in
        --check) check_only=1 ;;
        --keep) keep=1 ;;
        --no-kconfig) kconfig=0 ;;
        -h | --help) sed -n '2,/^set -euo/p' "$0" | sed '$d; s/^# \{0,1\}//'; exit 0 ;;
        -*) die "unknown option: $1" ;;
        *) [ -z "$target" ] || die "one target only"; target="$1" ;;
    esac
    shift
done
[ "$check_only" = 1 ] && [ -n "$target" ] && die "--check takes no target: it re-checks the current pin"

ROOT="${NQ_REPO_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
APKBUILD="$ROOT/pmos/linux-google-steelhead/APKBUILD"
PATCHES="$ROOT/kernel/patches"
DEFCONFIG="$ROOT/kernel/configs/steelhead_defconfig"
UPSTREAM="${NQ_PVRSGX_REPO:-https://github.com/openpvrsgx-devgroup/linux_openpvrsgx}"
MIRROR="${NQ_KERNEL_MIRROR:-https://cdn.kernel.org/pub/linux/kernel/v6.x}"
DIST="${NQ_DISTFILES:-${XDG_CACHE_HOME:-$HOME/.cache}/nexusq/distfiles}"
[ -f "$APKBUILD" ] || die "no APKBUILD at $APKBUILD"

# --- tools ---------------------------------------------------------------------
# abuild applies patches with GNU patch; BSD patch (macOS) accepts different
# fuzz and would make this a test of something else.
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
for t in curl git tar gzip xz; do command -v "$t" >/dev/null 2>&1 || die "$t not found"; done

# --- the current pin (the APKBUILD is plain assignments at top level) ----------
pin_get() { sed -n "s/^$1=//p" "$2" | head -1; }
cur_branch=$(pin_get _pvrsgx_branch "$APKBUILD")
cur_commit=$(pin_get _pvrsgx_commit "$APKBUILD")
cur_sha=$(pin_get _pvrsgx_sha512 "$APKBUILD")
pkgver=$(pin_get pkgver "$APKBUILD")
[ -n "$cur_commit" ] && [ -n "$cur_sha" ] && [ -n "$pkgver" ] \
    || die "the APKBUILD has no _pvrsgx_commit/_pvrsgx_sha512/pkgver line"

# --- 1. resolve the target ------------------------------------------------------
is_sha() { printf '%s' "$1" | grep -Eqx '[0-9a-f]{40}'; }
new_branch="$cur_branch"
if [ "$check_only" = 1 ]; then
    new_commit="$cur_commit"
elif [ -n "$target" ] && is_sha "$target"; then
    new_commit="$target"
else
    [ -n "$target" ] && new_branch="$target"
    [ -n "$new_branch" ] || die "no target given and the APKBUILD names no _pvrsgx_branch"
    new_commit=$(git ls-remote "$UPSTREAM" "refs/heads/$new_branch" | cut -f1)
    is_sha "$new_commit" || die "branch '$new_branch' not found in $UPSTREAM"
    say "branch $new_branch is at $new_commit"
fi

# --- 2. fetch ---------------------------------------------------------------------
mkdir -p "$DIST"
fetch_once() {  # fetch_once <url> <file>: once per file name; a partial download never lands
    local dst="${DIST:?}/${2:?}"
    [ -s "$dst" ] && return 0
    say "downloading $1"
    if ! curl -fsSL --retry 3 -o "$dst.part" "$1"; then
        rm -f -- "$dst.part"
        die "download failed: $1"
    fi
    mv "$dst.part" "$dst"
}
archive="linux_openpvrsgx-$new_commit.tar.gz"
fetch_once "$UPSTREAM/archive/$new_commit.tar.gz" "$archive"
fetch_once "$MIRROR/linux-$pkgver.tar.xz" "linux-$pkgver.tar.xz"
new_sha=$(sha512 "$DIST/$archive")
if [ "$new_commit" = "$cur_commit" ] && [ "$new_sha" != "$cur_sha" ]; then
    die "the archive of the PINNED commit $cur_commit no longer matches its sha512 -- upstream served different bytes for the same commit; find out why before anything else ($DIST/$archive)"
fi

# --- 3. test-apply, with the aport's own unpack()/prepare() ----------------------
WORK=$(mktemp -d "${TMPDIR:-/tmp}/bump-pvrsgx.XXXXXX")
cleanup() {
    if [ "$keep" = 1 ]; then say "work tree kept: $WORK"; else rm -rf -- "${WORK:?}"; fi
}
trap cleanup EXIT

candidate="$WORK/APKBUILD"
sed -e "s/^_pvrsgx_commit=.*/_pvrsgx_commit=$new_commit/" \
    -e "s/^_pvrsgx_sha512=.*/_pvrsgx_sha512=$new_sha/" \
    -e "s/^_pvrsgx_branch=.*/_pvrsgx_branch=$new_branch/" \
    "$APKBUILD" > "$candidate"

say "test-applying the series on pristine linux-$pkgver + openpvrsgx ${new_commit:0:12}"
log="$WORK/apply.log"
set +e
# The functions are the abuild API the sourced APKBUILD calls; $source and
# $_config come from it.
# shellcheck disable=SC2034,SC2329,SC2154
(
    set -e
    srcdir="$WORK/src"
    SRCDEST="$DIST"
    mkdir -p "$srcdir"
    # The minimum of abuild these functions call. default_prepare mirrors
    # abuild's: every *.patch in source=, in order, `patch -p1`, failures collected.
    msg() { printf '>>> %s\n' "$*"; }
    error() { printf '>>> ERROR: %s\n' "$*" >&2; }
    die() { error "$@"; exit 1; }
    fetch() { :; }
    command -v sha512sum >/dev/null 2>&1 || sha512sum() { shasum -a 512 "$@"; }
    filename_from_uri() { local f="${1%%::*}"; echo "${f##*/}"; }
    default_prepare() {
        local i failed=""
        cd "$builddir"
        for i in $source; do
            case ${i%%::*} in
                *.patch)
                    msg "${i%%::*}"
                    "$PATCH_BIN" -p1 -i "$srcdir/$(filename_from_uri "$i")" || failed="$failed $i"
                    ;;
            esac
        done
        [ -z "$failed" ] && return 0
        error "The following patches failed to apply:"
        for i in $failed; do printf '  %s\n' "$i" >&2; done
        return 1
    }
    # shellcheck disable=SC1090
    . "$candidate"
    builddir="$srcdir/linux-$pkgver"
    # Local sources the way abuild's fetch links them into $srcdir.
    for s in $source; do
        case "$s" in *://*) continue ;; esac
        case "$s" in
            *.patch) ln -sf "$PATCHES/$s" "$srcdir/$s" ;;
            "$_config") ln -sf "$DEFCONFIG" "$srcdir/$s" ;;
        esac
    done
    unpack
    cd "$builddir"
    prepare
) > "$log" 2>&1
rc=$?
set -e
grep -E 'with fuzz|FAILED|saving rejects|already exists|does not match the pinned' "$log" | sed 's/^/  /' >&2 || true
if [ $rc -ne 0 ]; then
    grep -A20 'ERROR' "$log" | sed 's/^/  /' >&2 || true
    die "the series does NOT apply on openpvrsgx $new_commit -- the APKBUILD is unchanged (--keep keeps the tree and the log)"
fi
if grep -q 'with fuzz' "$log"; then
    say "WARNING: hunks applied with fuzz (listed above) -- abuild accepts that, but regenerate those patches"
fi
say "series applies cleanly ($(grep -c '^>>> [0-9]\{4\}-' "$log") patches)"

# --- 4. olddefconfig keeps the SGX symbols ---------------------------------------
if [ "$kconfig" = 1 ]; then
    tree="$WORK/src/linux-$pkgver"
    say "make ARCH=arm olddefconfig"
    if ! make -s -C "$tree" ARCH=arm olddefconfig > "$WORK/kconfig.log" 2>&1; then
        tail -20 "$WORK/kconfig.log" | sed 's/^/  /' >&2
        die "olddefconfig failed (no host cc/flex/bison? --no-kconfig skips this step)"
    fi
    for sym in CONFIG_SGX=y CONFIG_PVRSGX_1_17_4948957=y CONFIG_SGX_DRM=y CONFIG_SGX_OMAP=m; do
        grep -qx "$sym" "$tree/.config" || die "olddefconfig dropped $sym on openpvrsgx $new_commit -- the APKBUILD is unchanged"
    done
    say "olddefconfig keeps the SGX symbols"
fi

# --- 5. write the pin -------------------------------------------------------------
if [ "$check_only" = 1 ]; then
    say "OK: the current pin $cur_commit applies (--check, nothing written)"
    exit 0
fi
if [ "$new_commit" = "$cur_commit" ] && [ "$new_branch" = "$cur_branch" ]; then
    say "OK: already pinned to $new_commit, nothing to change"
    exit 0
fi
# In place, so the file keeps its mode; git holds the previous version.
cat "$candidate" > "$APKBUILD"
say "pinned openpvrsgx ${new_branch:+$new_branch @ }$new_commit"
say "  sha512 $new_sha"
say "next: bump pkgrel in $APKBUILD, add the CHANGELOG line naming the revision, build, and read"
say "      upstream's changes since ${cur_commit:0:12}: $UPSTREAM/compare/$cur_commit...$new_commit"
