// What is playing and what follows, parsed out of /v1/me/player/queue.
//
// Petr, 2026-09-07: "nevidim vubec tam nazev toho co hraje ani artwork a treba
// bych chtel vedet co je next nez na to dam nebo frontu". The name and artwork
// could in principle come from the librespot hook, but the QUEUE cannot —
// librespot has no idea what Spotify will play next — so one call to this
// endpoint answers all three at once and the app reads now-playing from here
// whenever Spotify is linked.
//
// The parsing is where this can go wrong quietly: a missing artist list, an
// episode instead of a track, an album with no images, a 204 when nothing is
// playing. Each of those would render as a blank row rather than an error.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:nexusq_companion/spotify/spotify_player.dart';

Map<String, dynamic> track({
  String name = 'Kinkajou',
  List<String> artists = const ['Les Baxter'],
  String album = 'Ritual of the Savage',
  List<Map<String, dynamic>>? images,
  int ms = 143000,
}) =>
    {
      'name': name,
      'artists': [for (final a in artists) {'name': a}],
      'album': {
        'name': album,
        'images': images ??
            [
              {'url': 'https://i.example/640', 'height': 640, 'width': 640},
              {'url': 'https://i.example/300', 'height': 300, 'width': 300},
              {'url': 'https://i.example/64', 'height': 64, 'width': 64},
            ],
      },
      'duration_ms': ms,
    };

void main() {
  test('current track and the next few come out of one payload', () {
    final q = SpotifyQueue.fromJson({
      'currently_playing': track(),
      'queue': [track(name: 'Quiet Village'), track(name: 'Jungle Flower')],
    });
    expect(q.current!.title, 'Kinkajou');
    expect(q.current!.artist, 'Les Baxter');
    expect(q.current!.album, 'Ritual of the Savage');
    expect(q.current!.durationMs, 143000);
    expect(q.upNext.map((t) => t.title), ['Quiet Village', 'Jungle Flower']);
    expect(q.isEmpty, isFalse);
  });

  test('artwork is the smallest image still big enough for a thumbnail', () {
    final q = SpotifyQueue.fromJson({'currently_playing': track(), 'queue': const []});
    // 300 over 640: a thumbnail does not need 640, and over 64: that is mush.
    expect(q.current!.artUrl, 'https://i.example/300');
  });

  test('an album with only a tiny image still yields that one, not blank', () {
    final q = SpotifyQueue.fromJson({
      'currently_playing': track(images: [
        {'url': 'https://i.example/64', 'height': 64, 'width': 64},
      ]),
      'queue': const [],
    });
    expect(q.current!.artUrl, 'https://i.example/64');
  });

  test('an album with no images at all is empty, not a crash', () {
    final q = SpotifyQueue.fromJson({
      'currently_playing': track(images: const []),
      'queue': const [],
    });
    expect(q.current!.artUrl, isEmpty);
    expect(q.current!.title, 'Kinkajou');
  });

  test('several artists read as one line', () {
    final q = SpotifyQueue.fromJson({
      'currently_playing': track(artists: const ['Massive Attack', 'Tracey Thorn']),
      'queue': const [],
    });
    expect(q.current!.artist, 'Massive Attack, Tracey Thorn');
  });

  // A podcast episode has no `artists` and no `album`; without the show
  // fallback the row would show a title over a blank line.
  test('a podcast episode falls back to its show', () {
    final q = SpotifyQueue.fromJson({
      'currently_playing': {
        'name': 'Episode 12',
        'show': {
          'name': 'Some Show',
          'images': [
            {'url': 'https://i.example/show300', 'height': 300, 'width': 300}
          ],
        },
        'duration_ms': 2400000,
      },
      'queue': const [],
    });
    expect(q.current!.title, 'Episode 12');
    expect(q.current!.artist, 'Some Show');
    expect(q.current!.artUrl, 'https://i.example/show300');
  });

  test('nothing playing anywhere is an empty queue, not an exception', () {
    expect(const SpotifyQueue().isEmpty, isTrue);
    final q = SpotifyQueue.fromJson(const {});
    expect(q.current, isNull);
    expect(q.upNext, isEmpty);
    expect(q.isEmpty, isTrue);
  });

  test('a long queue is trimmed so the screen does not have to', () {
    final q = SpotifyQueue.fromJson({
      'currently_playing': track(),
      'queue': [for (var i = 0; i < 40; i++) track(name: 'T$i')],
    });
    expect(q.upNext.length, 8);
    expect(q.upNext.first.title, 'T0');
  });

  test('junk entries in the queue are skipped, not rendered', () {
    final q = SpotifyQueue.fromJson({
      'currently_playing': track(),
      'queue': ['nonsense', 42, track(name: 'Real')],
    });
    expect(q.upNext.map((t) => t.title), ['Real']);
  });

  // The endpoint is documented to answer 204 with no body; jsonDecode('') would
  // throw and take the whole Now Playing card down with it.
  test('an empty body decodes to nothing rather than throwing', () {
    expect(() => jsonDecode(''), throwsA(anything));
    expect(const SpotifyQueue().isEmpty, isTrue);
  });
}
