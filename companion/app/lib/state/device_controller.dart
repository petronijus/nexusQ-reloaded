import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/widgets.dart';
import '../protocol/client.dart';
import '../protocol/models.dart';

/// Holds [DeviceState], applies device events to it, and exposes intent methods
/// the UI calls. Optimistic: updates locally then sends, and reconciles on the
/// echoed event/result.
///
/// For supervised transports ([NexusQClient.needsSupervision]) it also keeps
/// the link alive across the app lifecycle:
///  * socket drop in the foreground → auto-reconnect with exponential backoff
///    (1s → 15s cap, retrying forever), full re-hydration (subscribe inside
///    [NexusQClient.connect] + getState + listOutputs) on success;
///  * app resumed → active `getState` probe with a short timeout — a half-open
///    socket after Android doze looks connected until written to, so a passive
///    check is worthless; a failed probe drops + reconnects immediately;
///  * foreground heartbeat (~25s `getState`) to catch silent drops (WiFi
///    blips) while the app is open;
///  * backgrounded (paused/inactive/hidden) → every timer paused, so nothing
///    burns battery behind the user's back.
class DeviceController extends ChangeNotifier with WidgetsBindingObserver {
  DeviceController(this._client);

  static const _probeTimeout = Duration(seconds: 3);
  static const _heartbeatPeriod = Duration(seconds: 25);
  static const _maxBackoff = Duration(seconds: 15);

  final NexusQClient _client;

  /// The live client, for screens that call the bridge directly rather than
  /// through this controller's cached state (e.g. the Devices screen's
  /// Bluetooth + desktop methods, which are one-shot actions, not state).
  NexusQClient get client => _client;
  final state = DeviceState();
  StreamSubscription? _evSub, _connSub;

  bool _disposed = false;
  bool _inForeground = true;
  bool _connectInFlight = false;
  bool _probeInFlight = false;
  int _attempt = 0; // consecutive failed reconnects, drives the backoff ladder
  Timer? _retryTimer, _heartbeat;

  Future<void> start() async {
    _evSub = _client.events.listen(_onEvent);
    _connSub = _client.connection.listen(_onConnection);
    if (_client.needsSupervision) {
      // Only the real transport watches the lifecycle — the mock never drops
      // (and plain `test()` has no WidgetsBinding to observe).
      WidgetsBinding.instance.addObserver(this);
      final ls = WidgetsBinding.instance.lifecycleState;
      _inForeground = ls == null || ls == AppLifecycleState.resumed;
    }
    await _connect();
  }

  // --- connection supervision ----------------------------------------------

  void _onConnection(bool up) {
    if (_disposed) return;
    state.connected = up;
    if (up) {
      _attempt = 0;
      state.reconnecting = false;
      _hydrate();
      _startHeartbeat();
    } else {
      _stopHeartbeat();
      if (_client.needsSupervision) {
        state.reconnecting = true;
        _scheduleReconnect();
      }
    }
    notifyListeners();
  }

  Future<void> _connect() async {
    if (_disposed || _connectInFlight) return;
    _retryTimer?.cancel();
    _retryTimer = null;
    _connectInFlight = true;
    var ok = true;
    try {
      await _client.connect();
      // success is signalled via the connection stream → _onConnection(true)
    } catch (_) {
      ok = false;
    } finally {
      _connectInFlight = false;
    }
    if (_disposed || ok) return;
    state.connected = false;
    if (_client.needsSupervision) {
      state.reconnecting = true;
      _scheduleReconnect();
    }
    notifyListeners();
  }

  void _scheduleReconnect() {
    if (_disposed || !_client.needsSupervision || !_inForeground) return;
    if (_retryTimer != null || _connectInFlight) return;
    // 1, 2, 4, 8 then capped at 15 seconds — forever, until the link is back.
    final delay = Duration(
        seconds: math.min(1 << math.min(_attempt, 4), _maxBackoff.inSeconds));
    _attempt++;
    _retryTimer = Timer(delay, () {
      _retryTimer = null;
      _connect();
    });
  }

  void _startHeartbeat() {
    _stopHeartbeat();
    if (_disposed || !_client.needsSupervision || !_inForeground) return;
    _heartbeat = Timer.periodic(_heartbeatPeriod, (_) => _probe());
  }

  void _stopHeartbeat() {
    _heartbeat?.cancel();
    _heartbeat = null;
  }

  /// Active liveness check: request `getState` and treat any error or
  /// [_probeTimeout] of silence as a dead link (a half-open socket never
  /// errors on its own — it must be written to). On failure the transport is
  /// torn down, which flows back through [_onConnection] as a drop.
  Future<bool> _probe() async {
    if (_disposed || _probeInFlight || !state.connected) return state.connected;
    _probeInFlight = true;
    try {
      final s = await _client.call('getState').timeout(_probeTimeout);
      if (_disposed) return false;
      state.applyJson(s); // the probe doubles as a free state refresh
      notifyListeners();
      return true;
    } catch (_) {
      if (!_disposed) _client.disconnect();
      return false;
    } finally {
      _probeInFlight = false;
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // NB: the parameter shadows our [state] field (the override signature
    // demands the name); this method touches only timers, never DeviceState.
    switch (state) {
      case AppLifecycleState.resumed:
        _inForeground = true;
        _onResumed();
      case AppLifecycleState.inactive:
      case AppLifecycleState.hidden:
      case AppLifecycleState.paused:
      case AppLifecycleState.detached:
        _inForeground = false;
        _stopHeartbeat();
        _retryTimer?.cancel();
        _retryTimer = null;
    }
  }

  Future<void> _onResumed() async {
    if (_disposed || !_client.needsSupervision) return;
    _attempt = 0; // a fresh foreground session earns a fresh backoff ladder
    if (!state.connected) {
      state.reconnecting = true;
      notifyListeners();
      await _connect();
      return;
    }
    // The socket may be half-open after doze — verify before trusting it.
    if (await _probe()) {
      _startHeartbeat();
    } else {
      await _connect(); // immediate — don't make the user wait out a backoff
    }
  }

  /// Manual retry (the banner's Retry button): skip any pending backoff wait
  /// and dial right now.
  Future<void> reconnectNow() async {
    if (_disposed) return;
    _attempt = 0;
    state.reconnecting = true;
    notifyListeners();
    await _connect();
  }

  // --- state hydration ------------------------------------------------------

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
    _disposed = true;
    if (_client.needsSupervision) {
      WidgetsBinding.instance.removeObserver(this);
    }
    _retryTimer?.cancel();
    _stopHeartbeat();
    _evSub?.cancel();
    _connSub?.cancel();
    _client.close();
    super.dispose();
  }
}
