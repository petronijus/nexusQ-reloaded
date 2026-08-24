import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../models/eq.dart';
import '../theme/nexusq_theme.dart';

/// The EQ response curve with one handle per band.
///
/// **Arm, then drag.** Tapping a band arms it: from then until you tap outside
/// the plot, a drag moves that band and the page does not scroll at all.
/// Tapping another band moves the arming; tapping outside gives scrolling back.
///
/// This is Petr's design and it replaces two failed attempts at out-competing
/// the enclosing ListView in Flutter's gesture arena. Those were the wrong shape
/// of solution: a `pan` recognizer accepts after `kPanSlop` (36 px) where a
/// scrollable's vertical drag accepts after `kTouchSlop` (18 px), so the scroll
/// wins fairly; forcing acceptance makes BOTH run; and a vertical recognizer
/// that should win on equal terms still did not, on a real finger.
///
/// Arming settles it by making intent explicit. While a band is armed the curve
/// CLAIMS the arena at pointer-down (`_ClaimingDragRecognizer`) — a legitimate
/// win, so the scrollable is rejected rather than running alongside. Crucially
/// the claim only exists inside the plot: a touch outside never reaches this
/// recognizer, so the page scrolls from the very first gesture instead of
/// needing one tap to disarm and a second to scroll.
///
/// While armed, the start of a drag also re-arms whatever band it began on, so
/// switching bands is one gesture rather than a tap followed by a drag.
///
/// Handles move vertically only; band frequencies are fixed and width/Q lives on
/// the slider under the curve. Hit-testing is therefore by horizontal distance
/// alone with no radius limit, so a band's whole column is its target.
///
/// The x axis spans exactly the first to the last band frequency, so the outer
/// handles sit on the edges. Painter and hit-testing share `plotX`, so a handle
/// can never be drawn anywhere other than where it is grabbed.
class EqCurve extends StatefulWidget {
  const EqCurve({
    super.key,
    required this.state,
    required this.selected,
    required this.armed,
    required this.onSelect,
    required this.onChanged,
    required this.onCommit,
    this.enabled = true,
    this.height = 190,
  });

  /// Which band currently owns gestures, or null when the page may scroll.
  /// Shared with whatever hosts this widget so it can freeze its scrollable.
  final ValueNotifier<int?> armed;

  final EqState state;
  final int selected;
  final ValueChanged<int> onSelect;
  final void Function(int index, double gainDb) onChanged;
  final VoidCallback onCommit;
  final bool enabled;
  final double height;

  @override
  State<EqCurve> createState() => _EqCurveState();
}

class _EqCurveState extends State<EqCurve> {
  int _dragging = -1;

  double _xOf(double f, double w) => plotX(widget.state.bands, f, w);

  double _dbOf(double y, double h) {
    final m = widget.state.maxGainDb;
    return (m - (y / h).clamp(0.0, 1.0) * 2 * m);
  }

  /// Nearest band by HORIZONTAL distance only. With gain-only handles the whole
  /// column belongs to one band, so there is no reason to make the user find a
  /// small disc — and no radius limit, because every touch inside the plot
  /// belongs to some band.
  int _nearest(Offset p, Size size) {
    var best = -1;
    var bestD = double.infinity;
    for (var i = 0; i < widget.state.bands.length; i++) {
      final d = (_xOf(widget.state.bands[i].freqHz, size.width) - p.dx).abs();
      if (d < bestD) {
        bestD = d;
        best = i;
      }
    }
    return best;
  }

  @override
  void initState() {
    super.initState();
    widget.armed.addListener(_onArmed);
  }

  @override
  void dispose() {
    widget.armed.removeListener(_onArmed);
    super.dispose();
  }

  void _onArmed() => setState(() {});

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, c) {
      final size = Size(c.maxWidth, widget.height);
      final enabled = widget.enabled;

      void start(DragStartDetails d) {
        // Re-arm on whatever the gesture started on, so moving to another band
        // is a single drag rather than tap-then-drag.
        final i = _nearest(d.localPosition, size);
        if (i < 0) return;
        _dragging = i;
        if (widget.armed.value != i) {
          widget.armed.value = i;
          widget.onSelect(i);
        }
      }

      void update(DragUpdateDetails d) {
        if (_dragging < 0) return;
        widget.onChanged(_dragging, _dbOf(d.localPosition.dy, size.height));
      }

      void end(DragEndDetails d) {
        if (_dragging < 0) return;
        _dragging = -1;
        widget.onCommit();
      }

      return RawGestureDetector(
        behavior: HitTestBehavior.opaque,
        gestures: {
          if (enabled && widget.armed.value != null)
            _ClaimingDragRecognizer:
                GestureRecognizerFactoryWithHandlers<_ClaimingDragRecognizer>(
              () => _ClaimingDragRecognizer(debugOwner: this),
              (r) {
                r.onStart = start;
                r.onUpdate = update;
                r.onEnd = end;
              },
            ),
          TapGestureRecognizer:
              GestureRecognizerFactoryWithHandlers<TapGestureRecognizer>(
            () => TapGestureRecognizer(debugOwner: this),
            (r) {
              r.onTapDown = !enabled
                  ? null
                  : (d) {
                      final i = _nearest(d.localPosition, size);
                      if (i < 0) return;
                      widget.onSelect(i);
                      widget.armed.value = i;   // arm: the page stops scrolling
                    };
            },
          ),
        },
        child: SizedBox(
          height: widget.height,
          width: double.infinity,
          child: CustomPaint(
            painter: _EqPainter(
              state: widget.state,
              selected: widget.selected,
              armed: widget.armed.value,
              enabled: widget.enabled,
            ),
          ),
        ),
      );
    });
  }
}

class _EqPainter extends CustomPainter {
  _EqPainter(
      {required this.state,
      required this.selected,
      required this.armed,
      required this.enabled});

  final EqState state;
  final int selected;
  final int? armed;
  final bool enabled;


  double _x(double f, double w) => plotX(state.bands, f, w);

  double _y(double db, double h) =>
      (state.maxGainDb - db.clamp(-state.maxGainDb, state.maxGainDb)) /
      (2 * state.maxGainDb) *
      h;

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width, h = size.height;
    final dim = enabled ? NexusQColors.dim : NexusQColors.dim.withValues(alpha: 0.4);

    final fine = Paint()
      ..color = dim.withValues(alpha: 0.13)
      ..strokeWidth = 1;
    final coarse = Paint()
      ..color = dim.withValues(alpha: 0.26)
      ..strokeWidth = 1;

    // dB grid every 3 dB, labelled every 6 — enough to read a gain off the
    // curve without turning the plot into graph paper.
    final maxDb = state.maxGainDb;
    for (var db = -maxDb; db <= maxDb + 0.01; db += 3) {
      if (db.abs() < 0.01) continue;
      final labelled = (db.abs() % 6).abs() < 0.01;
      canvas.drawLine(Offset(0, _y(db, h)), Offset(w, _y(db, h)),
          labelled ? coarse : fine);
      if (labelled) {
        _label(canvas, '${db > 0 ? '+' : '−'}${db.abs().toInt()}',
            Offset(2, _y(db, h) - 11), dim);
      }
    }
    // 0 dB is the reference, so it reads heavier than the rest.
    canvas.drawLine(
        Offset(0, _y(0, h)),
        Offset(w, _y(0, h)),
        Paint()
          ..color = dim.withValues(alpha: 0.55)
          ..strokeWidth = 1);

    // A line and a label at EVERY band frequency: those are the only points that
    // can be moved, so "which kHz am I raising" should never need guessing.
    if (state.bands.isNotEmpty) {
      for (var i = 0; i < state.bands.length; i++) {
        final f = state.bands[i].freqHz;
        final gx = _x(f, w);
        canvas.drawLine(Offset(gx, 0), Offset(gx, h),
            i == armed ? coarse : fine);
        final text = f >= 10000
            ? '${(f / 1000).toStringAsFixed(0)}k'
            : (f >= 1000
                ? '${(f / 1000).toStringAsFixed(1)}k'
                : '${f.round()}');
        _labelCentred(canvas, text, gx, h - 12,
            i == armed ? NexusQColors.accent : dim, w);
      }
    }

    if (state.bands.isEmpty) return;

    // Faint per-band curves make it obvious which handle owns which bump.
    for (var i = 0; i < state.bands.length; i++) {
      final b = state.bands[i];
      if (b.isFlat) continue;
      final p = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = i == selected ? 1.4 : 1.0
        ..color = (i == selected ? NexusQColors.accent : dim)
            .withValues(alpha: i == selected ? 0.55 : 0.28);
      canvas.drawPath(_path(size, (f) => b.responseDb(f)), p);
    }

    // The summed response — the thing that actually reaches the speaker.
    canvas.drawPath(
      _path(size, (f) => EqState.responseDb(state.bands, f, state.preampDb)),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.4
        ..strokeJoin = StrokeJoin.round
        ..color = enabled ? NexusQColors.accent : dim,
    );

    for (var i = 0; i < state.bands.length; i++) {
      final b = state.bands[i];
      final c = Offset(_x(b.freqHz, w), _y(b.gainDb, h));
      final sel = i == selected;
      final isArmed = i == armed;
      if (isArmed) {
        // The armed band owns the gestures and the page has stopped scrolling —
        // that has to be visible, or the frozen page looks like a bug.
        canvas.drawCircle(c, 18,
            Paint()..color = NexusQColors.accent.withValues(alpha: 0.16));
        canvas.drawCircle(
            c,
            14,
            Paint()
              ..style = PaintingStyle.stroke
              ..strokeWidth = 2
              ..color = NexusQColors.accent.withValues(alpha: 0.7));
      }
      canvas.drawCircle(
          c,
          sel ? 9 : 6,
          Paint()
            ..color = (enabled ? NexusQColors.accent : dim)
                .withValues(alpha: b.isFlat ? 0.45 : 1.0));
      canvas.drawCircle(
          c,
          sel ? 9 : 6,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 2
            ..color = NexusQColors.surface);
    }

    // What the armed band is actually set to, pinned to the top of the plot:
    // while dragging, the hand covers the handle and the row under the card.
    final a = armed;
    if (a != null && a < state.bands.length) {
      final b = state.bands[a];
      final hz = b.freqHz >= 1000
          ? '${(b.freqHz / 1000).toStringAsFixed(b.freqHz >= 10000 ? 0 : 1)} kHz'
          : '${b.freqHz.round()} Hz';
      final db =
          '${b.gainDb >= 0 ? '+' : '−'}${b.gainDb.abs().toStringAsFixed(1)} dB';
      _label(canvas, '$hz   $db', const Offset(4, 3), NexusQColors.accent,
          size: 12, bold: true);
    }
  }

  Path _path(Size size, double Function(double f) db) {
    final path = Path();
    const steps = 128;
    for (var i = 0; i <= steps; i++) {
      final x = size.width * i / steps;
      final f = plotFreq(state.bands, x, size.width);
      final y = _y(db(f), size.height);
      i == 0 ? path.moveTo(x, y) : path.lineTo(x, y);
    }
    return path;
  }

  void _label(Canvas canvas, String s, Offset at, Color color,
      {double size = 10, bool bold = false}) {
    _painter(s, color, size, bold).paint(canvas, at);
  }

  /// Centred on [cx] but nudged so an edge label is not clipped — the outermost
  /// band frequencies sit right on the edges of the plot.
  void _labelCentred(
      Canvas canvas, String s, double cx, double top, Color color, double w) {
    final tp = _painter(s, color, 10, false);
    final x = (cx - tp.width / 2).clamp(1.0, w - tp.width - 1);
    tp.paint(canvas, Offset(x, top));
  }

  TextPainter _painter(String s, Color color, double size, bool bold) =>
      TextPainter(
        text: TextSpan(
            text: s,
            style: TextStyle(
                color: color,
                fontSize: size,
                fontWeight: bold ? FontWeight.w600 : FontWeight.normal)),
        textDirection: TextDirection.ltr,
      )..layout();

  @override
  bool shouldRepaint(_EqPainter old) =>
      old.selected != selected ||
      old.armed != armed ||
      old.enabled != enabled ||
      old.state.preampDb != state.preampDb ||
      !identical(old.state.bands, state.bands);
}

/// Shared axis between the painter and the hit-testing, so a handle can never be
/// drawn somewhere other than where it is grabbed.
///
/// Spans the first to the last band frequency, inset by [_edgeInset] so the
/// outermost handles sit on the edges and are still drawn whole.
const double _edgeInset = 14;

double plotX(List<EqBand> bands, double f, double w) {
  if (bands.isEmpty) return 0;
  final lo = math.log(bands.first.freqHz), hi = math.log(bands.last.freqHz);
  final span = w - 2 * _edgeInset;
  if (hi <= lo || span <= 0) return w / 2;
  return _edgeInset +
      ((math.log(f) - lo) / (hi - lo)).clamp(0.0, 1.0) * span;
}

double plotFreq(List<EqBand> bands, double x, double w) {
  if (bands.isEmpty) return 1000;
  final lo = math.log(bands.first.freqHz), hi = math.log(bands.last.freqHz);
  final span = w - 2 * _edgeInset;
  if (hi <= lo || span <= 0) return bands.first.freqHz;
  return math.exp(lo + ((x - _edgeInset) / span).clamp(0.0, 1.0) * (hi - lo));
}

/// A vertical drag that claims the arena the moment the finger lands.
///
/// Only attached while a band is armed, and only over the plot, so it cannot
/// steal anything it should not: outside the curve this recognizer never sees
/// the pointer and the page scrolls normally. Winning at pointer-down (rather
/// than after the slop) is what makes an armed curve immune to the enclosing
/// list — and doing it by `resolve(accepted)` is a real win, unlike overriding
/// `rejectGesture`, which leaves the scrollable running too.
class _ClaimingDragRecognizer extends VerticalDragGestureRecognizer {
  _ClaimingDragRecognizer({super.debugOwner});

  @override
  void addAllowedPointer(PointerDownEvent event) {
    super.addAllowedPointer(event);
    resolve(GestureDisposition.accepted);
  }
}
