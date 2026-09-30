// Release alerts (PROTOCOL §12c): the phone rings once per release, never for
// what its owner is looking at, reaches a Q whose address moved, and shows
// "what's new" once, only after this Q was seen waiting for that release.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexusq_companion/protocol/client.dart';
import 'package:nexusq_companion/protocol/models.dart';
import 'package:nexusq_companion/update/release.dart';
import 'package:nexusq_companion/update/release_alerts.dart';
import 'package:nexusq_companion/update/release_background.dart';
import 'package:nexusq_companion/update/update_coordinator.dart';
import 'package:nexusq_companion/widgets/whats_new.dart';

Map<String, dynamic> release(String version) => {
  'version': version,
  'date': '2026-10-01',
  'headline': 'Quieter when nothing plays',
  'items': [
    {
      'icon': 'power',
      'title': 'Quiet when idle',
      'text': 'The Q sleeps deeper.',
    },
    {'icon': 'rocket', 'title': 'Unknown icon', 'text': 'Drawn as new.'},
  ],
};

UpdateStatus pending(String v, {String id = 'A1'}) =>
    UpdateStatus.fromJson({'id': id, 'available': release(v), 'current': null});
UpdateStatus runs(String v, {String id = 'A1'}) =>
    UpdateStatus.fromJson({'id': id, 'available': null, 'current': release(v)});

const kitchen = KnownDevice(
  id: 'A1',
  name: 'Kitchen',
  host: '192.168.20.246',
  port: 45015,
  hostname: 'kitchen',
);

class _EventClient implements NexusQClient {
  final _events = StreamController<NexusQEvent>.broadcast();
  Map<String, dynamic>? answer;
  Object? error;
  final List<Map<String, dynamic>?> params = [];

  void push(String event, Map<String, dynamic> data) =>
      _events.add(NexusQEvent(event, data));

  @override
  Future<Map<String, dynamic>> call(
    String method, [
    Map<String, dynamic>? p,
  ]) async {
    params.add(p);
    if (error != null) throw error!;
    return answer ?? {};
  }

  @override
  Stream<NexusQEvent> get events => _events.stream;
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
  void notify(String method, [Map<String, dynamic>? params]) {}
}

void main() {
  group('the status the Q reports', () {
    test('a release, with an unknown icon kept for the app to draw as new', () {
      final s = pending('2.0.0');
      expect(s.available!.version, '2.0.0');
      expect(s.available!.items.map((i) => i.icon), ['power', 'rocket']);
      expect(s.current, isNull);
    });

    test('a malformed release is no release, not half a card', () {
      final s = UpdateStatus.fromJson({
        'available': {'version': '2.0.0', 'headline': 'x', 'items': []},
        'current': 'nonsense',
        'checkedAt': 1790086400,
        'error': 'HTTP 503',
      });
      expect(s.available, isNull);
      expect(s.current, isNull);
      expect(s.error, 'HTTP 503');
      expect(s.checkedAt, DateTime.fromMillisecondsSinceEpoch(1790086400000));
    });
  });

  group('which Q this is', () {
    test(
      'the id from getDeviceInfo, never the serial every Q reads as unknown',
      () {
        final s = DeviceState()
          ..applyIdentity({
            'name': 'Kitchen',
            'serial': 'unknown',
            'id': 'nexusq_f88fca2048e1',
          });
        expect(s.deviceId, 'nexusq_f88fca2048e1');
        final old = DeviceState()
          ..applyIdentity({'name': 'Old', 'serial': 'unknown'});
        expect(
          old.deviceId,
          isNull,
          reason: 'a bridge before r62 is not remembered',
        );
        final real = DeviceState()..applyIdentity({'serial': '0123ABCD'});
        expect(real.deviceId, '0123ABCD');
        real.applyIdentity({'name': 'Renamed'}); // a deviceInfoChanged
        expect(real.deviceId, '0123ABCD');
      },
    );
  });

  group('known devices', () {
    test('tried by last address, then by name', () {
      expect(kitchen.addresses, ['192.168.20.246', 'kitchen.local']);
      const old = KnownDevice(id: 'B', name: 'B', host: '10.0.0.2', port: 1);
      expect(old.addresses, ['10.0.0.2'], reason: 'a bridge before r62');
    });

    test('remembered newest first, once each, at most eight', () async {
      final a = ReleaseAlerts(MemoryStore());
      for (var i = 0; i < 10; i++) {
        await a.remember(
          KnownDevice(id: 'S$i', name: 'Q$i', host: 'h$i', port: 1),
        );
      }
      await a.remember(
        const KnownDevice(id: 'S5', name: 'Q5', host: 'moved', port: 1),
      );
      final list = await a.devices();
      expect(list.length, ReleaseAlerts.maxDevices);
      expect(list.first.id, 'S5');
      expect(list.first.host, 'moved');
      expect(list.where((d) => d.id == 'S5').length, 1);
      expect(list.map((d) => d.id), isNot(contains('S0')));
    });

    test('a damaged list is an empty one', () async {
      final store = MemoryStore()..values['release.devices'] = '{nope';
      expect(await ReleaseAlerts(store).devices(), isEmpty);
    });
  });

  group('ringing', () {
    test('once per release, again for the next', () async {
      final a = ReleaseAlerts(MemoryStore());
      expect(
        (await a.observe(kitchen, pending('2.0.0')))?.release.version,
        '2.0.0',
      );
      expect(await a.observe(kitchen, pending('2.0.0')), isNull);
      expect(
        (await a.observe(kitchen, pending('2.1.0')))?.release.version,
        '2.1.0',
      );
    });

    test('nothing pending, nothing to say', () async {
      expect(
        await ReleaseAlerts(MemoryStore()).observe(kitchen, runs('2.0.0')),
        isNull,
      );
    });

    test('each Q rings for itself', () async {
      final a = ReleaseAlerts(MemoryStore());
      const other = KnownDevice(id: 'B2', name: 'Cottage', host: 'x', port: 1);
      expect(await a.observe(kitchen, pending('2.0.0')), isNotNull);
      expect(await a.observe(other, pending('2.0.0')), isNotNull);
    });
  });

  group("what's new", () {
    test('shown once, after this Q was seen waiting for the release', () async {
      final a = ReleaseAlerts(MemoryStore());
      await a.observe(kitchen, pending('2.0.0'));
      expect((await a.whatsNewToShow('A1', runs('2.0.0')))?.version, '2.0.0');
      expect(await a.whatsNewToShow('A1', runs('2.0.0')), isNull);
    });

    test('not for a Q first met already on the release', () async {
      final a = ReleaseAlerts(MemoryStore());
      expect(await a.whatsNewToShow('A1', runs('2.0.0')), isNull);
    });

    test('not for an older release than the one it waited for', () async {
      final a = ReleaseAlerts(MemoryStore());
      await a.observe(kitchen, pending('2.1.0'));
      expect(await a.whatsNewToShow('A1', runs('2.0.0')), isNull);
    });
  });

  test('the notification names the Q only when it has a name of its own', () {
    final rel = Release.fromJson(release('2.0.0'))!;
    expect(
      releaseAlertTitle(ReleaseAlert(kitchen, rel)),
      'Kitchen: Nexus Q 2.0.0 is ready',
    );
    const plain = KnownDevice(id: 'B', name: 'Nexus Q', host: 'x', port: 1);
    expect(
      releaseAlertTitle(
        const ReleaseAlert(
          plain,
          Release(
            version: '2.0.0',
            date: '',
            headline: 'h',
            items: [ReleaseItem(icon: 'new', title: 't', text: 'x')],
          ),
        ),
      ),
      'Nexus Q 2.0.0 is ready',
    );
  });

  test('the permission is asked for once', () async {
    final a = ReleaseAlerts(MemoryStore());
    expect(await a.firstPermissionAsk(), isTrue);
    expect(await a.firstPermissionAsk(), isFalse);
  });

  group('the background pass', () {
    test('rings for each Q with news, skips one it cannot reach', () async {
      final store = MemoryStore();
      final alerts = ReleaseAlerts(store);
      await alerts.remember(kitchen);
      await alerts.remember(
        const KnownDevice(id: 'B2', name: 'Cottage', host: 'x', port: 1),
      );
      final posted = <String>[];
      Future<UpdateStatus?> fetch(KnownDevice d) async =>
          d.id == 'A1' ? pending('2.0.0') : null;
      Future<void> post(ReleaseAlert a) async =>
          posted.add('${a.device.name} ${a.release.version}');

      await runReleaseCheck(store: store, fetch: fetch, post: post);
      await runReleaseCheck(store: store, fetch: fetch, post: post);
      expect(posted, ['Kitchen 2.0.0']);
    });

    test(
      'an answer from another Q (its address moved) is not filed under this one',
      () async {
        final store = MemoryStore();
        final alerts = ReleaseAlerts(store);
        await alerts.remember(kitchen);
        final posted = <ReleaseAlert>[];
        await runReleaseCheck(
          store: store,
          fetch: (_) async => pending('2.0.0', id: 'nexusq_other'),
          post: (a) async => posted.add(a),
        );
        expect(posted, isEmpty);
        expect(store.values['release.notified.A1'], isNull);
      },
    );

    test('switched off, it asks nobody', () async {
      final store = MemoryStore();
      final alerts = ReleaseAlerts(store);
      await alerts.remember(kitchen);
      await alerts.setEnabled(false);
      var asked = 0;
      await runReleaseCheck(
        store: store,
        fetch: (_) async {
          asked++;
          return pending('2.0.0');
        },
        post: (_) async {},
      );
      expect(asked, 0);
    });

    test('a release seen in the app does not ring later', () async {
      final store = MemoryStore();
      final alerts = ReleaseAlerts(store);
      await alerts.remember(kitchen);
      await alerts.observe(kitchen, pending('2.0.0')); // the home screen saw it
      final posted = <ReleaseAlert>[];
      await runReleaseCheck(
        store: store,
        fetch: (_) async => pending('2.0.0'),
        post: (a) async => posted.add(a),
      );
      expect(posted, isEmpty);
    });
  });

  group('the coordinator', () {
    setUp(UpdateCoordinator.resetForTests);

    test(
      'follows updateStatusChanged and asks for a check on demand',
      () async {
        final c = _EventClient()..answer = {'available': release('2.0.0')};
        final u = UpdateCoordinator.forClient(c);
        await u.refreshRelease();
        expect(u.release!.available!.version, '2.0.0');
        await u.refreshRelease(check: true);
        expect(c.params.last, {'refresh': true});
        c.push('updateStatusChanged', {'current': release('2.0.0')});
        await Future<void>.delayed(Duration.zero);
        expect(u.release!.available, isNull);
        expect(u.release!.current!.version, '2.0.0');
      },
    );

    test('a bridge without a release watch leaves it unknown', () async {
      final c = _EventClient()..error = NexusQError('unknown_method', 'x');
      final u = UpdateCoordinator.forClient(c);
      await u.refreshRelease();
      expect(u.release, isNull);
    });
  });

  testWidgets('the card: headline, and every item with its title and text', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: WhatsNewList(release: Release.fromJson(release('2.0.0'))!),
        ),
      ),
    );
    expect(find.text('Quieter when nothing plays'), findsOneWidget);
    expect(find.text('Quiet when idle'), findsOneWidget);
    expect(find.text('The Q sleeps deeper.'), findsOneWidget);
    expect(find.byIcon(Icons.bolt), findsOneWidget);
    expect(
      find.byIcon(Icons.auto_awesome),
      findsOneWidget,
      reason: 'rocket -> new',
    );
  });
}
