import 'package:flutter_test/flutter_test.dart';
import 'package:nexusq_companion/protocol/mock_client.dart';
import 'package:nexusq_companion/state/device_controller.dart';

void main() {
  test('mock client serves state and reacts to volume', () async {
    final c = DeviceController(MockClient());
    await c.start();
    final s = await Future.delayed(const Duration(milliseconds: 400), () => c.state);
    expect(s.connected, true);
    c.setVolume(73);
    await Future.delayed(const Duration(milliseconds: 50));
    expect(c.state.volume, 73);
    c.toggleMute();
    await Future.delayed(const Duration(milliseconds: 50));
    expect(c.state.muted, true);
    c.dispose();
  });
}
