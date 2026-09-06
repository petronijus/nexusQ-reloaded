// More than one Nexus Q on the LAN: the gate lists them under each other and
// the user picks one; a single Q still connects by itself; the "Switch" entry
// (pickerOnly) lists even a single one. Discovery and the client are injected,
// so no socket is dialled and the ambient network plays no part.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexusq_companion/protocol/client.dart';
import 'package:nexusq_companion/protocol/discovery.dart';
import 'package:nexusq_companion/protocol/glance.dart';
import 'package:nexusq_companion/protocol/models.dart';
import 'package:nexusq_companion/screens/connect_gate.dart';
import 'package:nexusq_companion/screens/home_screen.dart';
import 'package:nexusq_companion/theme/nexusq_theme.dart';
import 'package:nexusq_companion/widgets/device_sphere.dart';

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

/// The glance is injected too: what each box answers about itself, by key.
/// Absent → the box does not answer (a `null` glance), like a box that is off.
Widget gate({
  required List<Discovered> devices,
  bool pickerOnly = false,
  List<Discovered>? picked,
  Map<String, DeviceGlance> glances = const {},
}) =>
    MaterialApp(
      home: ConnectGate(
        pickerOnly: pickerOnly,
        discoverAll: () => Stream.fromIterable(devices),
        glance: (d) async => glances[d.key],
        clientFactory: (d) {
          picked?.add(d);
          return _QuietClient(d);
        },
      ),
    );

DeviceSphere sphereOf(WidgetTester tester, Discovered d) => tester.widget<DeviceSphere>(find.descendant(
      of: find.byKey(ValueKey('device-${d.key}')),
      matching: find.byType(DeviceSphere),
    ));

Text nameOf(WidgetTester tester, Discovered d) => tester.widget<Text>(find.descendant(
      of: find.byKey(ValueKey('device-${d.key}')),
      matching: find.text(d.name),
    ));

void main() {
  testWidgets('two devices → a list, and the tapped one is the one connected', (tester) async {
    final picked = <Discovered>[];
    await tester.pumpWidget(gate(devices: [praha, chalupa], picked: picked, glances: {
      praha.key: const DeviceGlance(theme: 'blue'),
      chalupa.key: const DeviceGlance(theme: 'blue'),
    }));
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

  // The list draws each box as the home screen does: its sphere lit in ITS
  // theme, its name in the theme's colour (Petr, 2026-09-06: "místo ikonky
  // obrázky těch koulí… pokud má některá jinou ambientní barvu, ať je vidět").
  testWidgets('each row is a sphere lit in that box\'s own theme', (tester) async {
    await tester.pumpWidget(gate(devices: [praha, chalupa], glances: {
      praha.key: const DeviceGlance(theme: 'blue'),
      chalupa.key: const DeviceGlance(theme: 'warm'),
    }));
    await tester.pump();
    await tester.pump();

    final blue = sphereOf(tester, praha);
    final warm = sphereOf(tester, chalupa);
    expect(blue.on, isTrue);
    expect(warm.on, isTrue);
    expect(blue.colors, themeByName('blue').colors);
    expect(warm.colors, themeByName('warm').colors);
    expect(nameOf(tester, chalupa).style?.color, nameColorFor(themeByName('warm')));
    // no generic icon competes with the spheres once there is a list
    expect(find.byIcon(Icons.speaker_group_outlined), findsNothing);
    expect(find.byIcon(Icons.speaker_outlined), findsNothing);
  });

  testWidgets('off / muted → the sphere is dark, the name stays readable', (tester) async {
    await tester.pumpWidget(gate(devices: [praha, chalupa], glances: {
      praha.key: const DeviceGlance(theme: 'off'),
      chalupa.key: const DeviceGlance(theme: 'rose', muted: true),
    }));
    await tester.pump();
    await tester.pump();
    expect(sphereOf(tester, praha).on, isFalse);
    expect(sphereOf(tester, chalupa).on, isFalse);
    // black on black would erase the name: the Off theme falls back to white
    expect(nameOf(tester, praha).style?.color, NexusQColors.white);
  });

  testWidgets('a box that does not answer the glance is drawn dark and says so', (tester) async {
    await tester.pumpWidget(gate(devices: [praha, chalupa], glances: {
      praha.key: const DeviceGlance(theme: 'cool'),
    }));
    await tester.pump();
    await tester.pump();
    expect(sphereOf(tester, praha).on, isTrue);
    expect(sphereOf(tester, chalupa).on, isFalse);
    expect(find.text('10.0.0.20:45015 · not answering'), findsOneWidget);
    expect(find.text('10.0.0.10:45015'), findsOneWidget);
    // …and it is still pickable: the glance is a picture, not a gate
    await tester.tap(find.byKey(const ValueKey('device-10.0.0.20:45015')));
    await tester.pump();
    expect(find.text('Choose your Nexus Q'), findsNothing);
  });

  testWidgets('a late glance from a previous search cannot light the new list', (tester) async {
    // Only the FIRST search's glance at chalupa is slow; the second search's
    // gets an immediate "no answer". If the slow one still landed, it would
    // wrongly paint the second list's row warm.
    final chalupaAnswer = Completer<DeviceGlance?>();
    var chalupaAsked = 0;
    await tester.pumpWidget(MaterialApp(
      home: ConnectGate(
        discoverAll: () => Stream.fromIterable([praha, chalupa]),
        glance: (d) => d.key == chalupa.key && ++chalupaAsked == 1
            ? chalupaAnswer.future
            : Future.value(null),
        clientFactory: (d) => _QuietClient(d),
      ),
    ));
    await tester.pump();
    await tester.pump();
    await tester.tap(find.text('Search again'));
    await tester.pump();
    await tester.pump();
    chalupaAnswer.complete(const DeviceGlance(theme: 'warm')); // from round 1
    await tester.pump();
    // round 2's chalupa row is a fresh glance (also unanswered → null → dark)
    expect(sphereOf(tester, chalupa).on, isFalse);
  });
}
