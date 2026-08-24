import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexusq_companion/protocol/client.dart';
import 'package:nexusq_companion/protocol/mock_client.dart';
import 'package:nexusq_companion/widgets/eq_card.dart';
import 'package:nexusq_companion/widgets/eq_curve.dart';

/// Records what actually reached the device — the point of most of these tests
/// is the request shape, because a wrong one writes wrong coefficients into a
/// 25 W amplifier.
class _RecordingClient implements NexusQClient {
  _RecordingClient({this.supported = true, this.parametric = true});

  final bool supported;
  final bool parametric;
  final List<(String, Map<String, dynamic>?)> calls = [];
  final _events = StreamController<NexusQEvent>.broadcast();
  final _conn = StreamController<bool>.broadcast();

  double bass = 0, treble = 0;
  List<Map<String, dynamic>> bands = [
    for (final d in const [
      ['lowshelf', 100.0], ['peaking', 200.0], ['peaking', 430.0],
      ['peaking', 900.0], ['peaking', 1800.0], ['peaking', 3800.0],
      ['highshelf', 8000.0],
    ])
      {'type': d[0], 'freq_hz': d[1], 'gain_db': 0.0, 'q': 1.0, 'enabled': true}
  ];

  /// Same idea as the device: the peak of what the bands ask for. Hardcoding 0
  /// here would leave "auto" permanently disabled and the test permanently green
  /// for the wrong reason.
  double get _headroom => bands
      .where((b) => b['enabled'] as bool)
      .map((b) => (b['gain_db'] as num).toDouble())
      .fold(0.0, (a, b) => b > a ? b : a);

  Map<String, dynamic> get _state => {
        'supported': supported,
        if (parametric) ...{
          'bands': bands,
          'preamp_db': 0.0,
          'headroom_db': _headroom,
          'max_bands': 7,
          'limits': {
            'gain_db': 12.0,
            'freq_hz': [20.0, 20000.0],
            'q': [0.3, 8.0],
            'preamp_db': [-24.0, 0.0],
          },
        },
        'bass_db': bass,
        'treble_db': treble,
      };

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
    calls.add((method, params));
    switch (method) {
      case 'getEq':
        return _state;
      case 'setEq':
        return _state;
      case 'listEqPresets':
        if (!parametric) throw NexusQError('unknown_method', method);
        return {
          'presets': [
            {'id': 'flat', 'label': 'Flat', 'preamp_db': 0.0, 'bands': bands},
            {
              'id': 'bass',
              'label': 'Bass boost',
              'preamp_db': -6.0,
              'bands': [
                for (var i = 0; i < bands.length; i++)
                  {...bands[i], 'gain_db': i == 0 ? 6.0 : 0.0}
              ]
            },
          ]
        };
    }
    throw NexusQError('unknown_method', method);
  }

  @override
  void notify(String method, [Map<String, dynamic>? params]) {}
}

Widget _host(NexusQClient client, {bool compact = false}) => MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
            child: SizedBox(
                width: 380, child: EqCard(client: client, compact: compact))),
      ),
    );

void main() {
  testWidgets('draws the curve and the presets once loaded', (tester) async {
    final client = MockClient();
    await tester.pumpWidget(_host(client));
    await tester.pumpAndSettle();

    expect(find.text('Equalizer'), findsOneWidget);
    expect(find.byType(EqCurve), findsOneWidget);
    expect(find.text('Bass boost'), findsOneWidget);
    // per-band editor: the width/slope slider plus the preamp slider
    expect(find.byType(Slider), findsNWidgets(2));
  });

  testWidgets('dragging a handle commits bands, not bass/treble',
      (tester) async {
    final client = _RecordingClient();
    await tester.pumpWidget(_host(client));
    await tester.pumpAndSettle();

    final curve = tester.getRect(find.byType(EqCurve));
    // Band 3 (900 Hz) sits near the middle of a log 20 Hz..20 kHz axis.
    await tester.dragFrom(curve.center, const Offset(0, -30));
    await tester.pumpAndSettle();

    final sets = client.calls.where((c) => c.$1 == 'setEq').toList();
    expect(sets, isNotEmpty);
    expect(sets.last.$2!['bands'], isA<List>());
    expect(sets.last.$2!.containsKey('bass_db'), isFalse);
    // a drag upward must ask for a boost somewhere
    final asked = (sets.last.$2!['bands'] as List)
        .map((b) => (b as Map)['gain_db'] as num)
        .toList();
    expect(asked.any((g) => g > 0.5), isTrue);
  });

  testWidgets('a preset is applied as one setEq with its bands and preamp',
      (tester) async {
    final client = _RecordingClient();
    await tester.pumpWidget(_host(client));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Bass boost'));
    await tester.pumpAndSettle();

    final sets = client.calls.where((c) => c.$1 == 'setEq').toList();
    expect(sets, hasLength(1));
    expect(sets.single.$2!['preamp_db'], -6.0);
    expect((sets.single.$2!['bands'] as List).first['gain_db'], 6.0);
  });

  testWidgets('auto preamp asks the device to compute it', (tester) async {
    final client = _RecordingClient();
    client.bands[2]['gain_db'] = 8.0;
    await tester.pumpWidget(_host(client));
    await tester.pumpAndSettle();

    await tester.tap(find.text('auto'));
    await tester.pumpAndSettle();

    final sets = client.calls.where((c) => c.$1 == 'setEq').toList();
    expect(sets.single.$2!['auto_preamp'], isTrue);
  });

  testWidgets('warns when the curve can clip', (tester) async {
    final client = _RecordingClient();
    client.bands[0]['gain_db'] = 9.0;
    await tester.pumpWidget(_host(client));
    await tester.pumpAndSettle();

    expect(find.textContaining('clip'), findsOneWidget);
  });

  testWidgets('an old kernel disables the card but keeps it discoverable',
      (tester) async {
    final client = _RecordingClient(supported: false, parametric: false);
    await tester.pumpWidget(_host(client));
    await tester.pumpAndSettle();

    expect(find.text('Equalizer'), findsOneWidget);
    expect(find.textContaining('device system update'), findsOneWidget);
    // nothing may be sent to a device that cannot run it
    await tester.dragFrom(
        tester.getRect(find.byType(EqCurve)).center, const Offset(0, -30));
    await tester.pumpAndSettle();
    expect(client.calls.where((c) => c.$1 == 'setEq'), isEmpty);
  });

  testWidgets('an old daemon falls back to two shelves and the v1 shape',
      (tester) async {
    final client = _RecordingClient(parametric: false);
    await tester.pumpWidget(_host(client));
    await tester.pumpAndSettle();

    expect(find.textContaining('predates the parametric EQ'), findsOneWidget);

    // Only two handles exist here (100 Hz and 8 kHz); the middle of a log axis
    // is ~630 Hz and belongs to neither, so grab the low shelf explicitly.
    final r = tester.getRect(find.byType(EqCurve));
    await tester.dragFrom(
        Offset(r.left + r.width * 0.23, r.center.dy), const Offset(0, -30));
    await tester.pumpAndSettle();

    final sets = client.calls.where((c) => c.$1 == 'setEq').toList();
    expect(sets, isNotEmpty);
    expect(sets.last.$2!.containsKey('bands'), isFalse);
    expect(sets.last.$2!.containsKey('bass_db'), isTrue);
  });

  testWidgets('compact form hides the per-band editor', (tester) async {
    final client = MockClient();
    await tester.pumpWidget(_host(client, compact: true));
    await tester.pumpAndSettle();

    expect(find.byType(EqCurve), findsOneWidget);
    expect(find.text('Bass boost'), findsOneWidget); // presets stay
    expect(find.byType(Slider), findsNothing);       // editing does not
  });

  testWidgets('reconciles from an eqChanged pushed by another client',
      (tester) async {
    final client = MockClient();
    await tester.pumpWidget(_host(client));
    await tester.pumpAndSettle();

    await client.call('setEq', {'bass_db': 7.0});
    await tester.pumpAndSettle();

    // the low shelf handle should now be off zero; Flat becomes available
    final flat = tester.widget<TextButton>(
        find.ancestor(of: find.text('Flat'), matching: find.byType(TextButton)));
    expect(flat.onPressed, isNotNull);
  });
}
