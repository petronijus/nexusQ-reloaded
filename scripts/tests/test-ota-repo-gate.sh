#!/usr/bin/env bash
# needs: docker
# Tests for scripts/ota-repo-gate.sh — the install gate of publish-ota-repo.sh.
#
# Every refusal here was seen failing: each fixture is a repo that is wrong in one
# way, and the test asserts the gate says so by name. The fixtures are tiny apks
# made with `apk mkpkg` and indexed with `apk mkndx`; "upstream" is a local repo
# standing in for Alpine and postmarketOS, and a "unit" is an apk root built from
# them, so no case touches the network (OTA_GATE_PULL=0).
#
# Usage: scripts/tests/test-ota-repo-gate.sh
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
GATE="$HERE/../ota-repo-gate.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
IMAGE="${OTA_GATE_IMAGE:-alpine:edge}"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  \033[32mPASS\033[0m  %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  \033[31mFAIL\033[0m  %s\n' "$1"; [ -n "${2:-}" ] && printf '%s\n' "$2" | sed 's/^/        /'; }

# mkrepo <dir> <name>=<version>[:<dep>,<dep>...]...  — a repo at <dir>/armv7
mkrepo() {
    local dir="$1"; shift
    mkdir -p "$dir/armv7"
    docker run --rm -u "$(id -u):$(id -g)" -v "$dir/armv7:/d" "$IMAGE" sh -c '
        set -e; cd /d
        for spec in "$@"; do
            nv=${spec%%:*}; deps=""
            case "$spec" in *:*) deps=$(echo "${spec#*:}" | tr , " ") ;; esac
            n=${nv%%=*}; v=${nv#*=}
            apk mkpkg --info name:$n --info version:$v --info arch:armv7 \
                --info description:fixture --info license:MIT \
                ${deps:+--info "depends:$deps"} --output "$n-$v.apk"
        done
        apk mkndx --allow-untrusted -o APKINDEX.tar.gz ./*.apk >/dev/null' sh "$@"
}

LIST="$WORK/ota.list"
printf '# fixture list\ndevice-x\nlibrespot\n' > "$LIST"

UP="$WORK/upstream"
mkrepo "$UP" libfoo=1-r0 librespot=0.8.0-r0

# gate <upstream-repos> <args...> — sets $out and $rc; offline (OTA_GATE_PULL=0)
gate() {
    local repos="$1"; shift
    out=$(OTA_GATE_REPOS="$repos" OTA_GATE_IMAGE="$IMAGE" OTA_GATE_PULL=0 "$GATE" "$@" 2>&1); rc=$?
}
run() { gate "$UP" "$@"; }

echo "ota-repo-gate"

# 1. a complete, installable repo passes
mkrepo "$WORK/good" "device-x=1.0-r2:librespot,libfoo,glibc-rt" librespot=0.8.0-r100
run "$WORK/good" "$LIST" glibc-rt=1.0-r0
if [ "$rc" -eq 0 ] && grep -q 'ok: all listed packages present' <<<"$out"; then
    ok "a complete repo whose packages install as published passes"
else bad "a complete repo was refused (rc=$rc)" "$out"; fi

# 2. a listed package with no build is refused by name, even though upstream has
#    one: the 2026-11-16 librespot case, which a plain install check would pass
mkrepo "$WORK/nolibrespot" "device-x=1.0-r2:librespot,libfoo,glibc-rt"
run "$WORK/nolibrespot" "$LIST" glibc-rt=1.0-r0
if [ "$rc" -eq 1 ] && grep -q 'not in the repo: librespot' <<<"$out"; then
    ok "a listed package missing from the repo is refused by name"
else bad "a missing listed package was not refused (rc=$rc)" "$out"; fi

# 3. a dependency nobody carries is refused, with apk's reason
mkrepo "$WORK/nodep" "device-x=1.0-r2:librespot,libbar,glibc-rt" librespot=0.8.0-r100
run "$WORK/nodep" "$LIST" glibc-rt=1.0-r0
if [ "$rc" -eq 1 ] && grep -q 'could not install' <<<"$out" && grep -q 'libbar' <<<"$out"; then
    ok "a dependency no repository carries is refused"
else bad "an unsatisfiable dependency was not refused (rc=$rc)" "$out"; fi

# 4. an image-only package counts only when declared: without it the same repo fails
run "$WORK/good" "$LIST"
if [ "$rc" -eq 1 ] && grep -q 'glibc-rt' <<<"$out"; then
    ok "an image-only dependency must be declared to count as present"
else bad "an undeclared image-only dependency was accepted (rc=$rc)" "$out"; fi

# 5. a newer upstream build shadowing ours is refused
UP2="$WORK/upstream-newer"
mkrepo "$UP2" libfoo=1-r0 librespot=0.8.0-r200
gate "$UP2" "$WORK/good" "$LIST" glibc-rt=1.0-r0
if [ "$rc" -eq 1 ] && grep -q 'librespot: the repo carries 0.8.0-r100 but a unit would install 0.8.0-r200' <<<"$out"; then
    ok "an upstream build newer than ours is refused"
else bad "a shadowed package was not refused (rc=$rc)" "$out"; fi

# 6. an upstream repository that does not answer is refused: apk 3 only warns
#    and resolves without it, which would blind check 3 to the Alpine builds
#    our overrides replace
gate "$UP
http://127.0.0.1:9/alpine/edge/community" "$WORK/good" "$LIST" glibc-rt=1.0-r0
if [ "$rc" -eq 1 ] && grep -q 'did not answer' <<<"$out"; then
    ok "an upstream repository that does not answer is refused"
else bad "an unreachable upstream repository was not refused (rc=$rc)" "$out"; fi

# 7. a unit's own System update. The unit has device-x r1 and `pinned`, which
#    needs libfoo=1-r0; upstream also has libfoo 2-r0.
UP3="$WORK/upstream-pinned"
mkrepo "$UP3" libfoo=1-r0 libfoo=2-r0 "pinned=1-r0:libfoo=1-r0" librespot=0.8.0-r0
OLD="$WORK/old"
mkrepo "$OLD" "device-x=1.0-r1:libfoo" linux-google-steelhead=6.18-r1
UNIT="$WORK/unit"
mkdir -p "$UNIT"
docker run --rm -v "$UNIT:/u" -v "$OLD:$OLD:ro" -v "$UP3:$UP3:ro" "$IMAGE" sh -c '
    apk --root /u --arch armv7 --initdb --allow-untrusted --no-interactive \
        --repositories-file /dev/null -X "$1" -X "$2" add device-x pinned linux-google-steelhead >/dev/null 2>&1 || exit 1
    chmod -R a+rwX /u' sh "$OLD" "$UP3" || bad "could not build the unit fixture"

#    a repo the unit can take passes, and its packages end at the repo's version
mkrepo "$WORK/unit-good" "device-x=1.0-r3:libfoo" librespot=0.8.0-r100
gate "$UP3" --unit-root "$UNIT" "$WORK/unit-good" "$LIST"
if [ "$rc" -eq 0 ] && grep -q "System update succeeds" <<<"$out"; then
    ok "a repo a unit's System update can take passes the unit check"
else bad "a takeable repo was refused by the unit check (rc=$rc)" "$out"; fi

#    a device-x that needs libfoo>=2 installs fine from scratch, but on the unit
#    `pinned` holds libfoo at 1: the update keeps device-x r1 or fails
mkrepo "$WORK/unit-held" "device-x=1.0-r3:libfoo>=2" librespot=0.8.0-r100
gate "$UP3" "$WORK/unit-held" "$LIST"
if [ "$rc" -eq 0 ]; then
    ok "(the same repo passes the from-scratch checks: only the unit sees it)"
else bad "the held-back fixture failed already from scratch (rc=$rc)" "$out"; fi
gate "$UP3" --unit-root "$UNIT" "$WORK/unit-held" "$LIST"
if [ "$rc" -eq 1 ] && grep -q "unit: device-x: the repo carries 1.0-r3 but the unit (1.0-r1) would end at 1.0-r1" <<<"$out"; then
    ok "a package a unit's update would hold back is refused"
else bad "a held-back package was not refused (rc=$rc)" "$out"; fi

#    a unit that runs a NEWER device-x than the repo carries would be rolled
#    back by --available: the build volume is behind the unit
NEWER="$WORK/newer"
mkrepo "$NEWER" "device-x=1.0-r5:libfoo" linux-google-steelhead=6.18-r1
UNIT_NEW="$WORK/unit-newer"
mkdir -p "$UNIT_NEW"
docker run --rm -v "$UNIT_NEW:/u" -v "$NEWER:$NEWER:ro" -v "$UP3:$UP3:ro" "$IMAGE" sh -c '
    apk --root /u --arch armv7 --initdb --allow-untrusted --no-interactive \
        --repositories-file /dev/null -X "$1" -X "$2" add device-x linux-google-steelhead >/dev/null 2>&1 || exit 1
    echo "unit-newer" > /u/LABEL
    chmod -R a+rwX /u' sh "$NEWER" "$UP3" || bad "could not build the newer-unit fixture"
gate "$UP3" --unit-root "$UNIT" --unit-root "$UNIT_NEW" "$WORK/unit-good" "$LIST"
if [ "$rc" -eq 1 ] && grep -q "unit-newer: device-x would be ROLLED BACK from 1.0-r5 to 1.0-r3" <<<"$out" \
        && grep -q "ok: $(basename "$UNIT"): System update succeeds" <<<"$out"; then
    ok "each unit is judged on its own, and a roll-back of ours is refused"
else bad "a roll-back was not refused, or the units were not judged one by one (rc=$rc)" "$out"; fi

#    a unit that cannot take upstream as it stands is reported, not judged: its
#    world wants a package no repository carries any more
GONE="$WORK/gone"
mkrepo "$GONE" "needsgone=1-r0:gone" gone=1-r0 linux-google-steelhead=6.18-r1
UNIT_BROKEN="$WORK/unit-broken"
mkdir -p "$UNIT_BROKEN"
docker run --rm -v "$UNIT_BROKEN:/u" -v "$GONE:$GONE:ro" "$IMAGE" sh -c '
    apk --root /u --arch armv7 --initdb --allow-untrusted --no-interactive \
        --repositories-file /dev/null -X "$1" add needsgone linux-google-steelhead >/dev/null 2>&1 || exit 1
    echo gone-for-good >> /u/etc/apk/world
    echo "unit-broken" > /u/LABEL
    chmod -R a+rwX /u' sh "$GONE" || bad "could not build the broken-unit fixture"
gate "$UP3" --unit-root "$UNIT_BROKEN" "$WORK/unit-good" "$LIST"
if [ "$rc" -eq 0 ] && grep -q "unit-broken: NOT JUDGED: its System update fails even without this repo" <<<"$out"; then
    ok "upstream breaking a unit by itself warns and does not block the publish"
else bad "an upstream-only failure blocked the publish or went unreported (rc=$rc)" "$out"; fi

#    with its own recorded repositories, which lack the one carrying libnone,
#    a unit that upstream already breaks still has this repo judged: the error
#    the repo adds is refused, the one upstream causes is not its doing
UP4="$WORK/upstream-extra"
mkrepo "$UP4" libnone=1-r0
UNIT_OWN="$WORK/unit-own-repos"
mkdir -p "$UNIT_OWN"
docker run --rm -v "$UNIT_OWN:/u" -v "$OLD:$OLD:ro" -v "$GONE:$GONE:ro" -v "$UP3:$UP3:ro" "$IMAGE" sh -c '
    apk --root /u --arch armv7 --initdb --allow-untrusted --no-interactive --repositories-file /dev/null \
        -X "$1" -X "$2" -X "$3" add device-x needsgone linux-google-steelhead >/dev/null 2>&1 || exit 1
    echo gone-for-good >> /u/etc/apk/world
    printf "%s\nhttps://petronijus.github.io/nexusQ-reloaded/nexusq\n" "$3" > /u/etc/apk/repositories
    echo "unit-own-repos" > /u/LABEL
    chmod -R a+rwX /u' sh "$OLD" "$GONE" "$UP3" || bad "could not build the own-repositories fixture"
mkrepo "$WORK/needs-extra" "device-x=1.0-r3:libnone" librespot=0.8.0-r100
gate "$UP3
$UP4" --unit-root "$UNIT_OWN" "$WORK/needs-extra" "$LIST"
if [ "$rc" -eq 1 ] && grep -q "unit-own-repos uses other upstream repositories" <<<"$out" \
        && grep -q "already fails without this repo, and this repo adds" <<<"$out" && grep -q libnone <<<"$out"; then
    ok "a unit is simulated with its own repositories, and an error the repo adds is refused"
else bad "a unit's own repositories were ignored, or the repo's own error passed (rc=$rc)" "$out"; fi

# 8. usage errors are not passes
run "$WORK/does-not-exist" "$LIST"
if [ "$rc" -eq 2 ]; then ok "a missing repo dir is a usage error"
else bad "a missing repo dir passed" "$out"; fi
run "$WORK/good" "$LIST" not-a-pair
if [ "$rc" -eq 2 ]; then ok "a malformed <name>=<version> is a usage error"
else bad "a malformed image-only argument was accepted (rc=$rc)" "$out"; fi

echo "  $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
