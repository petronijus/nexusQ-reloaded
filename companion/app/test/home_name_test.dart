import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexusq_companion/protocol/models.dart';
import 'package:nexusq_companion/screens/home_screen.dart';
import 'package:nexusq_companion/theme/nexusq_theme.dart';

/// The device name is shown ONCE, under the sphere, in the light theme's colour.
///
/// The colour rule has a trap worth pinning: the `off` theme is pure black, and
/// black on this black canvas would erase the only text saying which box you are
/// looking at.
void main() {
  test('the name takes the light theme colour', () {
    for (final name in ['blue', 'warm', 'cool', 'rose', 'smoke']) {
      final t = themeByName(name);
      expect(nameColorFor(t), t.primary, reason: name);
    }
  });

  test('a theme too dark to read falls back to white', () {
    expect(nameColorFor(themeByName('off')), NexusQColors.white);
    // Not a name check — any near-black preset must behave the same.
    expect(
      nameColorFor(const LedTheme('midnight', 'Midnight', [Color(0xFF050505)])),
      NexusQColors.white,
    );
  });

  test('a dim but readable theme keeps its own colour', () {
    // Smoke (0xFF6E7387) is the darkest shipped colour that must NOT be
    // overridden — it is the guard against a fallback threshold set too high.
    final smoke = themeByName('smoke');
    expect(nameColorFor(smoke), smoke.primary);
  });
}
