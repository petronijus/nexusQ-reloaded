import 'dart:convert';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexusq_companion/setup/bt_setup_client.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('call correlates ids and decodes result', () async {
    final client = BtSetupClient();
    final sent = <String>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('nexusq/btsetup'), (call) async {
      if (call.method == 'sendLine') {
        sent.add(call.arguments['line'] as String);
        return null;
      }
      return null;
    });

    final future = client.call('confirmColor');
    await Future<void>.delayed(Duration.zero);
    expect(sent, hasLength(1));
    final req = jsonDecode(sent.single) as Map<String, dynamic>;
    expect(req['method'], 'confirmColor');

    // Simulate the device response arriving on the event stream.
    client.handleEventForTest({
      'type': 'line',
      'line': jsonEncode({'id': req['id'], 'ok': true, 'result': {'rgb': [0, 183, 255]}}),
    });
    final result = await future;
    expect(result['rgb'], [0, 183, 255]);
  });

  test('error response throws BtSetupError', () async {
    final client = BtSetupClient();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('nexusq/btsetup'), (call) async => null);
    final future = client.call('setWifi', {'ssid': 'x', 'psk': 'bad'});
    await Future<void>.delayed(Duration.zero);
    client.handleEventForTest({
      'type': 'line',
      'line': jsonEncode({'id': 1, 'ok': false,
        'error': {'code': 'wrong_password', 'message': 'wifi join failed'}}),
    });
    await expectLater(future, throwsA(isA<BtSetupError>()
        .having((e) => e.code, 'code', 'wrong_password')));
  });
}
