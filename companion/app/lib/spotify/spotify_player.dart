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
