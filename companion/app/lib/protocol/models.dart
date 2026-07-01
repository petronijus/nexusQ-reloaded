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

// LED "themes" retint the idle *breathing* animation (the default #0099CC breathe,
// but in the theme's hue) — a mood color, not a static fill. The device breathes in
// this color when idle; music playback takes over with the selected Visualization.
const kLedThemes = <LedTheme>[
  LedTheme('blue',  'Blue',  [Color(0xFF0099CC)]),   // the original breathe color
  LedTheme('warm',  'Warm',  [Color(0xFFFF5A0A)]),
  LedTheme('cool',  'Cool',  [Color(0xFF00C88C)]),
  LedTheme('rose',  'Rose',  [Color(0xFFFF285A)]),
  LedTheme('smoke', 'Smoke', [Color(0xFF6E7387)]),
  LedTheme('off',   'Off',   [Color(0xFF000000)], led: false, display: false),
];

LedTheme themeByName(String name) =>
    kLedThemes.firstWhere((t) => t.name == name, orElse: () => kLedThemes[0]);

/// A music-reactive visualisation (nexusqd RenderEngine scene 0..4). Selected
/// separately from the color theme; shown on the ring while audio is playing.
class Visualization {
  const Visualization(this.name, this.label, this.icon);
  final String name;
  final String label;
  final IconData icon;
}

const kVisualizations = <Visualization>[
  Visualization('waveform',      'Waveform',   Icons.graphic_eq),
  Visualization('waveformsolid', 'Solid Wave', Icons.show_chart),
  Visualization('circles',       'Circles',    Icons.blur_circular),
  Visualization('pointmorph',    'Morph',      Icons.scatter_plot),
  Visualization('starfield',     'Starfield',  Icons.auto_awesome),
];

/// The full device state mirrored from the bridge (`getState` / events).
class DeviceState {
  DeviceState({
    this.volume = 50,
    this.muted = false,
    this.brightness = 200,
    this.theme = 'blue',
    this.scene = 'waveform',
    this.nowPlaying = const NowPlaying(),
    this.connected = false,
    this.deviceName = 'Nexus Q',
  });

  int volume; // 0..100
  bool muted;
  int brightness; // 0..255
  String theme;
  String scene; // active music visualisation (kVisualizations name)
  NowPlaying nowPlaying;
  bool connected;
  String deviceName;

  DeviceState copy() => DeviceState(
        volume: volume,
        muted: muted,
        brightness: brightness,
        theme: theme,
        scene: scene,
        nowPlaying: nowPlaying,
        connected: connected,
        deviceName: deviceName,
      );

  void applyJson(Map<String, dynamic> j) {
    if (j['volume'] is num) volume = (j['volume'] as num).round();
    if (j['muted'] is bool) muted = j['muted'] as bool;
    if (j['brightness'] is num) brightness = (j['brightness'] as num).round();
    if (j['theme'] is String) theme = j['theme'] as String;
    if (j['scene'] is String) scene = j['scene'] as String;
    if (j['nowPlaying'] is Map) nowPlaying = NowPlaying.fromJson(Map<String, dynamic>.from(j['nowPlaying']));
    if (j['name'] is String) deviceName = j['name'] as String;
  }
}
