import 'dart:async';
import 'dart:convert';
import 'package:flutter/services.dart';

class BtScanResult {
  BtScanResult(this.name, this.mac);
  final String name;
  final String mac;
}

class BtSetupError implements Exception {
  BtSetupError(this.code, this.message);
  final String code;
  final String message;
  @override
  String toString() => 'BtSetupError($code): $message';
}

/// PROTOCOL.md envelope over the BT RFCOMM platform channel (Task 9).
/// Same request/response semantics as TcpClient, different transport.
class BtSetupClient {
  static const _method = MethodChannel('nexusq/btsetup');
  static const _events = EventChannel('nexusq/btsetup/events');

  BtSetupClient() {
    // In tests there is no platform implementation behind the EventChannel,
    // so receiveBroadcastStream().listen() delivers a MissingPluginException
    // error event as soon as the stream is subscribed. That's expected and
    // harmless here (tests drive events via handleEventForTest instead) —
    // swallow it so it doesn't surface as an unhandled error in the zone.
    _sub = _events
        .receiveBroadcastStream()
        .listen((e) => _onEvent((e as Map).cast<String, dynamic>()), onError: (Object _) {});
  }

  StreamSubscription? _sub;
  int _nextId = 1;
  final _pending = <int, Completer<Map<String, dynamic>>>{};
  final _scan = StreamController<BtScanResult>.broadcast();
  final _connected = StreamController<bool>.broadcast();

  Stream<BtScanResult> get scanResults => _scan.stream;
  Stream<bool> get connected => _connected.stream;

  Future<bool> ensurePermissions() async =>
      await _method.invokeMethod<bool>('ensurePermissions') ?? false;

  Future<void> startScan() => _method.invokeMethod('startScan');
  Future<void> stopScan() => _method.invokeMethod('stopScan');

  Future<void> connect(String mac) async {
    await _method.invokeMethod('connect', {'mac': mac});
  }

  Future<void> disconnect() async {
    await _method.invokeMethod('disconnect');
  }

  Future<Map<String, dynamic>> call(String method, [Map<String, dynamic>? params]) {
    final id = _nextId++;
    final completer = Completer<Map<String, dynamic>>();
    _pending[id] = completer;
    final line = jsonEncode({
      'id': id,
      'method': method,
      'params': ?params,
    });
    _method.invokeMethod('sendLine', {'line': line}).catchError((Object e) {
      _pending.remove(id)?.completeError(BtSetupError('send_failed', '$e'));
    });
    // setWifi legitimately takes up to ~90 s on the device (nmcli --wait).
    final timeout = method == 'setWifi' ? const Duration(seconds: 100) : const Duration(seconds: 30);
    return completer.future.timeout(timeout, onTimeout: () {
      _pending.remove(id);
      throw BtSetupError('timeout', '$method timed out');
    });
  }

  void _onEvent(Map<String, dynamic> e) {
    switch (e['type']) {
      case 'scan':
        _scan.add(BtScanResult((e['name'] as String?) ?? '', e['mac'] as String));
      case 'state':
        _connected.add(e['connected'] == true);
      case 'line':
        _onLine(e['line'] as String);
    }
  }

  void _onLine(String line) {
    final Object obj;
    try {
      obj = jsonDecode(line);
    } on FormatException {
      return;
    }
    if (obj is! Map<String, dynamic>) return;
    final id = obj['id'];
    if (id is! int) return;
    final completer = _pending.remove(id);
    if (completer == null) return;
    if (obj['ok'] == true) {
      completer.complete((obj['result'] as Map?)?.cast<String, dynamic>() ?? const {});
    } else {
      final err = (obj['error'] as Map?)?.cast<String, dynamic>() ?? const {};
      completer.completeError(BtSetupError(
          (err['code'] as String?) ?? 'internal', (err['message'] as String?) ?? ''));
    }
  }

  /// Test hook: inject an event as if it came from the EventChannel.
  void handleEventForTest(Map<String, dynamic> e) => _onEvent(e);

  void dispose() {
    _sub?.cancel();
    _scan.close();
    _connected.close();
  }
}
