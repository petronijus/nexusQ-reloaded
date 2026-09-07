// The queue must arrive with the first screen, not one song later.
//
// Petr, 2026-09-07, watching the app come up: "nejdriv tam je artwork a
// playpause a pak kdyz dam dalsi song, pribyde timeline a fronta, je to mozny?"
// It was, and for a precise reason: `refreshQueue` reads `transportRoute`,
// which reads `nowPlaying.transport`, which is the default `none` until the
// first getState lands. A refresh fired at construction therefore always took
// the early return and fetched nothing, so the card came up with only the half
// the bridge supplies — cover, title, buttons — and the timeline and UP NEXT
// waited for a track change or for the 30 s tick.
//
// Two triggers fix it and both are asserted here: hydration refreshes once
// there is a state to judge by, and a transport that becomes actionable
// (`none` -> `spotify-web`) counts as a reason to refresh even when the track
// did not change.
import 'dart:async';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexusq_companion/protocol/client.dart';
import 'package:nexusq_companion/spotify/spotify_auth.dart';
import 'package:nexusq_companion/spotify/spotify_player.dart';
import 'package:nexusq_companion/state/device_controller.dart';

/// A client that answers getState with a Spotify-driven now-playing, so the
/// controller's transport route becomes `spotify-web` exactly as on the box.
class _SpotifyBridge implements NexusQClient {
  _SpotifyBridge({this.transport = 'spotify-web'});

  /// What the first getState reports. `none` models a box whose source has no
  /// backend yet, so the route only becomes fetchable on a later event.
  final String transport;
  final _events = StreamController<NexusQEvent>.broadcast();
  // Hydration hangs off the CONNECTION stream, exactly as with the real
  // client: connect() succeeding is signalled here, and that is what makes the
  // controller ask for state.
  final _conn = StreamController<bool>.broadcast();
  int getStateCalls = 0;

  @override
  Future<Map<String, dynamic>> call(String m, [Map<String, dynamic>? p]) async {
    if (m == 'getState') {
      getStateCalls++;
      return {
        'volume': 28,
        'nowPlaying': {
          'playing': true,
          'track': 'Kinkajou',
          'artist': 'Les Baxter',
          'source': transport == 'none' ? '' : 'spotify',
          'transport': transport,
        },
      };
    }
    return {};
  }

  void push(NexusQEvent e) => _events.add(e);

  @override
  Stream<NexusQEvent> get events => _events.stream;
  @override
  Stream<bool> get connection => _conn.stream;
  @override
  bool get needsSupervision => false;
  @override
  Future<void> connect() async => _conn.add(true);
  @override
  Future<void> close() async {
    await _events.close();
    await _conn.close();
  }
  @override
  void disconnect() {}
  @override
  void notify(String m, [Map<String, dynamic>? p]) {}
}

/// Counts queue fetches without touching the network.
class _CountingPlayer implements SpotifyPlayer {
  int queueCalls = 0;

  @override
  Future<SpotifyQueue> queue() async {
    queueCalls++;
    return const SpotifyQueue(
      current: SpotifyTrack(title: 'Kinkajou', artist: 'Les Baxter'),
      upNext: [SpotifyTrack(title: 'Quiet Village', artist: 'Les Baxter')],
    );
  }

  @override
  Future<SpotifyProgress?> progress() async =>
      SpotifyProgress(positionMs: 1000, durationMs: 100000, playing: true);

  @override
  noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

/// A store that reports a stored refresh token, so `SpotifyLink.isLinked` is
/// true and `transportRoute` can reach `spotifyWeb` — the state this file is
/// about. Without it every route is `spotifyUnlinked` and nothing fetches,
/// which is correct behaviour but not the thing under test.
class _LinkedStore extends FlutterSecureStorage {
  @override
  Future<String?> read({
    required String key,
    IOSOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    MacOsOptions? mOptions,
    WindowsOptions? wOptions,
  }) async =>
      key == 'spotify.refresh_token' ? 'a-refresh-token' : null;
}

Future<void> pretendLinked() async {
  SpotifyLink.instance.store = _LinkedStore();
  await SpotifyLink.instance.load();
}

void main() {
  setUp(pretendLinked);

  test('a refresh before the first state fetches nothing (the bug)', () async {
    // Documents WHY the eager refresh was useless: with the default state the
    // route is not spotifyWeb, so the call returns without asking Spotify.
    final c = DeviceController(_SpotifyBridge());
    final player = _CountingPlayer();
    c.playerFactory = (_) => player;
    await c.refreshQueue();
    expect(player.queueCalls, 0,
        reason: 'no transport known yet, so there is nothing to ask about');
    c.dispose();
  });

  test('once a spotify-web state is applied, a refresh does fetch', () async {
    final c = DeviceController(_SpotifyBridge());
    final player = _CountingPlayer();
    c.playerFactory = (_) => player;
    c.state.nowPlaying = c.state.nowPlaying.copyWith(playing: true);
    // Apply the state the bridge would send.
    c.state.applyJson({
      'nowPlaying': {
        'playing': true,
        'track': 'Kinkajou',
        'artist': 'Les Baxter',
        'source': 'spotify',
        'transport': 'spotify-web',
      }
    });
    await c.refreshQueue();
    expect(player.queueCalls, 1);
    expect(c.queue?.upNext.single.title, 'Quiet Village');
    expect(c.progress, isNotNull, reason: 'the timeline comes with it');
    c.dispose();
  });

  test('THE fix: the queue arrives with the first screen, not one song later',
      () async {
    // start() hydrates, and hydration is the first moment the transport is
    // known. Before the fix nothing fetched here and the timeline and UP NEXT
    // appeared only on the next track change.
    final c = DeviceController(_SpotifyBridge());
    final player = _CountingPlayer();
    c.playerFactory = (_) => player;
    c.start();
    await Future<void>.delayed(const Duration(milliseconds: 60));

    expect(player.queueCalls, greaterThan(0),
        reason: 'hydration must trigger the first refresh');
    expect(c.queue?.upNext, isNotEmpty);
    expect(c.progress, isNotNull);
    c.dispose();
  });

  test('the transport becoming actionable triggers a refresh on its own',
      () async {
    // none -> spotify-web with the SAME track: the old rule looked only at the
    // track, so a box that gained a backend mid-song waited for the next one.
    final bridge = _SpotifyBridge(transport: 'none');
    final c = DeviceController(bridge);
    final player = _CountingPlayer();
    c.playerFactory = (_) => player;
    c.start();
    await Future<void>.delayed(const Duration(milliseconds: 60));
    final before = player.queueCalls;

    bridge.push(NexusQEvent('nowPlayingChanged', {
      'playing': true,
      'track': 'Kinkajou',
      'artist': 'Les Baxter',
      'source': 'spotify',
      'transport': 'spotify-web',
    }));
    await Future<void>.delayed(const Duration(milliseconds: 60));

    expect(player.queueCalls, greaterThan(before),
        reason: 'the route just became fetchable, even though the track did not change');
    c.dispose();
  });
}
