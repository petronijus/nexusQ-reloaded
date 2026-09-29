// The volume mirror without a linked Spotify account: nothing to tell Spotify
// with, so nothing is attempted. A file of its own because SpotifyLink is a
// process-wide singleton that reads its store once.
import 'package:flutter_test/flutter_test.dart';

import 'volume_spotify_mirror_test.dart' show mirrorController;

void main() {
  test('Spotify account not linked: nothing to tell it with', () async {
    final (c, _, player) = await mirrorController(
      linked: false,
      source: 'spotify',
      transport: 'spotify-web',
    );
    c.commitVolume(50);
    await Future<void>.delayed(Duration.zero);
    expect(player.volumes, isEmpty);
    c.dispose();
  });
}
