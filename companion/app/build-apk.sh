#!/bin/sh
# Build the Nexus Q companion apk with a HONEST build identity.
#
# The app's real version lives in pubspec.yaml and nowhere else; this script
# reads it from there and injects it, so the version shown in the UI can never
# drift from the versionName Android records. It also stamps a per-build tag so
# two apks cut from the same version on the same day are still tellable apart.
#
# Usage:  ./build-apk.sh [--release]     (default: --debug)
#
# Remember to bump `version: X.Y.Z+N` in pubspec.yaml when handing a new apk to
# the phone. X.Y.Z moves on the APP's OWN semver track — deliberately NOT tied to
# the Nexus Q image releases; app changes are tracked separately. Always increase
# +N (Android refuses to install a lower versionCode over a higher one).
set -eu

cd "$(dirname "$0")"

MODE="${1:---debug}"
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

echo "Building companion app v$APP_VERSION (build $BUILD_TAG) $MODE"
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

# The signing key every installed app trusts lives in 1Password ("nexusQ
# companion Android signing key": the keystore as a Document, alias and
# passwords as fields). It is fetched to a private temp file for this build and
# removed after; android/app/build.gradle.kts signs with it. A caller may pass
# NQ_ANDROID_KEYSTORE & co. itself (a machine where op cannot sign in).
KEY_ITEM="${NQ_ANDROID_KEY_ITEM:-nexusQ companion Android signing key}"
KEYFILE=""
cleanup() { if [ -n "$KEYFILE" ]; then rm -f "$KEYFILE"; fi; }
trap cleanup EXIT INT TERM
if [ -z "${NQ_ANDROID_KEYSTORE:-}" ] && command -v op >/dev/null 2>&1; then
	KEYFILE=$(mktemp "${TMPDIR:-/tmp}/nq-android-key.XXXXXX")
	chmod 600 "$KEYFILE"
	if op document get "$KEY_ITEM" --account my --out-file "$KEYFILE" --force >/dev/null 2>&1; then
		NQ_ANDROID_KEYSTORE="$KEYFILE"
		NQ_ANDROID_KEYSTORE_PASSWORD=$(op item get "$KEY_ITEM" --account my --fields "label=store password" --reveal)
		NQ_ANDROID_KEY_ALIAS=$(op item get "$KEY_ITEM" --account my --fields "label=key alias")
		NQ_ANDROID_KEY_PASSWORD=$(op item get "$KEY_ITEM" --account my --fields "label=key password" --reveal)
		export NQ_ANDROID_KEYSTORE NQ_ANDROID_KEYSTORE_PASSWORD NQ_ANDROID_KEY_ALIAS NQ_ANDROID_KEY_PASSWORD
	else
		rm -f "$KEYFILE"
		KEYFILE=""
	fi
fi
if [ -n "${NQ_ANDROID_KEYSTORE:-}" ]; then
	echo "Signing: the app's key (1Password \"$KEY_ITEM\")"
elif [ "$MODE" = "--release" ]; then
	echo "ERROR: no app signing key (1Password \"$KEY_ITEM\" unreadable; is op signed in?)." >&2
	echo "       A release signed with this machine's debug key installs on no phone that" >&2
	echo "       has the app. Refusing." >&2
	exit 1
else
	echo "WARNING: no app signing key -> this debug build is signed with this machine's" >&2
	echo "         debug key and will not install over the phone's app." >&2
fi

flutter build apk "$MODE" \
	--dart-define=APP_VERSION="$APP_VERSION" \
	--dart-define=BUILD_TAG="$BUILD_TAG" \
	--dart-define=SPOTIFY_CLIENT_ID="$SPOTIFY_CLIENT_ID"

case "$MODE" in
	--release) APK=build/app/outputs/flutter-apk/app-release.apk ;;
	*)         APK=build/app/outputs/flutter-apk/app-debug.apk ;;
esac

echo ""
echo "Built: $APK"
echo "  version : $APP_VERSION"
echo "  build   : $BUILD_TAG"
echo ""
echo "Install with:  adb install -r $APK"
