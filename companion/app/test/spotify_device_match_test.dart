// Every Spotify command is aimed by device_id, and the only handle the app has
// is the NAME librespot advertises — the Q's own name. A wrong match sends
// play/pause to someone's laptop; no match must stay no match, not a guess.
import 'package:flutter_test/flutter_test.dart';
import 'package:nexusq_companion/spotify/spotify_player.dart';

SpotifyDevice d(String id, String name, {String type = 'Speaker'}) =>
    SpotifyDevice(id: id, name: name, type: type);

void main() {
  test('exact name wins, case and whitespace folded', () {
    final list = [d('1', 'Petr’s iPhone', type: 'Smartphone'), d('2', 'Nexus  Q Šumperák')];
    expect(matchQDevice(list, 'nexus q šumperák')?.id, '2');
    expect(matchQDevice(list, ' Nexus Q Šumperák ')?.id, '2');
  });

  test('a phone with the same name is still an exact match (names are the contract)', () {
    // If the user names two Connect devices identically the first exact hit is
    // used; this is documented behaviour, not a bug to paper over.
    final list = [d('p', 'Nexus Q', type: 'Smartphone'), d('q', 'Nexus Q')];
    expect(matchQDevice(list, 'Nexus Q')?.id, 'p');
  });

  test('falls back to the ONE speaker whose name contains the Q name', () {
    final list = [d('1', 'MacBook', type: 'Computer'), d('2', 'Nexus Q (living room)')];
    expect(matchQDevice(list, 'Nexus Q')?.id, '2');
  });

  test('two candidate speakers → no guess', () {
    final list = [d('a', 'Nexus Q kitchen'), d('b', 'Nexus Q cottage')];
    expect(matchQDevice(list, 'Nexus Q'), isNull);
  });

  test('a non-speaker that merely contains the name is not a fallback', () {
    final list = [d('c', 'Nexus Q remote', type: 'Smartphone')];
    expect(matchQDevice(list, 'Nexus Q'), isNull);
  });

  test('empty inputs', () {
    expect(matchQDevice([], 'Nexus Q'), isNull);
    expect(matchQDevice([d('1', 'Nexus Q')], ''), isNull);
  });

  test('fromJson reads the Web API shape', () {
    final dev = SpotifyDevice.fromJson({'id': 'x', 'name': 'Q', 'type': 'Speaker', 'is_active': true});
    expect(dev.id, 'x');
    expect(dev.isActive, isTrue);
  });
}
