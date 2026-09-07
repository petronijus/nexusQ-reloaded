// Drive Spotify Connect playback ON THE Q through Spotify's Web API.
//
// The Q is one Connect device among the user's others (phone, laptop). The
// app must therefore aim every command at the right device_id, and the only
// handle it has is the NAME librespot advertises — which is the Q's own name
// from /etc/nexusq/device.json (librespot-nexusq reads the same file the bridge
// does), i.e. exactly what the app shows under the sphere. So: list devices,
// match by name, command that id. The matcher is a pure function; the
// wire-level calls sit behind it.
//
// Web API semantics that matter here (measured against the docs, 2026-09):
//   PUT  /v1/me/player/play?device_id=…      resumes (204)
//   PUT  /v1/me/player/pause?device_id=…     pauses  (204)
//   POST /v1/me/player/next|previous?device_id=…  (204)
//   PUT  /v1/me/player  {device_ids:[id], play:true}  transfers playback
//   404 NO_ACTIVE_DEVICE when nothing is playing anywhere → transfer first
//   403 PREMIUM_REQUIRED — playback control is a Premium feature, full stop
//   401 — token expired/revoked → SpotifyLink refreshes, one retry
//   GET  /v1/me/player/queue   what is playing AND what follows, in ONE call —
//        which is why the app reads now-playing from here rather than adding a
//        second request to /currently-playing. 204 + empty body when nothing is
//        playing anywhere. Needs only `user-read-playback-state`, already among
//        the scopes the link asks for, so nobody has to re-consent for this.
import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../debug/app_log.dart';
import 'spotify_auth.dart';

class SpotifyDevice {
  const SpotifyDevice({required this.id, required this.name, required this.type, this.isActive = false});
  final String id, name, type;
  final bool isActive;

  factory SpotifyDevice.fromJson(Map<String, dynamic> j) => SpotifyDevice(
        id: j['id'] as String? ?? '',
        name: j['name'] as String? ?? '',
        type: j['type'] as String? ?? '',
        isActive: j['is_active'] == true,
      );
}

String _fold(String s) => s.trim().toLowerCase().replaceAll(RegExp(r'\s+'), ' ');

/// Which of the user's Connect devices is THIS Q. Exact name match first
/// (case and whitespace folded — Spotify returns the name as librespot sent
/// it, but users type names), then the only Speaker whose name contains the
/// Q's, and nothing otherwise: guessing would send play/pause to somebody's
/// laptop.
SpotifyDevice? matchQDevice(List<SpotifyDevice> devices, String qName) {
  final want = _fold(qName);
  if (want.isEmpty) return null;
  for (final d in devices) {
    if (_fold(d.name) == want) return d;
  }
  final speakers = devices
      .where((d) => d.type.toLowerCase() == 'speaker' && _fold(d.name).contains(want))
      .toList();
  return speakers.length == 1 ? speakers.first : null;
}

/// A track as the player endpoints describe it. Episodes come back through the
/// same fields (Spotify calls them `show`/`episode`), so a podcast still shows
/// a title and something in place of the artist rather than a blank row.
class SpotifyTrack {
  const SpotifyTrack({
    required this.title,
    this.artist = '',
    this.album = '',
    this.artUrl = '',
    this.durationMs = 0,
  });

  final String title, artist, album, artUrl;
  final int durationMs;

  /// Spotify orders `album.images` largest first (typically 640/300/64). The
  /// app draws a thumbnail, so take the SMALLEST image that is still big
  /// enough to look right on a phone — downloading 640 px to paint 56 is a
  /// waste of the Q owner's data and of the widget's time.
  static String _art(List images) {
    Map? best;
    for (final i in images) {
      if (i is! Map) continue;
      final h = (i['height'] as num?)?.toInt() ?? 0;
      if (h >= 160 && (best == null || h < ((best['height'] as num?)?.toInt() ?? 1 << 30))) {
        best = i;
      }
    }
    best ??= images.isNotEmpty && images.first is Map ? images.first as Map : null;
    return best?['url'] as String? ?? '';
  }

  factory SpotifyTrack.fromJson(Map<String, dynamic> j) {
    final artists = [
      for (final a in (j['artists'] as List? ?? const []))
        if (a is Map && a['name'] is String) a['name'] as String,
    ];
    final album = j['album'];
    final show = j['show'];
    return SpotifyTrack(
      title: j['name'] as String? ?? '',
      // An episode has no artists; its show is the closest thing to one.
      artist: artists.isNotEmpty
          ? artists.join(', ')
          : (show is Map ? show['name'] as String? ?? '' : ''),
      album: album is Map ? album['name'] as String? ?? '' : '',
      artUrl: album is Map
          ? _art(album['images'] as List? ?? const [])
          : (show is Map ? _art(show['images'] as List? ?? const []) : ''),
      durationMs: (j['duration_ms'] as num?)?.toInt() ?? 0,
    );
  }
}

/// Where the current track has got to. Spotify's queue endpoint does not carry
/// a position, so this is a second (cheap) call — and it is sampled, not
/// streamed: the app interpolates from [sampledAt] rather than asking again
/// every second, which no rate limit would survive.
class SpotifyProgress {
  SpotifyProgress({
    required this.positionMs,
    required this.durationMs,
    required this.playing,
    DateTime? sampledAt,
  }) : sampledAt = sampledAt ?? DateTime.now();

  final int positionMs, durationMs;
  final bool playing;
  final DateTime sampledAt;

  /// Where the track is NOW: the sample plus the wall clock since, while
  /// playing. Clamped to the track — a stale sample must never draw a bar past
  /// its end, and a paused track must not creep.
  Duration positionAt(DateTime now) {
    final base = Duration(milliseconds: positionMs);
    if (!playing) return base;
    final p = base + now.difference(sampledAt);
    final d = Duration(milliseconds: durationMs);
    return durationMs > 0 && p > d ? d : p;
  }

  /// 0..1, or null when the length is unknown (a live stream, an oddity) —
  /// which the bar draws as nothing rather than as "at the start".
  double? fractionAt(DateTime now) =>
      durationMs <= 0 ? null : (positionAt(now).inMilliseconds / durationMs).clamp(0.0, 1.0);
}

/// What Spotify is playing and what follows it.
class SpotifyQueue {
  const SpotifyQueue({this.current, this.upNext = const []});
  final SpotifyTrack? current;
  final List<SpotifyTrack> upNext;

  bool get isEmpty => current == null && upNext.isEmpty;

  /// `queue` is unbounded in the docs and long in practice; the screen shows a
  /// few. Parsing everything and trimming here keeps the widget dumb.
  factory SpotifyQueue.fromJson(Map<String, dynamic> j, {int max = 8}) {
    final cur = j['currently_playing'];
    final list = <SpotifyTrack>[];
    for (final t in (j['queue'] as List? ?? const [])) {
      if (t is Map) list.add(SpotifyTrack.fromJson(Map<String, dynamic>.from(t)));
      if (list.length >= max) break;
    }
    return SpotifyQueue(
      current: cur is Map ? SpotifyTrack.fromJson(Map<String, dynamic>.from(cur)) : null,
      upNext: list,
    );
  }
}

class SpotifyPlayerException implements Exception {
  SpotifyPlayerException(this.message);
  final String message;
  @override
  String toString() => 'SpotifyPlayerException: $message';
}

class SpotifyPlayer {
  SpotifyPlayer(this.link, {http.Client? httpClient}) : _http = httpClient ?? http.Client();
  final SpotifyLink link;
  final http.Client _http;

  static const _base = 'https://api.spotify.com/v1';

  Future<List<SpotifyDevice>> devices() async {
    final res = await _call('GET', '/me/player/devices');
    final j = jsonDecode(res.body) as Map<String, dynamic>;
    return [
      for (final d in (j['devices'] as List? ?? const []))
        if (d is Map) SpotifyDevice.fromJson(Map<String, dynamic>.from(d)),
    ];
  }

  /// Resolve the Q by name or explain why not.
  Future<SpotifyDevice> qDevice(String qName) async {
    final list = await devices();
    final d = matchQDevice(list, qName);
    if (d == null) {
      if (list.isEmpty) {
        throw SpotifyPlayerException(
            'Spotify lists no devices for this account. Start playing something to "$qName" from the Spotify app once, then try again.');
      }
      throw SpotifyPlayerException(
          '"$qName" is not among this account\'s Spotify devices (${list.map((d) => d.name).join(', ')}).');
    }
    return d;
  }

  /// Play or pause on the Q. When nothing is active anywhere Spotify answers
  /// 404 NO_ACTIVE_DEVICE; transferring playback to the Q first is what the
  /// Spotify app itself does in that case.
  Future<void> setPlaying(String qName, bool playing) async {
    final d = await qDevice(qName);
    final path = playing ? '/me/player/play' : '/me/player/pause';
    try {
      await _call('PUT', '$path?device_id=${Uri.encodeQueryComponent(d.id)}');
    } on _NoActiveDevice {
      if (!playing) return; // nothing to pause
      await _call('PUT', '/me/player', body: {'device_ids': [d.id], 'play': true});
    }
  }

  Future<void> next(String qName) async {
    final d = await qDevice(qName);
    await _call('POST', '/me/player/next?device_id=${Uri.encodeQueryComponent(d.id)}');
  }

  Future<void> previous(String qName) async {
    final d = await qDevice(qName);
    await _call('POST', '/me/player/previous?device_id=${Uri.encodeQueryComponent(d.id)}');
  }

  /// What is playing and what comes next. Deliberately NOT aimed at a
  /// device_id: the queue belongs to the account, and asking for the Q's id
  /// would fail whenever playback sits on the phone — where the user can still
  /// see, correctly, what their Q is about to play. Returns an empty queue
  /// rather than throwing when Spotify says 204 (nothing playing anywhere).
  Future<SpotifyQueue> queue() async {
    final res = await _call('GET', '/me/player/queue');
    if (res.statusCode == 204 || res.body.trim().isEmpty) return const SpotifyQueue();
    final j = jsonDecode(res.body);
    if (j is! Map) return const SpotifyQueue();
    return SpotifyQueue.fromJson(Map<String, dynamic>.from(j));
  }

  /// Position within the current track. `/me/player` answers 204 with no body
  /// when nothing is playing anywhere, which is not an error — it is the same
  /// "nothing loaded" the queue reports, so it comes back as null.
  Future<SpotifyProgress?> progress() async {
    final res = await _call('GET', '/me/player');
    if (res.statusCode == 204 || res.body.trim().isEmpty) return null;
    final j = jsonDecode(res.body);
    if (j is! Map) return null;
    final item = j['item'];
    return SpotifyProgress(
      positionMs: (j['progress_ms'] as num?)?.toInt() ?? 0,
      durationMs: item is Map ? (item['duration_ms'] as num?)?.toInt() ?? 0 : 0,
      playing: j['is_playing'] == true,
    );
  }

  Future<http.Response> _call(String method, String path, {Object? body, bool retried = false}) async {
    final token = await link.accessToken();
    final uri = Uri.parse('$_base$path');
    final headers = {'Authorization': 'Bearer $token', 'Content-Type': 'application/json'};
    final http.Response res;
    try {
      final req = http.Request(method, uri)..headers.addAll(headers);
      if (body != null) req.body = jsonEncode(body);
      res = await http.Response.fromStream(await _http.send(req)).timeout(const Duration(seconds: 12));
    } catch (e) {
      throw SpotifyPlayerException('Spotify did not answer: $e');
    }
    if (res.statusCode == 200 || res.statusCode == 202 || res.statusCode == 204) return res;
    if (res.statusCode == 401 && !retried) {
      // Expired between our check and their clock; SpotifyLink refreshes on the
      // next accessToken() because the stored expiry is now in the past.
      await link.invalidateAccessToken();
      return _call(method, path, body: body, retried: true);
    }
    String reason = '';
    try {
      final j = jsonDecode(res.body);
      if (j is Map && j['error'] is Map) {
        reason = (j['error']['reason'] ?? j['error']['message'] ?? '').toString();
      }
    } catch (_) {}
    AppLog.add('spotify', '$method $path -> ${res.statusCode} $reason');
    if (res.statusCode == 404 && (reason == 'NO_ACTIVE_DEVICE' || reason.isEmpty)) {
      throw _NoActiveDevice();
    }
    if (res.statusCode == 403 && reason == 'PREMIUM_REQUIRED') {
      throw SpotifyPlayerException('Spotify Premium is required to control playback.');
    }
    if (res.statusCode == 429) {
      throw SpotifyPlayerException('Spotify is rate-limiting; try again in a moment.');
    }
    throw SpotifyPlayerException(
        'Spotify refused ($method ${uri.path}): HTTP ${res.statusCode}${reason.isEmpty ? '' : ' $reason'}');
  }
}

class _NoActiveDevice implements Exception {}

@visibleForTesting
Exception noActiveDeviceForTest() => _NoActiveDevice();
