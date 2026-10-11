#!/bin/sh
# Fail when a built APK or app bundle asks for a permission the app must not
# carry. Plugins declare permissions of their own and the manifest merger adds
# them silently: open_filex brought storage and photo/video/audio access, which
# Google Play refuses without a declared core use (2026-10-11, release 68).
# The app's manifest removes them (tools:node="remove"); this gate keeps a
# plugin update from bringing them back unnoticed. build-apk.sh runs it on
# every release.
#
# Usage: tool/check-permissions.sh <app.apk | app.aab>
set -eu

FORBIDDEN='READ_EXTERNAL_STORAGE|WRITE_EXTERNAL_STORAGE|MANAGE_EXTERNAL_STORAGE|READ_MEDIA_IMAGES|READ_MEDIA_VIDEO|READ_MEDIA_AUDIO|READ_MEDIA_VISUAL_USER_SELECTED|ACCESS_BACKGROUND_LOCATION|com\.google\.android\.gms\.permission\.AD_ID'

[ $# -eq 1 ] && [ -f "$1" ] || {
	echo "usage: $0 <app.apk | app.aab>" >&2
	exit 2
}
case "$1" in
	*.aab) ENTRY=base/manifest/AndroidManifest.xml ;;
	*.apk) ENTRY=AndroidManifest.xml ;;
	*)
		echo "ERROR: $1 is neither an .apk nor an .aab" >&2
		exit 2
		;;
esac

# The bundle's manifest is a protobuf, the APK's binary XML; both keep the
# permission names as plain strings, in UTF-8 or UTF-16LE.
FOUND=$({
	unzip -p "$1" "$ENTRY" | strings -a
	unzip -p "$1" "$ENTRY" | strings -a -e l
} | grep -oE "permission\.($FORBIDDEN)|gms\.permission\.AD_ID" | sort -u || true)

if [ -n "$FOUND" ]; then
	echo "ERROR: $1 asks for permissions the app must not carry:" >&2
	echo "$FOUND" | sed 's/^/  /' >&2
	echo "       Remove them in android/app/src/main/AndroidManifest.xml (tools:node=\"remove\")." >&2
	exit 1
fi
echo "Permissions: none of the forbidden ones"
