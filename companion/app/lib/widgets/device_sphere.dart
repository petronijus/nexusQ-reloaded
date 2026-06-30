import 'package:flutter/material.dart';
import '../theme/nexusq_theme.dart';

/// The device as the original app showed it: the black Nexus Q sphere with the
/// equatorial LED ring (the "drop ball" graphic). On = lit ring, off/muted =
/// dim. A theme-tinted glow under the sphere echoes the current LED theme color.
class DeviceSphere extends StatelessWidget {
  const DeviceSphere({
    super.key,
    required this.on,
    this.glow = NexusQColors.accent,
    this.size = 180,
  });

  final bool on;
  final Color glow;
  final double size;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size,
      height: size,
      child: Stack(
        alignment: Alignment.center,
        children: [
          if (on)
            // soft theme-colored glow at the base, like the lit LED ring
            Positioned(
              bottom: size * 0.12,
              child: Container(
                width: size * 0.7,
                height: size * 0.18,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(size),
                  boxShadow: [
                    BoxShadow(color: glow.withValues(alpha: 0.55), blurRadius: 28, spreadRadius: 2),
                  ],
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
