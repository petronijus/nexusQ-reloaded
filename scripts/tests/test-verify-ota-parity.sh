#!/usr/bin/env bash
# Tests for scripts/verify-ota-parity.sh.
#
# Every case here has been SEEN failing: the gate is run against a rootfs that is
# deliberately wrong, and the test asserts it says so. A gate is only worth its
# exit code if you have watched it go red — the two release gates fixed on
# 2026-08-30 both returned green for months while unable to read their inputs,
# and no test would have caught that either, because nobody had one.
#
# Builds tiny synthetic rootfs images with `mkfs.ext4 -d`, which populates from a
# directory WITHOUT mounting, so only the gate itself needs sudo (as
# verify-rootfs.sh already does). Needs: mkfs.ext4, tar, curl.
#
# Usage: scripts/tests/test-verify-ota-parity.sh
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
GATE="$HERE/../verify-ota-parity.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

PASS=0; FAIL=0
KEY_A="pmos@local-6a42e957"
KEY_B="pmos@local-6a93112c"

ok()  { PASS=$((PASS+1)); printf '  \033[32mPASS\033[0m  %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  \033[31mFAIL\033[0m  %s\n' "$1"; [ -n "${2:-}" ] && printf '        %s\n' "$2"; }

# --- fixtures ----------------------------------------------------------------

# An apk `installed` db and an APKINDEX share the P:/V: block format, which is
# why the gate parses both with one awk — so one builder serves both.
mk_index_body() {  # mk_index_body <pkg=ver>...
    for pv in "$@"; do printf 'P:%s\nV:%s\nS:1024\nT:test\n\n' "${pv%%=*}" "${pv#*=}"; done
}

mk_published_index() {  # mk_published_index <out.tar.gz> <key> <pkg=ver>...
    local out="$1" key="$2"; shift 2
    local d="$WORK/idx.$$"; rm -rf "$d"; mkdir -p "$d"
    mk_index_body "$@" > "$d/APKINDEX"
    echo "fake signature" > "$d/.SIGN.RSA.$key.rsa.pub"
    tar czf "$out" -C "$d" ".SIGN.RSA.$key.rsa.pub" APKINDEX
    rm -rf "$d"
}

mk_rootfs() {  # mk_rootfs <out.img> <key|-> <pkg=ver>...
    local out="$1" key="$2"; shift 2
    local d="$WORK/rfs.$$"; rm -rf "$d"; mkdir -p "$d/lib/apk/db" "$d/etc/apk/keys"
    mk_index_body "$@" > "$d/lib/apk/db/installed"
    if [ "$key" != "-" ]; then
        # Byte-identical to the recorded fleet key when it is the fleet key, so
        # the gate's cmp check has something real to compare.
        if [ "$key" = "$KEY_A" ] && [ -f "$HERE/../../pmos/ota-signing-key.rsa.pub" ]; then
            cp "$HERE/../../pmos/ota-signing-key.rsa.pub" "$d/etc/apk/keys/$key.rsa.pub"
        else
            echo "some other key" > "$d/etc/apk/keys/$key.rsa.pub"
        fi
    fi
    rm -f "$out"
    mkfs.ext4 -q -F -b 1024 -d "$d" "$out" 4096 >/dev/null 2>&1 \
        || { echo "mkfs.ext4 -d failed (e2fsprogs too old?)" >&2; exit 2; }
    rm -rf "$d"
}

# The real package list drives the fixtures, so adding a package to
# pmos/ota-packages.list cannot quietly leave these tests testing a subset.
mapfile -t PKGS < <(sed 's/#.*//' "$HERE/../../pmos/ota-packages.list" | tr -d '[:blank:]' | grep -v '^$')
matched() { local out=(); for p in "${PKGS[@]}"; do out+=("$p=1.0-r87"); done; printf '%s\n' "${out[@]}"; }

run_gate() {  # run_gate <img> <index.tar.gz> -> prints output, returns exit code
    OTA_INDEX_URL="file://$2" "$GATE" "$1" 2>&1
}

# --- cases -------------------------------------------------------------------

echo "=== 1. everything matches -> exit 0 ==="
mapfile -t M < <(matched)
mk_rootfs "$WORK/happy.img" "$KEY_A" "${M[@]}"
mk_published_index "$WORK/happy.tar.gz" "$KEY_A" "${M[@]}"
out="$(run_gate "$WORK/happy.img" "$WORK/happy.tar.gz")"; rc=$?
if [ "$rc" -eq 0 ]; then ok "matching image and repo pass"
else bad "matching image and repo pass" "exit $rc: $(grep FAIL <<<"$out" | head -3)"; fi

echo "=== 2. version drift (the v1.14.2 bug) -> nonzero ==="
# The image ships r88 while the repo still serves r87 — exactly what shipped.
DRIFT=("${M[@]}"); DRIFT[0]="${PKGS[0]}=1.0-r88"
mk_rootfs "$WORK/drift.img" "$KEY_A" "${DRIFT[@]}"
out="$(run_gate "$WORK/drift.img" "$WORK/happy.tar.gz")"; rc=$?
if [ "$rc" -ne 0 ] && grep -q "publish-ota-repo.sh" <<<"$out"; then
    ok "a package newer in the image than in the repo fails, and says how to fix it"
else bad "version drift fails" "exit $rc"; fi

echo "=== 3. package missing from the repo entirely -> nonzero ==="
mapfile -t SHORT < <(matched); unset 'SHORT[0]'
mk_published_index "$WORK/short.tar.gz" "$KEY_A" "${SHORT[@]}"
out="$(run_gate "$WORK/happy.img" "$WORK/short.tar.gz")"; rc=$?
if [ "$rc" -ne 0 ] && grep -q "can never receive it" <<<"$out"; then
    ok "a package the repo does not carry at all fails"
else bad "missing package fails" "exit $rc"; fi

echo "=== 4. key drift (the v1.14.x bug) -> nonzero ==="
mk_rootfs "$WORK/keydrift.img" "$KEY_B" "${M[@]}"
out="$(run_gate "$WORK/keydrift.img" "$WORK/happy.tar.gz")"; rc=$?
if [ "$rc" -ne 0 ] && grep -q "UNTRUSTED" <<<"$out"; then
    ok "an image baking a key the repo is not signed with fails"
else bad "key drift fails" "exit $rc"; fi

echo "=== 5. image bakes no pmos key at all -> nonzero ==="
mk_rootfs "$WORK/nokey.img" "-" "${M[@]}"
out="$(run_gate "$WORK/nokey.img" "$WORK/happy.tar.gz")"; rc=$?
if [ "$rc" -ne 0 ] && grep -q "none in /etc/apk/keys" <<<"$out"; then
    ok "an image with no signing key fails"
else bad "no baked key fails" "exit $rc"; fi

echo "=== 6. cannot look -> fails closed, does NOT pass ==="
out="$(OTA_INDEX_URL="file://$WORK/does-not-exist.tar.gz" "$GATE" "$WORK/happy.img" 2>&1)"; rc=$?
if [ "$rc" -ne 0 ] && grep -q "refusing to guess" <<<"$out"; then
    ok "an unfetchable index fails instead of passing"
else bad "unfetchable index fails closed" "exit $rc"; fi

echo "=== 7. an empty package list is refused, not treated as 'nothing to check' ==="
EMPTY="$WORK/empty.list"; printf '# only comments\n\n' > "$EMPTY"
out="$(cd "$WORK" && OTA_INDEX_URL="file://$WORK/happy.tar.gz" bash -c "
    sed 's|\$REPO_ROOT/pmos/ota-packages.list|$EMPTY|' '$GATE' > '$WORK/gate-empty.sh'
    bash '$WORK/gate-empty.sh' '$WORK/happy.img'" 2>&1)"; rc=$?
if [ "$rc" -ne 0 ] && grep -q "lists no packages" <<<"$out"; then
    ok "an empty list fails instead of vacuously passing"
else bad "empty list fails" "exit $rc"; fi

echo
echo "================ $PASS passed, $FAIL failed ================"
[ "$FAIL" -eq 0 ]
