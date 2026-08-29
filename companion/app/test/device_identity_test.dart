import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nexusq_companion/protocol/tcp_client.dart';
import 'package:nexusq_companion/state/device_controller.dart';

/// The home screen prints `DeviceState.deviceName`, so a rename is only visible
/// if it reaches THAT field. Two things used to stop it:
///
///  * the bridge broadcasts `deviceInfoChanged`, which the controller ignored;
///  * `getState` carries a `name` snapshotted at bridge start-up, so the 25 s
///    heartbeat probe would have restored the old name anyway.
///
/// Both are checked here against a real socket, because the event path only
/// exists end-to-end.
class IdentityBridge {
  IdentityBridge._(this._server);
  final ServerSocket _server;
  Socket? _current;

  /// What `getDeviceInfo` answers — the live identity.
  String name = 'Old Name';

  /// What `getState` answers: deliberately frozen at the boot-time name, the
  /// way a bridge older than nexusq-control r35 behaves.
  String staleStateName = 'Old Name';

  static Future<IdentityBridge> start() async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final b = IdentityBridge._(server);
    server.listen(b._onClient);
    return b;
  }

  int get port => _server.port;

  void _onClient(Socket s) {
    _current = s;
    s
        .cast<List<int>>()
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) {
      final msg = jsonDecode(line) as Map<String, dynamic>;
      final id = msg['id'];
      if (id == null) return;
      final result = switch (msg['method'] as String) {
        'subscribe' => {'subscribed': ['*']},
        'getState' => {'volume': 10, 'name': staleStateName},
        'getDeviceInfo' => {'name': name, 'model': 'steelhead'},
        'listOutputs' => {'outputs': [], 'active': 'speaker'},
        _ => const <String, dynamic>{},
      };
      s.write('${jsonEncode({'id': id, 'ok': true, 'result': result})}\n');
    }, onError: (_) {}, onDone: () {});
  }

  /// The rename event the device broadcasts to every connected client.
  void renameTo(String n) {
    name = n;
    _current?.write(
        '${jsonEncode({'event': 'deviceInfoChanged', 'data': {'name': n, 'room': ''}})}\n');
  }

  Future<void> close() async {
    _current?.destroy();
    await _server.close();
  }
}

Future<void> _settle([int ms = 400]) async {
  final until = DateTime.now().add(Duration(milliseconds: ms));
  while (DateTime.now().isBefore(until)) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

void main() {
  // The controller observes the widget lifecycle for its heartbeat.
  TestWidgetsFlutterBinding.ensureInitialized();

  late IdentityBridge bridge;
  late DeviceController ctrl;

  setUp(() async {
    bridge = await IdentityBridge.start();
    ctrl = DeviceController(TcpClient(host: '127.0.0.1', port: bridge.port));
    await ctrl.start();
    await _settle();
  });

  tearDown(() async {
    ctrl.dispose();
    await bridge.close();
  });

  test('the name is hydrated from getDeviceInfo, not getState', () async {
    expect(ctrl.state.deviceName, 'Old Name');
    // Prove the source: only getDeviceInfo moves, and a freshly connected app
    // must follow it even while getState keeps insisting on the boot-time name.
    bridge.name = 'Šumperák';
    final second = DeviceController(TcpClient(host: '127.0.0.1', port: bridge.port));
    await second.start();
    await _settle();
    expect(second.state.deviceName, 'Šumperák');
    expect(bridge.staleStateName, 'Old Name', reason: 'getState stayed stale');
    second.dispose();
  });

  test('a rename event updates the name the home screen shows', () async {
    var notified = 0;
    ctrl.addListener(() => notified++);
    bridge.renameTo('Šumperák / chalupa');
    await _settle();
    expect(ctrl.state.deviceName, 'Šumperák / chalupa');
    expect(notified, greaterThan(0), reason: 'the UI must be told to rebuild');
  });

  test('a stale getState never drags the old name back', () async {
    bridge.renameTo('New Name');
    await _settle();
    expect(ctrl.state.deviceName, 'New Name');
    // This IS the 25 s heartbeat: the probe feeds its getState result straight
    // into applyJson, and that result still carries the pre-rename name.
    ctrl.state.applyJson({'volume': 11, 'name': bridge.staleStateName});
    expect(ctrl.state.volume, 11, reason: 'the rest of getState still applies');
    expect(ctrl.state.deviceName, 'New Name');
  });

  test('an empty or missing name is ignored, not shown as blank', () async {
    ctrl.state.applyIdentity({'name': '   '});
    expect(ctrl.state.deviceName, 'Old Name');
    ctrl.state.applyIdentity({'room': 'kitchen'});
    expect(ctrl.state.deviceName, 'Old Name');
  });
}
