import 'dart:convert';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexusq_companion/protocol/tcp_client.dart';
import 'package:nexusq_companion/state/device_controller.dart';

/// A minimal in-process bridge speaking PROTOCOL.md line-JSON, with knobs to
/// simulate the two real-world failure modes: a clean drop (device reboot,
/// WiFi blip → FIN/RST) and a half-open link (Android doze → silence).
class FakeBridge {
  FakeBridge._(this._server);
  final ServerSocket _server;
  Socket? _current;
  final _silenced = <Socket>{};
  int subscribeCount = 0;
  int volume = 10;

  static Future<FakeBridge> start() async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final b = FakeBridge._(server);
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
      if (_silenced.contains(s)) return; // half-open: swallow everything
      final msg = jsonDecode(line) as Map<String, dynamic>;
      final id = msg['id'];
      if (id == null) return; // notify — no response
      final result = switch (msg['method'] as String) {
        'subscribe' => (() {
            subscribeCount++;
            return {'subscribed': ['*']};
          })(),
        'getState' => {
            'volume': volume,
            'muted': false,
            'brightness': 100,
            'theme': 'blue',
            'scene': 'waveform',
            'output': 'speaker',
            'name': 'Nexus Q (fake)',
          },
        'listOutputs' => {
            'outputs': [
              {'id': 'speaker', 'label': 'Speaker', 'available': true},
            ],
            'active': 'speaker',
          },
        _ => const <String, dynamic>{},
      };
      s.write('${jsonEncode({'id': id, 'ok': true, 'result': result})}\n');
    }, onError: (_) {}, onDone: () {});
  }

  /// Clean drop: FIN/RST reaches the app (device reboot / WiFi blip).
  void dropClient() {
    _current?.destroy();
    _current = null;
  }

  /// Half-open: the connection stays "up" but nothing ever answers (doze).
  void silenceCurrent() {
    final c = _current;
    if (c != null) _silenced.add(c);
  }

  Future<void> close() async {
    dropClient();
    await _server.close();
  }
}

Future<void> until(bool Function() cond,
    {Duration timeout = const Duration(seconds: 8)}) async {
  final deadline = DateTime.now().add(timeout);
  while (!cond()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('condition not met within $timeout');
    }
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('auto-reconnects after a clean drop and fully re-hydrates', () async {
    final bridge = await FakeBridge.start();
    final c = DeviceController(TcpClient(host: '127.0.0.1', port: bridge.port));
    await c.start();
    await until(() => c.state.connected && c.state.volume == 10);
    expect(bridge.subscribeCount, 1);

    bridge.volume = 55; // state changes while the app is cut off
    bridge.dropClient();
    await until(() => !c.state.connected);
    expect(c.state.reconnecting, true);

    // backoff reconnect + re-hydration picks up the new state
    await until(() => c.state.connected && c.state.volume == 55,
        timeout: const Duration(seconds: 10));
    expect(bridge.subscribeCount, 2); // re-subscribed on the new socket
    expect(c.state.reconnecting, false);

    c.dispose();
    await bridge.close();
  });

  test('resume probe detects a half-open link and reconnects immediately',
      () async {
    final bridge = await FakeBridge.start();
    final c = DeviceController(TcpClient(host: '127.0.0.1', port: bridge.port));
    // The disconnected window is tiny (failed probe → immediate redial), so a
    // polling loop can miss it — observe the transient drop via the notifier.
    var sawDrop = false;
    c.addListener(() => sawDrop |= !c.state.connected);
    await c.start();
    await until(() => c.state.connected);

    // Background the app, then break the link doze-style: no FIN/RST, the
    // socket still looks connected — only a write can expose it.
    c.didChangeAppLifecycleState(AppLifecycleState.paused);
    bridge.silenceCurrent();
    sawDrop = false;

    c.didChangeAppLifecycleState(AppLifecycleState.resumed);
    // The active getState probe (3s timeout) must flag the dead link and the
    // immediate reconnect must land on a fresh, responsive socket.
    await until(() => sawDrop && c.state.connected,
        timeout: const Duration(seconds: 10));
    expect(bridge.subscribeCount, 2);

    c.dispose();
    await bridge.close();
  });
}
