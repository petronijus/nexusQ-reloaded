import 'dart:async';
import 'dart:convert';
import 'dart:io';
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
    final s = await Socket.connect(host, port, timeout: const Duration(seconds: 5));
    if (_closed) {
      s.destroy();
      return;
    }
    _socket = s;
    _conn.add(true);
    s
        .cast<List<int>>()
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        // Guard on THIS socket: after a drop + reconnect, the stale socket's
        // late onDone/onError must not tear down the fresh connection.
        .listen(_onLine, onError: (_) => _dropIf(s), onDone: () => _dropIf(s));
    // hydrate the event channel: subscribe to all events. If this fails the
    // link is not actually usable — tear it down so the caller retries cleanly.
    try {
      await call('subscribe', {'events': ['*']});
    } catch (_) {
      _drop();
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
      _events.add(NexusQEvent(
        msg['event'] as String,
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
    }
  }

  @override
  Future<Map<String, dynamic>> call(String method, [Map<String, dynamic>? params]) {
    final s = _socket;
    if (s == null) return Future.error(NexusQError('unavailable', 'not connected'));
    final id = _nextId++;
    final c = Completer<Map<String, dynamic>>();
    _pending[id] = c;
    s.write('${jsonEncode({'id': id, 'method': method, 'params': ?params})}\n');
    return c.future.timeout(const Duration(seconds: 5), onTimeout: () {
      _pending.remove(id);
      throw NexusQError('internal', 'timeout');
    });
  }

  @override
  void notify(String method, [Map<String, dynamic>? params]) {
    _socket?.write('${jsonEncode({'method': method, 'params': ?params})}\n');
  }

  @override
  void disconnect() => _drop();

  void _dropIf(Socket s) {
    if (identical(_socket, s)) _drop();
  }

  void _drop() {
    final s = _socket;
    if (s == null) return; // idempotent: onError + onDone may both fire
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
    _drop();
    await _events.close();
    await _conn.close();
  }
}
