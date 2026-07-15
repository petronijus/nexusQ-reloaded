/// Build identity, shown in the UI so the installed build is readable off the
/// phone without adb.
///
/// [kAppVersion] is the REAL app version and its single source of truth is
/// `pubspec.yaml` (`version:`), which is also what Gradle turns into Android's
/// versionName/versionCode. It is passed in at compile time rather than parsed
/// at runtime so the app pulls in no extra plugin just to read its own version.
///
/// NB the app's version is INDEPENDENT of the Nexus Q image releases (v1.9.0,
/// ...) — app changes are tracked separately. Do not "sync" the two.
///
/// [kBuildTag] distinguishes builds made from the same version on the same day —
/// it AUGMENTS the version, it never replaces it (the app sat at "1.0.0" for
/// dozens of builds while only this stamp moved, which is exactly the confusion
/// this file now exists to prevent).
///
/// Build with the helper so both stay in sync with pubspec:
///   companion/app/build-apk.sh
/// or by hand:
///   flutter build apk --debug \
///     --dart-define=APP_VERSION=$(grep '^version:' pubspec.yaml | cut -d' ' -f2) \
///     --dart-define=BUILD_TAG=$(date +%m%d-%H%M)
const String kAppVersion = String.fromEnvironment('APP_VERSION', defaultValue: 'dev');
const String kBuildTag = String.fromEnvironment('BUILD_TAG', defaultValue: 'dev');

/// One-line identity for the UI, e.g. "v1.9.0+2 · build 0715-1706".
const String kBuildLabel = 'v$kAppVersion · build $kBuildTag';
