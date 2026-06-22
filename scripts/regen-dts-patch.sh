#!/usr/bin/env bash
#
# Regenerate kernel/patches/0003-ARM-dts-omap4-add-steelhead.patch from the
# working DTS source (kernel/dts/omap4-steelhead.dts).
#
# Patch 0003 is a "new file" patch: it adds arch/arm/boot/dts/ti/omap/
# omap4-steelhead.dts (the whole DTS as the hunk body, each line '+'-prefixed)
# plus a one-line Makefile hunk that registers omap4-steelhead.dtb. After any
# edit to the DTS, the body and the line counts must be regenerated so the patch
# still applies cleanly to a pristine linux tree.
#
# This script preserves the commit message header AND the Makefile hunk verbatim
# (the Makefile hunk's context lines must match the real upstream Makefile, which
# we don't carry locally), and only rewrites the DTS hunk body + the two line
# counts (the diffstat line and the '@@ -0,0 +1,N @@' header).
#
# Usage: scripts/regen-dts-patch.sh
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
DTS="$REPO/kernel/dts/omap4-steelhead.dts"
PATCH="$REPO/kernel/patches/0003-ARM-dts-omap4-add-steelhead.patch"

[ -f "$DTS" ]   || { echo "missing $DTS"; exit 1; }
[ -f "$PATCH" ] || { echo "missing $PATCH"; exit 1; }

N=$(wc -l < "$DTS")
INS=$((N + 1))   # DTS lines + the one Makefile addition

# Line number of the DTS hunk header ('@@ -0,0 +1,...') -- everything above it
# (commit message, diffstat, Makefile hunk, new-file header) is preserved; the
# header's count is rewritten and everything below it is replaced by the body.
HUNK_LN=$(grep -n '^@@ -0,0 +1,' "$PATCH" | tail -1 | cut -d: -f1)
[ -n "$HUNK_LN" ] || { echo "could not find DTS hunk header in $PATCH"; exit 1; }

TMP="$(mktemp)"
# 1) header up to (but not including) the hunk line, with line counts refreshed:
#    - diffstat:  '... omap4-steelhead.dts | <N> +'
#    - diffstat:  ' 2 files changed, <INS> insertions(+)'
head -n "$((HUNK_LN - 1))" "$PATCH" \
  | sed -E "s#(omap4-steelhead\.dts[[:space:]]*\|[[:space:]]*)[0-9]+#\1${N}#" \
  | sed -E "s/^( 2 files changed, )[0-9]+( insertion)/\1${INS}\2/" \
  > "$TMP"
# 2) refreshed hunk header
printf '@@ -0,0 +1,%d @@\n' "$N" >> "$TMP"
# 3) DTS body, every line '+'-prefixed (blank lines become a bare '+')
sed 's/^/+/' "$DTS" >> "$TMP"

mv "$TMP" "$PATCH"
echo "regenerated $PATCH (DTS=$N lines, insertions=$INS)"
