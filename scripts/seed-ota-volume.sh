#!/usr/bin/env bash
# seed-ota-volume.sh — bring THIS machine's pmbootstrap build volume up to date
# with the apks the fleet is actually running, so an OTA-only build here can be
# published without regressing every package it did not rebuild.
#
# WHY. scripts/publish-ota-repo.sh publishes "the newest build of each OTA
# package found in the volume". That is the right rule on the machine that built
# everything, and a trap on any other: a volume holds whatever was ever built on
# that host, signed by whatever key it held at the time. On 2026-09-05 the
# MacBook's volume held every OTA package signed by its RETIRED pre-fleet key
# (pmos@local-6a93112c) and no kernel newer than 6.12 — publishing a two-package
# OTA build from it would have shipped a fleet-signed index over ten apks every
# device rejects as UNTRUSTED, and rolled the kernel payload back by a release.
#
# WHAT. Read the published index (the fleet-signed truth), download each listed
# apk, prove it is signed by the fleet key, and drop it into the volume's repo
# dir owned the way pmbootstrap expects. Nothing is destroyed: a same-named file
# signed by some other key is moved aside into .retired-<key>/, where neither
# pmbootstrap's glob nor the publisher's `sort -V | tail -1` can see it.
#
# WHEN. Before an OTA_PACKAGES_ONLY build on a machine that has not run the full
# pipeline since the fleet key was installed — i.e. before the first OTA publish
# from a new or re-keyed host. Idempotent; re-running is a no-op that says so.
#
# Usage: scripts/seed-ota-volume.sh            (VOL=nexusq-workdir by default)
#        OTA_URL=https://.../nexusq scripts/seed-ota-volume.sh
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VOL="${VOL:-nexusq-workdir}"
OTA_URL="${OTA_URL:-https://petronijus.github.io/nexusQ-reloaded/nexusq}"
FLEET_KEY="$REPO_ROOT/pmos/ota-signing-key.rsa.pub"
[ -f "$FLEET_KEY" ] || { echo "ERROR: $FLEET_KEY missing — nothing to verify signatures against" >&2; exit 1; }

command -v docker >/dev/null || { echo "docker required" >&2; exit 2; }
docker volume inspect "$VOL" >/dev/null 2>&1 || { echo "ERROR: docker volume $VOL does not exist — run a full build first" >&2; exit 1; }

# The fleet key's NAME is whatever config_abuild calls the file whose content
# matches pmos/ota-signing-key.rsa.pub (publish-ota-repo.sh discovers it the same
# way). Signatures inside apks are named after it: .SIGN.RSA.<name>.rsa.pub
KEY=$(docker run --rm -v "$VOL":/w -v "$FLEET_KEY":/fleet.pub:ro alpine sh -c '
    for k in /w/config_abuild/*.rsa.pub; do
        [ -e "$k" ] || continue
        cmp -s "$k" /fleet.pub && { basename "$k" .rsa.pub; exit 0; }
    done; exit 1' 2>/dev/null) || {
    echo "ERROR: the fleet key is not in $VOL/config_abuild — run scripts/install-fleet-signing-key.sh first" >&2; exit 1; }
echo "fleet key: $KEY"

STAGE="$(mktemp -d)"; trap 'rm -rf "$STAGE"' EXIT
echo "=== reading the published index: $OTA_URL/armv7/APKINDEX.tar.gz ==="
curl -fsSL "$OTA_URL/armv7/APKINDEX.tar.gz" -o "$STAGE/APKINDEX.tar.gz"
# P:/V: pairs -> "<name>-<version>.apk"
tar -xzOf "$STAGE/APKINDEX.tar.gz" APKINDEX \
    | awk '/^P:/{p=substr($0,3)} /^V:/{print p "-" substr($0,3) ".apk"}' | sort > "$STAGE/list"
[ -s "$STAGE/list" ] || { echo "ERROR: the published index lists no packages" >&2; exit 1; }
echo "  $(wc -l < "$STAGE/list" | tr -d ' ') published apks"

echo "=== downloading + verifying signatures ==="
while read -r f; do
    curl -fsSL "$OTA_URL/armv7/$f" -o "$STAGE/$f"
    sig=$(tar -tzf "$STAGE/$f" 2>/dev/null | sed -n 's/^\.SIGN\.RSA\.//p' | head -1)
    if [ "$sig" != "$KEY.rsa.pub" ]; then
        echo "  !! $f on the PUBLISHED repo is signed by ${sig:-nothing}, not $KEY — refusing to seed a repo the fleet cannot trust" >&2
        exit 1
    fi
    echo "  ok  $f  ($(du -h "$STAGE/$f" | cut -f1 | tr -d ' '))"
done < "$STAGE/list"

echo "=== placing into $VOL/packages/edge/armv7 ==="
docker run --rm -v "$VOL":/w -v "$STAGE":/in:ro alpine sh -c '
  set -e
  REPO=/w/packages/edge/armv7; mkdir -p "$REPO"; cd "$REPO"
  KEY="'"$KEY"'"
  # pmbootstrap runs as uid 12345 and re-owns REPODEST to it (docker-build.sh
  # Phase 7a); files owned by anyone else make abuild refuse to update the index.
  OWNER=$(stat -c %u:%g . 2>/dev/null || echo 12345:12345)
  seeded=0; kept=0; retired=0
  for src in /in/*.apk; do
    f=$(basename "$src")
    if [ -e "$f" ]; then
      have=$(tar -tzf "$f" 2>/dev/null | sed -n "s/^\\.SIGN\\.RSA\\.//p" | head -1)
      if cmp -s "$f" "$src"; then kept=$((kept+1)); echo "  =   $f (already the published bytes)"; continue; fi
      d=".retired-${have%.rsa.pub}"; mkdir -p "$d"; mv "$f" "$d/"; retired=$((retired+1))
      echo "  ->  $f moved to $d/ (signed by ${have:-nothing}, not the published bytes)"
    fi
    cp "$src" "$f"; chown "$OWNER" "$f"; seeded=$((seeded+1)); echo "  +   $f"
  done
  # Anything ELSE in the OTA set that is NEWER than what is published and signed
  # by a foreign key would still win the publisher'"'"'s sort -V. Say so.
  for src in /in/*.apk; do
    f=$(basename "$src"); p=${f%-[0-9]*}
    for g in $(ls -1 ${p}-[0-9]*.apk 2>/dev/null | sort -V); do
      [ "$g" = "$f" ] && continue
      have=$(tar -tzf "$g" 2>/dev/null | sed -n "s/^\\.SIGN\\.RSA\\.//p" | head -1)
      if [ "$have" != "$KEY.rsa.pub" ] && [ "$(printf "%s\n%s\n" "$f" "$g" | sort -V | tail -1)" = "$g" ]; then
        d=".retired-${have%.rsa.pub}"; mkdir -p "$d"; mv "$g" "$d/"; retired=$((retired+1))
        echo "  ->  $g moved to $d/ (newer than published AND signed by ${have:-nothing} — it would have won the publish)"
      fi
    done
  done
  # Leave the index to pmbootstrap/abuild: it is rewritten by the next build.
  rm -f APKINDEX.tar.gz
  echo "seeded=$seeded kept=$kept retired=$retired"
'
echo "=== done. The next OTA_PACKAGES_ONLY build here can be published safely. ==="
