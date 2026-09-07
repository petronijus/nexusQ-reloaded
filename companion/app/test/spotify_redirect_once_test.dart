// One login must be one login.
//
// Petr, 2026-09-07: "prihlasit se musim dvakrat." The redirect back from the
// browser arrives by TWO routes — `uriLinkStream` and `getInitialLink()` — and
// app_links delivers it on both. Unserialised, the two calls interleaved:
// both read `pendingState`, then whichever got there first deleted
// `pendingVerifier`, so its twin found none and threw "login failed: no
// verifier". The user saw a failure over a login that had in fact just
// succeeded, and logged in again.
//
// An authorization code is single-use, so a second exchange of the same one
// could only ever fail. The fix is therefore both a lock and a memory: one
// redirect at a time, and never the same URI twice.
import 'dart:async';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexusq_companion/spotify/spotify_auth.dart';

/// A store that counts what the redirect handler touches, so "did the second
/// delivery try to consume the attempt?" is observable without a network.
class _CountingStore extends FlutterSecureStorage {
  _CountingStore(this.values);
  final Map<String, String> values;
  int deletes = 0;
  final List<String> reads = [];

  @override
  Future<String?> read({
    required String key,
    IOSOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    MacOsOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    reads.add(key);
    return values[key];
  }

  @override
  Future<void> write({
    required String key,
    required String? value,
    IOSOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    MacOsOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    if (value == null) {
      values.remove(key);
    } else {
      values[key] = value;
    }
  }

  @override
  Future<void> delete({
    required String key,
    IOSOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    MacOsOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    deletes++;
    values.remove(key);
  }
}

void main() {
  test('the same redirect delivered twice is only acted on once', () async {
    final link = SpotifyLink.instance;
    final store = _CountingStore({});
    link.store = store;

    // No pending attempt: the handler swallows our own scheme and exchanges
    // nothing, which is the shape both deliveries take once one has consumed
    // the attempt.
    final uri = Uri.parse('nexusq://spotify-callback?code=abc&state=xyz');
    final first = await link.handleRedirect(uri);
    final readsAfterFirst = store.reads.length;
    final second = await link.handleRedirect(uri);

    expect(first, isTrue, reason: 'our scheme, so it is handled (and swallowed)');
    expect(second, isFalse, reason: 'the repeat must not be reported a second time');
    expect(store.reads.length, readsAfterFirst,
        reason: 'the repeat must not even look at the pending attempt');
  });

  test('a different redirect afterwards is still processed', () async {
    final link = SpotifyLink.instance;
    link.store = _CountingStore({});
    await link.handleRedirect(Uri.parse('nexusq://spotify-callback?code=one&state=s'));
    // A second, genuinely different login attempt must not be swallowed by the
    // memory of the first — that would make re-linking impossible.
    final again =
        await link.handleRedirect(Uri.parse('nexusq://spotify-callback?code=two&state=s'));
    expect(again, isTrue);
  });

  test('concurrent deliveries do not interleave', () async {
    final link = SpotifyLink.instance;
    final store = _CountingStore({});
    link.store = store;

    // Fired together, exactly as the stream and the initial-link future do.
    final a = link.handleRedirect(Uri.parse('nexusq://spotify-callback?code=x&state=s'));
    final b = link.handleRedirect(Uri.parse('nexusq://spotify-callback?code=x&state=s'));
    final results = await Future.wait([a, b]);

    // Exactly one of them owns the redirect; the other reports nothing, so the
    // user sees one outcome rather than a success and a failure.
    expect(results.where((r) => r).length, 1);
  });

  test('a throwing redirect does not wedge every later one', () async {
    final link = SpotifyLink.instance;
    // A pending state with no verifier is the shape that used to throw.
    link.store = _CountingStore({'spotify.pending_state': 's'});
    await expectLater(
      link.handleRedirect(Uri.parse('nexusq://spotify-callback?code=c&state=s')),
      throwsA(isA<SpotifyAuthException>()),
    );
    // The chain must still run: without the error-swallowing continuation this
    // second call would never complete.
    link.store = _CountingStore({});
    final later =
        await link.handleRedirect(Uri.parse('nexusq://spotify-callback?code=d&state=s'));
    expect(later, isTrue);
  });
}
