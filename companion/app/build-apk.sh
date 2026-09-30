#!/bin/sh
# Build the Nexus Q companion apk with a HONEST build identity.
#
# The app's real version lives in pubspec.yaml and nowhere else; this script
# reads it from there and injects it, so the version shown in the UI can never
# drift from the versionName Android records. It also stamps a per-build tag so
# two apks cut from the same version on the same day are still tellable apart.
#
# Usage:  ./build-apk.sh [--release] [--flavor github|play|fdroid]
#         (defaults: --debug, --flavor github)
#
# The flavor is where the build goes (android/app/build.gradle.kts): github
# is the APK that updates itself (Petr's phone, GitHub releases); play builds
# the Android App Bundle for Google Play (release only); fdroid is what
# F-Droid builds from source, here only to try it.
#
# Remember to bump `version: X.Y.Z+N` in pubspec.yaml when handing a new apk to
# the phone. X.Y.Z moves on the APP's OWN semver track — deliberately NOT tied to
# the Nexus Q image releases; app changes are tracked separately. Always increase
# +N (Android refuses to install a lower versionCode over a higher one).
set -eu

cd "$(dirname "$0")"

MODE=--debug
FLAVOR=github
while [ $# -gt 0 ]; do
	case "$1" in
		--release | --debug) MODE="$1" ;;
		--flavor)
			[ $# -ge 2 ] || { echo "ERROR: --flavor needs github, play or fdroid" >&2; exit 1; }
			FLAVOR="$2"
			shift
			;;
		*) echo "ERROR: unknown argument '$1'" >&2; exit 1 ;;
	esac
	shift
done
case "$FLAVOR" in
	github | play | fdroid) ;;
	*) echo "ERROR: flavor must be github, play or fdroid, not '$FLAVOR'" >&2; exit 1 ;;
esac
if [ "$FLAVOR" = play ] && [ "$MODE" != --release ]; then
	echo "ERROR: the play flavor is built for upload, i.e. --release" >&2
	exit 1
fi
APP_VERSION=$(sed -n 's/^version:[[:space:]]*//p' pubspec.yaml | head -1)
BUILD_TAG=$(date +%m%d-%H%M)

if [ -z "$APP_VERSION" ]; then
	echo "ERROR: no 'version:' in pubspec.yaml" >&2
	exit 1
fi

# The OTA check compares the `+N` build number, so a version without one leaves
# the app unable to place itself against the manifest. It fails safe now (no
# update offered) rather than looping, but a release still has to carry it.
case "$APP_VERSION" in
	*+*) ;;
	*)
		echo "ERROR: version '$APP_VERSION' has no '+N' build number." >&2
		echo "       pubspec.yaml must read 'version: X.Y.Z+N' — the +N IS" >&2
		echo "       Android's versionCode and what the OTA check compares." >&2
		exit 1
		;;
esac

echo "Building companion app v$APP_VERSION (build $BUILD_TAG) $MODE, flavor $FLAVOR"
# Spotify transport (lib/spotify/): the Web API client ID is a PUBLIC identifier
# (PKCE, no secret) but it names Petr's developer app, so it lives in 1Password
# ("Spotify API key", field "client ID" -- the same item the Spotify MCP uses) and is injected here,
# never committed. Without `op` the build still succeeds and the app reports
# Spotify control as "not configured" -- honest, not broken.
SPOTIFY_CLIENT_ID="${SPOTIFY_CLIENT_ID:-}"
if [ -z "$SPOTIFY_CLIENT_ID" ] && command -v op >/dev/null 2>&1; then
	SPOTIFY_CLIENT_ID=$(op item get "${NQ_SPOTIFY_ITEM:-Spotify API key}" --account my --fields "label=${NQ_SPOTIFY_FIELD:-client ID}" 2>/dev/null | tr -d '"' || true)
fi
if [ -n "$SPOTIFY_CLIENT_ID" ]; then
	echo "Spotify client ID: injected (${#SPOTIFY_CLIENT_ID} chars)"
else
	echo "WARNING: no Spotify client ID (1Password item missing or op not signed in) -> Spotify control disabled in this build" >&2
fi

# Signing (since 2026-09-30). Two keys, both in 1Password (a Document with the
# keystore, alias and passwords as fields), fetched to private temp files for
# this build and removed after:
#   "nexusQ companion Android release key"  the app's key; gradle signs every
#       flavor with it, and it is the Google Play upload key;
#   "nexusQ companion Android signing key"  the OLD key (the MacBook's and the
#       desktop's debug keystore) that every install before 1.27 was signed with.
# The github APK is then re-signed with both and the rotation record
# android/signing/rotation.lineage (old -> new, signed by the old key): v1/v2
# carry the old key, which Android 7-8 keep checking, and v3 the new key with
# its proof, so an installed app takes the update and moves to the new key.
# A caller may pass NQ_ANDROID_KEYSTORE & co. (the release key) itself.
KEY_ITEM="${NQ_ANDROID_KEY_ITEM:-nexusQ companion Android release key}"
OLD_KEY_ITEM="${NQ_ANDROID_OLD_KEY_ITEM:-nexusQ companion Android signing key}"
LINEAGE=android/signing/rotation.lineage
KEYDIR=""
EXPORT=""
cleanup() {
	if [ -n "$KEYDIR" ]; then rm -rf "$KEYDIR"; fi
	if [ -n "$EXPORT" ]; then rm -rf "$EXPORT"; fi
}
trap cleanup EXIT INT TERM
KEYDIR=$(mktemp -d "${TMPDIR:-/tmp}/nq-android-keys.XXXXXX")
chmod 700 "$KEYDIR"

# fetch_key ITEM FILE: the keystore Document of ITEM into FILE (0600).
fetch_key() {
	op document get "$1" --account my --out-file "$2" --force >/dev/null 2>&1 || return 1
	chmod 600 "$2"
}
op_field() { op item get "$1" --account my --fields "label=$2" --reveal; }

if [ -z "${NQ_ANDROID_KEYSTORE:-}" ] && command -v op >/dev/null 2>&1 && fetch_key "$KEY_ITEM" "$KEYDIR/release.p12"; then
	NQ_ANDROID_KEYSTORE="$KEYDIR/release.p12"
	NQ_ANDROID_KEYSTORE_PASSWORD=$(op_field "$KEY_ITEM" "store password")
	NQ_ANDROID_KEY_ALIAS=$(op item get "$KEY_ITEM" --account my --fields "label=key alias")
	NQ_ANDROID_KEY_PASSWORD=$(op_field "$KEY_ITEM" "key password")
	export NQ_ANDROID_KEYSTORE NQ_ANDROID_KEYSTORE_PASSWORD NQ_ANDROID_KEY_ALIAS NQ_ANDROID_KEY_PASSWORD
fi
if [ -n "${NQ_ANDROID_KEYSTORE:-}" ]; then
	echo "Signing: the app's release key (1Password \"$KEY_ITEM\")"
elif [ "$MODE" = "--release" ]; then
	echo "ERROR: no release key (1Password \"$KEY_ITEM\" unreadable; is op signed in?)." >&2
	echo "       A release signed with this machine's debug key installs on no phone that" >&2
	echo "       has the app. Refusing." >&2
	exit 1
else
	echo "WARNING: no release key -> this debug build is signed with this machine's" >&2
	echo "         debug key and will not install over the phone's app." >&2
fi

# apksigner from the newest build-tools of the Android SDK.
find_apksigner() {
	for sdk in "${ANDROID_HOME:-}" "${ANDROID_SDK_ROOT:-}" "$HOME/Android/Sdk" "$HOME/Library/Android/sdk"; do
		[ -n "$sdk" ] && [ -d "$sdk/build-tools" ] || continue
		found=$(ls -d "$sdk"/build-tools/*/apksigner 2>/dev/null | sort -V | tail -1)
		[ -n "$found" ] && { echo "$found"; return 0; }
	done
	return 1
}

# A release is built from the last commit, exported clean (`git archive`), as
# F-Droid builds it: it goes to the public (a store, GitHub releases), and the
# stock imagery and video of the original Nexus Q app that a developer's tree
# carries in assets/stock/ (gitignored, extracted from Google's app, see
# lib/setup/stock_assets.dart) must never go with it. It also makes what is
# uploaded exactly a commit. A debug build stays on the working tree, stock
# imagery and all, for a developer's own phone.
APP_DIR=$(pwd)
SRC_DIR="$APP_DIR"
if [ "$MODE" = --release ]; then
	if [ -n "$(git status --porcelain -- .)" ]; then
		echo "ERROR: a release is built from the last commit; companion/app has uncommitted" >&2
		echo "       changes (git status -- companion/app). Commit them first." >&2
		exit 1
	fi
	EXPORT=$(mktemp -d "${TMPDIR:-/tmp}/nq-app-export.XXXXXX")
	PREFIX=$(git rev-parse --show-prefix)
	git -C "$(git rev-parse --show-toplevel)" archive HEAD "$PREFIX" | tar -x -C "$EXPORT"
	SRC_DIR="$EXPORT/$PREFIX"
	echo "Source: commit $(git rev-parse --short HEAD), exported clean"
fi

# Google Play takes an Android App Bundle; everything else an APK.
TARGET=apk
[ "$FLAVOR" = play ] && TARGET=appbundle
(
	cd "$SRC_DIR"
	if [ "$SRC_DIR" != "$APP_DIR" ]; then flutter pub get >/dev/null; fi
	flutter build "$TARGET" "$MODE" --flavor "$FLAVOR" \
		--dart-define=APP_VERSION="$APP_VERSION" \
		--dart-define=BUILD_TAG="$BUILD_TAG" \
		--dart-define=SPOTIFY_CLIENT_ID="$SPOTIFY_CLIENT_ID"
)

BUILT_MODE=${MODE#--}
if [ "$TARGET" = appbundle ]; then
	OUT="build/app/outputs/bundle/${FLAVOR}Release/app-${FLAVOR}-release.aab"
else
	OUT="build/app/outputs/flutter-apk/app-${FLAVOR}-${BUILT_MODE}.apk"
fi
[ -f "$SRC_DIR/$OUT" ] || { echo "ERROR: the build reported success but $OUT is missing" >&2; exit 1; }
if [ "$SRC_DIR" != "$APP_DIR" ]; then
	mkdir -p "$(dirname "$OUT")"
	cp "$SRC_DIR/$OUT" "$OUT"
fi

# No stock imagery in a release, whatever happened above.
if [ "$MODE" = --release ]; then
	STOCK=$(unzip -Z1 "$OUT" | grep -E 'flutter_assets/assets/stock/' | grep -vE '/\.keep$' || true)
	if [ -n "$STOCK" ]; then
		echo "ERROR: $OUT carries the original app's stock assets:" >&2
		echo "$STOCK" | head -5 >&2
		exit 1
	fi
fi

# The github APK: re-sign with the old key, the release key and the rotation
# record (see Signing above), then prove it carries the release key.
if [ "$FLAVOR" = github ] && [ -n "${NQ_ANDROID_KEYSTORE:-}" ]; then
	APKSIGNER=$(find_apksigner) || { echo "ERROR: no apksigner in the Android SDK" >&2; exit 1; }
	fetch_key "$OLD_KEY_ITEM" "$KEYDIR/old.keystore" || {
		echo "ERROR: the old key (1Password \"$OLD_KEY_ITEM\") is needed to sign the rotation" >&2
		exit 1
	}
	NQ_OLD_PW=$(op_field "$OLD_KEY_ITEM" "store password")
	NQ_OLD_ALIAS=$(op item get "$OLD_KEY_ITEM" --account my --fields "label=key alias")
	export NQ_OLD_PW
	"$APKSIGNER" sign \
		--ks "$KEYDIR/old.keystore" --ks-pass env:NQ_OLD_PW --ks-key-alias "$NQ_OLD_ALIAS" \
		--next-signer --ks "$NQ_ANDROID_KEYSTORE" --ks-pass env:NQ_ANDROID_KEYSTORE_PASSWORD \
		--ks-key-alias "$NQ_ANDROID_KEY_ALIAS" \
		--lineage "$APP_DIR/$LINEAGE" --rotation-min-sdk-version 28 \
		"$OUT" 2>/dev/null
	"$APKSIGNER" verify --verbose --print-certs "$OUT" 2>/dev/null | grep -q 'Verified using v3 scheme (APK Signature Scheme v3): true' || {
		echo "ERROR: $OUT does not verify with a v3 signature after the re-sign" >&2
		exit 1
	}
	echo "Signed: v1/v2 with the old key, v3 with the release key + rotation record"
fi

echo ""
echo "Built: $OUT"
echo "  version : $APP_VERSION"
echo "  build   : $BUILD_TAG"
echo "  flavor  : $FLAVOR"
echo ""
if [ "$TARGET" = apk ]; then
	echo "Install with:  adb install -r $OUT"
else
	echo "Upload to the Play Console (a closed-testing or production release)."
fi
