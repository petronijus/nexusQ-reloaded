// The update check compares this build's `+N` against the manifest's. The
// interesting case is the one that shipped: an apk built WITHOUT
// `--dart-define=APP_VERSION` leaves kAppVersion at its 'dev' default, so the
// app cannot place itself at all.
//
// That used to read as versionCode 0 — not "unknown" but "older than
// everything" — so every published manifest looked newer. The app offered an
// update to the build it was already running, installed it, and offered it
// again. Both 1.17.1 and 1.17.2 were cut that way and the loop was unbreakable
// from the phone (2026-08-30: "App update available — App v1.17.2" on an
// installed 1.17.2+49, with "vdev · build dev" at the foot of the screen).
//
// These tests pin the distinction: unknown must be null, and null must never be
// treated as old.
import 'package:flutter_test/flutter_test.dart';

/// Mirror of AppUpdate.currentVersionCode, parameterised over the version
/// string. The real getter reads the compile-time const kAppVersion, which a
/// test cannot vary — so the PARSING RULE is what is pinned here, and
/// app_update.dart must keep using this shape.
int? versionCodeOf(String appVersion) {
  final plus = appVersion.indexOf('+');
  if (plus < 0) return null;
  return int.tryParse(appVersion.substring(plus + 1));
}

/// Mirror of the decision made by checkForUpdate() / the settings screen.
bool offersUpdate({required String appVersion, required int manifestCode}) {
  final mine = versionCodeOf(appVersion);
  if (mine == null) return false; // unknown: never offer
  return manifestCode > mine;
}

void main() {
  group('currentVersionCode parsing', () {
    test('reads the +N build number', () {
      expect(versionCodeOf('1.17.2+49'), 49);
      expect(versionCodeOf('1.8.0+17'), 17);
    });

    test('an unstamped build is null, NOT zero', () {
      // The whole bug in one line: 'dev' has no '+', and 0 would mean "older
      // than every release that will ever be published".
      expect(versionCodeOf('dev'), isNull);
      expect(versionCodeOf('dev'), isNot(0));
    });

    test('a version with no build number is null', () {
      expect(versionCodeOf('1.17.2'), isNull);
    });

    test('a non-numeric build number is null rather than 0', () {
      expect(versionCodeOf('1.17.2+beta'), isNull);
    });
  });

  group('update offer', () {
    test('offers a genuinely newer release', () {
      expect(offersUpdate(appVersion: '1.17.2+49', manifestCode: 50), isTrue);
    });

    test('does not offer the version already installed', () {
      expect(offersUpdate(appVersion: '1.17.2+49', manifestCode: 49), isFalse);
    });

    test('does not offer an older release', () {
      expect(offersUpdate(appVersion: '1.17.3+50', manifestCode: 49), isFalse);
    });

    test('an unstamped build offers NOTHING — the endless-loop regression', () {
      // Before the fix every one of these was true.
      for (final code in [1, 49, 50, 9999]) {
        expect(offersUpdate(appVersion: 'dev', manifestCode: code), isFalse,
            reason: 'a build that does not know its version must not offer $code');
      }
    });
  });
}
