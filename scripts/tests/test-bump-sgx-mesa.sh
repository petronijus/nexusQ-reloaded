#!/usr/bin/env bash
# Tests for scripts/bump-sgx-mesa.sh, the update path of the mesa-sgx pin.
#
# Offline and fast: a synthetic upstream (a local git repo whose archives are
# served over file://, with Forgejo's "mesa/" prefix) and an aport fixture that
# is the REAL pmos/nexusq-sgx-mesa/APKBUILD with synthetic patches under the
# real patch names -- so this also catches the APKBUILD's unpack() drifting
# from what the script provides. Every red case leaves the APKBUILD
# byte-identical.
#
# Usage: scripts/tests/test-bump-sgx-mesa.sh
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/../bump-sgx-mesa.sh"
REAL="$HERE/../../pmos/nexusq-sgx-mesa"
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
    echo "  SKIP  test-bump-sgx-mesa: no GNU patch on this machine (macOS: brew install gpatch)"
    exit 0
fi

sha512() { if command -v sha512sum >/dev/null 2>&1; then sha512sum "$1"; else shasum -a 512 "$1"; fi | cut -d' ' -f1; }
export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@localhost GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@localhost
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1

# --- the synthetic upstream -----------------------------------------------------
UP="$WORK/upstream"
git init -q -b maemo/excalibur "$UP"
mkdir -p "$UP/src/gallium/frontends/sgx" "$UP/archive"
f="$UP/src/gallium/frontends/sgx/sgx_ext.c"
printf '#define PVR_DRI_IMAGE_VERSION 7\n   .createImageFromFds = x,\n' > "$f"
printf 'files_libsgx = files(\n  '"'"'sgx_util.c'"'"',\n)\n' > "$UP/src/gallium/frontends/sgx/meson.build"
commit() {  # commit <msg>: commit, archive like Forgejo does, print the sha
    git -C "$UP" add -A src
    git -C "$UP" commit -qm "$1"
    local c
    c=$(git -C "$UP" rev-parse HEAD)
    git -C "$UP" archive --format=tar.gz --prefix="mesa/" -o "$UP/archive/$c.tar.gz" "$c"
    echo "$c"
}
A=$(commit "A: the pinned base")
printf 'unrelated\n' > "$UP/src/gallium/frontends/sgx/sgx_util.c"
B=$(commit "B: an upstream change our patches do not touch")
git -C "$UP" tag -a powervr-test -m tag "$B"
printf '#define PVR_DRI_IMAGE_VERSION 9\n   .createImageFromFds = x,\n' > "$f"
C=$(commit "C: upstream rewrote the line our 0001 changes")
git -C "$UP" update-ref refs/heads/maemo/excalibur "$B"
git -C "$UP" branch -q at-c "$C"

# --- the aport fixture: the real APKBUILD, synthetic patches under the real names ---
R="$WORK/repo"
mkdir -p "$R/pmos/nexusq-sgx-mesa"
p1=$(sed -n 's/^\t\(0001-.*\.patch\)$/\1/p' "$REAL/APKBUILD")
p2=$(sed -n 's/^\t\(0002-.*\.patch\)$/\1/p' "$REAL/APKBUILD")
[ -n "$p1" ] && [ -n "$p2" ] || { echo "  FAIL  the real APKBUILD lists no 0001/0002 patch"; exit 1; }
cat > "$R/pmos/nexusq-sgx-mesa/$p1" <<'P'
--- a/src/gallium/frontends/sgx/sgx_ext.c
+++ b/src/gallium/frontends/sgx/sgx_ext.c
@@ -1,2 +1,3 @@
-#define PVR_DRI_IMAGE_VERSION 7
+#define PVR_DRI_IMAGE_VERSION 8
    .createImageFromFds = x,
+   .createImageFromDmaBufs = y,
P
cat > "$R/pmos/nexusq-sgx-mesa/$p2" <<'P'
--- a/src/gallium/frontends/sgx/meson.build
+++ b/src/gallium/frontends/sgx/meson.build
@@ -1,3 +1,4 @@
 files_libsgx = files(
   'sgx_util.c',
+  'sgx_unpack.c',
 )
P
pin() {  # pin <commit>: the real APKBUILD, pinned to <commit> of the fixture upstream
    sed -e "s/^_mesa_commit=.*/_mesa_commit=$1/" \
        -e "s/^_mesa_sha512=.*/_mesa_sha512=$(sha512 "$UP/archive/$1.tar.gz")/" \
        -e "s#^_mesa_branch=.*#_mesa_branch=maemo/excalibur#" \
        "$REAL/APKBUILD" > "$R/pmos/nexusq-sgx-mesa/APKBUILD"
}

run() {
    NQ_REPO_ROOT="$R" NQ_MESA_REPO="file://$UP" NQ_DISTFILES="$WORK/dist" "$SCRIPT" "$@" > "$WORK/out" 2>&1
}

APK="$R/pmos/nexusq-sgx-mesa/APKBUILD"

# 1. --check on the current pin
pin "$A"
cp "$APK" "$WORK/before"
if run --check && cmp -s "$APK" "$WORK/before"; then ok "--check passes on the pinned commit and writes nothing"
else bad "--check on the pinned commit" "$(cat "$WORK/out")"; fi

# 2. no argument: the tracked branch's head, patches apply -> pinned
if run && grep -qx "_mesa_commit=$B" "$APK" && grep -qx "_mesa_sha512=$(sha512 "$UP/archive/$B.tar.gz")" "$APK"; then
    ok "no argument: moves to the branch head with its sha512"
else bad "bump to the branch head" "$(cat "$WORK/out")"; fi

# 3. a tag resolves to its commit
pin "$A"
if run powervr-test && grep -qx "_mesa_commit=$B" "$APK"; then ok "a tag name resolves to the tagged commit"
else bad "bump to a tag" "$(cat "$WORK/out")"; fi

# 4. a commit our patch no longer applies to -> refused, APKBUILD untouched
pin "$A"
cp "$APK" "$WORK/before"
if ! run "$C" && cmp -s "$APK" "$WORK/before" && grep -q "does NOT apply" "$WORK/out"; then
    ok "a conflicting upstream commit is refused and the APKBUILD stays byte-identical"
else bad "conflicting commit" "$(cat "$WORK/out")"; fi

# 5. the pinned commit's archive changed under us -> refused
pin "$A"
cp "$APK" "$WORK/before"
printf 'tampered' >> "$WORK/dist/mesa-sgx-$A.tar.gz"
if ! run --check && cmp -s "$APK" "$WORK/before" && grep -q "no longer matches" "$WORK/out"; then
    ok "a tampered archive of the pinned commit is refused"
else bad "tampered archive" "$(cat "$WORK/out")"; fi

echo "  $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
