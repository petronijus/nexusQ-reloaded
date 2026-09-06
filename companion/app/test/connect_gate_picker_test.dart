// More than one Nexus Q on the LAN: the gate lists them under each other and
// the user picks one; a single Q still connects by itself; the "Switch" entry
// (pickerOnly) lists even a single one. Discovery and the client are injected,
// so no socket is dialled and the ambient network plays no part.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexusq_companion/protocol/client.dart';
import 'package:nexusq_companion/protocol/discovery.dart';
import 'package:nexusq_companion/screens/connect_gate.dart';

class _QuietClient implements NexusQClient {
  _QuietClient(this.picked);
  final Discovered picked;
  @override
  Future<Map<String, dynamic>> call(String method, [Map<String, dynamic>? params]) async =>
      {'name': picked.name};
  @override
  Stream<NexusQEvent> get events => const Stream.empty();
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

const praha = Discovered('Nexus Q', '10.0.0.10', 45015);
const chalupa = Discovered('Nexus Q Šumperák', '10.0.0.20', 45015);

Widget gate({required List<Discovered> devices, bool pickerOnly = false, List<Discovered>? picked}) =>
    MaterialApp(
      home: ConnectGate(
        pickerOnly: pickerOnly,
        discoverAll: () => Stream.fromIterable(devices),
        clientFactory: (d) {
          picked?.add(d);
          return _QuietClient(d);
        },
      ),
    );

void main() {
  testWidgets('two devices → a list, and the tapped one is the one connected', (tester) async {
    final picked = <Discovered>[];
    await tester.pumpWidget(gate(devices: [praha, chalupa], picked: picked));
    await tester.pump(); // the stream delivers + closes on microtasks
    await tester.pump();

    expect(find.text('Choose your Nexus Q'), findsOneWidget);
    expect(find.text('Nexus Q'), findsOneWidget);
    expect(find.text('Nexus Q Šumperák'), findsOneWidget);
    expect(find.text('10.0.0.20:45015'), findsOneWidget);
    expect(picked, isEmpty, reason: 'nothing is auto-joined when there is a choice');

    await tester.tap(find.byKey(const ValueKey('device-10.0.0.20:45015')));
    await tester.pump();
    expect(picked.map((d) => d.host), ['10.0.0.20']);
    // HomeScreen is up: the gate's own headline is gone.
    expect(find.text('Choose your Nexus Q'), findsNothing);
  });

  testWidgets('one device → connects by itself, no list', (tester) async {
    final picked = <Discovered>[];
    await tester.pumpWidget(gate(devices: [praha], picked: picked));
    await tester.pump();
    await tester.pump();
    expect(picked.map((d) => d.host), ['10.0.0.10']);
    expect(find.text('Choose your Nexus Q'), findsNothing);
  });

  testWidgets('pickerOnly lists even a single device instead of joining it', (tester) async {
    final picked = <Discovered>[];
    await tester.pumpWidget(gate(devices: [praha], pickerOnly: true, picked: picked));
    await tester.pump();
    await tester.pump();
    expect(picked, isEmpty);
    expect(find.text('Your Nexus Q'), findsOneWidget);
    expect(find.byKey(const ValueKey('device-10.0.0.10:45015')), findsOneWidget);
  });

  testWidgets('duplicate records collapse to one row', (tester) async {
    await tester.pumpWidget(gate(devices: [chalupa, chalupa]));
    await tester.pump();
    await tester.pump();
    // Only one → auto-joined; had the duplicate counted, a picker would show.
    expect(find.text('Choose your Nexus Q'), findsNothing);
  });

  testWidgets('nothing found → the manual fallback, as before', (tester) async {
    await tester.pumpWidget(gate(devices: const []));
    await tester.pump();
    await tester.pump();
    expect(find.text('No Nexus Q found'), findsOneWidget);
    expect(find.text('Search again'), findsOneWidget);
  });
}
