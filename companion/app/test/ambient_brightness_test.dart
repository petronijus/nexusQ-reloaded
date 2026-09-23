import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexusq_companion/protocol/client.dart';
import 'package:nexusq_companion/protocol/mock_client.dart';
import 'package:nexusq_companion/protocol/models.dart';
import 'package:nexusq_companion/state/device_controller.dart';
import 'package:nexusq_companion/widgets/ambient_brightness.dart';

/// A bridge from before ambient brightness: its state has no `ambient`.
class _PreAmbientClient extends MockClient {
  @override
  Future<Map<String, dynamic>> call(String method, [Map<String, dynamic>? params]) async {
    final r = await super.call(method, params);
    if (method == 'getState') return Map.of(r)..remove('ambient');
    return r;
  }
}

/// A Q whose time zone has no coordinates: the bridge refuses.
class _NoLocationClient extends MockClient {
  @override
  Future<Map<String, dynamic>> call(String method, [Map<String, dynamic>? params]) {
    if (method == 'setAmbient') {
      return Future.error(NexusQError('unavailable', "the Nexus Q's time zone has no known location"));
    }
    return super.call(method, params);
  }
}

Future<DeviceController> _started(NexusQClient c) async {
  final ctl = DeviceController(c);
  final hydrated = Completer<void>();
  void check() {
    if (ctl.state.connected && ctl.state.deviceName != 'Nexus Q' && !hydrated.isCompleted) {
      hydrated.complete();
    }
  }
  ctl.addListener(check);
  await ctl.start();
  await hydrated.future.timeout(const Duration(seconds: 2));
  ctl.removeListener(check);
  return ctl;
}

void main() {
  group('controller', () {
    test('the ambient state arrives with getState', () async {
      final ctl = await _started(MockClient());
      expect(ctl.state.ambient, isNotNull);
      expect(ctl.state.ambient!.zone, 'Europe/Prague');
      await ctl.setAmbient(true);
      expect(ctl.state.ambient!.enabled, isTrue);
      ctl.dispose();
    });

    test('a pre-ambient bridge offers no switch and ignores the intent', () async {
      final ctl = await _started(_PreAmbientClient());
      expect(ctl.state.ambient, isNull);
      await ctl.setAmbient(true);
      expect(ctl.state.ambient, isNull);
      ctl.dispose();
    });

    test('a refusal is undone and shown', () async {
      final ctl = await _started(_NoLocationClient());
      await ctl.setAmbient(true);
      expect(ctl.state.ambient!.enabled, isFalse, reason: 'the switch must not lie');
      expect(ctl.ambientError, contains('no known location'));
      ctl.dispose();
    });

    test('the level the Q pushes at dusk reaches the app', () {
      final s = DeviceState();
      s.applyJson({
        'ambient': {'enabled': true, 'level': 64, 'clockSynced': true,
                    'location': {'zone': 'Europe/Prague', 'lat': 50.08, 'lon': 14.43}},
      });
      expect(s.ambient!.level, 64);
    });
  });

  group('widget', () {
    Future<void> pump(WidgetTester t, AmbientState a, {int maximum = 200, ValueChanged<bool>? onChanged}) {
      return t.pumpWidget(MaterialApp(
        home: Scaffold(
          body: AmbientBrightnessTile(ambient: a, maximum: maximum, onChanged: onChanged ?? (_) {}),
        ),
      ));
    }

    testWidgets('off names where the sun is taken from', (t) async {
      await pump(t, const AmbientState(zone: 'Europe/Prague'));
      expect(find.textContaining('Europe/Prague'), findsOneWidget);
    });

    testWidgets('on shows how far it has dimmed', (t) async {
      await pump(t, const AmbientState(enabled: true, level: 50, zone: 'Europe/Prague'), maximum: 200);
      expect(find.textContaining('25 %'), findsOneWidget);
      await pump(t, const AmbientState(enabled: true, level: 200, zone: 'Europe/Prague'), maximum: 200);
      expect(find.textContaining('Daylight'), findsOneWidget);
    });

    testWidgets('an unsynced clock is explained', (t) async {
      await pump(t, const AmbientState(enabled: true, clockSynced: false, zone: 'Europe/Prague'));
      expect(find.textContaining('Waiting for network time'), findsOneWidget);
    });

    testWidgets('no location: the switch is disabled', (t) async {
      bool? got;
      await pump(t, const AmbientState(), onChanged: (v) => got = v);
      await t.tap(find.byKey(const Key('ambient-switch')));
      expect(got, isNull);
      expect(find.textContaining('no known location'), findsOneWidget);
    });

    testWidgets('the switch reports the new value', (t) async {
      bool? got;
      await pump(t, const AmbientState(zone: 'Europe/Prague'), onChanged: (v) => got = v);
      await t.tap(find.byKey(const Key('ambient-switch')));
      expect(got, isTrue);
    });
  });
}
