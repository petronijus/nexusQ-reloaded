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
# NOT a separate step when cutting a release: since 2026-08-30 scripts/package-
# release.sh runs this itself and then gates on the image and the repo agreeing
# (scripts/verify-ota-parity.sh). Running it by hand is for an OTA-only push --
# a daemon/config apk shipped without a new image.
#
# The daemons + the device config now fit: the ~180 MB glibc-rt Roon base was
# split into its own package (nexusq-glibc-rt, 2026-08-02), so device-google-
# steelhead dropped under GitHub's 100 MB limit and its config is OTA-shippable.
# nexusq-glibc-rt (still big, static) stays flash-only. The KERNEL apk is
# published too (since 2026-08-23) but only as nq-kernel-ota's PAYLOAD source --
# apk never applies a kernel; see pmos/ota-packages.list.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VOL="${VOL:-nexusq-workdir}"

# The signing key is DISCOVERED, not hardcoded. It used to be pinned to
# `pmos@local-6a42e957`, and on 2026-08-29 that name had silently drifted from
# reality: the published index was signed with 6a42e957 while the v1.13.0 image
# baked 6a913e9e into /etc/apk/keys, so a freshly flashed Q answered every
# `apk update` with "UNTRUSTED signature" and could not OTA at all. A hardcoded
# name cannot notice that; a discovered one plus the check below can.
KEY="${KEY:-}"
if [ -z "$KEY" ]; then
    KEY=$(docker run --rm -v "$VOL":/w alpine sh -c \
        'ls -1 /w/config_abuild/*.rsa.pub 2>/dev/null | head -1' \
        | xargs -r basename | sed 's/\.rsa\.pub$//')
fi
[ -n "$KEY" ] || { echo "ERROR: no signing key in volume $VOL/config_abuild" >&2; exit 1; }
echo "signing key: $KEY"

# And the drift guard: the fleet's recorded public key. Devices trust what was
# baked into their image, so publishing under a key no device holds is a silent
# outage. Refuse it.
FLEET_KEY="$REPO_ROOT/pmos/ota-signing-key.rsa.pub"
if [ ! -f "$FLEET_KEY" ]; then
    # The guard used to be `if [ -f ]` … with no else, so the ONE check written to
    # stop key drift did nothing whenever its reference file was absent — and the
    # file was never committed, so it did nothing always. Found 2026-08-30, when
    # this Mac (pmos@local-6a93112c) would have happily republished a repo that
    # every device flashed to trust pmos@local-6a42e957 rejects as UNTRUSTED.
    # A guard conditional on data nobody supplied is not a guard.
    cat >&2 <<MSG
ERROR: pmos/ota-signing-key.rsa.pub is missing, so the fleet-key drift check
       cannot run — and publishing under the wrong key is a SILENT outage:
       every device answers "UNTRUSTED signature" and OTA stops dead.
       Record the fleet's public key first. It is the one baked into the
       devices' /etc/apk/keys, readable from a running Q:
           ssh root@<device> cat /etc/apk/keys/pmos@local-*.rsa.pub
       or from an image that boots on the fleet today. Then commit it as
       pmos/ota-signing-key.rsa.pub so this check has something to compare.
       Override for a deliberate re-key: FLEET_KEY_OVERRIDE=1
MSG
    [ "${FLEET_KEY_OVERRIDE:-0}" = "1" ] || exit 1
    echo "FLEET_KEY_OVERRIDE=1 set — publishing WITHOUT the drift check" >&2
fi
if [ -f "$FLEET_KEY" ]; then
    HOST_KEY=$(docker run --rm -v "$VOL":/w alpine cat "/w/config_abuild/$KEY.rsa.pub")
    if [ "$HOST_KEY" != "$(cat "$FLEET_KEY")" ]; then
        cat >&2 <<MSG
ERROR: this build host signs with $KEY, which is NOT the fleet key recorded in
       pmos/ota-signing-key.rsa.pub. Publishing would produce a repo that every
       device rejects as UNTRUSTED (this exact drift broke OTA once already).
       Either build on the host that holds the fleet key, or re-key the fleet
       deliberately: update pmos/ota-signing-key.rsa.pub, ship an image that
       bakes it, and install it into /etc/apk/keys on every box in the field.
MSG
        exit 1
    fi
fi
# The OTA package set lives in pmos/ota-packages.list — one place, because the
# release gate (scripts/verify-ota-parity.sh) must judge the SAME set. It used to
# be this array, and a second copy in the gate would let the gate agree with the
# very bug it exists to catch. A size guard below still refuses to publish
# anything ≥99 MB, so a mistaken big apk can never break the push.
OTA_LIST="$REPO_ROOT/pmos/ota-packages.list"
[ -f "$OTA_LIST" ] || { echo "ERROR: missing $OTA_LIST — refusing to publish an unknown package set" >&2; exit 1; }
mapfile -t OTA_PACKAGES < <(sed 's/#.*//' "$OTA_LIST" | tr -d '[:blank:]' | grep -v '^$')
[ "${#OTA_PACKAGES[@]}" -gt 0 ] || { echo "ERROR: $OTA_LIST lists no packages" >&2; exit 1; }

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

# THE SECRETS GATE. gh-pages is PUBLIC, and `device-google-steelhead` bakes the
# WiFi profile (PSK in plain text) and ssh authorized_keys when built from the
# private overlay. That went unnoticed from r62 (2026-08-02) to r90 (2026-08-30):
# four weeks of publishing the WPA PSK to a public URL, while the image-side gate
# `release-preflight-no-secrets.sh` sat right there catching the identical bytes
# in the rootfs. It was never pointed at the packages. It is now.
echo "=== secrets gate: nothing personal inside the packages ==="
"$REPO_ROOT/scripts/verify-apk-no-secrets.sh" "$STAGE"/nexusq/armv7/*.apk

echo "=== publishing to the gh-pages branch ==="
WT="$STAGE/gh-pages-wt"
git -C "$REPO_ROOT" worktree add "$WT" gh-pages
rm -rf "$WT/nexusq"
cp -r "$STAGE/nexusq" "$WT/"

# The landing page carries a package table between OTA:TABLE markers — rebuild
# it from the APKINDEX we just staged so the page never shows stale versions.
python3 - "$WT" <<'PY'
import datetime, html, pathlib, re, sys, tarfile

wt = pathlib.Path(sys.argv[1])
with tarfile.open(wt / "nexusq/armv7/APKINDEX.tar.gz") as t:
    raw = t.extractfile("APKINDEX").read().decode()

pkgs = sorted(
    (dict(line.split(":", 1) for line in block.splitlines() if ":" in line)
     for block in raw.split("\n\n") if "P:" in block),
    key=lambda f: f["P"])

def human(n):
    n = int(n)
    return f"{n/1048576:.1f} MB" if n >= 1048576 else f"{n/1024:.1f} KB"

rows = "\n".join(
    '      <tr><td class="pkg">{}</td><td class="ver">{}</td>'
    '<td class="size">{}</td><td class="desc">{}</td></tr>'.format(
        html.escape(f["P"]), html.escape(f["V"]), human(f.get("S", 0)),
        html.escape(f.get("T", "")))
    for f in pkgs)

block = f'''<!-- OTA:TABLE:START — this block is regenerated by scripts/publish-ota-repo.sh; do not edit by hand -->
  <div class="tablewrap">
  <table>
    <thead><tr><th>Package</th><th>Version</th><th style="text-align:right">Size</th><th>Description</th></tr></thead>
    <tbody>
{rows}
    </tbody>
  </table>
  </div>
  <p class="published">Last published: {datetime.date.today().isoformat()}</p>
  <!-- OTA:TABLE:END -->'''

page = wt / "index.html"
new, n = re.subn(r"<!-- OTA:TABLE:START.*?<!-- OTA:TABLE:END -->", block,
                 page.read_text(), flags=re.S)
if n != 1:
    sys.exit("index.html: OTA:TABLE markers not found exactly once — refusing to publish a stale page")
page.write_text(new)
print(f"  index.html: table rebuilt ({len(pkgs)} packages)")
PY

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
