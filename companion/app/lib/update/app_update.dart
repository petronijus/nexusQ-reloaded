import 'dart:async';
import 'dart:convert';
import 'dart:io';

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

  /// Raw manifest on the default branch — no API token, no rate limit that
  /// matters for an occasional check.
  static const manifestUrl =
      'https://raw.githubusercontent.com/petronijus/nexusQ-reloaded/main/companion/app-release.json';

  /// This build's Android versionCode = the `+N` in kAppVersion ("1.8.0+17").
  static int get currentVersionCode {
    final plus = kAppVersion.indexOf('+');
    if (plus < 0) return 0;
    return int.tryParse(kAppVersion.substring(plus + 1)) ?? 0;
  }

  /// Fetch the manifest. Returns the release, or null on any failure (offline,
  /// malformed) — an update check must never throw into the UI.
  static Future<AppRelease?> fetchLatest() async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 10);
    try {
      final req = await client.getUrl(Uri.parse(manifestUrl));
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
    if (rel.versionCode <= currentVersionCode) {
      AppLog.add('update',
          'up to date (installed $currentVersionCode, latest ${rel.versionCode})');
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
      await for (final chunk in resp) {
        received += chunk.length;
        sink.add(chunk);
        onProgress(total > 0 ? received / total : null, received);
      }
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
