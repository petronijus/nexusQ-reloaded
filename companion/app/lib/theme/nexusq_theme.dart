import 'package:flutter/material.dart';

/// Design system distilled from the original Nexus Q app
/// (see docs/2026-06-30-companion-design-language.md): Holo-dark canvas,
/// glowing Holo-Blue accent, Roboto, the sphere+ring as the hero element.
class NexusQColors {
  NexusQColors._();

  /// True-black canvas — the glowing sphere renders on pure black.
  static const canvas = Color(0xFF000000);

  /// Surfaces/cards above the canvas (`off_black`).
  static const surface = Color(0xFF252525);

  /// Primary accent — Holo Blue (`title_color` / `holo_blue_light`).
  static const accent = Color(0xFF33B5E5);

  static const white = Color(0xFFFFFFFF);
  static const dim = Color(0x8FFFFFFF);
  static const divider = Color(0x33FFFFFF);

  /// LED ring / theme palette — the exact swatches the device ring + theme
  /// presets use, so on-screen chips and the hardware ring stay in lockstep.
  static const ledWhite = Color(0xFFFFFFFF);
  static const ledOrange = Color(0xFFFF8800);
  static const ledBlue = Color(0xFF0099CC);
  static const ledGreen = Color(0xFF669900);
  static const ledPurple = Color(0xFFAA66CC);
  static const ledYellow = Color(0xFFFFBB33);
  static const ledRed = Color(0xFFCC0000);
}

/// Spacing tokens (from the original `dimens.xml`).
class NexusQSpace {
  NexusQSpace._();
  static const standardMargin = 15.0;
  static const grouped = 6.0;
  static const vertical = 12.0;
  static const buttonHeight = 48.0;
  static const titleSize = 22.0;
}

ThemeData buildNexusQTheme() {
  const scheme = ColorScheme.dark(
    primary: NexusQColors.accent,
    secondary: NexusQColors.accent,
    surface: NexusQColors.surface,
    onPrimary: NexusQColors.canvas,
    onSurface: NexusQColors.white,
  );
  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: NexusQColors.canvas,
    fontFamily: 'Roboto',
    sliderTheme: const SliderThemeData(
      activeTrackColor: NexusQColors.accent,
      inactiveTrackColor: NexusQColors.divider,
      thumbColor: NexusQColors.accent,
      overlayColor: Color(0x3333B5E5),
      trackHeight: 3,
    ),
    appBarTheme: const AppBarTheme(
      backgroundColor: NexusQColors.canvas,
      foregroundColor: NexusQColors.accent,
      elevation: 0,
      centerTitle: true,
      titleTextStyle: TextStyle(
        color: NexusQColors.accent,
        fontSize: NexusQSpace.titleSize,
        fontWeight: FontWeight.w300, // Roboto-Light, the welcome face
        letterSpacing: 0.5,
      ),
    ),
    textTheme: const TextTheme(
      headlineSmall: TextStyle(color: NexusQColors.white, fontWeight: FontWeight.w300),
      titleMedium: TextStyle(color: NexusQColors.white),
      bodyMedium: TextStyle(color: NexusQColors.dim),
    ),
  );
}
