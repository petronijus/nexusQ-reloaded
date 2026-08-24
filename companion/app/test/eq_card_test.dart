import 'dart:async';

import 'package:flutter/services.dart';
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
        if (!parametric || !presetsVerb) {
          throw NexusQError('unknown_method', method);
        }
        return presetList;
      case 'saveEqPreset':
        if (!savePresets) throw NexusQError('unknown_method', method);
        final name = (params?['name'] as String? ?? '').trim();
        if (name.isEmpty) throw NexusQError('bad_params', 'name required');
        final id = EqPreset.userIdFor(name);
        // Stores what was SENT, not the live bands: a fake that saved the
        // device's own state would stay green even if the card sent the wrong
        // curve, which is the exact bug worth catching.
        final entry = {
          'id': id,
          'label': name,
          'builtin': false,
          'preamp_db': (params?['preamp_db'] as num?)?.toDouble() ?? 0.0,
          'bands': [
            for (var i = 0; i < bands.length; i++)
              {
                ...bands[i],
                ...?((params?['bands'] as List?)?.elementAtOrNull(i) as Map?)
                    ?.cast<String, dynamic>(),
              }
          ],
        };
        final at = userPresets.indexWhere((e) => e['id'] == id);
        if (at >= 0) {
          userPresets[at] = entry;
        } else {
          userPresets.add(entry);
        }
        return {...presetList, 'id': id};
      case 'deleteEqPreset':
        if (!savePresets) throw NexusQError('unknown_method', method);
        final delId = params?['id'] as String? ?? '';
        if (!delId.startsWith('u:')) {
          throw NexusQError('bad_params', 'built-in presets cannot be deleted');
        }
        final before = userPresets.length;
        userPresets.removeWhere((e) => e['id'] == delId);
        if (userPresets.length == before) {
          throw NexusQError('bad_params', 'no saved preset $delId');
        }
        return presetList;
    }
    throw NexusQError('unknown_method', method);
  }

  /// Presets saved on the fake device, and whether it can hold any at all —
  /// `savePresets: false` is a daemon that predates them, which must leave the
  /// card working WITHOUT a save button rather than showing one that fails.
  final List<Map<String, dynamic>> userPresets = [];
  bool savePresets = true;

  /// A daemon so old it has no presets at ALL — `listEqPresets` itself is an
  /// unknown method. Distinct from `savePresets: false`, which answers but
  /// cannot save; only this one leaves the card with a reply to learn from.
  bool presetsVerb = true;

  Map<String, dynamic> get presetList => {
        'presets': [
          {
            'id': 'flat',
            'label': 'Flat',
            'preamp_db': 0.0,
            if (savePresets) 'builtin': true,
            'bands': [for (final b in bands) {...b, 'gain_db': 0.0}],
          },
          {
            'id': 'bass',
            'label': 'Bass boost',
            'preamp_db': -6.0,
            if (savePresets) 'builtin': true,
            'bands': [
              for (var i = 0; i < bands.length; i++)
                {...bands[i], 'gain_db': i == 0 ? 6.0 : 0.0}
            ],
          },
          ...userPresets,
        ]
      };

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

    // the low shelf handle should now be off zero; reset becomes available
    expect(_resetButton(tester).onPressed, isNotNull);
  });

  group('flat detent', () {
    // The plot's own geometry: EqCurve is given height 190 for the PLOT, the
    // range is ±12 dB, and the frequency labels live in a strip below that.
    // Computing y from dB here (rather than nudging by eyeballed pixels) is what
    // makes "just inside the detent" mean what it says.
    const plotH = 190.0, maxDb = 12.0;

    double yFor(WidgetTester tester, double db) =>
        tester.getRect(find.byType(EqCurve)).top +
        (maxDb - db) / (2 * maxDb) * plotH;

    double movedGain(_RecordingClient c) => c.bands
        .map((b) => (b['gain_db'] as num).toDouble())
        .reduce((a, b) => b.abs() > a.abs() ? b : a);

    /// Arms the band under the middle of the plot, then drags it so the finger
    /// ENDS at [toDb]. The travel has to clear kTouchSlop, so it always starts
    /// from a long way off rather than nudging from where it already is.
    Future<void> dragTo(WidgetTester tester, double fromDb, double toDb) async {
      final x = tester.getRect(find.byType(EqCurve)).center.dx;
      await tester.tapAt(Offset(x, yFor(tester, 0)));
      await tester.pumpAndSettle();
      await tester.dragFrom(Offset(x, yFor(tester, fromDb)),
          Offset(0, yFor(tester, toDb) - yFor(tester, fromDb)));
      await tester.pumpAndSettle();
    }

    testWidgets('a band released near flat lands exactly on flat',
        (tester) async {
      final client = _RecordingClient();
      await tester.pumpWidget(_host(client));
      await tester.pumpAndSettle();

      await dragTo(tester, 0, 6);
      expect(movedGain(client), closeTo(6, 0.3), reason: 'the drag did nothing');

      await dragTo(tester, 6, 0.5);
      // 0.5 dB is ~4 px on this plot — inside the detent
      expect(client.bands.map((b) => b['gain_db']), everyElement(0.0));
    });

    testWidgets('the detent does not swallow a deliberate small boost',
        (tester) async {
      final client = _RecordingClient();
      await tester.pumpWidget(_host(client));
      await tester.pumpAndSettle();

      await dragTo(tester, 6, 2);
      // 2 dB is ~16 px away — well outside, and must arrive unrounded
      expect(movedGain(client), closeTo(2, 0.3));
    });

    testWidgets('the detent clicks on the way in, once per entry',
        (tester) async {
      final haptics = <String>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform, (call) async {
        if (call.method == 'HapticFeedback.vibrate') {
          haptics.add('${call.arguments}');
        }
        return null;
      });
      addTearDown(() => tester.binding.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null));

      final client = _RecordingClient();
      await tester.pumpWidget(_host(client));
      await tester.pumpAndSettle();
      final x = tester.getRect(find.byType(EqCurve)).center.dx;
      await tester.tapAt(Offset(x, yFor(tester, 0)));
      await tester.pumpAndSettle();

      final g = await tester.startGesture(Offset(x, yFor(tester, 8)));
      for (final db in [4.0, 0.3, -0.3, -4.0, -0.2]) {
        await g.moveTo(Offset(x, yFor(tester, db)));
        await tester.pump();
      }
      await g.up();
      await tester.pumpAndSettle();

      // entered at +0.3, stayed through −0.3, left at −4, entered again at −0.2
      expect(haptics, ['HapticFeedbackType.selectionClick', 'HapticFeedbackType.selectionClick']);
    });
  });

  group('saved presets', () {
    Future<_RecordingClient> pumpCard(WidgetTester tester,
        {bool savePresets = true}) async {
      final client = _RecordingClient()..savePresets = savePresets;
      await tester.pumpWidget(_host(client));
      await tester.pumpAndSettle();
      return client;
    }

    /// The plot is arm-then-drag (Petr's model): a bare drag moves nothing, so
    /// tap the band first — otherwise a test "moves a band" without moving one
    /// and everything downstream of it is green for the wrong reason.
    Future<void> armAndDrag(WidgetTester tester, double dy) async {
      final curve = tester.getRect(find.byType(EqCurve));
      await tester.tapAt(curve.center);
      await tester.pumpAndSettle();
      await tester.dragFrom(curve.center, Offset(0, dy));
      await tester.pumpAndSettle();
    }

    /// Chips live in a horizontal scroller and it is lazy: on a phone-width
    /// card a preset saved third is not merely off-screen, it is not BUILT. So
    /// reveal it the way a person would — by scrolling that row — before
    /// asserting on it or touching it.
    final chipRow = find.byWidgetPredicate(
        (w) => w is Scrollable && w.axisDirection == AxisDirection.right);

    Future<void> reveal(WidgetTester tester, Finder f) async {
      if (tester.any(f)) {
        await tester.ensureVisible(f);
      } else {
        await tester.scrollUntilVisible(f, 120, scrollable: chipRow);
      }
      await tester.pumpAndSettle();
    }

    Future<void> saveAs(WidgetTester tester, String name) async {
      await tester.tap(find.widgetWithText(ActionChip, 'Save'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), name);
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(TextButton, 'Save'));
      await tester.pumpAndSettle();
    }

    testWidgets('sends the whole curve on screen, not just a name',
        (tester) async {
      final client = await pumpCard(tester);
      await armAndDrag(tester, -30);
      await saveAs(tester, 'Vinyl');

      final save = client.calls.lastWhere((c) => c.$1 == 'saveEqPreset');
      expect(save.$2!['name'], 'Vinyl');
      final sent = (save.$2!['bands'] as List).cast<Map<String, dynamic>>();
      expect(sent.length, 7);
      final shown = tester.widget<EqCurve>(find.byType(EqCurve)).state.bands;
      for (var i = 0; i < 7; i++) {
        expect(sent[i]['gain_db'], closeTo(shown[i].gainDb, 1e-9),
            reason: 'band $i');
      }
      expect(save.$2!.containsKey('preamp_db'), isTrue);
    });

    testWidgets('reset flattens every band and the preamp with them',
        (tester) async {
      final client = await pumpCard(tester);
      await armAndDrag(tester, -40);
      expect(client.bands.any((b) => (b['gain_db'] as double).abs() > 0.05),
          isTrue,
          reason: 'the drag never moved anything');

      await tester.tap(find.byTooltip('Reset to flat'));
      await tester.pumpAndSettle();
      final last = client.calls.lastWhere((c) => c.$1 == 'setEq').$2!;
      expect((last['bands'] as List).map((b) => (b as Map)['gain_db']),
          everyElement(closeTo(0, 1e-9)));
      expect(last['preamp_db'], closeTo(0, 1e-9));
      // the bands are still all there — it flattens, it does not drop tuning
      expect((last['bands'] as List).length, 7);
      expect(_resetButton(tester).onPressed, isNull,
          reason: 'still offers reset');
    });

    testWidgets('the saved preset shows up as a chip you can apply back',
        (tester) async {
      final client = await pumpCard(tester);
      await armAndDrag(tester, -40);
      await saveAs(tester, 'Vinyl');
      await reveal(tester, find.widgetWithText(InputChip, 'Vinyl'));
      expect(find.widgetWithText(InputChip, 'Vinyl'), findsOneWidget);

      final saved = client.userPresets.single['bands'] as List;
      final savedGain = (saved[0] as Map)['gain_db'] as double;

      // flatten, then tap the chip: the EQ must come back to what was saved
      await tester.tap(find.byTooltip('Reset to flat'));
      await tester.pumpAndSettle();
      await reveal(tester, find.widgetWithText(InputChip, 'Vinyl'));
      await tester.tap(find.widgetWithText(InputChip, 'Vinyl'));
      await tester.pumpAndSettle();
      expect(client.bands[0]['gain_db'], closeTo(savedGain, 1e-9));
    });

    testWidgets('the same name replaces instead of piling up', (tester) async {
      final client = await pumpCard(tester);
      await saveAs(tester, 'Vinyl');
      await tester.tap(find.widgetWithText(ActionChip, 'Save'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'vinyl');
      await tester.pumpAndSettle();
      // the dialog says so before you commit to it
      expect(find.textContaining('Replaces'), findsOneWidget);
      await tester.tap(find.widgetWithText(TextButton, 'Replace'));
      await tester.pumpAndSettle();

      expect(client.userPresets.length, 1);
      await reveal(tester, find.widgetWithText(InputChip, 'vinyl'));
      expect(find.widgetWithText(InputChip, 'vinyl'), findsOneWidget);
      expect(find.widgetWithText(InputChip, 'Vinyl'), findsNothing);
    });

    testWidgets('a name with nothing to slug cannot be submitted',
        (tester) async {
      final client = await pumpCard(tester);
      await tester.tap(find.widgetWithText(ActionChip, 'Save'));
      await tester.pumpAndSettle();
      for (final bad in ['', '   ', '***']) {
        await tester.enterText(find.byType(TextField), bad);
        await tester.pumpAndSettle();
        expect(
            tester
                .widget<TextButton>(find.widgetWithText(TextButton, 'Save'))
                .onPressed,
            isNull,
            reason: 'accepted "$bad"');
      }
      await tester.enterText(find.byType(TextField), 'Kuchyň');
      await tester.pumpAndSettle();
      expect(
          tester
              .widget<TextButton>(find.widgetWithText(TextButton, 'Save'))
              .onPressed,
          isNotNull);
      await tester.tap(find.widgetWithText(TextButton, 'Save'));
      await tester.pumpAndSettle();
      // Czech letters survive the slug — the daemon uses Python's isalnum(), so
      // stripping them here would make app and device disagree about what
      // replaces what
      expect(client.userPresets.single['id'], 'u:kuchyň');
    });

    testWidgets('delete asks first, then removes it everywhere', (tester) async {
      final client = await pumpCard(tester);
      await saveAs(tester, 'Vinyl');

      await reveal(tester, find.widgetWithText(InputChip, 'Vinyl'));
      await tester.tap(find.byTooltip('Delete Vinyl'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
      await tester.pumpAndSettle();
      expect(client.userPresets, hasLength(1), reason: 'cancel deleted it');
      expect(client.calls.where((c) => c.$1 == 'deleteEqPreset'), isEmpty);

      await reveal(tester, find.widgetWithText(InputChip, 'Vinyl'));
      await tester.tap(find.byTooltip('Delete Vinyl'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(TextButton, 'Delete'));
      await tester.pumpAndSettle();
      expect(client.userPresets, isEmpty);
      expect(find.widgetWithText(InputChip, 'Vinyl'), findsNothing);
    });

    testWidgets('save stays reachable however many presets you have',
        (tester) async {
      final client = await pumpCard(tester);
      for (var i = 0; i < 8; i++) {
        client.userPresets.add({
          'id': 'u:p$i',
          'label': 'Preset number $i',
          'builtin': false,
          'preamp_db': 0.0,
          'bands': [for (final b in client.bands) {...b, 'gain_db': 0.0}],
        });
      }
      client._events.add(NexusQEvent('eqPresetsChanged', client.presetList));
      await tester.pumpAndSettle();
      // no scrolling, no reveal: it is pinned outside the chip scroller
      await tester.tap(find.widgetWithText(ActionChip, 'Save'));
      await tester.pumpAndSettle();
      expect(find.byType(TextField), findsOneWidget);
    });

    testWidgets('built-in presets offer no delete at all', (tester) async {
      await pumpCard(tester);
      expect(find.widgetWithText(ActionChip, 'Flat'), findsOneWidget);
      expect(find.byTooltip('Delete Flat'), findsNothing);
      expect(find.byTooltip('Delete Bass boost'), findsNothing);
    });

    testWidgets('a daemon that cannot save presets shows no save button',
        (tester) async {
      await pumpCard(tester, savePresets: false);
      expect(find.widgetWithText(ActionChip, 'Flat'), findsOneWidget);
      expect(find.widgetWithText(ActionChip, 'Save'), findsNothing);
    });

    testWidgets('a device downgraded past presets withdraws the save button',
        (tester) async {
      final client = await pumpCard(tester);
      expect(find.widgetWithText(ActionChip, 'Save'), findsOneWidget);
      // downgraded underneath us to a daemon with no preset verbs at all, then
      // the link comes back: there is no reply left to learn "cannot save"
      // from, so the flag has to be cleared before asking
      client.presetsVerb = false;
      client.goOnline();
      await tester.pumpAndSettle();
      expect(find.widgetWithText(ActionChip, 'Flat'), findsNothing);
      expect(find.widgetWithText(ActionChip, 'Save'), findsNothing);
    });

    testWidgets('another client saving one updates this card', (tester) async {
      final client = await pumpCard(tester);
      client.userPresets.add({
        'id': 'u:night',
        'label': 'Night',
        'builtin': false,
        'preamp_db': 0.0,
        'bands': [for (final b in client.bands) {...b, 'gain_db': 0.0}],
      });
      client._events.add(NexusQEvent('eqPresetsChanged', client.presetList));
      await tester.pumpAndSettle();
      await reveal(tester, find.widgetWithText(InputChip, 'Night'));
      expect(find.widgetWithText(InputChip, 'Night'), findsOneWidget);
    });

    testWidgets('a refused save is reported, not swallowed', (tester) async {
      final client = await pumpCard(tester);
      client.connected = false;
      await saveAs(tester, 'Vinyl');
      expect(find.textContaining('not connected'), findsOneWidget);
    });
  });
}

/// The reset control is an icon, so there is no text to find it by — the
/// tooltip is its name, for this test and for a screen reader alike.
IconButton _resetButton(WidgetTester tester) => tester.widget<IconButton>(
    find.ancestor(
        of: find.byTooltip('Reset to flat'), matching: find.byType(IconButton)));
