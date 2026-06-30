import 'dart:math' as math;
import 'package:flutter/material.dart';
import '../theme/nexusq_theme.dart';

/// The hero element: the Nexus Q sphere as a glowing Holo-Blue circle outline
/// with a bright equatorial LED arc — reproduced procedurally (not from the
/// copyrighted q-spin PNGs) so it reacts live to volume / theme / mute, exactly
/// like the device's own ring (RE doc §3.2: VOLUME_ACTIVE lights the ring).
///
/// [volume] 0..1 fills the equator arc; [color] tints the ring (current LED
/// theme); [muted] dims it. A slow idle rotation echoes the original spin.
class GlowingRing extends StatefulWidget {
  const GlowingRing({
    super.key,
    required this.volume,
    this.color = NexusQColors.accent,
    this.muted = false,
    this.child,
  });

  final double volume;
  final Color color;
  final bool muted;
  final Widget? child;

  @override
  State<GlowingRing> createState() => _GlowingRingState();
}

class _GlowingRingState extends State<GlowingRing> with SingleTickerProviderStateMixin {
  late final AnimationController _spin =
      AnimationController(vsync: this, duration: const Duration(seconds: 12))..repeat();

  @override
  void dispose() {
    _spin.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final color = widget.muted ? NexusQColors.dim.withValues(alpha: 0.25) : widget.color;
    return AspectRatio(
      aspectRatio: 1,
      child: AnimatedBuilder(
        animation: _spin,
        builder: (context, _) => CustomPaint(
          painter: _RingPainter(
            volume: widget.volume.clamp(0.0, 1.0),
            color: color,
            phase: _spin.value * 2 * math.pi,
            muted: widget.muted,
          ),
          child: Center(child: widget.child),
        ),
      ),
    );
  }
}

class _RingPainter extends CustomPainter {
  _RingPainter({
    required this.volume,
    required this.color,
    required this.phase,
    required this.muted,
  });

  final double volume;
  final Color color;
  final double phase;
  final bool muted;

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final r = size.shortestSide / 2 - 6;
    final rect = Rect.fromCircle(center: c, radius: r);

    // 1) dim sphere silhouette outline
    final outline = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5
      ..color = color.withValues(alpha: 0.35);
    canvas.drawCircle(c, r, outline);

    // 2) the bright equatorial LED arc = volume level, with a soft glow.
    //    Empty ring at volume 0; a full sweep at volume 1. Centered on the
    //    bottom equator and growing symmetrically, like the device ring.
    final sweep = 2 * math.pi * volume;
    final start = math.pi / 2 - sweep / 2; // centered on the bottom (90°)

    final glow = Paint()
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeWidth = 5
      ..color = color.withValues(alpha: muted ? 0.2 : 0.9)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 8);
    if (volume > 0) canvas.drawArc(rect, start, sweep, false, glow);

    final arc = Paint()
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeWidth = 3
      ..color = color.withValues(alpha: muted ? 0.4 : 1.0);
    if (volume > 0) canvas.drawArc(rect, start, sweep, false, arc);

    // 3) a faint rotating highlight tick — echoes the original spin animation.
    if (!muted) {
      final tick = Paint()
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round
        ..strokeWidth = 2
        ..color = color.withValues(alpha: 0.5)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4);
      canvas.drawArc(rect, phase, 0.25, false, tick);
    }
  }

  @override
  bool shouldRepaint(_RingPainter old) =>
      old.volume != volume || old.color != color || old.phase != phase || old.muted != muted;
}
