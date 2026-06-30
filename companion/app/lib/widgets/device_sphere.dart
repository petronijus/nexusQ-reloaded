import 'dart:math' as math;
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import '../theme/nexusq_theme.dart';

/// The device as the original app showed it: the black Nexus Q sphere. The
/// animated LED ring is drawn *behind* the sphere PNG (assets/device/sphere.png),
/// whose ring band is transparent — so the ring shows through the cutout exactly
/// where the real ring is, and the opaque sphere body hides the middle (the front
/// and back rim show, like the real device). The ring color tracks the LED theme
/// palette and rotates. Off / muted → no ring (dark band).
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
            // soft theme-colored bloom spilling below the base
            if (widget.on)
              Positioned(
                bottom: s * 0.06,
                child: ImageFiltered(
                  imageFilter: ui.ImageFilter.blur(sigmaX: 20, sigmaY: 20),
                  child: Opacity(
                    opacity: 0.5,
                    child: Container(
                      width: s * 0.66,
                      height: s * 0.16,
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(s),
                        gradient: palette.length > 1 ? LinearGradient(colors: palette) : null,
                        color: palette.length == 1 ? palette.first : null,
                      ),
                    ),
                  ),
                ),
              ),
            // the animated LED ring — drawn BEHIND the sphere; the transparent
            // ring band in the PNG masks it to the exact rim shape.
            if (widget.on)
              CustomPaint(
                size: Size(s, s),
                painter: _RingPainter(palette: palette, phase: _c.value),
              ),
            // the sphere on top: opaque body hides the ring's middle, the
            // transparent band lets the rim show through.
            Image.asset('assets/device/sphere.png',
                width: s, height: s, filterQuality: FilterQuality.medium),
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
    // Ellipse measured from the transparent ring band in sphere.png; the band
    // masks it, so draw it a touch generous and thick to fully fill the cutout.
    final cx = w * 0.517, cy = h * 0.733;
    final a = w * 0.405, b = h * 0.120;
    const n = 96;
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
        // far half (top, sin<0) is the back rim — slightly dimmer than the front.
        final depth = math.sin(ang0) < 0 ? 0.7 : 1.0;
        double intensity;
        Color base;
        if (single) {
          base = palette.first;
          double d = (t0 - phase).abs();
          d = math.min(d, 1 - d);
          intensity = 0.4 + 0.6 * math.exp(-math.pow(d / 0.14, 2).toDouble());
        } else {
          base = _sample(t0 + phase);
          intensity = 1.0;
        }
        p.color = base.withValues(alpha: (intensity * depth * alphaScale).clamp(0.0, 1.0));
        canvas.drawLine(p0, p1, p);
      }
    }

    pass(w * 0.075, w * 0.02, 0.6);  // glow / fill
    pass(w * 0.05, 0, 1.0);          // bright core (fills the band)
  }

  @override
  bool shouldRepaint(_RingPainter old) => old.phase != phase || old.palette != palette;
}
