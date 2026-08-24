import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexusq_companion/models/eq.dart';
import 'package:nexusq_companion/protocol/client.dart';
import 'package:nexusq_companion/protocol/mock_client.dart';
import 'package:nexusq_companion/widgets/eq_card.dart';
import 'package:nexusq_companion/widgets/eq_curve.dart';

/// Records what actually reached the device — the point of most of these tests
/// is the request shape, because a wrong one writes wrong coefficients into a
/// 25 W amplifier.
class _RecordingClient implements NexusQClient {
  _RecordingClient(
      {this.supported = true, this.parametric = true, this.connected = true,
       this.latency = Duration.zero});

  /// A real setEq is ~300 ms: fourteen I2C coefficient writes. Modelling that
  /// matters — with zero latency the card is never in its "sending" state, so a
  /// lockout there is invisible to the tests.
  final Duration latency;

  final bool supported;
  final bool parametric;
  bool connected;

  List<EqBand> get bandsModel =>
      bands.map((b) => EqBand.fromJson(b)).toList();

  /// Bring the link up the way the real client does: a `connection` event.
  void goOnline() {
    connected = true;
    _conn.add(true);
  }
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
    if (!connected) throw NexusQError('unavailable', 'not connected');
    if (latency > Duration.zero) await Future<void>.delayed(latency);
    switch (method) {
      case 'getEq':
        return _state;
      case 'setEq':
        // Apply, like the daemon does, then echo. A fake that returns unchanged
        // defaults quietly undoes every gesture and hides real bugs behind
        // green tests.
        final incoming = params?['bands'];
        if (incoming is List) {
          for (var i = 0; i < incoming.length && i < bands.length; i++) {
            final b = incoming[i];
            if (b is! Map) continue;
            for (final k in ['freq_hz', 'gain_db', 'q']) {
              if (b[k] is num) bands[i][k] = (b[k] as num).toDouble();
            }
          }
        }
        if (params?['bass_db'] is num) {
          bands.first['gain_db'] = (params!['bass_db'] as num).toDouble();
        }
        if (params?['treble_db'] is num) {
          bands.last['gain_db'] = (params!['treble_db'] as num).toDouble();
        }
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

/// The card ships inside a genuinely scrollable page, and that is the whole
/// point: Flutter's gesture arena hands vertical drags to the nearest
/// scrollable, so a curve drag competes with the scroll. An earlier version of
/// this host had a scroll view with nothing to scroll — it never entered the
/// arena, so the drag test passed while dragging was broken in the real app.
/// The filler below makes the competition real.
final _scroll = ScrollController();

Widget _host(NexusQClient client) => MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          controller: _scroll,
          child: SizedBox(
            width: 380,
            child: Column(children: [
              EqCard(client: client),
              const SizedBox(height: 2000), // makes the page actually scroll
            ]),
          ),
        ),
      ),
    );

void main() {
  setUp(() {
    if (_scroll.hasClients) _scroll.jumpTo(0);
  });

  testWidgets('dragging outside the curve still scrolls the page',
      (tester) async {
    final client = _RecordingClient();
    await tester.pumpWidget(_host(client));
    await tester.pumpAndSettle();

    // The curve may not swallow the whole page: below it is filler, and a drag
    // there must still scroll or the EQ has made the screen unusable.
    final curve = tester.getRect(find.byType(EqCurve));
    await tester.dragFrom(
        Offset(curve.center.dx, curve.bottom + 300), const Offset(0, -120));
    await tester.pumpAndSettle();

    expect(_scroll.offset, greaterThan(0));
    expect(client.calls.where((c) => c.$1 == 'setEq'), isEmpty);
  });

  testWidgets('draws the curve and the presets once loaded', (tester) async {
    final client = MockClient();
    await tester.pumpWidget(_host(client));
    await tester.pumpAndSettle();

    // No 'Equalizer' text inside the card on purpose: the section header above
    // it already says that, and having it twice just ate vertical space.
    expect(find.text('Equalizer'), findsNothing);
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
    final before = _scroll.offset;
    await tester.tapAt(curve.center); // arm the band under the finger
    await tester.pumpAndSettle();
    await tester.dragFrom(curve.center, const Offset(0, -30));
    await tester.pumpAndSettle();

    // THE assertion this file was missing: dragging a handle must not also
    // scroll the page. The first fix made the curve respond while the scroll
    // kept running underneath, and a test that only checked setEq was happy.
    expect(_scroll.offset, before,
        reason: 'the page scrolled while a handle was dragged');

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

  testWidgets('drags keep working while a slow write is in flight',
      (tester) async {
    // The real device takes ~300 ms per setEq. If the card goes dead for that
    // window, a normal person dragging one band after another finds that
    // "nothing can be grabbed any more".
    final client = _RecordingClient(latency: const Duration(milliseconds: 300));
    await tester.pumpWidget(_host(client));
    // pumpAndSettle does not move the clock when nothing schedules a frame, so
    // the delayed replies need explicit pumps — and _load makes TWO sequential
    // calls (getEq then listEqPresets), so one latency is not enough.
    for (var i = 0; i < 4; i++) {
      await tester.pump(const Duration(milliseconds: 400));
    }

    final curve = tester.getRect(find.byType(EqCurve));
    await tester.tapAt(curve.center);
    await tester.pump();
    await tester.dragFrom(curve.center, const Offset(0, -25));
    await tester.pump(const Duration(milliseconds: 50)); // write still in flight

    final before = client.calls.where((c) => c.$1 == 'setEq').length;
    await tester.tapAt(Offset(curve.left + curve.width * 0.23, curve.center.dy));
    await tester.pump();
    await tester.dragFrom(
        Offset(curve.left + curve.width * 0.23, curve.center.dy),
        const Offset(0, -25));
    for (var i = 0; i < 4; i++) {
      await tester.pump(const Duration(milliseconds: 400));
    }

    expect(client.calls.where((c) => c.$1 == 'setEq').length,
        greaterThan(before),
        reason: 'a drag during an in-flight write was swallowed');
  });

  testWidgets('a second drag still grabs a handle', (tester) async {
    // Petr on 1.15.2: the first handle moved fine, then nothing could be
    // grabbed. One drag proving the gesture works is not enough.
    final client = _RecordingClient();
    await tester.pumpWidget(_host(client));
    await tester.pumpAndSettle();

    final curve = tester.getRect(find.byType(EqCurve));
    // band 3 (900 Hz) is near the middle of a log axis; band 0 (100 Hz) at ~23 %
    final targets = [curve.center, Offset(curve.left + curve.width * 0.23, curve.center.dy)];

    for (var n = 0; n < targets.length; n++) {
      final before = client.calls.where((c) => c.$1 == 'setEq').length;
      await tester.tapAt(targets[n]);        // arm this band
      await tester.pumpAndSettle();
      await tester.dragFrom(targets[n], const Offset(0, -25));
      await tester.pumpAndSettle();
      expect(client.calls.where((c) => c.$1 == 'setEq').length,
          greaterThan(before),
          reason: 'drag #${n + 1} did not reach the device');
    }
  });

  testWidgets('a drag changes gain only — never the band frequency',
      (tester) async {
    // Handles used to move in both axes, which silently retuned bands nobody
    // asked to retune. Petr: "jenom vertikálně nahoru a dolu by mely jit tahat".
    final client = _RecordingClient();
    await tester.pumpWidget(_host(client));
    await tester.pumpAndSettle();

    final curve = tester.getRect(find.byType(EqCurve));
    final freqsBefore =
        client.bands.map((b) => (b['freq_hz'] as num).toDouble()).toList();

    await tester.tapAt(curve.center);
    await tester.pumpAndSettle();
    // drag diagonally: the sideways component must be ignored
    await tester.dragFrom(curve.center, const Offset(90, -30));
    await tester.pumpAndSettle();

    final sent = (client.calls.last.$2!['bands'] as List)
        .map((b) => ((b as Map)['freq_hz'] as num).toDouble())
        .toList();
    expect(sent, freqsBefore, reason: 'a drag retuned a band');
    expect(
        (client.calls.last.$2!['bands'] as List)
            .any((b) => ((b as Map)['gain_db'] as num) > 0.5),
        isTrue,
        reason: 'the vertical part of the drag was ignored too');
  });

  testWidgets('the whole column grabs a band, not just the dot',
      (tester) async {
    // "ty hit arey jsou hodne maly" — with fixed frequencies the entire
    // vertical strip belongs to one band, so a touch near the top of the plot
    // must still grab it.
    final client = _RecordingClient();
    await tester.pumpWidget(_host(client));
    await tester.pumpAndSettle();

    final curve = tester.getRect(find.byType(EqCurve));
    await tester.tapAt(Offset(curve.center.dx, curve.top + 8));
    await tester.pumpAndSettle();
    await tester.dragFrom(
        Offset(curve.center.dx, curve.top + 8), const Offset(0, 40));
    await tester.pumpAndSettle();

    expect(client.calls.where((c) => c.$1 == 'setEq'), isNotEmpty,
        reason: 'a touch away from the dot did not grab the band');
  });

  testWidgets('the outer handles sit on the edges of the plot', (tester) async {
    // "proc ten prvni bod neni uplne vlevo a ten posledni vpravo?"
    final client = _RecordingClient();
    await tester.pumpWidget(_host(client));
    await tester.pumpAndSettle();

    final curve = tester.getRect(find.byType(EqCurve));
    final w = curve.width;
    expect(plotX(client.bandsModel, client.bandsModel.first.freqHz, w),
        lessThan(w * 0.1));
    expect(plotX(client.bandsModel, client.bandsModel.last.freqHz, w),
        greaterThan(w * 0.9));
  });

  testWidgets('an un-armed curve does not swallow the drag — the page scrolls',
      (tester) async {
    // The contract Petr asked for: until you tap a point, the curve is inert and
    // the page behaves normally.
    final client = _RecordingClient();
    await tester.pumpWidget(_host(client));
    await tester.pumpAndSettle();

    final curve = tester.getRect(find.byType(EqCurve));
    await tester.dragFrom(curve.center, const Offset(0, -120));
    await tester.pumpAndSettle();

    expect(_scroll.offset, greaterThan(0), reason: 'the page should have scrolled');
    expect(client.calls.where((c) => c.$1 == 'setEq'), isEmpty);
  });

  testWidgets('arming one band then another moves the second, not the first',
      (tester) async {
    final client = _RecordingClient();
    await tester.pumpWidget(_host(client));
    await tester.pumpAndSettle();

    final curve = tester.getRect(find.byType(EqCurve));
    final firstX = curve.left + curve.width * 0.02;   // band 0, on the left edge
    final lastX = curve.right - curve.width * 0.02;   // band 6, on the right edge

    await tester.tapAt(Offset(firstX, curve.center.dy));
    await tester.pumpAndSettle();
    await tester.dragFrom(Offset(firstX, curve.center.dy), const Offset(0, -30));
    await tester.pumpAndSettle();

    await tester.tapAt(Offset(lastX, curve.center.dy));
    await tester.pumpAndSettle();
    await tester.dragFrom(Offset(lastX, curve.center.dy), const Offset(0, -30));
    await tester.pumpAndSettle();

    final sent = (client.calls.last.$2!['bands'] as List)
        .map((b) => ((b as Map)['gain_db'] as num).toDouble())
        .toList();
    expect(sent.first, greaterThan(0.5), reason: 'the first band lost its gain');
    expect(sent.last, greaterThan(0.5), reason: 'the second arming did not take');
  });

  testWidgets('lays out without overflowing a narrow phone', (tester) async {
    // A RenderFlex overflow paints a striped warning bar on a real device. This
    // surfaced by accident once (11 px, the band-editor row); a width test makes
    // it deliberate. Flutter fails the test on overflow, so rendering is the
    // assertion.
    final client = _RecordingClient();
    tester.view.physicalSize = const Size(320 * 3, 640 * 3);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: SingleChildScrollView(child: EqCard(client: client))),
    ));
    await tester.pumpAndSettle();

    // widest labels: a shelf name, a kHz frequency and a two-digit dB value
    client.bands.last['gain_db'] = -12.0;
    final curve = tester.getRect(find.byType(EqCurve));
    await tester.tapAt(Offset(curve.right - 4, curve.center.dy));
    await tester.pumpAndSettle();
    expect(find.byType(EqCurve), findsOneWidget);
  });

  testWidgets('armed, a drag starting outside the plot scrolls immediately',
      (tester) async {
    // Petr: "kdyz se tapne a rovnou draguje mimo ten equalizer, tak uz to zacne
    // scrollovat" — it used to take one tap to disarm and a second gesture to
    // scroll, because the whole list had been frozen. The claim is now scoped to
    // the plot instead.
    final client = _RecordingClient();
    await tester.pumpWidget(_host(client));
    await tester.pumpAndSettle();

    final curve = tester.getRect(find.byType(EqCurve));
    await tester.tapAt(curve.center); // arm
    await tester.pumpAndSettle();

    final before = _scroll.offset;
    await tester.dragFrom(
        Offset(curve.center.dx, curve.bottom + 300), const Offset(0, -120));
    await tester.pumpAndSettle();

    expect(_scroll.offset, greaterThan(before),
        reason: 'an armed EQ froze the whole page instead of just its plot');
  });

  testWidgets('armed, a drag switches to whatever band it started on',
      (tester) async {
    final client = _RecordingClient();
    await tester.pumpWidget(_host(client));
    await tester.pumpAndSettle();

    final curve = tester.getRect(find.byType(EqCurve));
    await tester.tapAt(Offset(curve.left + 4, curve.center.dy)); // arm band 0
    await tester.pumpAndSettle();

    // now drag the LAST band directly, without tapping it first
    await tester.dragFrom(
        Offset(curve.right - 4, curve.center.dy), const Offset(0, -30));
    await tester.pumpAndSettle();

    final sent = (client.calls.last.$2!['bands'] as List)
        .map((b) => ((b as Map)['gain_db'] as num).toDouble())
        .toList();
    expect(sent.last, greaterThan(0.5),
        reason: 'the drag did not move the band it started on');
    expect(sent.first, closeTo(0, 0.05),
        reason: 'it moved the previously armed band instead');
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

    expect(find.textContaining('device system update'), findsOneWidget);
    // nothing may be sent to a device that cannot run it
    final r0 = tester.getRect(find.byType(EqCurve));
    await tester.tapAt(r0.center);
    await tester.pumpAndSettle();
    await tester.dragFrom(r0.center, const Offset(0, -30));
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
    await tester.tapAt(Offset(r.left + r.width * 0.23, r.center.dy));
    await tester.pumpAndSettle();
    await tester.dragFrom(
        Offset(r.left + r.width * 0.23, r.center.dy), const Offset(0, -30));
    await tester.pumpAndSettle();

    final sets = client.calls.where((c) => c.$1 == 'setEq').toList();
    expect(sets, isNotEmpty);
    expect(sets.last.$2!.containsKey('bands'), isFalse);
    expect(sets.last.$2!.containsKey('bass_db'), isTrue);
  });

  testWidgets('a cold mount before the link is up waits, it does not accuse the EQ',
      (tester) async {
    // Regression: the card used to render "EQ unavailable: NexusQError not
    // connected" because it loads in initState, before the client connects.
    final client = _RecordingClient(connected: false);
    await tester.pumpWidget(_host(client));
    await tester.pumpAndSettle();

    expect(find.textContaining('unavailable'), findsNothing);
    expect(find.textContaining('not connected'), findsNothing);
    expect(find.text('Waiting for the Q…'), findsOneWidget);

    client.goOnline();
    await tester.pumpAndSettle();

    expect(find.text('Waiting for the Q…'), findsNothing);
    expect(find.byType(EqCurve), findsOneWidget);
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
