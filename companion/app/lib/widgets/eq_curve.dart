import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../models/eq.dart';
import '../theme/nexusq_theme.dart';

/// The EQ response curve with one draggable handle per band.
///
/// Handles move **vertically only** — the band frequencies are fixed, so a
/// sideways drag would silently retune a band nobody asked to retune. Width/Q
/// is the slider under the curve.
///
/// Because the handles sit at fixed x positions, hit-testing is by horizontal
/// distance alone: touching anywhere in a band's vertical strip grabs it. That
/// makes the target the full height of the plot instead of a 44 px disc, which
/// is what "the hit areas are very small" was about.
///
/// The x axis spans exactly the first to the last band frequency, so the
/// outermost handles sit on the edges rather than floating a fifth of the way
/// in. The trade is that the response below the low shelf and above the high
/// shelf is off-screen; both are flat-ish there by construction, and having the
/// handles reachable matters more.
///
/// `onChanged` fires continuously so the curve tracks the finger; `onCommit`
/// fires once on release and is what should reach the device.
///
/// Winning the gesture from the enclosing scroll view is the other subtlety. A
/// `pan` recognizer LOSES to a ListView: pan accepts after `kPanSlop` (36 px)
/// while the scrollable's vertical drag accepts after `kTouchSlop` (18 px), so
/// the scroll gets there first and wins fairly. Forcing the pan to accept
/// anyway does not fix it — the arena has already awarded the gesture, so BOTH
/// run and the page scrolls while the handle moves. A vertical drag recognizer
/// competes on equal terms and, being the innermost hit-test entry, accepts
/// first.
class EqCurve extends StatefulWidget {
  const EqCurve({
    super.key,
    required this.state,
    required this.selected,
    required this.onSelect,
    required this.onChanged,
    required this.onCommit,
    this.enabled = true,
    this.height = 190,
  });

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
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, c) {
      final size = Size(c.maxWidth, widget.height);
      final enabled = widget.enabled;

      void start(DragStartDetails d) {
        final i = _nearest(d.localPosition, size);
        if (i < 0) return;
        _dragging = i;
        widget.onSelect(i);
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
          VerticalDragGestureRecognizer:
              GestureRecognizerFactoryWithHandlers<VerticalDragGestureRecognizer>(
            () => VerticalDragGestureRecognizer(debugOwner: this),
            (r) {
              r.onStart = enabled ? start : null;
              r.onUpdate = enabled ? update : null;
              r.onEnd = enabled ? end : null;
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
                      if (i >= 0) widget.onSelect(i);
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
              enabled: widget.enabled,
            ),
          ),
        ),
      );
    });
  }
}

class _EqPainter extends CustomPainter {
  _EqPainter({required this.state, required this.selected, required this.enabled});

  final EqState state;
  final int selected;
  final bool enabled;

  static const _gridHz = [100.0, 1000.0, 10000.0];

  double _x(double f, double w) => plotX(state.bands, f, w);

  double _y(double db, double h) =>
      (state.maxGainDb - db.clamp(-state.maxGainDb, state.maxGainDb)) /
      (2 * state.maxGainDb) *
      h;

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width, h = size.height;
    final dim = enabled ? NexusQColors.dim : NexusQColors.dim.withValues(alpha: 0.4);

    final grid = Paint()
      ..color = dim.withValues(alpha: 0.22)
      ..strokeWidth = 1;
    // 0 dB line reads as the reference, so it gets its own weight.
    for (final db in [-state.maxGainDb / 2, state.maxGainDb / 2]) {
      canvas.drawLine(Offset(0, _y(db, h)), Offset(w, _y(db, h)), grid);
    }
    canvas.drawLine(
        Offset(0, _y(0, h)),
        Offset(w, _y(0, h)),
        Paint()
          ..color = dim.withValues(alpha: 0.5)
          ..strokeWidth = 1);
    for (final f in _gridHz) {
      final gx = _x(f, w);
      if (gx < 2 || gx > w - 2) continue;   // outside the plotted band range
      canvas.drawLine(Offset(gx, 0), Offset(gx, h), grid);
      _label(canvas, f >= 1000 ? '${(f / 1000).toStringAsFixed(0)}k' : '${f.toInt()}',
          Offset(gx + 4, h - 14), dim);
    }
    _label(canvas, '+${state.maxGainDb.toInt()}', const Offset(4, 2), dim);
    _label(canvas, '−${state.maxGainDb.toInt()}', Offset(4, h - 14), dim);

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

  void _label(Canvas canvas, String s, Offset at, Color color) {
    final tp = TextPainter(
      text: TextSpan(text: s, style: TextStyle(color: color, fontSize: 10)),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas, at);
  }

  @override
  bool shouldRepaint(_EqPainter old) =>
      old.selected != selected ||
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
