import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/widgets.dart';
import '../debug/app_log.dart';
import '../protocol/client.dart';
import '../protocol/models.dart';
import '../spotify/spotify_auth.dart';
import '../spotify/spotify_player.dart';
import '../spotify/transport_rules.dart' as rules;
import '../spotify/transport_rules.dart' show TransportRoute;

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
  Timer? _retryTimer, _heartbeat, _queueTimer;

  Future<void> start() async {
    _evSub = _client.events.listen(_onEvent);
    // Queue edits made in the Spotify app itself raise no event here, so a slow
    // tick catches them. 30 s is far below any rate limit and far above what a
    // person notices.
    _queueTimer = Timer.periodic(const Duration(seconds: 30), (_) => refreshQueue());
    // NOT refreshed here: `transportRoute` reads nowPlaying.transport, which is
    // still the default `none` until the first getState lands, so a refresh at
    // construction always takes the early return. _hydrate() does it instead,
    // once there is a state to judge by.
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
    // This is THE banner switch: connected=false is the exact moment the UI
    // shows "Disconnected". Everything above it in the log is the why.
    AppLog.add('ctrl', up ? 'connection UP' : 'connection DOWN → banner shows',
        warn: !up);
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
    } catch (e) {
      AppLog.add('ctrl', 'connect attempt failed: $e', warn: true);
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
    AppLog.add('ctrl', 'reconnect in ${delay.inSeconds}s (attempt $_attempt)');
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
    final sw = Stopwatch()..start();
    try {
      final s = await _client.call('getState').timeout(_probeTimeout);
      if (_disposed) return false;
      AppLog.add('ctrl', 'probe ok ${sw.elapsedMilliseconds}ms');
      state.applyJson(s); // the probe doubles as a free state refresh
      notifyListeners();
      return true;
    } catch (e) {
      // A probe failure is the app UNILATERALLY declaring the link dead — the
      // subsequent DROP/DOWN entries are consequences of this line, not causes.
      AppLog.add('ctrl',
          'probe FAILED after ${sw.elapsedMilliseconds}ms ($e) → tearing the link down',
          warn: true);
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
    //
    // Logged because lifecycle is a prime suspect for banner flicker: screen
    // off/doze half-opens the socket, and the resume probe then tears it down
    // and redials — a real (if brief) disconnect the user sees as a blink.
    AppLog.add('ctrl', 'lifecycle: ${state.name}');
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
      // Only NOW is the transport known, so this is the first moment a queue
      // refresh can do anything. Without it the card came up with the bridge's
      // half — cover and buttons — and stayed that way until the track changed
      // or the 30 s tick came round, which is exactly what Petr saw
      // (2026-09-07: "nejdriv tam je artwork a playpause a pak kdyz dam dalsi
      // song, pribyde timeline a fronta").
      unawaited(refreshQueue());
    } catch (_) {/* stays on defaults until first event */}
    try {
      final o = await _client.call('listOutputs');
      state.applyOutputs(o);
      notifyListeners();
    } catch (_) {/* keep the default output set until it's available */}
    try {
      // Identity is asked for separately because `getState`'s copy of the name
      // goes stale on rename (see DeviceState.applyJson).
      final i = await _client.call('getDeviceInfo');
      state.applyIdentity(i);
      notifyListeners();
    } catch (_) {/* keep the last known name */}
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
        final before = state.nowPlaying;
        state.nowPlaying = NowPlaying.fromJson(e.data);
        // The track moved on, so the queue did too. A play/pause on the same
        // track does not move it, and refreshing on that would just spend
        // requests. The TRANSPORT changing counts as well: `none` ->
        // `spotify-web` is the moment a queue becomes fetchable at all, and
        // waiting for a track change there is what made the timeline arrive
        // one song late.
        // Play/pause changes nothing about the QUEUE, but it changes the
        // position sample: `progress.playing` came from Spotify at fetch time,
        // so after a pause the bar would keep advancing on a stale `true`
        // until the 30 s tick (Petr, 2026-09-07: "zapauzoval jsem prehravani a
        // progress bar porad jede"). The bar also freezes locally and at once
        // — see _ProgressBar — but the position still has to be re-sampled, or
        // resuming would jump.
        if (state.nowPlaying.track != before.track ||
            state.nowPlaying.artist != before.artist ||
            state.nowPlaying.transport != before.transport ||
            state.nowPlaying.playing != before.playing) {
          unawaited(refreshQueue());
        }
      case 'deviceInfoChanged':
        // Broadcast by the bridge on every rename, to every client — so the
        // home screen follows a rename done from this phone AND from another.
        state.applyIdentity(e.data);
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

  // --- transport (PROTOCOL §5) --------------------------------------------
  // Routed by nowPlaying.transport: `device` goes to the bridge, `spotify-web`
  // goes to Spotify's Web API from this phone (librespot has no local control
  // interface, by design), anything else is a no-op with a notice. The buttons
  // are already disabled for the last case; the notice covers a race where the
  // source changed under a tap.

  /// Spotify account link, shared with Settings.
  final SpotifyLink spotify = SpotifyLink.instance;

  /// How a SpotifyPlayer is obtained. Real code builds one on the live link;
  /// tests hand in a fake so nothing dials api.spotify.com.
  @visibleForTesting
  SpotifyPlayer Function(SpotifyLink)? playerFactory;
  SpotifyPlayer get _player => (playerFactory ?? SpotifyPlayer.new)(spotify);

  /// What Spotify says is playing and what follows. `null` until the first
  /// answer, and left alone on a failed refresh — a queue that briefly cannot
  /// be fetched should keep showing what it last knew rather than blinking to
  /// "nothing playing", which reads as a bug.
  SpotifyQueue? queue;
  bool _queueInFlight = false;

  /// Where the current track has got to, sampled at the moment it was fetched.
  /// The bar interpolates from it locally; nothing here ticks.
  SpotifyProgress? progress;

  /// Nothing is loaded anywhere: no current item and nothing queued behind it.
  ///
  /// Pressing play in that state does nothing at all — Spotify has no context
  /// to resume, and librespot answers every request with "context is not
  /// available", which is what surfaced to Petr as an opaque "error 43"
  /// (2026-09-07: "pokud jsem na konci fronty, nemel bych mit moznost dat
  /// play"). So the buttons say it by being disabled rather than by failing.
  ///
  /// The queue is the authority when Spotify is linked, because it knows about
  /// an exhausted context that the bridge cannot see. Otherwise fall back to
  /// what the bridge reports, which since control r41 is honestly empty once
  /// librespot says `stopped`.
  bool get nothingToPlay {
    // A `device` transport means the BRIDGE said it can act — for AirPlay that
    // is shairport's own CanControl, checked against a live session. Trust it.
    //
    // Not trusting it cost an evening: AirPlay from macOS system audio carries
    // NO track metadata (only an app publishing Now Playing does), so the card
    // is legitimately blank while music plays. The rule below then read "no
    // title" as "nothing to play" and greyed the buttons out — Petr, 2026-09-07:
    // "Pauza jde ale uz pak nejde play v appce, stejne tak se da jit nadalsi
    // track ale pak uz nejde play ani pause."
    if (transportRoute == TransportRoute.device) return false;
    final q = queue;
    if (q != null) return q.current == null && q.upNext.isEmpty;
    return state.nowPlaying.isEmpty && !state.nowPlaying.playing;
  }

  /// Only Spotify can answer this. librespot tells us the CURRENT track (that
  /// is the hook), but it has no idea what Spotify will play next, so the
  /// queue exists only when the account is linked. Refreshed on track change
  /// — the bridge's nowPlayingChanged is the perfect trigger, it fires exactly
  /// when the queue has moved — and on a slow tick for queue edits made
  /// elsewhere, rather than polling hard against Spotify's rate limits.
  Future<void> refreshQueue() async {
    if (_disposed || _queueInFlight) return;
    if (transportRoute != TransportRoute.spotifyWeb) {
      if (queue != null || progress != null) {
        queue = null;
        progress = null;
        notifyListeners();
      }
      return;
    }
    _queueInFlight = true;
    try {
      final player = _player;
      final q = await player.queue();
      if (_disposed) return;
      queue = q;
      // Position is a second call — the queue endpoint has none. Its failure
      // must not cost us the queue we just got, so it is caught separately.
      try {
        final p = await player.progress();
        if (_disposed) return;
        progress = p;
      } catch (e) {
        AppLog.add('spotify', 'progress refresh failed: $e', warn: true);
      }
      notifyListeners();
    } catch (e) {
      // Never a SnackBar: the user did not ask for this, it refreshes itself,
      // and a transient 429/timeout is not something to interrupt them with.
      AppLog.add('spotify', 'queue refresh failed: $e', warn: true);
    } finally {
      _queueInFlight = false;
    }
  }

  /// One-line, user-facing outcomes of transport commands that could not be
  /// carried out (not linked, no such Connect device, Premium required, …).
  /// The home screen shows them as a SnackBar.
  Stream<String> get notices => _notices.stream;
  final _notices = StreamController<String>.broadcast();

  TransportRoute get transportRoute =>
      rules.transportRoute(state.nowPlaying.transport, spotifyLinked: spotify.isLinked);

  void playPause() {
    final np = state.nowPlaying;
    switch (transportRoute) {
      case TransportRoute.device:
        state.nowPlaying = np.copyWith(playing: !np.playing);
        notifyListeners();
        _client.notify('playPause');
      case TransportRoute.spotifyWeb:
        // Optimistic, like the device path; the librespot hook's playing/paused
        // event corrects it within a second either way.
        state.nowPlaying = np.copyWith(playing: !np.playing);
        notifyListeners();
        _spotify((p) => p.setPlaying(state.deviceName, !np.playing), revert: () {
          state.nowPlaying = np;
          notifyListeners();
        });
      case TransportRoute.spotifyUnlinked:
        _notices.add('Connect your Spotify account in Settings to control playback.');
      case TransportRoute.none:
        _notices.add('Nothing is playing that this app can control.');
    }
  }

  void next() => _transport('next', (p) => p.next(state.deviceName));
  void previous() => _transport('previous', (p) => p.previous(state.deviceName));

  void _transport(String method, Future<void> Function(SpotifyPlayer) viaSpotify) {
    switch (transportRoute) {
      case TransportRoute.device:
        _client.notify(method);
      case TransportRoute.spotifyWeb:
        _spotify(viaSpotify);
      case TransportRoute.spotifyUnlinked:
        _notices.add('Connect your Spotify account in Settings to control playback.');
      case TransportRoute.none:
        _notices.add('Nothing is playing that this app can control.');
    }
  }

  void _spotify(Future<void> Function(SpotifyPlayer) op, {void Function()? revert}) {
    unawaited(() async {
      try {
        await op(SpotifyPlayer(spotify));
      } on SpotifyPlayerException catch (e) {
        revert?.call();
        _notices.add(e.message);
      } on SpotifyAuthException catch (e) {
        revert?.call();
        _notices.add(e.message);
      } catch (e) {
        revert?.call();
        AppLog.add('spotify', 'transport failed: $e', warn: true);
        _notices.add('Spotify command failed: $e');
      }
    }());
  }

  @override
  void dispose() {
    _disposed = true;
    if (_client.needsSupervision) {
      WidgetsBinding.instance.removeObserver(this);
    }
    _retryTimer?.cancel();
    _queueTimer?.cancel();
    _stopHeartbeat();
    _evSub?.cancel();
    _connSub?.cancel();
    _client.close();
    super.dispose();
  }
}
