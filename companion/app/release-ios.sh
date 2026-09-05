#!/bin/sh
# Build the Nexus Q companion IPA with the same HONEST build identity as
# build-apk.sh, and ship it to TestFlight.
#
# Every app release is BOTH platforms (Petr, 2026-09-05): the Android apk goes to
# the `app-vX.Y.Z` GitHub release + `../app-release.json`, and the iOS build goes
# to App Store Connect from this Mac in the same session. One version, two
# uploads; neither is optional.
#
# What this does, in order:
#   1. reads `version: X.Y.Z+N` from pubspec.yaml (the ONLY place the version
#      lives) and injects APP_VERSION / BUILD_TAG exactly like build-apk.sh, so
#      the label on the connect gate cannot drift from CFBundleShortVersionString;
#   2. `flutter build ipa --release` against ios/ExportOptions.plist (manual
#      signing, team ASFPR2T2DQ, profile "NexusQ Companion Distribution");
#   3. uploads with `xcrun altool --upload-app` using the team's App Store Connect
#      API key from 1Password. The .p8 is staged as ~/.private_keys/AuthKey_<id>.p8
#      (0600) only for the duration of the upload and removed afterwards, never
#      echoed. ⚠️ The Apple-ID + app-specific-password route does NOT work for
#      this account (altool -20101, measured 2026-09-05); the API key does.
#
# Prerequisites on the Mac (one-time; HANDOFF.md "iOS / TestFlight"):
#   * the "Apple Distribution: Petr Parkan Janda" identity in the login keychain
#   * profile TY847W7VDT installed (fetched over the ASC API; see HANDOFF)
#   * `flutter config --no-enable-swift-package-manager` (CocoaPods-only project)
#   * `op` signed in; 1Password item "Kulturni prehled ASC API Key" (team-scoped)
#
# Usage:  ./release-ios.sh [--no-upload]
#   --no-upload   build + sign only (verify a change compiles and signs)
#
# TestFlight side: the internal group "Internal" has access to all builds, and
# ITSAppUsesNonExemptEncryption=false is in Info.plist, so a processed build
# needs no clicking — it shows up in TestFlight in 5–15 min.
set -eu

cd "$(dirname "$0")"

UPLOAD=1
[ "${1:-}" = "--no-upload" ] && UPLOAD=0

APP_VERSION=$(sed -n 's/^version:[[:space:]]*//p' pubspec.yaml | head -1)
BUILD_TAG=$(date +%m%d-%H%M)
[ -n "$APP_VERSION" ] || { echo "ERROR: no 'version:' in pubspec.yaml" >&2; exit 1; }
case "$APP_VERSION" in
	*+*) ;;
	*)
		echo "ERROR: version '$APP_VERSION' has no '+N' build number — it is CFBundleVersion here" >&2
		echo "       and Android's versionCode there; pubspec.yaml must read 'version: X.Y.Z+N'." >&2
		exit 1
		;;
esac

# Fail early on the signing prerequisites, with the fix in the message.
security find-identity -v -p codesigning 2>/dev/null | grep -q "Apple Distribution: Petr Parkan Janda" \
	|| { echo "ERROR: no 'Apple Distribution: Petr Parkan Janda' identity in the keychain — see HANDOFF.md 'iOS / TestFlight'" >&2; exit 1; }
PROFILE_NAME=$(sed -n 's/.*<string>\(NexusQ Companion Distribution\)<\/string>.*/\1/p' ios/ExportOptions.plist | head -1)
found=0
for d in "$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles" "$HOME/Library/MobileDevice/Provisioning Profiles"; do
	for f in "$d"/*.mobileprovision; do
		[ -f "$f" ] || continue
		if security cms -D -i "$f" 2>/dev/null | grep -q "<string>$PROFILE_NAME</string>"; then found=1; fi
	done
done
[ "$found" = 1 ] || { echo "ERROR: provisioning profile '$PROFILE_NAME' is not installed — fetch it over the ASC API (HANDOFF.md 'iOS / TestFlight')" >&2; exit 1; }

echo "Building companion app v$APP_VERSION (build $BUILD_TAG) for iOS (release, app-store export)"
flutter build ipa --release \
	--export-options-plist=ios/ExportOptions.plist \
	--dart-define=APP_VERSION="$APP_VERSION" \
	--dart-define=BUILD_TAG="$BUILD_TAG"

IPA=$(ls build/ios/ipa/*.ipa | head -1)
[ -f "$IPA" ] || { echo "ERROR: no .ipa under build/ios/ipa" >&2; exit 1; }
echo ""
echo "Built: $IPA"
echo "  version : $APP_VERSION"
echo "  build   : $BUILD_TAG"
# The .ipa is a zip; xcodebuild records the signing identity next to it.
echo "  signed  : $(python3 - build/ios/ipa/DistributionSummary.plist <<'PY'
import plistlib, sys
d = plistlib.load(open(sys.argv[1], "rb"))
e = next(iter(d.values()))[0]
c = e.get("certificate", {}); t = e.get("team", {})
print("%s %s, team %s, CFBundleVersion %s" % (c.get("type", "?"), c.get("SHA1", "")[:8], t.get("id", "?"), e.get("buildNumber", "?")))
PY
)"

# pod install may have refreshed the lock; a release commits what it built with.
if git -C . status --porcelain ios/Podfile.lock 2>/dev/null | grep -q .; then
	echo "  note    : ios/Podfile.lock changed — commit it with the release"
fi

[ "$UPLOAD" = 1 ] || { echo ""; echo "--no-upload: stopping after the build."; exit 0; }

command -v op >/dev/null || { echo "ERROR: 1Password CLI (op) not found" >&2; exit 1; }
ITEM="${NQ_ASC_KEY_ITEM:-Kulturni prehled ASC API Key}"
KEY_ID=$(op item get "$ITEM" --account my --fields label=key_id 2>/dev/null | tr -d '"')
ISSUER=$(op item get "$ITEM" --account my --fields label=issuer_id 2>/dev/null | tr -d '"')
[ -n "$KEY_ID" ] && [ -n "$ISSUER" ] || { echo "ERROR: could not read key_id/issuer_id from 1Password item '$ITEM'" >&2; exit 1; }

KEYDIR="$HOME/.private_keys"
KEYFILE="$KEYDIR/AuthKey_$KEY_ID.p8"
mkdir -p "$KEYDIR" && chmod 700 "$KEYDIR"
trap 'rm -f "$KEYFILE"' EXIT INT TERM
umask 077
op item get "$ITEM" --account my --fields label=private_key --reveal 2>/dev/null | sed 's/^"//;s/"$//' > "$KEYFILE"
grep -q "BEGIN PRIVATE KEY" "$KEYFILE" || { echo "ERROR: the private_key field of '$ITEM' is not a PEM key" >&2; exit 1; }

echo ""
echo "Uploading to App Store Connect (API key $KEY_ID) ..."
xcrun altool --upload-app -f "$IPA" -t ios --apiKey "$KEY_ID" --apiIssuer "$ISSUER" 2>&1 \
	| grep -v '^$' | grep -iv 'running altool'
echo ""
echo "Uploaded v$APP_VERSION. App Store Connect processes it in ~5–15 min, then it is in"
echo "TestFlight for the 'Internal' group. Check with the ASC API or the TestFlight app."
