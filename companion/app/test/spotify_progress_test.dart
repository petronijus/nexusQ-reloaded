// The position bar, and the arithmetic it ticks on.
//
// Petr, 2026-09-07: "slo by tam mit i progress bar?" Spotify's queue endpoint
// carries no position, so it comes from a second call — and it is SAMPLED, not
// streamed: asking every second would be rude to the rate limiter and no
// smoother than interpolating locally. Everything that can go wrong lives in
// that interpolation: a paused track that creeps, a stale sample that runs off
// the end of the song, a track with no known length.
import 'package:flutter_test/flutter_test.dart';
import 'package:nexusq_companion/spotify/spotify_player.dart';

final _t0 = DateTime(2026, 9, 7, 14, 0, 0);

SpotifyProgress at({int pos = 30000, int dur = 180000, bool playing = true}) =>
    SpotifyProgress(positionMs: pos, durationMs: dur, playing: playing, sampledAt: _t0);

void main() {
  test('a playing track advances with the wall clock', () {
    final p = at();
    expect(p.positionAt(_t0), const Duration(seconds: 30));
    expect(p.positionAt(_t0.add(const Duration(seconds: 5))), const Duration(seconds: 35));
  });

  test('a paused track does not creep', () {
    // The bar must sit still while paused; interpolating regardless would walk
    // it across the song while nothing plays.
    final p = at(playing: false);
    expect(p.positionAt(_t0.add(const Duration(minutes: 2))), const Duration(seconds: 30));
  });

  test('a stale sample cannot run past the end of the track', () {
    // The refresh is 30 s and a track can end between two of them; without the
    // clamp the bar would report more than the song is long.
    final p = at(pos: 170000, dur: 180000);
    expect(p.positionAt(_t0.add(const Duration(minutes: 5))), const Duration(milliseconds: 180000));
    expect(p.fractionAt(_t0.add(const Duration(minutes: 5))), 1.0);
  });

  test('the fraction is 0..1 across the track', () {
    final p = at(pos: 0, dur: 100000);
    expect(p.fractionAt(_t0), 0.0);
    expect(p.fractionAt(_t0.add(const Duration(seconds: 50))), 0.5);
    expect(p.fractionAt(_t0.add(const Duration(seconds: 100))), 1.0);
  });

  test('an unknown length has no fraction, so the bar draws nothing', () {
    // A live stream, or an item Spotify gives no duration for. `null` renders
    // as an indeterminate/absent bar rather than as "at the very start".
    final p = at(pos: 5000, dur: 0);
    expect(p.fractionAt(_t0), isNull);
    expect(p.positionAt(_t0), const Duration(seconds: 5));
  });

  test('sampledAt defaults to now, so a fresh sample starts where it says', () {
    final p = SpotifyProgress(positionMs: 1000, durationMs: 2000, playing: false);
    expect(p.positionAt(DateTime.now()).inMilliseconds, closeTo(1000, 50));
  });
}
