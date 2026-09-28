import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexusq_companion/protocol/client.dart';
import 'package:nexusq_companion/protocol/mock_client.dart';
import 'package:nexusq_companion/state/device_controller.dart';
import 'package:nexusq_companion/theme/nexusq_theme.dart';
import 'package:nexusq_companion/widgets/lights_section.dart';

/// The LIGHTS category (Petr, 2026-09-28): one section holding everything the
/// LED ring does, in this order — LED ring, schedule, brightness, ambient
/// brightness, light theme, visualisation — as flat rows with no grey card
/// behind the ring controls.

/// A bridge from before the ring switch: its state has no `ring`.
class _PreRingClient extends MockClient {
  @override
  Future<Map<String, dynamic>> call(String method, [Map<String, dynamic>? params]) async {
    final r = await super.call(method, params);
    if (method == 'getState') return Map.of(r)..remove('ring');
    return r;
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

Future<void> _pump(WidgetTester t, DeviceController ctl) async {
  // Tall enough that every row is laid out, so their positions can be compared.
  t.view.physicalSize = const Size(1080, 4000);
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
  await t.pumpWidget(MaterialApp(
    home: Scaffold(
      body: SingleChildScrollView(child: LightsSection(controller: ctl)),
    ),
  ));
}

double _top(WidgetTester t, String key) => t.getTopLeft(find.byKey(Key(key))).dy;

void main() {
  testWidgets('the rows come in the agreed order, the ring first', (t) async {
    final ctl = await t.runAsync(() => _started(MockClient()));
    await _pump(t, ctl!);
    // the ambient row exists only when the bridge reports it; the mock does
    expect(ctl.state.ambient, isNotNull);
    final order = [
      'ring-switch',
      'ring-schedule-switch',
      'lights-brightness',
      'ambient-switch',
      'lights-theme',
      'lights-visualization',
    ];
    for (var i = 0; i + 1 < order.length; i++) {
      expect(_top(t, order[i]), lessThan(_top(t, order[i + 1])),
          reason: '${order[i]} must sit above ${order[i + 1]}');
    }
    ctl.dispose();
  });

  testWidgets('no grey card behind any of it', (t) async {
    final ctl = await t.runAsync(() => _started(MockClient()));
    await _pump(t, ctl!);
    final grey = find.descendant(
      of: find.byType(LightsSection),
      matching: find.byWidgetPredicate((w) =>
          w is Card ||
          (w is Container && w.color == NexusQColors.surface) ||
          (w is Material && w.color == NexusQColors.surface)),
    );
    expect(grey, findsNothing);
    ctl.dispose();
  });

  testWidgets('without a ring state the rest of LIGHTS is still there', (t) async {
    final ctl = await t.runAsync(() => _started(_PreRingClient()));
    await _pump(t, ctl!);
    expect(find.byKey(const Key('ring-switch')), findsNothing);
    expect(find.byKey(const Key('lights-brightness')), findsOneWidget);
    expect(find.byKey(const Key('lights-theme')), findsOneWidget);
    expect(find.byKey(const Key('lights-visualization')), findsOneWidget);
    ctl.dispose();
  });
}
