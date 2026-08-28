import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexusq_companion/protocol/client.dart';
import 'package:nexusq_companion/screens/settings_screen.dart';

/// Renaming the Q used to be reachable only through the Bluetooth setup flow.
/// These tests cover the LAN rename in Settings, and specifically the shapes
/// that a green-looking test can miss: the request that actually leaves the
/// phone, cancel sending nothing, and a device-side refusal not being shown as
/// success.
class _FakeClient implements NexusQClient {
  _FakeClient({this.failSetName = false, this.latency = Duration.zero});

  /// A real setName runs hostnamectl + a file write + an avahi restart. With
  /// zero latency the spinner state never exists, so a lockout bug there would
  /// be invisible — the exact trap the EQ card fell into three releases running.
  final Duration latency;
  final bool failSetName;

  final List<(String, Map<String, dynamic>?)> calls = [];
  final _events = StreamController<NexusQEvent>.broadcast();
  final _conn = StreamController<bool>.broadcast();

  String name = 'Nexus Q';
  String room = '';

  @override
  Stream<NexusQEvent> get events => _events.stream;
  @override
  Stream<bool> get connection => _conn.stream;
  @override
  bool get needsSupervision => false;
  @override
  Future<void> connect() async {}
  @override
  void disconnect() {}
  @override
  Future<void> close() async {
    await _events.close();
    await _conn.close();
  }

  @override
  void notify(String method, [Map<String, dynamic>? params]) {
    calls.add((method, params));
  }

  @override
  Future<Map<String, dynamic>> call(String method,
      [Map<String, dynamic>? params]) async {
    calls.add((method, params));
    if (latency != Duration.zero) await Future.delayed(latency);
    switch (method) {
      case 'getDeviceInfo':
        return {'name': name, 'model': 'steelhead', 'room': room};
      case 'setName':
        if (failSetName) throw Exception('hostname change failed');
        // The device trims and echoes back what it actually stored.
        name = (params!['name'] as String).trim();
        room = (params['room'] as String? ?? '').trim();
        return {'name': name, 'room': room, 'hostname': 'x', 'mdns': 'x.local'};
      case 'listServices':
        return {'services': <Map<String, dynamic>>[]};
      case 'getDesktop':
        return {'desktop': false};
    }
    return {};
  }

  List<(String, Map<String, dynamic>?)> get setNames =>
      calls.where((c) => c.$1 == 'setName').toList();
}

/// SettingsScreen polls every 3 s, so `pumpAndSettle` can never settle — it
/// keeps finding a pending timer and times out. Pump a bounded number of frames
/// instead; that is enough for a dialog transition and an awaited call.
Future<void> _settle(WidgetTester t) async {
  for (var i = 0; i < 12; i++) {
    await t.pump(const Duration(milliseconds: 50));
  }
}

Future<void> _pump(WidgetTester t, _FakeClient c) async {
  await t.pumpWidget(MaterialApp(home: SettingsScreen(client: c)));
  await _settle(t);
}

void main() {
  testWidgets('shows the device name and renames it', (t) async {
    final c = _FakeClient();
    await _pump(t, c);
    expect(find.text('Nexus Q'), findsOneWidget);

    await t.tap(find.text('Nexus Q'));
    await _settle(t);

    await t.enterText(find.byType(TextField).first, '  Šumperák  ');
    await t.enterText(find.byType(TextField).last, 'cottage');
    await t.tap(find.text('Save'));
    await _settle(t);

    expect(c.setNames.length, 1);
    expect(c.setNames.first.$2, {'name': 'Šumperák', 'room': 'cottage'});
    // The label follows the device's echo, not the raw text field.
    expect(find.text('Šumperák'), findsOneWidget);
    expect(find.textContaining('In cottage'), findsOneWidget);
  });

  testWidgets('cancel sends nothing and keeps the old name', (t) async {
    final c = _FakeClient();
    await _pump(t, c);

    await t.tap(find.text('Nexus Q'));
    await _settle(t);
    await t.enterText(find.byType(TextField).first, 'Discarded');
    await t.tap(find.text('Cancel'));
    await _settle(t);

    expect(c.setNames, isEmpty);
    expect(find.text('Nexus Q'), findsOneWidget);
    expect(find.text('Discarded'), findsNothing);
  });

  testWidgets('an empty name is not sent', (t) async {
    final c = _FakeClient();
    await _pump(t, c);

    await t.tap(find.text('Nexus Q'));
    await _settle(t);
    await t.enterText(find.byType(TextField).first, '   ');
    await t.tap(find.text('Save'));
    await _settle(t);

    expect(c.setNames, isEmpty);
    expect(find.text('Nexus Q'), findsOneWidget);
  });

  testWidgets('a refused rename shows an error and keeps the old name',
      (t) async {
    final c = _FakeClient(failSetName: true);
    await _pump(t, c);

    await t.tap(find.text('Nexus Q'));
    await _settle(t);
    await t.enterText(find.byType(TextField).first, 'Nope');
    await t.tap(find.text('Save'));
    await _settle(t);

    expect(c.setNames.length, 1);
    expect(find.textContaining('went wrong'), findsOneWidget);
    expect(find.text('Nexus Q'), findsOneWidget);
  });

  testWidgets('the tile is locked while the rename is in flight', (t) async {
    final c = _FakeClient(latency: const Duration(milliseconds: 300));
    await _pump(t, c);

    await t.tap(find.text('Nexus Q'));
    await _settle(t);
    await t.enterText(find.byType(TextField).first, 'Slow');
    await t.tap(find.text('Save'));
    await t.pump(); // dialog gone, request in flight
    await t.pump(const Duration(milliseconds: 50));

    expect(find.byType(CircularProgressIndicator), findsWidgets);
    await _settle(t);
    expect(find.text('Slow'), findsOneWidget);
  });
}
