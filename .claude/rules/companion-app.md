---
paths:
  - "companion/**"
---
# Companion app

- `version:` in `pubspec.yaml` is the app's own semver track, independent of
  the image releases; bump `X.Y.Z+N` for every APK handed to a phone (`+N` is
  the Android versionCode and what the in-app update check compares).
- Build a phone APK with `companion/app/build-apk.sh` (it injects the version
  and the Spotify client id); iOS goes to TestFlight via the
  nexusq-ios-release agent.
- Formatting is `dart format` through `tools/dev/format.sh` (tall style, since
  2026-09-29); `flutter analyze --fatal-infos` must stay clean.
- The Android package id `org.nexusq.nexusq_companion` is the installed app's
  identity; never rename it.
