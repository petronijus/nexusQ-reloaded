import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path_provider/path_provider.dart';

import '../build_info.dart';
import '../debug/app_log.dart';

/// One available companion-app release, parsed from `companion/app-release.json`
/// (see that file). The app compares [versionCode] against its own build number.
class AppRelease {
  AppRelease({
    required this.version,
    required this.versionCode,
    required this.apkUrl,
    required this.notes,
  });

  final String version; // display name, e.g. "1.8.0"
  final int versionCode; // Android versionCode = the +N build number
  final String apkUrl;
  final String notes;

  static AppRelease? fromJson(Map<String, dynamic> j) {
    final vc = j['versionCode'];
    final url = j['apkUrl'];
    if (vc is! int || url is! String || url.isEmpty) return null;
    return AppRelease(
      version: (j['version'] as String?) ?? '?',
      versionCode: vc,
      apkUrl: url,
      notes: (j['notes'] as String?) ?? '',
    );
  }
}

/// Over-the-air updates for the companion apk itself: fetch the manifest from
/// GitHub, tell whether it is newer than what is installed, download it, and
/// hand it to the Android package installer. Kept dependency-light — the fetch
/// and download use dart:io's HttpClient directly; only the final "open the apk
/// so the OS installer takes over" needs a plugin (open_filex).
///
/// The apk is versioned on its OWN track (see build_info.dart / pubspec), so the
/// manifest lives next to the app source, NOT in the Nexus Q image releases.
class AppUpdate {
  AppUpdate._();

  /// The whole self-update mechanism is an apk hand-off to the Android package
  /// installer — no other OS lets an app replace itself. On iOS the binary
  /// comes from the outside (Xcode/TestFlight), so the app-track is skipped
  /// there and the merged "App update" card carries only the device daemons.
  static bool get selfUpdateSupported =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  /// Raw manifest on the default branch — no API token, no rate limit that
  /// matters for an occasional check.
  static const manifestUrl =
      'https://raw.githubusercontent.com/petronijus/nexusQ-reloaded/main/companion/app-release.json';

  /// This build's Android versionCode = the `+N` in kAppVersion ("1.8.0+17"),
  /// or **null when this build does not know its own version**.
  ///
  /// [kAppVersion] comes from `--dart-define=APP_VERSION`, which `build-apk.sh`
  /// fills from pubspec — but a plain `flutter build apk` leaves it at its
  /// `'dev'` default, and both published 1.17.1 and 1.17.2 apks were cut that
  /// way. This used to return **0** for that case, which does not mean "unknown",
  /// it means "older than everything": the manifest's versionCode was forever
  /// greater, so the app offered an update to the very build it was already
  /// running, installed it, and offered it again — an endless loop that no
  /// amount of updating could clear (2026-08-30, seen on the phone as
  /// "App update available — App v1.17.2" on an installed 1.17.2+49).
  ///
  /// Not knowing your version is not the same as being out of date. Unknown now
  /// suppresses the update offer instead of guaranteeing it: the worst case is a
  /// hand-built apk that never nags, rather than one that nags forever.
  static int? get currentVersionCode {
    final plus = kAppVersion.indexOf('+');
    if (plus < 0) return null;
    return int.tryParse(kAppVersion.substring(plus + 1));
  }

  /// True when this build can be compared against the manifest at all.
  static bool get knowsOwnVersion => currentVersionCode != null;

  /// Fetch the manifest. Returns the release, or null on any failure (offline,
  /// malformed) — an update check must never throw into the UI.
  static Future<AppRelease?> fetchLatest() async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 10);
    try {
      // Cache-bust: raw.githubusercontent is fronted by Fastly with max-age=300,
      // so a freshly-pushed manifest can read as stale for up to 5 min — which
      // made a just-published release show as "up to date". A per-request query
      // param is a distinct cache key, and we also ask upstream not to serve a
      // cached copy. An update CHECK must always see the real latest.
      final bust = DateTime.now().millisecondsSinceEpoch;
      final req = await client.getUrl(Uri.parse('$manifestUrl?t=$bust'));
      req.headers.set(HttpHeaders.cacheControlHeader, 'no-cache');
      req.headers.set(HttpHeaders.pragmaHeader, 'no-cache');
      final resp = await req.close().timeout(const Duration(seconds: 15));
      if (resp.statusCode != 200) {
        AppLog.add('update', 'manifest HTTP ${resp.statusCode}', warn: true);
        return null;
      }
      final body = await resp.transform(utf8.decoder).join();
      final rel = AppRelease.fromJson(jsonDecode(body) as Map<String, dynamic>);
      if (rel == null) AppLog.add('update', 'manifest malformed', warn: true);
      return rel;
    } catch (e) {
      AppLog.add('update', 'manifest fetch failed: $e', warn: true);
      return null;
    } finally {
      client.close(force: true);
    }
  }

  /// The newer release if one is available, else null (up to date / offline).
  static Future<AppRelease?> checkForUpdate() async {
    final rel = await fetchLatest();
    if (rel == null) return null;
    final mine = currentVersionCode;
    if (mine == null) {
      AppLog.add('update',
          'build does not know its own version (APP_VERSION="$kAppVersion") — '
          'not offering ${rel.versionCode}; build with build-apk.sh');
      return null;
    }
    if (rel.versionCode <= mine) {
      AppLog.add(
          'update', 'up to date (installed $mine, latest ${rel.versionCode})');
      return null;
    }
    AppLog.add('update',
        'update available: v${rel.version} (${rel.versionCode} > $currentVersionCode)');
    return rel;
  }

  /// Download the apk to app storage, reporting progress. The callback gets
  /// `(fraction, receivedBytes)` — `fraction` is 0..1 when the server sent a
  /// Content-Length, or `null` when it did NOT (GitHub release assets 302-redirect
  /// to objects.githubusercontent.com and the final response often omits the
  /// length, which is why the bar used to sit at 0 %). `receivedBytes` is always
  /// live, so the UI can show an indeterminate bar with a running MB counter.
  /// Returns the file path, or throws on failure (the caller shows the error).
  static Future<String> downloadApk(
      AppRelease rel, void Function(double? fraction, int received) onProgress) async {
    final dir = await getTemporaryDirectory();
    final file = File('${dir.path}/nexusq-companion-${rel.version}.apk');
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 15);
    try {
      final req = await client.getUrl(Uri.parse(rel.apkUrl));
      req.followRedirects = true; // github.com -> objects.githubusercontent.com
      final resp = await req.close();
      if (resp.statusCode != 200) {
        throw HttpException('download HTTP ${resp.statusCode}');
      }
      final total = resp.contentLength; // -1 when unknown (redirected asset)
      AppLog.add('update', 'download start: contentLength=$total');
      var received = 0;
      onProgress(total > 0 ? 0.0 : null, 0); // prime the bar (0 % or indeterminate)
      final sink = file.openWrite();
      // THROTTLE: a 54 MB apk arrives in ~10 000 chunks; firing setState on every
      // one pegs the UI thread rebuilding so the bar only ever paints once, at the
      // end (looked like a static full bar). Emit only when the integer percent
      // moves (≤101 updates), or every 256 KB when the length is unknown.
      var lastPct = -1;
      var lastReported = 0;
      await for (final chunk in resp) {
        received += chunk.length;
        sink.add(chunk);
        if (total > 0) {
          final pct = received * 100 ~/ total;
          if (pct != lastPct) {
            lastPct = pct;
            onProgress(received / total, received);
          }
        } else if (received - lastReported >= 262144) {
          lastReported = received;
          onProgress(null, received);
        }
      }
      onProgress(total > 0 ? 1.0 : null, received); // settle at 100 %
      await sink.close();
      AppLog.add('update', 'downloaded ${rel.version} ($received bytes)');
      return file.path;
    } finally {
      client.close(force: true);
    }
  }

  /// Hand the downloaded apk to the OS: Android opens the package installer
  /// (needs REQUEST_INSTALL_PACKAGES). The user confirms; the app is replaced.
  static Future<void> install(String apkPath) async {
    final r = await OpenFilex.open(apkPath, type: 'application/vnd.android.package-archive');
    AppLog.add('update', 'install intent: ${r.type} ${r.message}',
        warn: r.type != ResultType.done);
  }
}
