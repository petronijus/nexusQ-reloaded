import 'package:flutter/material.dart';
import '../theme/nexusq_theme.dart';

/// Now-playing metadata (from librespot on the device).
class NowPlaying {
  const NowPlaying({
    this.playing = false,
    this.artist = '',
    this.track = '',
    this.album = '',
    this.artUrl = '',
    this.source = '',
  });

  final bool playing;
  final String artist, track, album, artUrl, source;

  bool get isEmpty => track.isEmpty && artist.isEmpty;

  factory NowPlaying.fromJson(Map<String, dynamic> j) => NowPlaying(
        playing: j['playing'] == true,
        artist: j['artist'] as String? ?? '',
        track: j['track'] as String? ?? '',
        album: j['album'] as String? ?? '',
        artUrl: j['artUrl'] as String? ?? '',
        source: j['source'] as String? ?? '',
      );
}

/// A LED ring theme preset (the 7 shipped by the original — RE doc §3.2).
class LedTheme {
  const LedTheme(this.name, this.label, this.colors, {this.led = true, this.display = true});
  final String name;
  final String label;
  final List<Color> colors;
  final bool led, display;

  Color get primary => colors.isNotEmpty ? colors.first : NexusQColors.accent;
}

const kLedThemes = <LedTheme>[
  LedTheme('spectrum', 'Spectrum', [
    NexusQColors.ledRed, NexusQColors.ledOrange, NexusQColors.ledYellow,
    NexusQColors.ledGreen, NexusQColors.ledBlue, NexusQColors.ledPurple,
  ]),
  LedTheme('warm', 'Warm', [Color(0xFFCC0000), Color(0xFFFF4444), NexusQColors.ledOrange, NexusQColors.ledYellow]),
  LedTheme('cool', 'Cool', [Color(0xFF99CC00), NexusQColors.ledGreen, NexusQColors.ledBlue, NexusQColors.accent]),
  LedTheme('blue', 'Blue', [NexusQColors.accent]),
  LedTheme('smoke', 'Smoke', [Color(0xFF222222), Color(0xFF111111)]),
  LedTheme('off', 'Off', [Color(0xFF000000)], led: false, display: false),
  LedTheme('trackinfo', 'Track Info', [
    NexusQColors.ledRed, NexusQColors.ledOrange, NexusQColors.ledYellow,
    NexusQColors.ledGreen, NexusQColors.ledBlue, NexusQColors.ledPurple,
  ], display: false),
];

LedTheme themeByName(String name) =>
    kLedThemes.firstWhere((t) => t.name == name, orElse: () => kLedThemes[3]);

/// The full device state mirrored from the bridge (`getState` / events).
class DeviceState {
  DeviceState({
    this.volume = 50,
    this.muted = false,
    this.brightness = 200,
    this.theme = 'blue',
    this.nowPlaying = const NowPlaying(),
    this.connected = false,
    this.deviceName = 'Nexus Q',
  });

  int volume; // 0..100
  bool muted;
  int brightness; // 0..255
  String theme;
  NowPlaying nowPlaying;
  bool connected;
  String deviceName;

  DeviceState copy() => DeviceState(
        volume: volume,
        muted: muted,
        brightness: brightness,
        theme: theme,
        nowPlaying: nowPlaying,
        connected: connected,
        deviceName: deviceName,
      );

  void applyJson(Map<String, dynamic> j) {
    if (j['volume'] is num) volume = (j['volume'] as num).round();
    if (j['muted'] is bool) muted = j['muted'] as bool;
    if (j['brightness'] is num) brightness = (j['brightness'] as num).round();
    if (j['theme'] is String) theme = j['theme'] as String;
    if (j['nowPlaying'] is Map) nowPlaying = NowPlaying.fromJson(Map<String, dynamic>.from(j['nowPlaying']));
    if (j['name'] is String) deviceName = j['name'] as String;
  }
}
