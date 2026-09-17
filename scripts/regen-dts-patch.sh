#!/usr/bin/env bash
#
# Regenerate kernel/patches/0003-ARM-dts-omap4-add-steelhead.patch from the
# working DTS source (kernel/dts/omap4-steelhead.dts).
#
# Patch 0003 is a "new file" patch: it adds arch/arm/boot/dts/ti/omap/
# omap4-steelhead.dts (the whole DTS as the hunk body, each line '+'-prefixed)
# plus a one-line Makefile hunk that registers omap4-steelhead.dtb.
#
# THE DTS SOURCE IS THE FINAL STATE, 0003 IS NOT. Later patches in the series
# (0040 BT UART max-speed, 0042 DPLL_ABE ref, 0043 WiFi local-mac-address, and
# whatever comes next) modify omap4-steelhead.dts ON TOP of 0003. So the body
# of 0003 has to be the DTS *with those later hunks taken back out*, or the
# later patches find their changes already present and the whole series stops
# applying. Until 2026-09-17 this script dumped the full DTS into 0003 and
# would have done exactly that -- it had simply not been run since 0043 was
# added (2026-07-16), which is why 0003 in git was 44 lines behind the source.
#
# So, per run:
#   1. copy the DTS source into a scratch tree at the in-kernel path;
#   2. reverse-apply every later patch that touches that path, newest first,
#      using only each patch's DTS-file section (0042 also touches clock code,
#      which the scratch tree does not have);
#   3. the result is the new 0003 body -- header, diffstat counts and the
#      Makefile hunk are preserved (the Makefile hunk's context has to match
#      the real upstream Makefile, which we do not carry);
#   4. VERIFY: a fresh scratch tree, the new 0003 body, then the later patches
#      forward in series order; it must come out byte-identical to the DTS
#      source, or the script exits non-zero and leaves 0003 untouched.
#
# If step 2 fails, a later patch touches a region you just edited in the
# source: regenerate THAT patch too (it is a normal diff against the pre-patch
# state), then re-run.
#
# Usage: scripts/regen-dts-patch.sh
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
DTS="$REPO/kernel/dts/omap4-steelhead.dts"
PATCHES="$REPO/kernel/patches"
PATCH="$PATCHES/0003-ARM-dts-omap4-add-steelhead.patch"
INTREE="arch/arm/boot/dts/ti/omap/omap4-steelhead.dts"

[ -f "$DTS" ]   || { echo "missing $DTS"; exit 1; }
[ -f "$PATCH" ] || { echo "missing $PATCH"; exit 1; }
command -v patch >/dev/null || { echo "GNU patch required"; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# Later patches in the series that touch the DTS, in series order. Anything
# numbered above 0003 whose diff names the in-tree DTS path.
LATER=()
while IFS= read -r f; do
    LATER+=("$f")
done < <(grep -l "^+++ b/$INTREE" "$PATCHES"/*.patch | sort | grep -v '/0003-')

# Only the DTS-file section of a patch: from its 'diff --git' line up to the
# next 'diff --git' (or EOF). GNU patch would otherwise try -- and fail -- to
# reverse the non-DTS files in the same patch against our one-file tree.
dts_section() {
    awk -v path="$INTREE" '
        /^diff --git /      { keep = ($0 ~ " b/" path "$") }
        keep                { print }
    ' "$1"
}

# --- 1+2: the pre-later-patches DTS -----------------------------------------
BASE="$WORK/base"
mkdir -p "$BASE/$(dirname "$INTREE")"
cp "$DTS" "$BASE/$INTREE"
if [ "${#LATER[@]}" -gt 0 ]; then
    echo "later DTS patches in the series (reverse-applying, newest first):"
    for (( i=${#LATER[@]}-1; i>=0; i-- )); do
        p="${LATER[$i]}"
        printf '  -R %s\n' "$(basename "$p")"
        if ! dts_section "$p" | patch -R -p1 -s --no-backup-if-mismatch -d "$BASE"; then
            echo "ERROR: $(basename "$p") does not reverse-apply to the DTS source." >&2
            echo "       Your edit touched a region that patch modifies. Regenerate" >&2
            echo "       that patch against the pre-patch state first, then re-run." >&2
            exit 1
        fi
    done
fi
BODY="$BASE/$INTREE"

N=$(wc -l < "$BODY")
INS=$((N + 1))   # DTS lines + the one Makefile addition

# --- 3: rebuild 0003 around the preserved header + Makefile hunk --------------
# Line number of the DTS hunk header ('@@ -0,0 +1,...') -- everything above it
# (commit message, diffstat, Makefile hunk, new-file header) is preserved; the
# header's count is rewritten and everything below it is replaced by the body.
HUNK_LN=$(grep -n '^@@ -0,0 +1,' "$PATCH" | tail -1 | cut -d: -f1)
[ -n "$HUNK_LN" ] || { echo "could not find DTS hunk header in $PATCH"; exit 1; }

NEW="$WORK/0003.patch"
head -n "$((HUNK_LN - 1))" "$PATCH" \
  | sed -E "s#(omap4-steelhead\.dts[[:space:]]*\|[[:space:]]*)[0-9]+#\1${N}#" \
  | sed -E "s/^( 2 files changed, )[0-9]+( insertion)/\1${INS}\2/" \
  > "$NEW"
printf '@@ -0,0 +1,%d @@\n' "$N" >> "$NEW"
sed 's/^/+/' "$BODY" >> "$NEW"

# --- 4: the series must reproduce the source, byte for byte ------------------
CHECK="$WORK/check"
mkdir -p "$CHECK/$(dirname "$INTREE")"
# Applying 0003's DTS hunk to an empty tree is exactly "write the body".
cp "$BODY" "$CHECK/$INTREE"
for p in "${LATER[@]}"; do
    if ! dts_section "$p" | patch -p1 -s --no-backup-if-mismatch -d "$CHECK"; then
        echo "ERROR: series verification failed forward-applying $(basename "$p")." >&2
        echo "       0003 left untouched." >&2
        exit 1
    fi
done
if ! cmp -s "$CHECK/$INTREE" "$DTS"; then
    echo "ERROR: 0003 + later patches do not reproduce kernel/dts/omap4-steelhead.dts:" >&2
    diff -u "$CHECK/$INTREE" "$DTS" | head -40 >&2
    echo "       0003 left untouched." >&2
    exit 1
fi

mv "$NEW" "$PATCH"
echo "regenerated $PATCH"
echo "  0003 body: $N lines (source $(wc -l < "$DTS") lines minus ${#LATER[@]} later patch(es)); insertions=$INS"
echo "  series verified: 0003 + $(printf '%s ' "${LATER[@]##*/}")reproduces the DTS source byte for byte"
