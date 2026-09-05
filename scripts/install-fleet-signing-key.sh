#!/usr/bin/env bash
# Make THIS machine sign packages and bake images with the FLEET key.
#
# Why this exists: the key is per-build-volume, not per-repo. pmbootstrap runs
# `abuild-keygen` the first time a volume is initialised, so every machine that
# ever built the image invented its own — the desktop got pmos@local-6a42e957,
# the MacBook pmos@local-6a93112c, and an older volume produced 6a913e9e. That is
# invisible until it bites, and it bites in two directions at once:
#
#   * a PACKAGE signed with the wrong key is refused by every Q over OTA;
#   * an IMAGE built with the wrong key bakes it into /etc/apk/keys, so a box
#     flashed from that image answers every `apk update` with UNTRUSTED
#     signature and can never OTA at all. v1.14.0, v1.14.1 and v1.14.2 all
#     shipped that way (2026-08-30).
#
# So "which machine may cut a release" was really "which machine happens to hold
# the fleet key". This script removes that constraint: it installs the recorded
# fleet key from 1Password into this machine's build volume, after proving the
# private half actually matches the public half committed in the repo.
#
# The key lives in TWO places in a pmbootstrap volume, and both must agree:
#
#   config_abuild/    what abuild SIGNS with (private + public half, abuild.conf)
#   config_apk_keys/  what every chroot TRUSTS -- pmbootstrap 3 bind-mounts this
#                     directory as /etc/apk/keys into the native, buildroot AND
#                     rootfs chroots, and populates it exactly once, at first
#                     init, with whatever abuild key existed then.
#
# The first version of this script only did config_abuild. Found 2026-09-05 on
# the MacBook: the volume signed with the fleet key and TRUSTED only the retired
# one, so abuild's post-build `apk index` rejected every fleet-signed apk as
# UNTRUSTED (the build failed), and an image built there would have baked the
# retired key into /etc/apk/keys -- the v1.13.0 drift all over again, from the
# machine that had supposedly been fixed. Hence the reconcile step below, which
# runs on every invocation, --check included, because "already holds the key" was
# true and insufficient.
#
# Usage:
#   scripts/install-fleet-signing-key.sh [--check]
#     --check   report what this machine would sign with, change nothing
#
# Needs: `op` (signed in), docker. Works on Linux and macOS.
#
# The private key is streamed 1Password -> docker stdin and never written to the
# host filesystem, never echoed, and never passed as an argument.
set -euo pipefail
cd "$(dirname "$0")/.."

VOL="${VOL:-nexusq-workdir}"
ITEM="${NQ_FLEET_KEY_ITEM:-nexusQ OTA signing key (fleet)}"
FLEET_PUB="pmos/ota-signing-key.rsa.pub"
CHECK=0
[ "${1:-}" = "--check" ] && CHECK=1

[ -f "$FLEET_PUB" ] || { echo "ERROR: $FLEET_PUB missing — nothing to install against" >&2; exit 1; }

# The key's NAME is not recorded anywhere machine-readable, so derive it from
# whatever the volume already has, falling back to the canonical fleet name. The
# name is only a filename; the bytes are what apk verifies, and those are checked
# below.
FLEET_NAME="${NQ_FLEET_KEY_NAME:-pmos@local-6a42e957}"

echo "=== what this machine signs with today ==="
docker run --rm -v "$VOL":/w alpine sh -c '
  if [ -d /w/config_abuild ]; then
    ls -1 /w/config_abuild/*.rsa.pub 2>/dev/null | while read -r k; do
      echo "  key: $(basename "$k" .rsa.pub)"
    done
    [ -f /w/config_abuild/abuild.conf ] && sed "s/^/  /" /w/config_abuild/abuild.conf
  else
    echo "  (no config_abuild yet — a fresh volume; pmbootstrap would invent a key)"
  fi'

# Does the volume already hold exactly the fleet key, byte for byte?
if docker run --rm -v "$VOL":/w -v "$PWD/$FLEET_PUB":/fleet.pub:ro alpine \
       sh -c 'cmp -s /w/config_abuild/'"$FLEET_NAME"'.rsa.pub /fleet.pub' 2>/dev/null; then
    echo
    echo "✅ already signing with the fleet key ($FLEET_NAME), byte-identical to $FLEET_PUB"
    ALREADY=1
else
    ALREADY=0
fi

# Reconcile the TRUST side and the package repo with the signing key. Idempotent;
# prints what it changed. Runs in --check mode too (read-only there).
reconcile() {  # reconcile <apply:0|1>
    docker run --rm -v "$VOL":/w -v "$PWD/$FLEET_PUB":/fleet.pub:ro alpine sh -c '
      set -e
      APPLY='"$1"'; NAME='"$FLEET_NAME"'; rc=0
      say() { echo "  $*"; }
      # -- config_apk_keys: the fleet key must be trusted, retired abuild keys must not
      if [ -d /w/config_apk_keys ]; then
        if cmp -s /w/config_apk_keys/$NAME.rsa.pub /fleet.pub 2>/dev/null; then
          say "trust: $NAME.rsa.pub present in config_apk_keys ✅"
        else
          say "trust: $NAME.rsa.pub MISSING from config_apk_keys -- chroots would reject every fleet-signed apk as UNTRUSTED"
          if [ "$APPLY" = 1 ]; then
            owner=$(stat -c %u:%g /w/config_apk_keys)
            cp /fleet.pub /w/config_apk_keys/$NAME.rsa.pub && chown "$owner" /w/config_apk_keys/$NAME.rsa.pub && say "  -> installed"
          else rc=1; fi
        fi
        for k in /w/config_apk_keys/pmos@local-*.rsa.pub; do
          [ -e "$k" ] || continue; [ "$(basename "$k")" = "$NAME.rsa.pub" ] && continue
          say "trust: $(basename "$k") is a retired build key still trusted by every chroot"
          if [ "$APPLY" = 1 ]; then
            mkdir -p /w/config_apk_keys/retired && mv "$k" /w/config_apk_keys/retired/ && say "  -> retired"
          else rc=1; fi
        done
      else
        say "trust: no config_apk_keys yet (fresh volume) -- pmbootstrap will create it from config_abuild on first init"
      fi
      # -- packages/: an apk the chroots no longer trust breaks abuild'"'"'s index update
      #    for EVERY later build ("Failed to create index"), so park them. Nothing is
      #    deleted; the publisher and pmbootstrap only glob the top level.
      for repo in /w/packages/*/armv7; do
        [ -d "$repo" ] || continue
        for f in "$repo"/*.apk; do
          [ -e "$f" ] || continue
          sig=$(tar -tzf "$f" 2>/dev/null | sed -n "s/^\.SIGN\.RSA\.//p" | head -1)
          [ "$sig" = "$NAME.rsa.pub" ] && continue
          say "repo: $(basename "$f") is signed by ${sig:-nothing}, not $NAME"
          if [ "$APPLY" = 1 ]; then
            d="$repo/.retired-${sig%.rsa.pub}"; mkdir -p "$d" && mv "$f" "$d/" && say "  -> moved to $(basename "$d")/"
          else rc=1; fi
        done
        # the index describes files that may just have moved; abuild rewrites it
        [ "$APPLY" = 1 ] && rm -f "$repo"/APKINDEX.tar.gz
      done
      exit $rc'
}

if [ "$CHECK" = 1 ]; then
    echo
    echo "=== trust + repo (read-only) ==="
    if [ "$ALREADY" = 1 ] && reconcile 0; then exit 0; fi
    echo
    echo "⚠️  this machine is not (fully) on the fleet key."
    echo "    Releases cut here would bake a key no Q trusts, and packages built"
    echo "    here would be refused over OTA. Run without --check to fix it."
    exit 1
fi

if [ "$ALREADY" = 1 ]; then
    echo
    echo "=== signing key already installed; reconciling trust + repo ==="
    reconcile 1
    echo "done."
    exit 0
fi

command -v op >/dev/null || { echo "ERROR: 1Password CLI (op) not found" >&2; exit 1; }

echo
echo "=== installing the fleet key from 1Password → docker volume $VOL ==="
# Stream the private key straight into the container. It is verified INSIDE:
# openssl derives the public half from the private one and compares it with the
# committed public key. A name match would prove nothing — that is precisely the
# mistake that let the key drift go unnoticed for weeks.
op document get "$ITEM" --account my \
  | docker run --rm -i -v "$VOL":/w -v "$PWD/$FLEET_PUB":/fleet.pub:ro alpine sh -c '
    set -e
    apk add --no-cache openssl >/dev/null 2>&1
    mkdir -p /w/config_abuild
    cat > /tmp/k.rsa
    chmod 600 /tmp/k.rsa
    if ! openssl rsa -in /tmp/k.rsa -pubout 2>/dev/null > /tmp/derived.pub; then
        echo "ERROR: what 1Password returned is not an RSA private key" >&2; exit 1
    fi
    if ! cmp -s /tmp/derived.pub /fleet.pub; then
        echo "ERROR: the private key in 1Password does NOT match pmos/ota-signing-key.rsa.pub." >&2
        echo "       Refusing to install a key the fleet does not trust." >&2
        exit 1
    fi
    cp /tmp/k.rsa "/w/config_abuild/'"$FLEET_NAME"'.rsa"
    cp /fleet.pub  "/w/config_abuild/'"$FLEET_NAME"'.rsa.pub"
    printf "PACKAGER_PRIVKEY=\"/home/pmos/.abuild/'"$FLEET_NAME"'.rsa\"\n" \
        > /w/config_abuild/abuild.conf
    # Any OTHER key in here is a loaded gun: publish-ota-repo.sh discovers the
    # key by globbing, and a stale local key could win. Park them out of the way
    # rather than deleting someone else than us made.
    for k in /w/config_abuild/*.rsa /w/config_abuild/*.rsa.pub; do
        case "$k" in *'"$FLEET_NAME"'.rsa|*'"$FLEET_NAME"'.rsa.pub) continue ;; esac
        [ -e "$k" ] || continue
        mkdir -p /w/config_abuild/retired
        mv "$k" /w/config_abuild/retired/ && echo "  retired $(basename "$k")"
    done
    # Ownership matters: pmbootstrap reads this as the in-chroot uid 12345, and a
    # 0600 key owned by anyone else fails with a bare "Permission denied" out of
    # openssl during create_apks (see docker-build.sh Phase 7a).
    chown -R 12345:12345 /w/config_abuild
    chmod 600 "/w/config_abuild/'"$FLEET_NAME"'.rsa"
    rm -f /tmp/k.rsa /tmp/derived.pub
    echo "  installed '"$FLEET_NAME"' (private 0600, uid 12345)"
'

echo
echo "=== reconciling trust + repo ==="
reconcile 1

echo
echo "=== verifying ==="
docker run --rm -v "$VOL":/w -v "$PWD/$FLEET_PUB":/fleet.pub:ro alpine sh -c '
  cmp -s /w/config_abuild/'"$FLEET_NAME"'.rsa.pub /fleet.pub \
    && echo "  public half byte-identical to '"$FLEET_PUB"' ✅" \
    || { echo "  MISMATCH ❌" >&2; exit 1; }
  sed "s/^/  /" /w/config_abuild/abuild.conf'

cat <<MSG

This machine can now cut releases: packages it builds are signed with the fleet
key, and images it builds bake that key into /etc/apk/keys.

Packages the old key signed were moved out of packages/*/armv7 into
.retired-<key>/ (nothing deleted). Before publishing an OTA-only build from this
machine, seed the volume with the fleet's published apks:
scripts/seed-ota-volume.sh -- or run a full build here.
MSG
