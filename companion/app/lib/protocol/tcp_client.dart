import 'dart:async';
import 'dart:convert';
import 'dart:io';
import '../debug/app_log.dart';
import 'client.dart';

/// Real transport: newline-delimited JSON objects over TCP (PROTOCOL.md §1).
/// Requests carry an incrementing `id`; responses are correlated back to their
/// pending future; objects with an `event` key are pushed to [events].
///
/// The client is re-connectable: when the socket drops ([connection] emits
/// false), a later [connect] dials a fresh socket to the same host and
/// re-subscribes. The reconnect *policy* (backoff, heartbeat, lifecycle
/// probes) lives in DeviceController, keyed off [needsSupervision].
class TcpClient implements NexusQClient {
  TcpClient({required this.host, this.port = 45015});

  final String host;
  final int port;

  Socket? _socket;
  Future<void>? _dialing; // single-flight guard: concurrent connects share it
  bool _closed = false;
  int _nextId = 1;
  final _pending = <int, Completer<Map<String, dynamic>>>{};
  final _events = StreamController<NexusQEvent>.broadcast();
  final _conn = StreamController<bool>.broadcast();

  // Diagnostics only (AppLog): when a drop happens, the age of the connection
  // and how many events it carried say more than the drop itself — e.g. an
  // event flood from nowPlayingChanged starving a probe response.
  DateTime? _connectedAt;
  final _eventCounts = <String, int>{};

  @override
  Stream<NexusQEvent> get events => _events.stream;
  @override
  Stream<bool> get connection => _conn.stream;

  @override
  bool get needsSupervision => true;

  @override
  Future<void> connect() {
    if (_closed) return Future.error(NexusQError('unavailable', 'client closed'));
    if (_socket != null) return Future.value(); // already connected
    return _dialing ??= _dial().whenComplete(() => _dialing = null);
  }

  Future<void> _dial() async {
    AppLog.add('tcp', 'dial $host:$port');
    final s = await Socket.connect(host, port, timeout: const Duration(seconds: 5));
    if (_closed) {
      s.destroy();
      return;
    }
    _socket = s;
    _connectedAt = DateTime.now();
    _eventCounts.clear();
    AppLog.add('tcp', 'connected $host:$port');
    _conn.add(true);
    s
        .cast<List<int>>()
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        // Guard on THIS socket: after a drop + reconnect, the stale socket's
        // late onDone/onError must not tear down the fresh connection.
        .listen(_onLine,
            onError: (e) => _dropIf(s, 'socket error: $e'),
            onDone: () => _dropIf(s, 'peer closed the socket (onDone)'));
    // hydrate the event channel: subscribe to all events. If this fails the
    // link is not actually usable — tear it down so the caller retries cleanly.
    try {
      await call('subscribe', {'events': ['*']});
    } catch (e) {
      AppLog.add('tcp', 'subscribe failed: $e', warn: true);
      _drop('subscribe failed');
      rethrow;
    }
  }

  void _onLine(String line) {
    if (line.trim().isEmpty) return;
    final Map<String, dynamic> msg;
    try {
      msg = jsonDecode(line) as Map<String, dynamic>;
    } catch (_) {
      return;
    }
    if (msg.containsKey('event')) {
      final name = msg['event'] as String;
      _eventCounts.update(name, (v) => v + 1, ifAbsent: () => 1);
      _events.add(NexusQEvent(
        name,
        (msg['data'] as Map?)?.cast<String, dynamic>() ?? const {},
      ));
      return;
    }
    final id = msg['id'];
    if (id is int && _pending.containsKey(id)) {
      final c = _pending.remove(id)!;
      if (msg['ok'] == true) {
        c.complete((msg['result'] as Map?)?.cast<String, dynamic>() ?? const {});
      } else {
        final e = (msg['error'] as Map?)?.cast<String, dynamic>() ?? const {};
        c.completeError(NexusQError(e['code'] as String? ?? 'internal', e['message'] as String? ?? ''));
      }
    } else if (id is int) {
      // A response whose caller already timed out and gave up. If these show up
      // right after a "timeout" entry, the link was never dead — just slow.
      AppLog.add('tcp', 'late response id=$id arrived after its caller timed out',
          warn: true);
    }
  }

  @override
  Future<Map<String, dynamic>> call(String method, [Map<String, dynamic>? params]) {
    final s = _socket;
    if (s == null) return Future.error(NexusQError('unavailable', 'not connected'));
    final id = _nextId++;
    final c = Completer<Map<String, dynamic>>();
    _pending[id] = c;
    // NB the log gets the METHOD NAME ONLY, never params — setWifi carries the
    // WiFi PSK, and credentials never reach any log (standing rule).
    final sw = Stopwatch()..start();
    s.write('${jsonEncode({'id': id, 'method': method, 'params': ?params})}\n');
    return c.future.timeout(const Duration(seconds: 5), onTimeout: () {
      _pending.remove(id);
      AppLog.add('tcp',
          '$method timeout after 5s (id $id, ${_pending.length} still pending)',
          warn: true);
      throw NexusQError('internal', 'timeout');
    }).then((r) {
      // Successes are logged only when slow: a healthy call is ~100 ms, so
      // anything near the probe timeout deserves a trace without flooding the
      // ring on every poll.
      if (sw.elapsedMilliseconds >= 1000) {
        AppLog.add('tcp', 'slow: $method took ${sw.elapsedMilliseconds}ms',
            warn: true);
      }
      return r;
    });
  }

  @override
  void notify(String method, [Map<String, dynamic>? params]) {
    _socket?.write('${jsonEncode({'method': method, 'params': ?params})}\n');
  }

  @override
  void disconnect() => _drop('supervisor disconnect (failed probe)');

  void _dropIf(Socket s, String cause) {
    if (identical(_socket, s)) _drop(cause);
  }

  void _drop(String cause) {
    final s = _socket;
    if (s == null) return; // idempotent: onError + onDone may both fire
    // The money line for the flicker hunt: WHO killed the link, how old it was,
    // and how much event traffic it carried. "supervisor disconnect" = the app
    // decided the link was dead (probe); "peer closed" = the bridge/network did.
    final age = _connectedAt == null
        ? '?'
        : '${DateTime.now().difference(_connectedAt!).inSeconds}s';
    AppLog.add('tcp',
        'DROP: $cause — connection age $age, '
        '${_pending.length} calls in flight, events received: '
        '${_eventCounts.isEmpty ? 'none' : _eventCounts.toString()}',
        warn: true);
    _connectedAt = null;
    _socket = null;
    s.destroy();
    for (final c in _pending.values) {
      c.completeError(NexusQError('unavailable', 'connection closed'));
    }
    _pending.clear();
    if (!_closed) _conn.add(false);
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    try {
      await _socket?.flush(); // let queued notifies out before tearing down
    } catch (_) {/* dropping anyway */}
    _drop('client closed');
    await _events.close();
    await _conn.close();
  }
}
