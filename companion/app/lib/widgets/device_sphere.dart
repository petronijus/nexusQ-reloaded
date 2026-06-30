import 'dart:math' as math;
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import '../theme/nexusq_theme.dart';

/// The device as the original app showed it: the black Nexus Q sphere with the
/// equatorial LED ring. The ring is drawn procedurally over the (dim) sphere so
/// it takes the **current LED theme palette** and **animates** — a rotating
/// rainbow for multi-color themes, a colored ring with an orbiting bright spot
/// for solid ones — like the device's real ring. Off / muted → dark ring.
class DeviceSphere extends StatefulWidget {
  const DeviceSphere({
    super.key,
    required this.on,
    required this.colors,
    this.size = 180,
  });

  final bool on;
  final List<Color> colors;
  final double size;

  @override
  State<DeviceSphere> createState() => _DeviceSphereState();
}

class _DeviceSphereState extends State<DeviceSphere> with SingleTickerProviderStateMixin {
  late final AnimationController _c =
      AnimationController(vsync: this, duration: const Duration(seconds: 6))..repeat();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final palette = widget.colors.isEmpty ? const [NexusQColors.accent] : widget.colors;
    final s = widget.size;
    return SizedBox(
      width: s,
      height: s,
      child: AnimatedBuilder(
        animation: _c,
        builder: (context, _) => Stack(
          alignment: Alignment.center,
          children: [
            // soft theme-colored bloom under the base
            if (widget.on)
              Positioned(
                bottom: s * 0.10,
                child: ImageFiltered(
                  imageFilter: ui.ImageFilter.blur(sigmaX: 20, sigmaY: 20),
                  child: Opacity(
                    opacity: 0.55,
                    child: Container(
                      width: s * 0.66,
                      height: s * 0.18,
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(s),
                        gradient: palette.length > 1 ? LinearGradient(colors: palette) : null,
                        color: palette.length == 1 ? palette.first : null,
                      ),
                    ),
                  ),
                ),
              ),
            // the dim sphere (its baked-in ring stays dark; we light our own)
            Image.asset('assets/device/sphere_off.png',
                width: s, height: s, filterQuality: FilterQuality.medium),
            // the procedural, animated, theme-colored LED ring
            if (widget.on)
              CustomPaint(
                size: Size(s, s),
                painter: _RingPainter(palette: palette, phase: _c.value),
              ),
          ],
        ),
      ),
    );
  }
}

class _RingPainter extends CustomPainter {
  _RingPainter({required this.palette, required this.phase});
  final List<Color> palette;
  final double phase;

  Color _sample(double t) {
    // t in [0,1) around the ring -> color from the palette (wraps).
    t -= t.floorToDouble();
    if (palette.length == 1) return palette.first;
    final scaled = t * palette.length;
    final i = scaled.floor() % palette.length;
    final j = (i + 1) % palette.length;
    return Color.lerp(palette[i], palette[j], scaled - scaled.floor())!;
  }

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width, h = size.height;
    // Geometry measured from the original lit-ring pixels (drop_ball_activated):
    // the ring sits on the base rim at ~80% height, half-width 0.215, and is a
    // very flat ellipse (b≈0.045) — a near-edge-on view of the base ring.
    final cx = w * 0.505, cy = h * 0.80;
    final a = w * 0.215, b = h * 0.045;
    const n = 72;
    final single = palette.length == 1;

    void pass(double width, double sigma, double alphaScale) {
      final p = Paint()
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round
        ..strokeWidth = width;
      if (sigma > 0) p.maskFilter = MaskFilter.blur(BlurStyle.normal, sigma);
      for (int i = 0; i < n; i++) {
        final t0 = i / n, t1 = (i + 1) / n;
        final ang0 = t0 * 2 * math.pi, ang1 = t1 * 2 * math.pi;
        final p0 = Offset(cx + a * math.cos(ang0), cy + b * math.sin(ang0));
        final p1 = Offset(cx + a * math.cos(ang1), cy + b * math.sin(ang1));
        // far half (top of the ellipse, sin<0) reads as the ring's back: still
        // clearly visible, just a touch dimmer than the near (front) half.
        final depth = math.sin(ang0) < 0 ? 0.6 : 1.0;
        double intensity;
        Color base;
        if (single) {
          base = palette.first;
          // an orbiting bright spot
          double d = (t0 - phase).abs();
          d = math.min(d, 1 - d);
          intensity = 0.35 + 0.65 * math.exp(-math.pow(d / 0.13, 2).toDouble());
        } else {
          base = _sample(t0 + phase);   // rotating palette
          intensity = 1.0;
        }
        p.color = base.withValues(alpha: (intensity * depth * alphaScale).clamp(0.0, 1.0));
        canvas.drawLine(p0, p1, p);
      }
    }

    pass(size.width * 0.034, size.width * 0.018, 0.55); // glow
    pass(size.width * 0.013, 0, 1.0);                   // crisp ring
  }

  @override
  bool shouldRepaint(_RingPainter old) => old.phase != phase || old.palette != palette;
}
