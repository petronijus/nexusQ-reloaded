#!/usr/bin/env bash
# Tests for scripts/bump-pvrsgx.sh, the update path of the openpvrsgx pin.
#
# Offline and fast: a synthetic upstream (a local git repo whose archives are
# served over file://), a two-file "kernel" tarball, and an APKBUILD fixture that
# carries the REAL unpack() and prepare() of pmos/linux-google-steelhead -- so
# this also catches those two functions drifting away from the abuild API the
# script provides. Every red case below has been seen red: the conflicting
# commit, the tampered archive and the dropped hook all have to leave the
# APKBUILD byte-identical.
#
# Usage: scripts/tests/test-bump-pvrsgx.sh
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/../bump-pvrsgx.sh"
REAL_APKBUILD="$HERE/../../pmos/linux-google-steelhead/APKBUILD"
WORK="$(mktemp -d)"
trap 'rm -rf -- "${WORK:?}"' EXIT

PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); printf '  \033[32mPASS\033[0m  %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  \033[31mFAIL\033[0m  %s\n' "$1"; [ -n "${2:-}" ] && printf '%s\n' "$2" | sed 's/^/        /'; }

gnu_patch=""
for p in gpatch patch; do
    if command -v "$p" >/dev/null 2>&1 && "$p" --version 2>/dev/null | grep -q 'GNU patch'; then gnu_patch=$p; fi
done
if [ -z "$gnu_patch" ]; then
    echo "  SKIP  test-bump-pvrsgx: no GNU patch on this machine (macOS: brew install gpatch)"
    exit 0
fi

sha512() { if command -v sha512sum >/dev/null 2>&1; then sha512sum "$1"; else shasum -a 512 "$1"; fi | cut -d' ' -f1; }
export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@localhost GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@localhost
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1

# --- the synthetic upstream ------------------------------------------------------
UP="$WORK/upstream"
git init -q -b pvr-branch "$UP"
mkdir -p "$UP/drivers/gpu/drm/pvrsgx/1.17.4948957" "$UP/archive"
pvr="$UP/drivers/gpu/drm/pvrsgx"
printf 'config SGX\n\tbool "SGX"\n' > "$pvr/Kconfig"
printf 'obj-y += 1.17.4948957/\n' > "$pvr/Makefile"
printf 'probe\nput_sync\nremove\n' > "$pvr/pvr-drv.c"
printf '/* pvr-drv.h */\n' > "$pvr/pvr-drv.h"
printf 'km\n' > "$pvr/1.17.4948957/Makefile"
commit() {  # commit <msg>: commit, archive like GitHub does, print the sha
    git -C "$UP" add -A drivers
    git -C "$UP" commit -qm "$1"
    local c
    c=$(git -C "$UP" rev-parse HEAD)
    git -C "$UP" archive --format=tar.gz --prefix="linux_openpvrsgx-$c/" -o "$UP/archive/$c.tar.gz" "$c"
    echo "$c"
}
A=$(commit "A: the pinned base")
printf 'km\nnew upstream fix\n' > "$pvr/1.17.4948957/Makefile"
B=$(commit "B: an upstream fix our patches do not touch")
printf 'probe\nput_sync_suspend\nremove\n' > "$pvr/pvr-drv.c"
C=$(commit "C: upstream rewrote the line our 0002 changes")
git -C "$UP" branch -q at-b "$B"

# --- the synthetic kernel and our patches ------------------------------------------
mkdir -p "$WORK/k/linux-1.0/drivers/gpu/drm" "$WORK/mirror"
printf 'source "drivers/gpu/drm/xlnx/Kconfig"\n\nsource "drivers/gpu/drm/gud/Kconfig"\n' > "$WORK/k/linux-1.0/drivers/gpu/drm/Kconfig"
printf 'obj-y += drm.o\n' > "$WORK/k/linux-1.0/drivers/gpu/drm/Makefile"
tar -C "$WORK/k" -cJf "$WORK/mirror/linux-1.0.tar.xz" linux-1.0

R="$WORK/repo"
mkdir -p "$R/pmos/linux-google-steelhead" "$R/kernel/patches" "$R/kernel/configs"
printf 'CONFIG_LOCALVERSION=""\nCONFIG_SGX=y\n' > "$R/kernel/configs/steelhead_defconfig"
cat > "$R/kernel/patches/0001-hook.patch" <<'P'
--- a/drivers/gpu/drm/Kconfig
+++ b/drivers/gpu/drm/Kconfig
@@ -1,3 +1,4 @@
 source "drivers/gpu/drm/xlnx/Kconfig"
+source "drivers/gpu/drm/pvrsgx/Kconfig"
 
 source "drivers/gpu/drm/gud/Kconfig"
P
cat > "$R/kernel/patches/0002-autosuspend.patch" <<'P'
--- a/drivers/gpu/drm/pvrsgx/pvr-drv.c
+++ b/drivers/gpu/drm/pvrsgx/pvr-drv.c
@@ -1,3 +1,3 @@
 probe
-put_sync
+put_autosuspend
 remove
P

mk_apkbuild() {  # mk_apkbuild <commit>: the fixture header + the REAL unpack()/prepare()
    cat <<H
pkgname=linux-google-steelhead
pkgver=1.0
pkgrel=7
arch="armv7"
_flavor="\${pkgname#linux-}"
_config="config-\$_flavor.\$arch"
_pvrsgx_branch=pvr-branch
_pvrsgx_commit=$1
_pvrsgx_sha512=$(sha512 "$UP/archive/$1.tar.gz")
_pvrsgx_ddk=1.17.4948957
_pvrsgx_archive="linux_openpvrsgx-\$_pvrsgx_commit.tar.gz"
source="
	https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-\$pkgver.tar.xz
	\$_pvrsgx_archive::https://github.com/openpvrsgx-devgroup/linux_openpvrsgx/archive/\$_pvrsgx_commit.tar.gz
	\$_config
	0001-hook.patch
	0002-autosuspend.patch
"
builddir="\$srcdir/linux-\$pkgver"

H
    sed -n '/^unpack() {/,/^}/p; /^prepare() {/,/^}/p' "$REAL_APKBUILD"
}
APK="$R/pmos/linux-google-steelhead/APKBUILD"
reset_apkbuild() { mk_apkbuild "$A" > "$APK"; cp "$APK" "$WORK/APKBUILD.orig"; }

run() {  # run <args...>: the script against the fixtures; output in $WORK/out
    rm -rf -- "${WORK:?}/dist"
    NQ_REPO_ROOT="$R" NQ_PVRSGX_REPO="file://$UP" NQ_KERNEL_MIRROR="file://$WORK/mirror" \
        NQ_DISTFILES="$WORK/dist" TMPDIR="$WORK" \
        "$SCRIPT" --no-kconfig "$@" > "$WORK/out" 2>&1
}
unchanged() { cmp -s "$APK" "$WORK/APKBUILD.orig"; }
pin() { sed -n "s/^$1=//p" "$APK"; }

# --- cases -------------------------------------------------------------------------
if [ "$(sed -n '/^unpack() {/,/^}/p; /^prepare() {/,/^}/p' "$REAL_APKBUILD" | grep -c '^}')" = 2 ]; then
    ok "the real APKBUILD has an unpack() and a prepare() to test"
else
    bad "the real APKBUILD no longer defines both unpack() and prepare()"
fi

reset_apkbuild
if run --check && unchanged && grep -q 'applies (--check' "$WORK/out"; then
    ok "--check: the current pin applies; nothing written"
else
    bad "--check on a good pin" "$(cat "$WORK/out")"
fi

reset_apkbuild
if run "$B" && [ "$(pin _pvrsgx_commit)" = "$B" ] \
    && [ "$(pin _pvrsgx_sha512)" = "$(sha512 "$UP/archive/$B.tar.gz")" ] \
    && [ "$(pin pkgrel)" = 7 ]; then
    ok "bump to a compatible commit: commit and sha512 move together, pkgrel left to the human"
else
    bad "bump to a compatible commit" "$(cat "$WORK/out")"
fi

reset_apkbuild
if run at-b && [ "$(pin _pvrsgx_commit)" = "$B" ] && [ "$(pin _pvrsgx_branch)" = at-b ]; then
    ok "bump to a branch: resolved with ls-remote, branch recorded"
else
    bad "bump to a branch" "$(cat "$WORK/out")"
fi

reset_apkbuild
if run && [ "$(pin _pvrsgx_commit)" = "$C" ]; then
    bad "no argument: follow the tracked branch -- but its head C conflicts and was pinned anyway"
elif unchanged && grep -q 'does NOT apply' "$WORK/out" && grep -q '0002-autosuspend.patch' "$WORK/out"; then
    ok "no argument: the tracked branch's head conflicts -> refused, the patch named, APKBUILD untouched"
else
    bad "no argument, conflicting head" "$(cat "$WORK/out")"
fi

reset_apkbuild
if ! run "$C" && unchanged && grep -q '0002-autosuspend.patch' "$WORK/out"; then
    ok "bump to a conflicting commit: non-zero, the failing patch named, APKBUILD untouched"
else
    bad "bump to a conflicting commit" "$(cat "$WORK/out")"
fi

reset_apkbuild
cp "$UP/archive/$A.tar.gz" "$WORK/A.good"
printf 'tampered' | cat "$WORK/A.good" - > "$UP/archive/$A.tar.gz"
if ! run --check && unchanged && grep -q 'no longer matches its sha512' "$WORK/out"; then
    ok "--check: the pinned commit's archive changed upstream -> refused"
else
    bad "a tampered archive for the pinned commit" "$(cat "$WORK/out")"
fi
cp "$WORK/A.good" "$UP/archive/$A.tar.gz"

reset_apkbuild
mv "$R/kernel/patches/0001-hook.patch" "$WORK/hook.patch"
# Upstream moved the line the hook replaces: a removed line has to match exactly,
# fuzz cannot save it.
printf -- '--- a/drivers/gpu/drm/Kconfig\n+++ b/drivers/gpu/drm/Kconfig\n@@ -1,3 +1,3 @@\n-source "drivers/gpu/drm/NOPE/Kconfig"\n+source "drivers/gpu/drm/pvrsgx/Kconfig"\n \n source "drivers/gpu/drm/gud/Kconfig"\n' \
    > "$R/kernel/patches/0001-hook.patch"
if ! run "$B" && unchanged && grep -q '0001-hook.patch' "$WORK/out"; then
    ok "a hook patch that misses the pristine tree: refused, APKBUILD untouched"
else
    bad "a broken hook patch" "$(cat "$WORK/out")"
fi
mv "$WORK/hook.patch" "$R/kernel/patches/0001-hook.patch"

reset_apkbuild
mkdir -p "$WORK/k/linux-1.0/drivers/gpu/drm/pvrsgx"
tar -C "$WORK/k" -cJf "$WORK/mirror/linux-1.0.tar.xz" linux-1.0
if ! run --check && unchanged && grep -q 'already has drivers/gpu/drm/pvrsgx' "$WORK/out"; then
    ok "a kernel that ships its own pvrsgx is noticed, not overwritten"
else
    bad "a kernel with its own pvrsgx" "$(cat "$WORK/out")"
fi

echo "test-bump-pvrsgx: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
