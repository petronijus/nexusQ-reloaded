import 'package:flutter/material.dart';

/// The device as the original app showed it: the black Nexus Q sphere
/// (assets/device/sphere.png), whose LED-ring band is transparent. We light a
/// horizontal bar across that hole — drawn *behind* the sphere and *clipped to
/// the hole* — so the light appears only inside the sphere (no spill around it),
/// from one end of the slot to the other. Color tracks the LED theme palette and
/// glides; off / muted → dark slot.
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
    final palette = widget.colors.isEmpty ? const [Color(0xFF33B5E5)] : widget.colors;
    final s = widget.size;
    return SizedBox(
      width: s,
      height: s,
      child: AnimatedBuilder(
        animation: _c,
        builder: (context, _) => Stack(
          alignment: Alignment.center,
          children: [
            // the lit slot — behind the sphere, clipped to the hole so the glow
            // stays inside the sphere.
            if (widget.on)
              CustomPaint(size: Size(s, s), painter: _SlotPainter(palette: palette, phase: _c.value)),
            // the sphere on top: its transparent band reveals the slot; the
            // opaque body hides everything else.
            Image.asset('assets/device/sphere.png',
                width: s, height: s, filterQuality: FilterQuality.medium),
          ],
        ),
      ),
    );
  }
}

class _SlotPainter extends CustomPainter {
  _SlotPainter({required this.palette, required this.phase});
  final List<Color> palette;
  final double phase;

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width, h = size.height;
    // the transparent ring band's bounding box (measured from sphere.png).
    final hole = Rect.fromLTRB(w * 0.10, h * 0.595, w * 0.92, h * 0.865);

    canvas.save();
    // keep all light strictly inside the sphere silhouette (a circle, measured
    // from sphere.png) AND within the slot — so nothing spills out the rounded
    // corners of the band's bounding box.
    canvas.clipPath(Path()
      ..addOval(Rect.fromCircle(center: Offset(w * 0.5, h * 0.502), radius: w * 0.447)));
    canvas.clipRect(hole);

    if (palette.length == 1) {
      canvas.drawRect(hole, Paint()..color = palette.first);
      // a soft highlight gliding along the slot
      final hw = hole.width * 0.22;
      final x = hole.left + phase * hole.width;
      final hl = Paint()
        ..color = Colors.white.withValues(alpha: 0.30)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 8);
      for (final dx in [0.0, -hole.width, hole.width]) {
        canvas.drawRect(Rect.fromLTWH(x + dx - hw / 2, hole.top, hw, hole.height), hl);
      }
    } else {
      // palette as a horizontal gradient, scrolling -> the colors glide along.
      final colors = [...palette, palette.first];
      final shader = LinearGradient(colors: colors, tileMode: TileMode.repeated).createShader(
        Rect.fromLTWH(hole.left - phase * hole.width, hole.top, hole.width, hole.height),
      );
      canvas.drawRect(hole, Paint()..shader = shader);
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(_SlotPainter old) => old.phase != phase || old.palette != palette;
}
