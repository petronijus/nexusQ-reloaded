import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexusq_companion/protocol/client.dart';
import 'package:nexusq_companion/protocol/mock_client.dart';
import 'package:nexusq_companion/protocol/models.dart';
import 'package:nexusq_companion/state/device_controller.dart';
import 'package:nexusq_companion/widgets/ring_controls.dart';

/// A Q whose nexusqd predates `dark`: the bridge answers `unavailable`.
class _OldNexusqdClient extends MockClient {
  @override
  Future<Map<String, dynamic>> call(String method, [Map<String, dynamic>? params]) {
    if (method == 'setRing' || method == 'setRingSchedule') {
      return Future.error(NexusQError('unavailable', 'nexusqd rejected the ring setting'));
    }
    return super.call(method, params);
  }
}

/// A bridge from before the ring switch: its state has no `ring`.
class _PreRingClient extends MockClient {
  @override
  Future<Map<String, dynamic>> call(String method, [Map<String, dynamic>? params]) async {
    final r = await super.call(method, params);
    if (method == 'getState') return Map.of(r)..remove('ring');
    return r;
  }
}

/// Started AND hydrated: `getState` runs off the connection event, after
/// start() has returned, so wait until the controller has actually applied it.
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
    test('the ring state arrives with getState', () async {
      final ctl = await _started(MockClient());
      expect(ctl.state.ring, isNotNull);
      expect(ctl.state.ring!.on, isTrue);
      ctl.dispose();
    });

    test('a pre-ring bridge leaves no ring state, so no control is offered', () async {
      final ctl = await _started(_PreRingClient());
      expect(ctl.state.ring, isNull);
      await ctl.setRingOn(false); // must be a harmless no-op
      expect(ctl.state.ring, isNull);
      ctl.dispose();
    });

    test('switching by hand turns the schedule off', () async {
      final ctl = await _started(MockClient());
      await ctl.setRingSchedule(enabled: true, offAt: '22:30');
      expect(ctl.state.ring!.scheduleEnabled, isTrue);
      expect(ctl.state.ring!.offAt, '22:30');
      await ctl.setRingOn(false);
      expect(ctl.state.ring!.on, isFalse);
      expect(ctl.state.ring!.scheduleEnabled, isFalse);
      // the times are kept for the next time the schedule is enabled
      expect(ctl.state.ring!.offAt, '22:30');
      ctl.dispose();
    });

    test('a refused switch is undone and the reason is shown', () async {
      final ctl = await _started(_OldNexusqdClient());
      await ctl.setRingOn(false);
      expect(ctl.state.ring!.on, isTrue, reason: 'the switch must not lie');
      expect(ctl.ringError, contains('rejected'));
      ctl.dispose();
    });

    test('a scheduled switch pushed by the Q updates the app', () async {
      final client = MockClient();
      final ctl = await _started(client);
      final seen = Completer<void>();
      ctl.addListener(() {
        if (ctl.state.ring?.on == false && !seen.isCompleted) seen.complete();
      });
      // What the bridge broadcasts at 23:00 — no request from this phone.
      await client.call('setRing', {'on': false});
      await seen.future.timeout(const Duration(seconds: 1));
      ctl.dispose();
    });
  });

  group('widget', () {
    Future<void> pump(WidgetTester t, RingState ring,
        {ValueChanged<bool>? onRing,
        void Function({required bool enabled, String? offAt, String? onAt})? onSchedule,
        String? error}) {
      return t.pumpWidget(MaterialApp(
        home: Scaffold(
          body: RingControls(
            ring: ring,
            error: error,
            onRingChanged: onRing ?? (_) {},
            onScheduleChanged: onSchedule ?? ({required bool enabled, String? offAt, String? onAt}) {},
          ),
        ),
      ));
    }

    testWidgets('the time pickers only appear with the schedule on', (t) async {
      await pump(t, const RingState());
      expect(find.byKey(const Key('ring-off-at')), findsNothing);
      await pump(t, const RingState(scheduleEnabled: true, offAt: '22:15', onAt: '06:45'));
      expect(find.byKey(const Key('ring-off-at')), findsOneWidget);
      expect(find.text('22:15'), findsOneWidget);
      expect(find.text('06:45'), findsOneWidget);
    });

    testWidgets('an unsynced clock is explained, not silently ignored', (t) async {
      await pump(t, const RingState(scheduleEnabled: true, clockSynced: false));
      expect(find.textContaining('Waiting for network time'), findsOneWidget);
      await pump(t, const RingState(scheduleEnabled: false, clockSynced: false));
      expect(find.textContaining('Waiting for network time'), findsNothing);
    });

    testWidgets('the main switch reports the new value', (t) async {
      bool? got;
      await pump(t, const RingState(), onRing: (v) => got = v);
      await t.tap(find.byKey(const Key('ring-switch')));
      expect(got, isFalse);
    });

    testWidgets('the picker is 24 h and an unchanged time sends nothing', (t) async {
      var sent = 0;
      await pump(t, const RingState(scheduleEnabled: true),
          onSchedule: ({required bool enabled, String? offAt, String? onAt}) => sent++);
      await t.tap(find.byKey(const Key('ring-off-at')));
      await t.pumpAndSettle();
      expect(find.text('AM'), findsNothing, reason: 'the Q keeps 24 h time');
      await t.tap(find.text('OK'));
      await t.pumpAndSettle();
      expect(sent, 0);
    });

    test('times travel as zero-padded 24 h HH:MM', () {
      expect(formatRingTime(const TimeOfDay(hour: 7, minute: 5)), '07:05');
      expect(formatRingTime(const TimeOfDay(hour: 23, minute: 0)), '23:00');
      expect(parseRingTime('06:45'), const TimeOfDay(hour: 6, minute: 45));
    });
  });
}
