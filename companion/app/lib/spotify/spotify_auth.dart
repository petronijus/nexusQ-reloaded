// Spotify account link for the companion app — OAuth 2.0 Authorization Code
// with PKCE, no client secret, tokens in the platform keychain.
//
// WHY THIS EXISTS. librespot on the Q is a pure Spotify Connect endpoint with
// no local transport API, by upstream design (issues #457 / #1473). The bridge
// therefore advertises `nowPlaying.transport = "spotify-web"` and the CLIENT
// drives Spotify's own Web API against the Q as a Connect device — see
// PROTOCOL.md §5. This file is the "link a Spotify account" half of that;
// spotify_player.dart is the "send play/pause/next to the Q" half.
//
// The Client ID is a PUBLIC identifier (PKCE has no secret), but it identifies
// Petr's developer app, so it is injected at build time
// (`--dart-define=SPOTIFY_CLIENT_ID=…`, done by build-apk.sh / release-ios.sh
// from 1Password) rather than committed. Without it the feature reports itself
// as not configured instead of failing at Spotify's door.
//
// Pure pieces (verifier, challenge, authorize URL, redirect parsing) are
// top-level functions so tests pin them without a browser or a keychain.
import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart';

import '../debug/app_log.dart';

/// Injected at build time; empty means "not configured" (see file header).
const String kSpotifyClientId =
    String.fromEnvironment('SPOTIFY_CLIENT_ID', defaultValue: '');

/// Registered on the Spotify developer app AND as the app's URL scheme
/// (AndroidManifest intent-filter, iOS CFBundleURLTypes). Custom scheme, not
/// loopback: this is a phone, there is no localhost listener to come back to.
const String kSpotifyRedirectUri = 'nexusq://spotify-callback';

/// The two scopes transport needs, nothing more: read the device list / play
/// state, and change it. No library, no profile beyond `/me` display name.
const String kSpotifyScopes =
    'user-read-playback-state user-modify-playback-state';

const _authorizeEndpoint = 'https://accounts.spotify.com/authorize';
const _tokenEndpoint = 'https://accounts.spotify.com/api/token';

// --- pure PKCE helpers -----------------------------------------------------

/// RFC 7636 §4.1: 43–128 chars from the unreserved set. 64 random bytes,
/// base64url without padding → 86 chars, all within the allowed alphabet.
String pkceVerifier([Random? rng]) {
  final r = rng ?? Random.secure();
  final bytes = List<int>.generate(64, (_) => r.nextInt(256));
  return base64UrlEncode(bytes).replaceAll('=', '');
}

/// RFC 7636 §4.2: BASE64URL(SHA256(ASCII(verifier))), no padding.
String pkceChallenge(String verifier) =>
    base64UrlEncode(sha256.convert(ascii.encode(verifier)).bytes)
        .replaceAll('=', '');

/// The URL the browser is sent to. `state` ties the redirect back to THIS
/// attempt, so a stale or forged callback cannot complete a login.
Uri spotifyAuthorizeUrl({
  required String clientId,
  required String challenge,
  required String state,
  String redirectUri = kSpotifyRedirectUri,
  String scopes = kSpotifyScopes,
}) =>
    Uri.parse(_authorizeEndpoint).replace(queryParameters: {
      'response_type': 'code',
      'client_id': clientId,
      'redirect_uri': redirectUri,
      'scope': scopes,
      'code_challenge_method': 'S256',
      'code_challenge': challenge,
      'state': state,
    });

/// Outcome of parsing the redirect Spotify sends back.
class SpotifyRedirect {
  const SpotifyRedirect._({this.code, this.error});
  final String? code;
  final String? error;
  bool get ok => code != null;
}

/// Accept only OUR callback for OUR pending attempt. Anything else — a
/// different URI, a mismatched state, Spotify's `error=` — is reported, never
/// exchanged. Returns null for URIs that are simply not a Spotify callback.
SpotifyRedirect? parseSpotifyRedirect(Uri uri, {required String expectedState}) {
  final expected = Uri.parse(kSpotifyRedirectUri);
  if (uri.scheme != expected.scheme || uri.host != expected.host) return null;
  final q = uri.queryParameters;
  if (q['state'] != expectedState) {
    return const SpotifyRedirect._(error: 'state mismatch');
  }
  if (q['error'] != null) return SpotifyRedirect._(error: q['error']);
  final code = q['code'];
  if (code == null || code.isEmpty) {
    return const SpotifyRedirect._(error: 'no code');
  }
  return SpotifyRedirect._(code: code);
}

// --- the link itself --------------------------------------------------------

/// Where the tokens live. Keychain / Keystore via flutter_secure_storage —
/// the same store that holds the MQTT broker login, which is why the iOS
/// entitlement carries a keychain access group.
class _Keys {
  static const refresh = 'spotify.refresh_token';
  static const access = 'spotify.access_token';
  static const expiresAt = 'spotify.expires_at_ms';
  static const user = 'spotify.user_display_name';
  static const pendingVerifier = 'spotify.pending_verifier';
  static const pendingState = 'spotify.pending_state';
}

class SpotifyAuthException implements Exception {
  SpotifyAuthException(this.message);
  final String message;
  @override
  String toString() => 'SpotifyAuthException: $message';
}

/// App-wide link state. A [ChangeNotifier] so Settings and the Now Playing
/// controls redraw when the account is linked or unlinked.
class SpotifyLink extends ChangeNotifier {
  SpotifyLink._();
  static final SpotifyLink instance = SpotifyLink._();

  /// Test seam: the real one talks to accounts.spotify.com.
  @visibleForTesting
  http.Client httpClient = http.Client();
  @visibleForTesting
  FlutterSecureStorage store = const FlutterSecureStorage();

  bool _loaded = false;
  bool _linked = false;
  String _user = '';

  /// A Client ID was compiled in. Without one, nothing here can work and the
  /// UI says so instead of opening a browser to a Spotify error page.
  bool get isConfigured => kSpotifyClientId.isNotEmpty;

  /// A refresh token is stored — the account is linked (the access token may
  /// be expired; [accessToken] handles that).
  bool get isLinked => _linked;
  String get userDisplayName => _user;

  /// Read the stored state once; cheap to call repeatedly.
  Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    try {
      _linked = (await store.read(key: _Keys.refresh))?.isNotEmpty ?? false;
      _user = await store.read(key: _Keys.user) ?? '';
    } catch (e) {
      AppLog.add('spotify', 'keychain read failed: $e');
    }
    notifyListeners();
  }

  /// Start the login: remember the verifier + state for THIS attempt, then hand
  /// the user to the browser. The redirect comes back through [handleRedirect].
  Future<void> beginLogin() async {
    if (!isConfigured) {
      throw SpotifyAuthException(
          'Spotify is not configured in this build (no client ID).');
    }
    final verifier = pkceVerifier();
    final state = pkceVerifier().substring(0, 32);
    await store.write(key: _Keys.pendingVerifier, value: verifier);
    await store.write(key: _Keys.pendingState, value: state);
    final url = spotifyAuthorizeUrl(
        clientId: kSpotifyClientId,
        challenge: pkceChallenge(verifier),
        state: state);
    AppLog.add('spotify', 'opening authorize URL');
    if (!await launchUrl(url, mode: LaunchMode.externalApplication)) {
      throw SpotifyAuthException('Could not open the browser for Spotify login.');
    }
  }

  /// Feed every incoming app link here. Returns true when the URI was a Spotify
  /// callback (handled, successfully or not); false when it was something else.
  /// Serialises redirect handling and refuses a repeat of the same URI.
  ///
  /// The redirect arrives by TWO routes — `uriLinkStream` and
  /// `getInitialLink()` — and app_links delivers it on both on some platforms.
  /// Unserialised, the two calls interleave: both read `pendingState`, then one
  /// deletes `pendingVerifier` before the other reads it, so that one throws
  /// "no verifier" while its twin links successfully. The user sees a failure
  /// SnackBar over a login that in fact worked, tries again, and logs in twice
  /// (Petr, 2026-09-07: "prihlasit se musim dvakrat"). An authorization code is
  /// single-use anyway, so a second exchange of the same one could only ever
  /// fail. One at a time, and never the same URI twice.
  Future<bool> _redirectChain = Future.value(false);
  String? _lastRedirect;

  Future<bool> handleRedirect(Uri uri) {
    final Future<bool> next = _redirectChain.then((_) {
      if (_lastRedirect == uri.toString()) {
        // Already dealt with, by us, moments ago. Swallow it: it is our scheme
        // and re-reporting it would show a second SnackBar for one login.
        AppLog.add('spotify', 'redirect delivered twice, ignoring the repeat');
        return false;
      }
      _lastRedirect = uri.toString();
      return _handleRedirect(uri);
    });
    // Keep the chain alive even when this attempt throws, or one failure would
    // wedge every later login behind a dead Future.
    _redirectChain = next.then((_) => false, onError: (_) => false);
    return next;
  }

  Future<bool> _handleRedirect(Uri uri) async {
    final expectedState = await store.read(key: _Keys.pendingState);
    if (expectedState == null) {
      // Not waiting for anything: still swallow our own scheme, never exchange.
      return uri.scheme == Uri.parse(kSpotifyRedirectUri).scheme;
    }
    final r = parseSpotifyRedirect(uri, expectedState: expectedState);
    if (r == null) return false;
    await store.delete(key: _Keys.pendingState);
    final verifier = await store.read(key: _Keys.pendingVerifier);
    await store.delete(key: _Keys.pendingVerifier);
    if (!r.ok || verifier == null) {
      AppLog.add('spotify', 'spotify: login rejected: ${r.error ?? 'no verifier'}');
      throw SpotifyAuthException('Spotify login failed: ${r.error ?? 'no verifier'}');
    }
    await _exchange({
      'grant_type': 'authorization_code',
      'code': r.code!,
      'redirect_uri': kSpotifyRedirectUri,
      'client_id': kSpotifyClientId,
      'code_verifier': verifier,
    });
    await _fetchDisplayName();
    _linked = true;
    notifyListeners();
    AppLog.add('spotify', 'linked as "$_user"');
    return true;
  }

  /// A valid access token, refreshed when within a minute of expiry. Throws
  /// [SpotifyAuthException] when not linked or the refresh is refused (the
  /// user revoked access) — in which case the link is dropped.
  Future<String> accessToken() async {
    await load();
    if (!_linked) throw SpotifyAuthException('Spotify is not connected.');
    final token = await store.read(key: _Keys.access);
    final expStr = await store.read(key: _Keys.expiresAt);
    final exp = int.tryParse(expStr ?? '') ?? 0;
    if (token != null &&
        token.isNotEmpty &&
        DateTime.now().millisecondsSinceEpoch < exp - 60 * 1000) {
      return token;
    }
    final refresh = await store.read(key: _Keys.refresh);
    if (refresh == null || refresh.isEmpty) {
      await unlink();
      throw SpotifyAuthException('Spotify is not connected.');
    }
    try {
      await _exchange({
        'grant_type': 'refresh_token',
        'refresh_token': refresh,
        'client_id': kSpotifyClientId,
      });
    } on SpotifyAuthException {
      // A refused refresh means the grant is gone (revoked in Spotify's account
      // page, or the developer app changed). Nothing to retry; start over.
      await unlink();
      rethrow;
    }
    return (await store.read(key: _Keys.access))!;
  }

  /// Forget the cached access token so the next [accessToken] refreshes —
  /// for a 401 Spotify returned before our own expiry check would have.
  Future<void> invalidateAccessToken() =>
      store.write(key: _Keys.expiresAt, value: '0');

  Future<void> unlink() async {
    for (final k in [_Keys.refresh, _Keys.access, _Keys.expiresAt, _Keys.user]) {
      await store.delete(key: k);
    }
    _linked = false;
    _user = '';
    notifyListeners();
    AppLog.add('spotify', 'unlinked');
  }

  Future<void> _exchange(Map<String, String> form) async {
    final http.Response res;
    try {
      res = await httpClient
          .post(Uri.parse(_tokenEndpoint), body: form)
          .timeout(const Duration(seconds: 15));
    } catch (e) {
      throw SpotifyAuthException('Spotify token request failed: $e');
    }
    if (res.statusCode != 200) {
      String why = 'HTTP ${res.statusCode}';
      try {
        final j = jsonDecode(res.body);
        if (j is Map && j['error_description'] != null) why = '${j['error_description']}';
      } catch (_) {}
      throw SpotifyAuthException('Spotify token request refused: $why');
    }
    final j = jsonDecode(res.body) as Map<String, dynamic>;
    final access = j['access_token'] as String?;
    if (access == null || access.isEmpty) {
      throw SpotifyAuthException('Spotify token response carried no access token.');
    }
    final expiresIn = (j['expires_in'] as num?)?.toInt() ?? 3600;
    await store.write(key: _Keys.access, value: access);
    await store.write(
        key: _Keys.expiresAt,
        value:
            '${DateTime.now().millisecondsSinceEpoch + expiresIn * 1000}');
    // A refresh response MAY rotate the refresh token; keep whichever is newest.
    final refresh = j['refresh_token'] as String?;
    if (refresh != null && refresh.isNotEmpty) {
      await store.write(key: _Keys.refresh, value: refresh);
    }
  }

  Future<void> _fetchDisplayName() async {
    try {
      final token = await store.read(key: _Keys.access);
      final res = await httpClient.get(Uri.parse('https://api.spotify.com/v1/me'),
          headers: {'Authorization': 'Bearer $token'}).timeout(const Duration(seconds: 10));
      if (res.statusCode == 200) {
        final j = jsonDecode(res.body) as Map<String, dynamic>;
        _user = (j['display_name'] as String?)?.trim() ?? '';
        if (_user.isEmpty) _user = (j['id'] as String?) ?? '';
        await store.write(key: _Keys.user, value: _user);
      }
    } catch (e) {
      AppLog.add('spotify', '/me failed (non-fatal): $e');
    }
  }
}
