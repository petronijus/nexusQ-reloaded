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
    this.transport = 'none',
  });

  final bool playing;
  final String artist, track, album, artUrl, source;

  /// Who can drive the current source — `device`, `spotify-web` or `none`
  /// (PROTOCOL.md §5). Decided by the bridge per source; the app routes
  /// play/pause/next by THIS, never by [source].
  final String transport;

  NowPlaying copyWith({bool? playing}) => NowPlaying(
        playing: playing ?? this.playing,
        artist: artist,
        track: track,
        album: album,
        artUrl: artUrl,
        source: source,
        transport: transport,
      );

  bool get isEmpty => track.isEmpty && artist.isEmpty;

  factory NowPlaying.fromJson(Map<String, dynamic> j) => NowPlaying(
        playing: j['playing'] == true,
        artist: j['artist'] as String? ?? '',
        track: j['track'] as String? ?? '',
        album: j['album'] as String? ?? '',
        artUrl: j['artUrl'] as String? ?? '',
        source: j['source'] as String? ?? '',
        // Older bridges (pre-r33) did not send it; treat absent as `none`, which
        // disables the buttons — the honest default, since such a bridge cannot
        // drive anything either.
        transport: j['transport'] as String? ?? 'none',
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

/// The LED ring switch and its schedule (PROTOCOL §4, "LED ring on/off").
/// Off keeps the ring dark except for what answers the user — the music
/// visualiser and the volume-knob overlay. Any manual switch disables the
/// schedule (the bridge enforces it; the app only mirrors it).
class RingState {
  const RingState({
    this.on = true,
    this.scheduleEnabled = false,
    this.offAt = '23:00',
    this.onAt = '07:00',
    this.clockSynced = true,
  });

  final bool on;
  final bool scheduleEnabled;
  final String offAt; // 'HH:MM', the Q's local time
  final String onAt;
  /// False until the Q's clock has been set from network time; a schedule
  /// waits for it (the RTC has no backup cell).
  final bool clockSynced;

  factory RingState.fromJson(Map<String, dynamic> j) {
    final s = j['schedule'] is Map ? Map<String, dynamic>.from(j['schedule']) : const <String, dynamic>{};
    return RingState(
      on: j['on'] is bool ? j['on'] as bool : true,
      scheduleEnabled: s['enabled'] is bool ? s['enabled'] as bool : false,
      offAt: s['off'] is String ? s['off'] as String : '23:00',
      onAt: s['on'] is String ? s['on'] as String : '07:00',
      clockSynced: j['clockSynced'] is bool ? j['clockSynced'] as bool : true,
    );
  }

  RingState copyWith({bool? on, bool? scheduleEnabled, String? offAt, String? onAt}) => RingState(
        on: on ?? this.on,
        scheduleEnabled: scheduleEnabled ?? this.scheduleEnabled,
        offAt: offAt ?? this.offAt,
        onAt: onAt ?? this.onAt,
        clockSynced: clockSynced,
      );
}

/// Ambient brightness (PROTOCOL §4, "Ambient brightness"). With it on, the
/// brightness slider is the MAXIMUM and the Q dims the ring through dusk by
/// the sun at its time zone's location — never to dark.
class AmbientState {
  const AmbientState({
    this.enabled = false,
    this.level = 255,
    this.zone,
    this.clockSynced = true,
  });

  final bool enabled;
  /// What the ring runs at right now (0..255), under the slider's maximum.
  final int level;
  /// The time zone the location comes from; null = no known location, so
  /// ambient cannot be switched on.
  final String? zone;
  final bool clockSynced;

  bool get available => zone != null;

  factory AmbientState.fromJson(Map<String, dynamic> j) {
    final loc = j['location'] is Map ? Map<String, dynamic>.from(j['location']) : null;
    return AmbientState(
      enabled: j['enabled'] is bool ? j['enabled'] as bool : false,
      level: j['level'] is num ? (j['level'] as num).round() : 255,
      zone: loc != null && loc['zone'] is String ? loc['zone'] as String : null,
      clockSynced: j['clockSynced'] is bool ? j['clockSynced'] as bool : true,
    );
  }

  AmbientState copyWith({bool? enabled}) => AmbientState(
        enabled: enabled ?? this.enabled,
        level: level,
        zone: zone,
        clockSynced: clockSynced,
      );
}

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
    this.ring,
    this.ambient,
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
  /// Null when the bridge predates the ring switch — the app then offers none.
  RingState? ring;
  /// Null when the bridge predates ambient brightness — no switch then.
  AmbientState? ambient;

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
        ring: ring,
        ambient: ambient,
      );

  void applyJson(Map<String, dynamic> j) {
    if (j['volume'] is num) volume = (j['volume'] as num).round();
    if (j['muted'] is bool) muted = j['muted'] as bool;
    if (j['brightness'] is num) brightness = (j['brightness'] as num).round();
    if (j['theme'] is String) theme = j['theme'] as String;
    if (j['scene'] is String) scene = j['scene'] as String;
    if (j['output'] is String) output = j['output'] as String;
    if (j['nowPlaying'] is Map) nowPlaying = NowPlaying.fromJson(Map<String, dynamic>.from(j['nowPlaying']));
    if (j['ring'] is Map) ring = RingState.fromJson(Map<String, dynamic>.from(j['ring']));
    if (j['ambient'] is Map) ambient = AmbientState.fromJson(Map<String, dynamic>.from(j['ambient']));
    // NB: `getState` also carries a `name`, and it is deliberately IGNORED here.
    // The bridge snapshots it into its state dict at start-up and never
    // refreshes it, so after a rename that field serves the OLD name — and the
    // 25 s heartbeat probe would drag it back over the new one, forever.
    // Identity has one source: [applyIdentity].
  }

  /// Apply `getDeviceInfo` / a `deviceInfoChanged` event — the authoritative
  /// identity of the box, the only thing allowed to set [deviceName].
  void applyIdentity(Map<String, dynamic> j) {
    final n = j['name'];
    if (n is String && n.trim().isNotEmpty) deviceName = n.trim();
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
