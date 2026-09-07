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

  // 2026-09-07, the over-correction: the bar was made to move only when the
  // LIVE flag and the sampled one agreed, and then it did not move at all —
  // Spotify can still answer `is_playing: false` for a moment after a resume,
  // and until the next fetch the bar stood still while the music ran. The
  // sample is authoritative about the POSITION, never about whether the track
  // is moving now.
  test('the caller can override a stale sampled flag', () {
    final stale = at(pos: 30000, playing: false); // Spotify had not caught up
    expect(stale.positionAt(_t0.add(const Duration(seconds: 10))),
        const Duration(seconds: 30),
        reason: 'the sample on its own says frozen');
    expect(stale.positionAt(_t0.add(const Duration(seconds: 10)), playing: true),
        const Duration(seconds: 40),
        reason: 'the live flag wins, which is what the bar passes');
    expect(stale.fractionAt(_t0.add(const Duration(seconds: 10)), playing: true),
        closeTo(40000 / 180000, 0.0001));
  });

  test('a clock that went backwards does not produce a negative position', () {
    // Wall-clock time can step (NTP, a resume from sleep). A negative position
    // would render as a bar drawn from the wrong end.
    final p = at(pos: 1000);
    expect(p.positionAt(_t0.subtract(const Duration(seconds: 30)), playing: true),
        Duration.zero);
  });

  test('sampledAt defaults to now, so a fresh sample starts where it says', () {
    final p = SpotifyProgress(positionMs: 1000, durationMs: 2000, playing: false);
    expect(p.positionAt(DateTime.now()).inMilliseconds, closeTo(1000, 50));
  });
}
