#!/usr/bin/env bash
# publish-ota-repo.sh — (re)publish the device-daemon apk OTA repo to GitHub Pages.
#
# The Nexus Q trusts the pmbootstrap build key `pmos@local-6a42e957` (its public
# part is already in the device's /etc/apk/keys), so it installs our SIGNED apks
# straight from https://petronijus.github.io/nexusQ-reloaded/nexusq — no new key,
# no reflash. This script takes the newest build of each OTA package from the
# pmbootstrap packages repo (in the `nexusq-workdir` docker volume), rebuilds +
# signs a clean APKINDEX with that key (inside a throwaway container that has the
# key), and pushes the tree to the `gh-pages` branch.
#
# Run it AFTER a build that bumped any of the OTA packages. `apk upgrade` on the
# device (or the app's "Nexus Q" update) then pulls the new versions.
#
# The daemons + the device config now fit: the ~180 MB glibc-rt Roon base was
# split into its own package (nexusq-glibc-rt, 2026-08-02), so device-google-
# steelhead dropped under GitHub's 100 MB limit and its config is OTA-shippable.
# nexusq-glibc-rt (still big, static) and the kernel stay flash-only.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VOL=nexusq-workdir
KEY=pmos@local-6a42e957
# The four daemons + the device CONFIG package (device-google-steelhead) and its
# firmware subpackage — all now under GitHub's 100 MB limit after the glibc-rt
# split (2026-08-02). This is what the app's SYSTEM update pulls (the base
# packages come from the Alpine/pmOS mirrors; the ~180 MB nexusq-glibc-rt base and
# the kernel are deliberately NOT here — flash-only). A size guard below refuses
# to publish anything ≥99 MB so a mistaken big apk can never break the push.
OTA_PACKAGES=(nexusq-control nexusqd nexusq-btagent nexusq-setupd nexusq-mqtt \
              device-google-steelhead device-google-steelhead-nonfree-firmware)

STAGE="$(mktemp -d)"
trap 'sudo rm -rf "$STAGE" 2>/dev/null || rm -rf "$STAGE"' EXIT

echo "=== building signed OTA repo from $VOL (packages: ${OTA_PACKAGES[*]}) ==="
docker run --rm -v "$VOL":/w -v "$STAGE":/out alpine sh -c '
  set -e
  apk add --no-cache abuild >/dev/null 2>&1
  cp /w/config_abuild/'"$KEY"'.rsa.pub /etc/apk/keys/
  export HOME=/tmp/ab; mkdir -p $HOME/.abuild
  cp /w/config_abuild/'"$KEY"'.rsa* $HOME/.abuild/
  REPO=/w/packages/edge/armv7
  mkdir -p /out/nexusq/armv7; cd /out/nexusq/armv7
  for pkg in '"${OTA_PACKAGES[*]}"'; do
    f=$(ls -1 $REPO/${pkg}-[0-9]*.apk 2>/dev/null | sort -V | tail -1)
    [ -n "$f" ] || continue
    sz=$(stat -c%s "$f")
    if [ "$sz" -ge 103809024 ]; then
      echo "  !! SKIP $(basename "$f") — ${sz} bytes >= 99 MB (GitHub limit); NOT publishing" >&2
      continue
    fi
    cp "$f" . && echo "  + $(basename "$f") ($((sz/1024/1024)) MB)"
  done
  apk index --rewrite-arch armv7 -o APKINDEX.tar.gz *.apk >/dev/null 2>&1
  abuild-sign -k $HOME/.abuild/'"$KEY"'.rsa APKINDEX.tar.gz
  chmod -R a+rw /out
'

echo "=== publishing to the gh-pages branch ==="
WT="$STAGE/gh-pages-wt"
git -C "$REPO_ROOT" worktree add "$WT" gh-pages
rm -rf "$WT/nexusq"
cp -r "$STAGE/nexusq" "$WT/"
git -C "$WT" add -A
if git -C "$WT" diff --cached --quiet; then
  echo "no changes — repo already up to date"
else
  VERS="$(tar xzf "$WT/nexusq/armv7/APKINDEX.tar.gz" -O APKINDEX 2>/dev/null \
    | awk '/^P:/{p=$0} /^V:/{print p" "$0}' | sed 's/P://;s/V://' | tr '\n' ' ')"
  git -C "$WT" -c user.email=petronijus@bastla.com -c user.name="Petr Parkan Janda" \
    commit -m "OTA apk repo — $VERS"
  git -C "$WT" push origin gh-pages
  echo "published: $VERS"
fi
git -C "$REPO_ROOT" worktree remove "$WT" --force
echo "=== done — https://petronijus.github.io/nexusQ-reloaded/nexusq ==="
