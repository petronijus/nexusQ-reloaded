// The Spotify link is PKCE (RFC 7636): no secret in the app, a per-attempt
// verifier whose SHA-256 the browser round-trip proves, and a `state` that ties
// the redirect to THIS attempt. These pin the pure pieces, so a refactor cannot
// quietly weaken them (a padded challenge, an accepted foreign state) without a
// red test — the failure modes are silent at Spotify's end ("invalid_grant").
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:nexusq_companion/spotify/spotify_auth.dart';

void main() {
  group('verifier', () {
    test('is 86 chars of the unreserved alphabet, no padding', () {
      final v = pkceVerifier(Random(7));
      expect(v.length, 86);
      expect(RegExp(r'^[A-Za-z0-9\-_]+$').hasMatch(v), isTrue, reason: v);
      expect(v.contains('='), isFalse);
    });
    test('is random per attempt', () {
      expect(pkceVerifier(), isNot(pkceVerifier()));
    });
  });

  group('challenge', () {
    test('matches the RFC 7636 appendix B vector', () {
      // https://www.rfc-editor.org/rfc/rfc7636#appendix-B
      expect(pkceChallenge('dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk'),
          'E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM');
    });
    test('carries no base64 padding', () {
      for (var i = 0; i < 20; i++) {
        expect(pkceChallenge(pkceVerifier()).contains('='), isFalse);
      }
    });
  });

  group('authorize URL', () {
    test('carries exactly the PKCE + scope parameters', () {
      final u = spotifyAuthorizeUrl(clientId: 'cid', challenge: 'chal', state: 'st8');
      expect(u.scheme, 'https');
      expect(u.host, 'accounts.spotify.com');
      expect(u.path, '/authorize');
      expect(u.queryParameters, {
        'response_type': 'code',
        'client_id': 'cid',
        'redirect_uri': 'nexusq://spotify-callback',
        'scope': 'user-read-playback-state user-modify-playback-state',
        'code_challenge_method': 'S256',
        'code_challenge': 'chal',
        'state': 'st8',
      });
    });
  });

  group('redirect parsing', () {
    test('our callback with the right state yields the code', () {
      final r = parseSpotifyRedirect(Uri.parse('nexusq://spotify-callback?code=abc&state=s1'),
          expectedState: 's1');
      expect(r, isNotNull);
      expect(r!.ok, isTrue);
      expect(r.code, 'abc');
    });
    test('a mismatched state is refused, code and all', () {
      final r = parseSpotifyRedirect(Uri.parse('nexusq://spotify-callback?code=abc&state=OTHER'),
          expectedState: 's1');
      expect(r!.ok, isFalse);
      expect(r.error, 'state mismatch');
      expect(r.code, isNull);
    });
    test("Spotify's error= is surfaced, not exchanged", () {
      final r = parseSpotifyRedirect(
          Uri.parse('nexusq://spotify-callback?error=access_denied&state=s1'),
          expectedState: 's1');
      expect(r!.ok, isFalse);
      expect(r.error, 'access_denied');
    });
    test('a foreign URI is not a Spotify callback at all', () {
      expect(parseSpotifyRedirect(Uri.parse('nexusq://something-else?code=x&state=s1'), expectedState: 's1'), isNull);
      expect(parseSpotifyRedirect(Uri.parse('https://evil.example/spotify-callback?code=x&state=s1'), expectedState: 's1'), isNull);
    });
    test('a callback without a code is an error', () {
      final r = parseSpotifyRedirect(Uri.parse('nexusq://spotify-callback?state=s1'), expectedState: 's1');
      expect(r!.ok, isFalse);
      expect(r.error, 'no code');
    });
  });
}
