// At the end of a queue there is nothing to play, and the app must say so by
// going quiet rather than by failing.
//
// Petr, 2026-09-07, with Spotify finished: "pokud jsem na konci fronty, nemel
// bych mit moznost dat play. Zaroven pokud tam ted nic nehraje, nemelo by tam
// bejt now playing title a image, proste tam nic neni." Pressing play in that
// state produced an opaque "error 43" — librespot answering "context is not
// available" to every request — over a card still showing the song that had
// ended minutes earlier.
//
// Two rules, one condition: [DeviceController.nothingToPlay]. The queue is the
// authority whenever Spotify is linked, because only it knows the context is
// exhausted; the bridge's own view is the fallback and, since control r41, is
// honestly empty after `stopped`.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexusq_companion/protocol/client.dart';
import 'package:nexusq_companion/protocol/models.dart';
import 'package:nexusq_companion/spotify/spotify_player.dart';
import 'package:nexusq_companion/spotify/transport_rules.dart' show TransportRoute;
import 'package:nexusq_companion/state/device_controller.dart';

class _Quiet implements NexusQClient {
  @override
  Future<Map<String, dynamic>> call(String m, [Map<String, dynamic>? p]) async => {};
  @override
  Stream<NexusQEvent> get events => const Stream.empty();
  @override
  Stream<bool> get connection => const Stream.empty();
  @override
  bool get needsSupervision => false;
  @override
  Future<void> connect() async {}
  @override
  Future<void> close() async {}
  @override
  void disconnect() {}
  @override
  void notify(String m, [Map<String, dynamic>? p]) {}
}

const _track = SpotifyTrack(title: 'Kinkajou', artist: 'Les Baxter');

DeviceController controller({NowPlaying? np, SpotifyQueue? q}) {
  final c = DeviceController(_Quiet());
  if (np != null) c.state.nowPlaying = np;
  c.queue = q;
  return c;
}

void main() {
  group('nothingToPlay', () {
    test('an exhausted Spotify queue means nothing to play', () {
      // THE case: the album finished. The bridge may still be carrying the last
      // track (an older device package does), and the queue overrules it.
      final c = controller(
        np: const NowPlaying(track: 'Quiet Village', artist: 'Les Baxter', source: 'spotify'),
        q: const SpotifyQueue(),
      );
      expect(c.nothingToPlay, isTrue);
      c.dispose();
    });

    test('a current track means there is something', () {
      final c = controller(q: const SpotifyQueue(current: _track));
      expect(c.nothingToPlay, isFalse);
      c.dispose();
    });

    test('nothing current but something queued still counts as playable', () {
      // Between tracks the current item can be momentarily absent; disabling
      // the buttons there would make them flicker.
      final c = controller(q: const SpotifyQueue(upNext: [_track]));
      expect(c.nothingToPlay, isFalse);
      c.dispose();
    });

    test('without a queue it falls back to what the bridge reports', () {
      final playing = controller(
          np: const NowPlaying(track: 'Kinkajou', artist: 'Les Baxter', playing: true));
      expect(playing.nothingToPlay, isFalse);
      playing.dispose();

      final empty = controller(np: const NowPlaying());
      expect(empty.nothingToPlay, isTrue);
      empty.dispose();
    });

    test('a paused-but-loaded track is NOT nothing to play', () {
      // Pause keeps its track (bridge r41 only clears on `stopped`), and play
      // must stay live so it can resume.
      final c = controller(
          np: const NowPlaying(track: 'Kinkajou', artist: 'Les Baxter', playing: false));
      expect(c.nothingToPlay, isFalse);
      c.dispose();
    });
  });

  test('a device transport is never "nothing to play", even with no title', () {
    // AirPlay from macOS system audio sends no metadata at all, so the card is
    // blank while music plays. `device` means the bridge already checked it can
    // act (shairport's CanControl against a live session), and greying the
    // buttons out on a missing title is what made pause a one-way door.
    final c = controller(
      np: const NowPlaying(track: '', artist: '', source: 'airplay',
          transport: 'device', playing: false),
    );
    expect(c.transportRoute, TransportRoute.device);
    expect(c.nothingToPlay, isFalse);
    c.dispose();
  });

  testWidgets('the Now Playing card is absent when nothing is loaded', (tester) async {
    final c = controller(
      np: const NowPlaying(track: 'Quiet Village', artist: 'Les Baxter', source: 'spotify'),
      q: const SpotifyQueue(),
    );
    addTearDown(c.dispose);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: ListenableBuilder(
          listenable: c,
          builder: (_, _) => c.nothingToPlay
              ? const Text('nothing')
              : Text(c.state.nowPlaying.track),
        ),
      ),
    ));
    // The stale title must not be on screen just because the bridge kept it.
    expect(find.text('Quiet Village'), findsNothing);
    expect(find.text('nothing'), findsOneWidget);
  });
}
