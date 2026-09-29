// The app slider tells Spotify the Q's volume when Spotify plays here.
//
// Since device r117 the Q has one volume, the PulseAudio sink, and librespot
// drives it, so Spotify's N % is the app's N %. librespot has no local control
// interface and re-reads its mixer only at the next play, so a slider move in
// the app would stay invisible in the Spotify apps until then. The controller
// mirrors it through the Web API -- on the user's own release only, never in
// answer to an event, so nothing can ring.
import 'dart:async';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexusq_companion/protocol/client.dart';
import 'package:nexusq_companion/spotify/spotify_auth.dart';
import 'package:nexusq_companion/spotify/spotify_player.dart';
import 'package:nexusq_companion/state/device_controller.dart';

class LinkStore extends FlutterSecureStorage {
  LinkStore(this.linked);
  final bool linked;
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
      linked && key == 'spotify.refresh_token' ? 'a-refresh-token' : null;
}

class FakeBridge implements NexusQClient {
  final notified = <String>[];
  final _events = StreamController<NexusQEvent>.broadcast();
  final _conn = StreamController<bool>.broadcast();
  @override
  Future<Map<String, dynamic>> call(
    String m, [
    Map<String, dynamic>? p,
  ]) async => {};
  @override
  Stream<NexusQEvent> get events => _events.stream;
  @override
  Stream<bool> get connection => _conn.stream;
  @override
  bool get needsSupervision => false;
  @override
  Future<void> connect() async {}
  @override
  Future<void> close() async {
    await _events.close();
    await _conn.close();
  }

  @override
  void disconnect() {}
  @override
  void notify(String m, [Map<String, dynamic>? p]) => notified.add(m);
}

class FakePlayer implements SpotifyPlayer {
  final volumes = <(String, int)>[];
  @override
  Future<void> setVolume(String qName, int percent) async =>
      volumes.add((qName, percent));
  @override
  noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

Future<(DeviceController, FakeBridge, FakePlayer)> mirrorController({
  required bool linked,
  required String source,
  required String transport,
}) async {
  SpotifyLink.instance.store = LinkStore(linked);
  await SpotifyLink.instance.load();
  final bridge = FakeBridge();
  final c = DeviceController(bridge);
  final player = FakePlayer();
  c.playerFactory = (_) => player;
  c.state.applyIdentity({'name': 'Obývák Q'});
  c.state.applyJson({
    'nowPlaying': {
      'playing': true,
      'track': 'Kinkajou',
      'source': source,
      'transport': transport,
    },
  });
  return (c, bridge, player);
}

void main() {
  test(
    'Spotify playing here: the released value goes to Spotify too',
    () async {
      final (c, bridge, player) = await mirrorController(
        linked: true,
        source: 'spotify',
        transport: 'spotify-web',
      );
      c.setVolume(37); // dragging: the Q only
      c.setVolume(41);
      expect(player.volumes, isEmpty);
      c.commitVolume(41); // released
      await Future<void>.delayed(Duration.zero);
      expect(player.volumes, [('Obývák Q', 41)]);
      expect(bridge.notified, ['setVolume', 'setVolume']);
      c.dispose();
    },
  );

  test('another source (AirPlay, Roon): Spotify is not told', () async {
    final (c, _, player) = await mirrorController(
      linked: true,
      source: 'airplay',
      transport: 'device',
    );
    c.commitVolume(50);
    await Future<void>.delayed(Duration.zero);
    expect(player.volumes, isEmpty);
    c.dispose();
  });

  test(
    'a volume event from the Q never reaches Spotify (no ringing)',
    () async {
      final (c, _, player) = await mirrorController(
        linked: true,
        source: 'spotify',
        transport: 'spotify-web',
      );
      c.state.applyJson({'volume': 60});
      await Future<void>.delayed(Duration.zero);
      expect(player.volumes, isEmpty);
      c.dispose();
    },
  );
}
