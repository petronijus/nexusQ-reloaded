import 'package:flutter/material.dart';

import '../theme/nexusq_theme.dart';

/// The icons a release item may name (PROTOCOL §12c), in the order of
/// scripts/release_manifest.py ICONS and nexusq-control RELEASE_ICONS;
/// scripts/tests/test_release_manifest.py reads the keys below and keeps the
/// three lists equal. Each has its own colour, so a card of four items reads
/// as four different things at a glance.
const Map<String, IconData> releaseIcons = {
  'new': Icons.auto_awesome,
  'sound': Icons.graphic_eq,
  'speaker': Icons.speaker,
  'wifi': Icons.wifi,
  'bluetooth': Icons.bluetooth,
  'power': Icons.bolt,
  'lights': Icons.light_mode,
  'music': Icons.music_note,
  'usb': Icons.usb,
  'fix': Icons.build_circle,
  'security': Icons.shield,
};

// The stock LED palette, so the card speaks the Q's own colours.
const Map<String, Color> _releaseColors = {
  'new': NexusQColors.accent,
  'sound': NexusQColors.ledPurple,
  'speaker': NexusQColors.ledPurple,
  'wifi': NexusQColors.ledBlue,
  'bluetooth': NexusQColors.ledBlue,
  'power': NexusQColors.ledYellow,
  'lights': NexusQColors.ledOrange,
  'music': NexusQColors.ledPurple,
  'usb': NexusQColors.ledGreen,
  'fix': NexusQColors.ledGreen,
  'security': NexusQColors.white,
};

IconData releaseIcon(String name) => releaseIcons[name] ?? Icons.auto_awesome;

Color releaseIconColor(String name) =>
    _releaseColors[name] ?? NexusQColors.accent;
