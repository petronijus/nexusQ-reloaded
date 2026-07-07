import 'dart:async';
import 'client.dart';

/// In-process fake device implementing PROTOCOL.md v1, so the app runs and the
/// UI can be developed without the real bridge/hardware. Mirrors the real
/// request/response + event semantics.
class MockClient implements NexusQClient {
  final _events = StreamController<NexusQEvent>.broadcast();
  final _conn = StreamController<bool>.broadcast();
  Timer? _trackTimer;

  int _volume = 42;
  bool _muted = false;
  int _brightness = 200;
  String _theme = 'blue';
  String _scene = 'waveform';
  String _output = 'speaker';
  bool _playing = true;
  int _trackIdx = 0;

  static const _outputs = [
    {'id': 'speaker', 'label': 'Reproduktor', 'sink': 'alsa_output.platform-sound-tas5713.stereo-fallback', 'available': true},
    {'id': 'spdif', 'label': 'Optický výstup', 'sink': 'alsa_output.platform-sound-spdif.stereo-fallback', 'available': true},
  ];

  static const _tracks = [
    {'artist': 'Boards of Canada', 'track': 'Roygbiv', 'album': 'Music Has the Right to Children'},
    {'artist': 'Tycho', 'track': 'Awake', 'album': 'Awake'},
    {'artist': 'Jon Hopkins', 'track': 'Open Eye Signal', 'album': 'Immunity'},
    {'artist': 'Bonobo', 'track': 'Kerala', 'album': 'Migration'},
  ];

  @override
  Stream<NexusQEvent> get events => _events.stream;
  @override
  Stream<bool> get connection => _conn.stream;

  @override
  Future<void> connect() async {
    await Future<void>.delayed(const Duration(milliseconds: 300));
    _conn.add(true);
    // simulate track changes while "playing"
    _trackTimer = Timer.periodic(const Duration(seconds: 20), (_) {
      if (_playing) {
        _trackIdx = (_trackIdx + 1) % _tracks.length;
        _emitNowPlaying();
      }
    });
  }

  Map<String, dynamic> get _nowPlaying => {
        'playing': _playing,
        ..._tracks[_trackIdx],
        'artUrl': '',
        'source': 'spotify',
      };

  Map<String, dynamic> get _state => {
        'volume': _volume,
        'muted': _muted,
        'brightness': _brightness,
        'theme': _theme,
        'scene': _scene,
        'output': _output,
        'nowPlaying': _nowPlaying,
        'name': 'Nexus Q (mock)',
      };

  void _emitVolume() => _events.add(NexusQEvent('volumeChanged', {'volume': _volume, 'muted': _muted}));
  void _emitNowPlaying() => _events.add(NexusQEvent('nowPlayingChanged', _nowPlaying));

  @override
  Future<Map<String, dynamic>> call(String method, [Map<String, dynamic>? params]) async {
    final p = params ?? const {};
    switch (method) {
      case 'subscribe':
        return {'subscribed': ['*']};
      case 'getState':
        return _state;
      case 'getDeviceInfo':
        return {'name': 'Nexus Q (mock)', 'model': 'steelhead', 'serial': 'MOCK0001', 'swVersion': 'dev'};
      case 'setVolume':
        _volume = (p['volume'] as num).round().clamp(0, 100);
        _muted = false;
        _emitVolume();
        return {'volume': _volume, 'muted': _muted};
      case 'adjustVolume':
        _volume = (_volume + (p['steps'] as num).round()).clamp(0, 100);
        _emitVolume();
        return {'volume': _volume, 'muted': _muted};
      case 'setMuted':
        _muted = p['muted'] as bool;
        _emitVolume();
        return {'volume': _volume, 'muted': _muted};
      case 'toggleMute':
        _muted = !_muted;
        _emitVolume();
        return {'volume': _volume, 'muted': _muted};
      case 'setTheme':
        _theme = p['theme'] as String;
        _events.add(NexusQEvent('themeChanged', {'theme': _theme}));
        return {'theme': _theme};
      case 'setScene':
        _scene = p['scene'] as String;
        _events.add(NexusQEvent('sceneChanged', {'scene': _scene}));
        return {'scene': _scene};
      case 'listOutputs':
        return {'outputs': _outputs, 'active': _output};
      case 'setOutput':
        final id = p['output'] as String;
        if (!_outputs.any((o) => o['id'] == id)) {
          throw NexusQError('bad_request', 'unknown output $id');
        }
        _output = id;
        _events.add(NexusQEvent('outputChanged', {'output': _output}));
        return {'output': _output};
      case 'setBrightness':
        _brightness = (p['brightness'] as num).round().clamp(0, 255);
        _events.add(NexusQEvent('brightnessChanged', {'brightness': _brightness}));
        return {'brightness': _brightness};
      case 'playPause':
        _playing = !_playing;
        _emitNowPlaying();
        return {'playing': _playing};
      case 'next':
        _trackIdx = (_trackIdx + 1) % _tracks.length;
        _emitNowPlaying();
        return {};
      case 'previous':
        _trackIdx = (_trackIdx - 1 + _tracks.length) % _tracks.length;
        _emitNowPlaying();
        return {};
      default:
        throw NexusQError('unknown_method', method);
    }
  }

  @override
  void notify(String method, [Map<String, dynamic>? params]) {
    call(method, params);
  }

  @override
  Future<void> close() async {
    _trackTimer?.cancel();
    await _events.close();
    await _conn.close();
  }
}
