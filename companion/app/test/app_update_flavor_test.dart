// Only the `github` build updates itself. An app from Google Play or F-Droid
// may not install packages by any other route than its store (Play's policy,
// F-Droid's inclusion rules); the play/fdroid flavors also carry no
// REQUEST_INSTALL_PACKAGES (android/app/src/github/AndroidManifest.xml).
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexusq_companion/update/app_update.dart';

void main() {
  tearDown(() {
    AppUpdate.flavorOverride = null;
    debugDefaultTargetPlatformOverride = null;
  });

  test('only the github build on Android updates itself', () {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    for (final (flavor, expected) in [
      ('github', true),
      ('play', false),
      ('fdroid', false),
    ]) {
      AppUpdate.flavorOverride = flavor;
      expect(AppUpdate.selfUpdateSupported, expected, reason: flavor);
    }
  });

  test('iOS never does, whatever the flavor', () {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    AppUpdate.flavorOverride = 'github';
    expect(AppUpdate.selfUpdateSupported, isFalse);
  });
}
