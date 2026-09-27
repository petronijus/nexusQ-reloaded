import 'package:flutter_test/flutter_test.dart';
import 'package:nexusq_companion/protocol/mock_client.dart';
import 'package:nexusq_companion/protocol/client.dart';
import 'package:nexusq_companion/protocol/models.dart';

/// The diagnostics mode as the app reads it (PROTOCOL §16).
void main() {
  test('off, and garbage, read as off', () {
    for (final j in <Map<String, dynamic>>[
      {},
      {'enabled': 'yes', 'until': 'x', 'pending': 'spotify'},
    ]) {
      final d = DiagnosticsState.fromJson(j);
      expect(d.enabled, isFalse);
      expect(d.until, isNull);
      expect(d.pending, isEmpty);
      expect(d.pendingNote, isNull);
      expect(d.summary, contains('Switches itself off'));
    }
  });

  test('on: countdown and the pending note name the service', () {
    final d = DiagnosticsState.fromJson({
      'enabled': true,
      'until': 1790086400,
      'remainingS': 23 * 3600 + 7 * 60 + 30,
      'services': [
        {'id': 'spotify', 'name': 'Spotify Connect'},
        {'id': 'airplay', 'name': 'AirPlay'},
      ],
      'pending': ['spotify'],
    });
    expect(d.enabled, isTrue);
    expect(d.until, DateTime.fromMillisecondsSinceEpoch(1790086400 * 1000, isUtc: true));
    expect(d.summary, 'On — ends in 23 h 07 min.');
    expect(d.pendingNote, 'Applies to Spotify Connect when playback stops.');
    expect(DiagnosticsState.fromJson({'enabled': true, 'remainingS': 300}).summary, 'On — ends in 5 min.');
  });

  test('mock: set on/off round-trips and pushes diagnosticsChanged', () async {
    final c = MockClient();
    final events = <NexusQEvent>[];
    final sub = c.events.listen(events.add);
    expect((await c.call('getDiagnostics'))['enabled'], isFalse);
    final on = DiagnosticsState.fromJson(await c.call('setDiagnostics', {'enabled': true, 'hours': 24}));
    expect(on.enabled, isTrue);
    expect(on.remaining.inHours, anyOf(23, 24));
    expect((await c.call('setDiagnostics', {'enabled': false}))['enabled'], isFalse);
    await expectLater(c.call('setDiagnostics', {'enabled': true, 'hours': 100}), throwsA(isA<NexusQError>()));
    await Future<void>.delayed(Duration.zero);
    expect(events.where((e) => e.event == 'diagnosticsChanged').length, 2);
    await sub.cancel();
  });
}
