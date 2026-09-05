// The Now Playing buttons are enabled only when a tap can do something
// (PROTOCOL §5 `transport`). Before 1.18 they were always enabled and always
// dead. This table is the whole behaviour; the widget only renders it.
import 'package:flutter_test/flutter_test.dart';
import 'package:nexusq_companion/protocol/models.dart';
import 'package:nexusq_companion/spotify/transport_rules.dart';

void main() {
  test('device transport → bridge, enabled', () {
    final r = transportRoute('device', spotifyLinked: false);
    expect(r, TransportRoute.device);
    expect(controlsEnabled(r), isTrue);
  });

  test('spotify-web + linked → Web API, enabled', () {
    final r = transportRoute('spotify-web', spotifyLinked: true);
    expect(r, TransportRoute.spotifyWeb);
    expect(controlsEnabled(r), isTrue);
  });

  test('spotify-web without an account → disabled, offer to link', () {
    final r = transportRoute('spotify-web', spotifyLinked: false);
    expect(r, TransportRoute.spotifyUnlinked);
    expect(controlsEnabled(r), isFalse);
  });

  test('none / unknown / empty → disabled, whatever the link state', () {
    for (final t in ['none', '', 'roon-core', 'garbage']) {
      for (final linked in [true, false]) {
        final r = transportRoute(t, spotifyLinked: linked);
        expect(r, TransportRoute.none, reason: '$t linked=$linked');
        expect(controlsEnabled(r), isFalse);
      }
    }
  });

  test('NowPlaying.fromJson: transport parsed, absent means none', () {
    expect(NowPlaying.fromJson({'playing': true, 'transport': 'spotify-web'}).transport, 'spotify-web');
    expect(NowPlaying.fromJson({'playing': true}).transport, 'none');
  });

  test('copyWith keeps transport', () {
    final np = NowPlaying.fromJson({'track': 't', 'transport': 'device'});
    expect(np.copyWith(playing: true).transport, 'device');
    expect(np.copyWith(playing: true).playing, isTrue);
  });
}
