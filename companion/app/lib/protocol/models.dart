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

/// An audio OUTPUT sink exposed by the device (`listOutputs`). Input-agnostic:
/// the device routes whatever is currently playing (Spotify now; BT/Tidal/cast
/// later) to the selected output.
class AudioOutput {
  const AudioOutput({required this.id, required this.label, this.available = true});
  final String id;
  final String label;
  final bool available;

  factory AudioOutput.fromJson(Map<String, dynamic> j) => AudioOutput(
        id: j['id'] as String? ?? '',
        label: j['label'] as String? ?? (j['id'] as String? ?? ''),
        available: j['available'] is bool ? j['available'] as bool : true,
      );

  /// A Holo-style glyph per known output id (falls back to a generic speaker).
  IconData get icon {
    switch (id) {
      case 'speaker':
        return Icons.speaker;
      case 'spdif':
        return Icons.fiber_manual_record; // optical / TOSLINK
      case 'hdmi':
        return Icons.tv;
      default:
        return Icons.volume_up;
    }
  }
}

/// Shown until the bridge's `listOutputs` fills in the real set — the two
/// always-present hardware outputs (matches the device's speaker + optical).
const kDefaultOutputs = <AudioOutput>[
  AudioOutput(id: 'speaker', label: 'Reproduktor'),
  AudioOutput(id: 'spdif', label: 'Optický výstup'),
];

/// The full device state mirrored from the bridge (`getState` / events).
class DeviceState {
  DeviceState({
    this.volume = 50,
    this.muted = false,
    this.brightness = 200,
    this.theme = 'blue',
    this.scene = 'waveform',
    this.output = 'speaker',
    List<AudioOutput>? outputs,
    this.nowPlaying = const NowPlaying(),
    this.connected = false,
    this.reconnecting = false,
    this.deviceName = 'Nexus Q',
  }) : outputs = outputs ?? kDefaultOutputs;

  int volume; // 0..100
  bool muted;
  int brightness; // 0..255
  String theme;
  String scene; // active music visualisation (kVisualizations name)
  String output; // active audio output id (speaker/spdif/hdmi)
  List<AudioOutput> outputs; // available outputs, from listOutputs
  NowPlaying nowPlaying;
  bool connected;
  bool reconnecting; // link down, the controller is auto-retrying
  String deviceName;

  DeviceState copy() => DeviceState(
        volume: volume,
        muted: muted,
        brightness: brightness,
        theme: theme,
        scene: scene,
        output: output,
        outputs: outputs,
        nowPlaying: nowPlaying,
        connected: connected,
        reconnecting: reconnecting,
        deviceName: deviceName,
      );

  void applyJson(Map<String, dynamic> j) {
    if (j['volume'] is num) volume = (j['volume'] as num).round();
    if (j['muted'] is bool) muted = j['muted'] as bool;
    if (j['brightness'] is num) brightness = (j['brightness'] as num).round();
    if (j['theme'] is String) theme = j['theme'] as String;
    if (j['scene'] is String) scene = j['scene'] as String;
    if (j['output'] is String) output = j['output'] as String;
    if (j['nowPlaying'] is Map) nowPlaying = NowPlaying.fromJson(Map<String, dynamic>.from(j['nowPlaying']));
    if (j['name'] is String) deviceName = j['name'] as String;
  }

  /// Apply a `listOutputs` result: the available outputs + the active one.
  void applyOutputs(Map<String, dynamic> j) {
    if (j['outputs'] is List) {
      outputs = [
        for (final o in (j['outputs'] as List))
          if (o is Map) AudioOutput.fromJson(Map<String, dynamic>.from(o)),
      ];
    }
    if (j['active'] is String) output = j['active'] as String;
  }
}
