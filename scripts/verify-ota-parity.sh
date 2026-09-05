#!/usr/bin/env bash
# verify-ota-parity.sh — prove the OTA repo actually carries the release.
#
# Cutting a release has always been two independent publishes of ONE build:
#
#   scripts/package-release.sh   -> boot.img + rootfs  -> GitHub Releases
#   scripts/publish-ota-repo.sh  -> signed apks        -> gh-pages
#
# Nothing connected them, so on 2026-08-30 v1.14.2 shipped an image carrying
# device r89 while the OTA repo still served r87 — published 28-08 and never
# again. Every box in the field stayed two revisions behind, and every UI said
# "up to date", because a device cannot be behind a version its repo does not
# offer. The image track was fine; the fleet just never heard about it.
#
# This gate compares the two, on the two axes that can silently diverge:
#
#   1. VERSIONS — every package in pmos/ota-packages.list must be at the same
#      pkgrel in the released rootfs and in the published index.
#   2. THE SIGNING KEY — the key baked into the image's /etc/apk/keys must be the
#      one the published index is signed with. v1.14.0/1/2 were cut on a machine
#      whose abuild key was pmos@local-6a93112c while the index is signed
#      pmos@local-6a42e957, so a Q flashed from any of them answers every
#      `apk update` with UNTRUSTED signature and can never OTA at all. That is
#      invisible from either side alone: both artifacts are internally perfect.
#
# Usage:
#   scripts/verify-ota-parity.sh <rootfs.img|rootfs-sparse.img>
#
# Env:
#   OTA_INDEX_URL   override the published index (default: the live gh-pages one)
#
# Read-only, and NO root: the image is parsed with debugfs rather than mounted,
# so this gate runs unprivileged and works on macOS too (it borrows debugfs from
# a container when the host has none). A release gate that only runs on one
# machine is a release gate that gets skipped.
#
# FAILS CLOSED, on purpose. Every "cannot look" path below is a failure, not a
# shrug — the two release gates fixed earlier the same day both reported success
# precisely because they had been unable to read what they judge, and an empty
# reading fell into their "absent is fine" branch. A gate that cannot see must
# say so in the exit code.
set -uo pipefail

IMG="${1:?usage: verify-ota-parity.sh <rootfs.img>}"
INDEX_URL="${OTA_INDEX_URL:-https://petronijus.github.io/nexusQ-reloaded/nexusq/armv7/APKINDEX.tar.gz}"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OTA_LIST="$REPO_ROOT/pmos/ota-packages.list"

TMP="$(mktemp -d)"
RAW=""
PASS=0
FAIL=0

cleanup() { rm -rf "$TMP"; [ -n "$RAW" ] && [ -f "$RAW" ] && rm -f "$RAW"; }
trap cleanup EXIT

say() { printf '%s\n' "$*"; }
ok()  { PASS=$((PASS+1)); printf '  \033[32mPASS\033[0m  %-52s %s\n' "$1" "${2:-}"; }
bad() { FAIL=$((FAIL+1)); printf '  \033[31mFAIL\033[0m  %-52s %s\n' "$1" "${2:-}"; }

# The image is read with debugfs, which parses ext4 WITHOUT mounting it: no root,
# no loop device, and therefore no reason for this gate to be a Linux-only step —
# which would mean a gate skipped on whichever machine happens to be cutting the
# release. macOS has neither debugfs nor loop mounts, so borrow them from a
# container, exactly as release-preflight-no-secrets.sh does. Guarded against
# recursion: inside, debugfs exists.
if ! command -v debugfs >/dev/null 2>&1; then
    if command -v docker >/dev/null 2>&1; then
        say "debugfs absent -> running the gate in a container"
        exec docker run --rm --network host \
            -v "$(cd "$(dirname "$IMG")" && pwd)":/img:ro \
            -v "$REPO_ROOT":/repo:ro \
            -e "OTA_INDEX_URL=$INDEX_URL" \
            alpine:3.21 sh -c \
            "apk add --no-cache --quiet bash e2fsprogs-extra android-tools curl tar >/dev/null 2>&1; \
             bash /repo/scripts/$(basename "$0") /img/$(basename "$IMG")"
    fi
    echo "ERROR: debugfs (e2fsprogs) required, and no docker to borrow it from" >&2
    exit 2
fi

[ -f "$OTA_LIST" ] || { say "FAIL: missing $OTA_LIST — nothing to compare"; exit 2; }
PKGS=(); while IFS= read -r _l; do PKGS+=("$_l"); done < <(sed 's/#.*//' "$OTA_LIST" | tr -d '[:blank:]' | grep -v '^$')
[ "${#PKGS[@]}" -gt 0 ] || { say "FAIL: $OTA_LIST lists no packages"; exit 2; }

# --- sparse -> raw if needed (same magic test as verify-rootfs.sh) ------------
if [ "$(od -An -tx4 -N4 "$IMG" | tr -d ' ')" = "ed26ff3a" ]; then
    RAW="$TMP/raw.img"
    say "sparse image detected, converting -> $RAW"
    simg2img "$IMG" "$RAW" || { say "FAIL: simg2img failed — cannot read the image"; exit 2; }
    IMG="$RAW"
fi

# debugfs prints its own banner and "cat" errors to stderr; keep stdout clean.
img_cat() { debugfs -R "cat $1" "$IMG" 2>/dev/null; }

say "=== reading $IMG (debugfs, no mount) ==="
img_cat /lib/apk/db/installed > "$TMP/installed"
[ -s "$TMP/installed" ] || { say "FAIL: cannot read /lib/apk/db/installed from the image — the gate cannot see what it ships"; exit 2; }
DB="$TMP/installed"

say "=== fetching the published index ==="
say "  $INDEX_URL"
# Cache-bust: a stale CDN copy would let this gate bless a repo that is already
# behind, which is the exact failure it exists to catch. Only for http(s) — a
# query string appended to a file:// URL is part of the FILENAME, so doing it
# unconditionally would make the gate unable to read a local index (and the
# tests point it at one).
FETCH="$INDEX_URL"
case "$INDEX_URL" in
    http://*|https://*) FETCH="$INDEX_URL?ts=$(date +%s)" ;;
esac
if ! curl -fsSL -H 'Cache-Control: no-cache' -o "$TMP/APKINDEX.tar.gz" "$FETCH"; then
    say "FAIL: cannot fetch the published index — refusing to guess that it matches"
    exit 2
fi
tar xzf "$TMP/APKINDEX.tar.gz" -C "$TMP" APKINDEX 2>/dev/null \
    || { say "FAIL: published index has no APKINDEX member"; exit 2; }

# The signature member names the signing key: .SIGN.RSA.<key>.rsa.pub
IDX_KEY="$(tar tzf "$TMP/APKINDEX.tar.gz" | sed -n 's|^\.SIGN\.RSA\.\(.*\)\.rsa\.pub$|\1|p' | head -1)"

say ""
say "=== 1. package versions: released rootfs vs published repo ==="
for p in "${PKGS[@]}"; do
    # `installed` and APKINDEX share the P:/V: block format, so one awk does both.
    img_v="$(awk -F: -v want="$p" '/^P:/{cur=$2} /^V:/{if(cur==want){print $2; exit}}' "$DB")"
    pub_v="$(awk -F: -v want="$p" '/^P:/{cur=$2} /^V:/{if(cur==want){print $2; exit}}' "$TMP/APKINDEX")"
    if [ -z "$img_v" ] && [ -z "$pub_v" ]; then
        bad "$p" "listed for OTA but present in NEITHER the image nor the repo"
    elif [ -z "$pub_v" ]; then
        bad "$p" "image has $img_v, repo has NOTHING — the fleet can never receive it"
    elif [ -z "$img_v" ]; then
        bad "$p" "repo has $pub_v, image does not install it — stale or wrong list entry"
    elif [ "$img_v" != "$pub_v" ]; then
        bad "$p" "image $img_v vs repo $pub_v — run scripts/publish-ota-repo.sh"
    else
        ok "$p" "$img_v"
    fi
done

say ""
say "=== 2. signing key: what the image trusts vs what signed the repo ==="
BAKED=(); while IFS= read -r _l; do BAKED+=("$_l"); done < <(debugfs -R "ls -p /etc/apk/keys" "$IMG" 2>/dev/null \
    | awk -F/ '{print $6}' | sed -n 's/\.rsa\.pub$//p' | grep '^pmos@local-')
if [ "${#BAKED[@]}" -eq 0 ]; then
    bad "image bakes a pmos signing key" "none in /etc/apk/keys — it can never OTA"
elif [ -z "$IDX_KEY" ]; then
    bad "published index is signed" "no .SIGN.RSA member — apk will reject it"
elif printf '%s\n' "${BAKED[@]}" | grep -qx "$IDX_KEY"; then
    ok "image trusts the key that signed the repo" "$IDX_KEY"
else
    bad "image trusts the key that signed the repo" \
        "image has ${BAKED[*]}, repo signed by $IDX_KEY — every apk update = UNTRUSTED"
fi

# And the recorded fleet key must be that same key, byte for byte — the name is
# only a filename and could be reused; the bytes are the thing apk verifies.
FLEET_KEY="$REPO_ROOT/pmos/ota-signing-key.rsa.pub"
if [ ! -f "$FLEET_KEY" ]; then
    bad "fleet key is recorded in the repo" "pmos/ota-signing-key.rsa.pub missing"
elif [ -n "$IDX_KEY" ] && img_cat "/etc/apk/keys/$IDX_KEY.rsa.pub" > "$TMP/baked.pub" \
     && [ -s "$TMP/baked.pub" ]; then
    if cmp -s "$FLEET_KEY" "$TMP/baked.pub"; then
        ok "baked key is byte-identical to the recorded fleet key" "$IDX_KEY"
    else
        bad "baked key is byte-identical to the recorded fleet key" \
            "$IDX_KEY differs from pmos/ota-signing-key.rsa.pub"
    fi
else
    bad "baked key is byte-identical to the recorded fleet key" \
        "cannot read the baked key to compare"
fi

say ""
say "================ $PASS passed, $FAIL failed ================"
if [ "$FAIL" -ne 0 ]; then
    say ""
    say "A release whose OTA repo does not carry it reaches nobody already in the"
    say "field. Publish the repo (scripts/publish-ota-repo.sh) and re-run, or fix"
    say "the key drift before cutting the release."
fi
[ "$FAIL" -eq 0 ]
