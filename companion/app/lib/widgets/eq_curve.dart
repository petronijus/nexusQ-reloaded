import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../models/eq.dart';
import '../theme/nexusq_theme.dart';

/// The EQ response curve with one draggable handle per band.
///
/// Dragging moves a handle in both axes at once: horizontally it retunes the
/// band (log frequency), vertically it sets the gain. Q is a separate control —
/// a pinch gesture on a 7-handle curve on a phone is a good way to change the
/// wrong band by accident, and every change here is an I2C write into a 25 W
/// amplifier.
///
/// `onChanged` fires continuously so the curve tracks the finger; `onCommit`
/// fires once on release and is what should reach the device.
///
/// Winning the gesture from the enclosing scroll view took two attempts, so the
/// reasoning is written down.
///
/// A `pan` recognizer LOSES to a ListView: pan accepts only after `kPanSlop`
/// (36 px) while the scrollable's vertical drag accepts after `kTouchSlop`
/// (18 px), so the scroll gets there first and wins fairly. Forcing the pan to
/// accept anyway (overriding `rejectGesture`) does not fix it — the arena has
/// already awarded the gesture to the scrollable, so BOTH run and the page
/// scrolls while the handle moves.
///
/// The fix is to compete on equal terms: a vertical drag recognizer uses the
/// same slop as the scrollable, and pointer events reach the innermost hit-test
/// entry first, so this one accepts first and the scrollable is rejected
/// properly. A horizontal recognizer sits alongside it for sideways retuning,
/// which nothing outside competes for. Both feed the same handler and use
/// `localPosition`, which is a full 2-D point regardless of which axis won.
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
  final void Function(int index, double freqHz, double gainDb) onChanged;
  final VoidCallback onCommit;
  final bool enabled;
  final double height;

  @override
  State<EqCurve> createState() => _EqCurveState();
}

class _EqCurveState extends State<EqCurve> {
  int _dragging = -1;

  double _xOf(double f, double w) {
    final lo = math.log(widget.state.minFreqHz), hi = math.log(widget.state.maxFreqHz);
    return (math.log(f.clamp(widget.state.minFreqHz, widget.state.maxFreqHz)) - lo) /
        (hi - lo) *
        w;
  }

  double _freqOf(double x, double w) {
    final lo = math.log(widget.state.minFreqHz), hi = math.log(widget.state.maxFreqHz);
    return math.exp(lo + (x / w).clamp(0.0, 1.0) * (hi - lo));
  }

  double _yOf(double db, double h) {
    final m = widget.state.maxGainDb;
    return (m - db.clamp(-m, m)) / (2 * m) * h;
  }

  double _dbOf(double y, double h) {
    final m = widget.state.maxGainDb;
    return (m - (y / h).clamp(0.0, 1.0) * 2 * m);
  }

  int _nearest(Offset p, Size size) {
    var best = -1;
    var bestD = 44.0; // generous target: fingers, not mice
    for (var i = 0; i < widget.state.bands.length; i++) {
      final b = widget.state.bands[i];
      final d = (Offset(_xOf(b.freqHz, size.width), _yOf(b.gainDb, size.height)) - p)
          .distance;
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
        widget.onChanged(
          _dragging,
          _freqOf(d.localPosition.dx, size.width),
          _dbOf(d.localPosition.dy, size.height),
        );
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
          HorizontalDragGestureRecognizer:
              GestureRecognizerFactoryWithHandlers<HorizontalDragGestureRecognizer>(
            () => HorizontalDragGestureRecognizer(debugOwner: this),
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

  double _x(double f, double w) {
    final lo = math.log(state.minFreqHz), hi = math.log(state.maxFreqHz);
    return (math.log(f) - lo) / (hi - lo) * w;
  }

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
      canvas.drawLine(Offset(_x(f, w), 0), Offset(_x(f, w), h), grid);
      _label(canvas, f >= 1000 ? '${(f / 1000).toStringAsFixed(0)}k' : '${f.toInt()}',
          Offset(_x(f, w) + 4, h - 14), dim);
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
      final lo = math.log(state.minFreqHz), hi = math.log(state.maxFreqHz);
      final f = math.exp(lo + (x / size.width) * (hi - lo));
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
