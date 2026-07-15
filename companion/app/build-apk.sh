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

echo "Building companion app v$APP_VERSION (build $BUILD_TAG) $MODE"
flutter build apk "$MODE" \
	--dart-define=APP_VERSION="$APP_VERSION" \
	--dart-define=BUILD_TAG="$BUILD_TAG"

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
