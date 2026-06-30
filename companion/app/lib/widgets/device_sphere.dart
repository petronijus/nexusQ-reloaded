import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import '../theme/nexusq_theme.dart';

/// The device as the original app showed it: the black Nexus Q sphere with the
/// equatorial LED ring (the "drop ball" graphic). The ring glow under the sphere
/// takes the **current LED theme palette** — a single color for solid themes, a
/// blended multi-color bloom for Spectrum / Warm / Cool / Track Info — so the
/// sphere reacts to the theme exactly like the device's real ring. Off/muted →
/// no glow.
class DeviceSphere extends StatelessWidget {
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
  Widget build(BuildContext context) {
    final palette = colors.isEmpty ? const [NexusQColors.accent] : colors;
    return SizedBox(
      width: size,
      height: size,
      child: Stack(
        alignment: Alignment.center,
        children: [
          if (on)
            // theme-colored bloom at the base, blurred — single color or a
            // gradient across the palette for multi-color themes.
            Positioned(
              bottom: size * 0.10,
              child: ImageFiltered(
                imageFilter: ui.ImageFilter.blur(sigmaX: 22, sigmaY: 22),
                child: Opacity(
                  opacity: 0.7,
                  child: Container(
                    width: size * 0.72,
                    height: size * 0.20,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(size),
                      gradient: palette.length > 1
                          ? LinearGradient(colors: palette)
                          : null,
                      color: palette.length == 1 ? palette.first : null,
                    ),
                  ),
                ),
              ),
            ),
          Image.asset(
            on ? 'assets/device/sphere_on.png' : 'assets/device/sphere_off.png',
            width: size,
            height: size,
            filterQuality: FilterQuality.medium,
          ),
        ],
      ),
    );
  }
}
