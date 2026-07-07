import 'dart:async';
import 'package:flutter/foundation.dart';
import '../protocol/client.dart';
import '../protocol/models.dart';

/// Holds [DeviceState], applies device events to it, and exposes intent methods
/// the UI calls. Optimistic: updates locally then sends, and reconciles on the
/// echoed event/result.
class DeviceController extends ChangeNotifier {
  DeviceController(this._client);

  final NexusQClient _client;
  final state = DeviceState();
  StreamSubscription? _evSub, _connSub;

  Future<void> start() async {
    _evSub = _client.events.listen(_onEvent);
    _connSub = _client.connection.listen((up) {
      state.connected = up;
      notifyListeners();
      if (up) _hydrate();
    });
    try {
      await _client.connect();
    } catch (_) {
      state.connected = false;
      notifyListeners();
    }
  }

  Future<void> _hydrate() async {
    try {
      final s = await _client.call('getState');
      state.applyJson(s);
      notifyListeners();
    } catch (_) {/* stays on defaults until first event */}
    try {
      final o = await _client.call('listOutputs');
      state.applyOutputs(o);
      notifyListeners();
    } catch (_) {/* keep the default output set until it's available */}
  }

  void _onEvent(NexusQEvent e) {
    switch (e.event) {
      case 'volumeChanged':
        if (e.data['volume'] is num) state.volume = (e.data['volume'] as num).round();
        if (e.data['muted'] is bool) state.muted = e.data['muted'] as bool;
      case 'themeChanged':
        if (e.data['theme'] is String) state.theme = e.data['theme'] as String;
      case 'sceneChanged':
        if (e.data['scene'] is String) state.scene = e.data['scene'] as String;
      case 'brightnessChanged':
        if (e.data['brightness'] is num) state.brightness = (e.data['brightness'] as num).round();
      case 'outputChanged':
        if (e.data['output'] is String) state.output = e.data['output'] as String;
      case 'nowPlayingChanged':
        state.nowPlaying = NowPlaying.fromJson(e.data);
    }
    notifyListeners();
  }

  // --- intents (optimistic local update + send) ---------------------------
  void setVolume(int v) {
    state.volume = v.clamp(0, 100);
    state.muted = false;
    notifyListeners();
    _client.notify('setVolume', {'volume': state.volume});
  }

  void toggleMute() {
    state.muted = !state.muted;
    notifyListeners();
    _client.notify('toggleMute');
  }

  void setTheme(String name) {
    state.theme = name;
    notifyListeners();
    _client.notify('setTheme', {'theme': name});
  }

  void setScene(String name) {
    state.scene = name;
    notifyListeners();
    _client.notify('setScene', {'scene': name});
  }

  void setBrightness(int b) {
    state.brightness = b.clamp(0, 255);
    notifyListeners();
    _client.notify('setBrightness', {'brightness': state.brightness});
  }

  void setOutput(String id) {
    state.output = id;
    notifyListeners();
    _client.notify('setOutput', {'output': id});
  }

  void playPause() {
    state.nowPlaying = NowPlaying(
      playing: !state.nowPlaying.playing,
      artist: state.nowPlaying.artist,
      track: state.nowPlaying.track,
      album: state.nowPlaying.album,
      artUrl: state.nowPlaying.artUrl,
      source: state.nowPlaying.source,
    );
    notifyListeners();
    _client.notify('playPause');
  }

  void next() => _client.notify('next');
  void previous() => _client.notify('previous');

  @override
  void dispose() {
    _evSub?.cancel();
    _connSub?.cancel();
    _client.close();
    super.dispose();
  }
}
