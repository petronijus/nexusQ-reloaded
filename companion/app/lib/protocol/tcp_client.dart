import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'client.dart';

/// Real transport: newline-delimited JSON objects over TCP (PROTOCOL.md §1).
/// Requests carry an incrementing `id`; responses are correlated back to their
/// pending future; objects with an `event` key are pushed to [events].
class TcpClient implements NexusQClient {
  TcpClient({required this.host, this.port = 45015});

  final String host;
  final int port;

  Socket? _socket;
  int _nextId = 1;
  final _pending = <int, Completer<Map<String, dynamic>>>{};
  final _events = StreamController<NexusQEvent>.broadcast();
  final _conn = StreamController<bool>.broadcast();

  @override
  Stream<NexusQEvent> get events => _events.stream;
  @override
  Stream<bool> get connection => _conn.stream;

  @override
  Future<void> connect() async {
    final s = await Socket.connect(host, port, timeout: const Duration(seconds: 5));
    _socket = s;
    _conn.add(true);
    s
        .cast<List<int>>()
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(_onLine, onError: (_) => _drop(), onDone: _drop);
    // hydrate state + subscribe to all events
    await call('subscribe', {'events': ['*']});
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

  void _drop() {
    _conn.add(false);
    for (final c in _pending.values) {
      c.completeError(NexusQError('unavailable', 'connection closed'));
    }
    _pending.clear();
    _socket = null;
  }

  @override
  Future<void> close() async {
    await _socket?.close();
    _drop();
    await _events.close();
    await _conn.close();
  }
}
