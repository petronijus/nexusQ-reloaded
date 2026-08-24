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
  // Mirrors the device's 7-band parametric EQ (PROTOCOL §14) closely enough that
  // widget tests exercise the real shapes: bands in, bands out, plus the
  // bass_db/treble_db compatibility view.
  static const _eqDefaults = [
    ['lowshelf', 100.0], ['peaking', 200.0], ['peaking', 430.0],
    ['peaking', 900.0], ['peaking', 1800.0], ['peaking', 3800.0],
    ['highshelf', 8000.0],
  ];
  late final List<Map<String, dynamic>> _eqBands = [
    for (final d in _eqDefaults)
      {'type': d[0], 'freq_hz': d[1], 'gain_db': 0.0,
       'q': d[0] == 'peaking' ? 0.707 : 1.0, 'enabled': true}
  ];
  double _eqPreamp = 0.0;

  double get _eqHeadroom {
    var peak = 0.0;
    for (final b in _eqBands) {
      final g = (b['gain_db'] as num).toDouble();
      if ((b['enabled'] as bool) && g > peak) peak = g;
    }
    return double.parse((peak + _eqPreamp).toStringAsFixed(2));
  }

  int _eqShelf(String type) => _eqBands.indexWhere((b) => b['type'] == type);

  Map<String, dynamic> get _eqState => {
        'supported': true,
        'bands': [for (final b in _eqBands) Map<String, dynamic>.from(b)],
        'preamp_db': _eqPreamp,
        'headroom_db': _eqHeadroom,
        'max_bands': _eqBands.length,
        'limits': {
          'gain_db': 12.0,
          'freq_hz': [20.0, 20000.0],
          'q': [0.3, 8.0],
          'preamp_db': [-24.0, 0.0],
        },
        'bass_db': _eqBands[_eqShelf('lowshelf')]['gain_db'],
        'treble_db': _eqBands[_eqShelf('highshelf')]['gain_db'],
      };

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

  /// In-process — the "link" can never drop, so no reconnect/heartbeat/resume
  /// supervision is wanted (and none of it must run under plain `test()`).
  @override
  bool get needsSupervision => false;

  @override
  void disconnect() {/* nothing to tear down — the mock link is permanent */}

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
      case 'getEq':
        return _eqState;
      case 'setEq':
        final bands = p['bands'];
        if (bands != null) {
          if (bands is! List) throw NexusQError('bad_params', 'bands must be a list');
          for (var i = 0; i < bands.length && i < _eqBands.length; i++) {
            final b = bands[i];
            if (b is! Map) continue;
            for (final k in ['freq_hz', 'gain_db', 'q']) {
              final v = b[k];
              if (v is num) _eqBands[i][k] = v.toDouble();
            }
            if (b['enabled'] is bool) _eqBands[i]['enabled'] = b['enabled'];
          }
        }
        for (final e in [['bass_db', 'lowshelf'], ['treble_db', 'highshelf']]) {
          final v = p[e[0]];
          if (v != null) {
            if (v is! num) throw NexusQError('bad_params', '${e[0]} must be a number');
            _eqBands[_eqShelf(e[1])]['gain_db'] = v.toDouble().clamp(-12.0, 12.0);
          }
        }
        if (p['preamp_db'] is num) {
          _eqPreamp = (p['preamp_db'] as num).toDouble().clamp(-24.0, 0.0);
        }
        if (p['auto_preamp'] == true) {
          _eqPreamp = 0;
          _eqPreamp = _eqHeadroom > 0 ? -_eqHeadroom : 0;
        }
        _events.add(NexusQEvent('eqChanged', _eqState));
        return _eqState;
      case 'listEqPresets':
        return {
          'presets': [
            {'id': 'flat', 'label': 'Flat', 'preamp_db': 0.0,
             'bands': [for (final b in _eqBands)
               {...b, 'gain_db': 0.0}]},
            {'id': 'bass', 'label': 'Bass boost', 'preamp_db': -6.0,
             'bands': [for (var i = 0; i < _eqBands.length; i++)
               {..._eqBands[i], 'gain_db': i == 0 ? 6.0 : 0.0}]},
          ]
        };
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
