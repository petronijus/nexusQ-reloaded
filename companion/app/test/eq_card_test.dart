import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexusq_companion/protocol/client.dart';
import 'package:nexusq_companion/protocol/mock_client.dart';
import 'package:nexusq_companion/widgets/eq_card.dart';

/// A device whose kernel predates r49: getEq answers, but supported=false.
class _UnsupportedClient implements NexusQClient {
  final _events = StreamController<NexusQEvent>.broadcast();
  final _conn = StreamController<bool>.broadcast();
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
  Future<Map<String, dynamic>> call(String method,
      [Map<String, dynamic>? params]) async {
    if (method == 'getEq') {
      return {'supported': false, 'bass_db': 0.0, 'treble_db': 0.0};
    }
    throw NexusQError('unknown_method', method);
  }

  @override
  void notify(String method, [Map<String, dynamic>? params]) {}
}

Widget _host(NexusQClient client) => MaterialApp(
      home: Scaffold(body: SingleChildScrollView(child: EqCard(client: client))),
    );

void main() {
  testWidgets('renders both sliders and applies a change end-to-end',
      (tester) async {
    final client = MockClient();
    await tester.pumpWidget(_host(client));
    await tester.pump(); // let getEq resolve

    expect(find.text('Equalizer'), findsOneWidget);
    expect(find.text('Bass'), findsOneWidget);
    expect(find.text('Treble'), findsOneWidget);
    expect(find.byType(Slider), findsNWidgets(2));

    // Flat is disabled while the EQ is already flat.
    final flatBtn = tester.widget<TextButton>(find.widgetWithText(TextButton, 'Flat'));
    expect(flatBtn.onPressed, isNull);

    // Drag the bass slider fully right -> setEq lands on the (mock) device.
    await tester.drag(find.byType(Slider).first, const Offset(300, 0));
    await tester.pumpAndSettle();
    final st = await client.call('getEq');
    expect(st['bass_db'], 12.0);

    // The card now shows the value and Flat becomes tappable.
    expect(find.text('+12.0 dB'), findsOneWidget);
    final flatBtn2 =
        tester.widget<TextButton>(find.widgetWithText(TextButton, 'Flat'));
    expect(flatBtn2.onPressed, isNotNull);

    // Flat resets both knobs on the device.
    await tester.tap(find.widgetWithText(TextButton, 'Flat'));
    await tester.pumpAndSettle();
    final st2 = await client.call('getEq');
    expect(st2['bass_db'], 0.0);
    expect(st2['treble_db'], 0.0);
    await client.close();
  });

  testWidgets('an eqChanged event from another client reconciles the sliders',
      (tester) async {
    final client = MockClient();
    await tester.pumpWidget(_host(client));
    await tester.pump();

    // Another app instance sets the EQ -> our card follows the event.
    await client.call('setEq', {'treble_db': -6.0});
    await tester.pumpAndSettle();
    expect(find.text('−6.0 dB'), findsOneWidget);
    await client.close();
  });

  testWidgets('pre-r49 kernel: sliders disabled with the update hint',
      (tester) async {
    final client = _UnsupportedClient();
    await tester.pumpWidget(_host(client));
    await tester.pump();

    for (final s in tester.widgetList<Slider>(find.byType(Slider))) {
      expect(s.onChanged, isNull);
    }
    expect(find.textContaining('kernel r49+'), findsOneWidget);
    await client.close();
  });
}
