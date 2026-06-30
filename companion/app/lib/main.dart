import 'package:flutter/material.dart';
import 'protocol/client.dart';
import 'protocol/mock_client.dart';
import 'protocol/tcp_client.dart';
import 'screens/home_screen.dart';
import 'state/device_controller.dart';
import 'theme/nexusq_theme.dart';

/// Pass --dart-define=NEXUSQ_HOST=192.168.x.y to talk to a real bridge;
/// with no host the in-process MockClient is used (runs anywhere, no device).
const _host = String.fromEnvironment('NEXUSQ_HOST');

void main() {
  final NexusQClient client = _host.isEmpty ? MockClient() : TcpClient(host: _host);
  final controller = DeviceController(client)..start();
  runApp(NexusQApp(controller: controller));
}

class NexusQApp extends StatelessWidget {
  const NexusQApp({super.key, required this.controller});
  final DeviceController controller;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Nexus Q',
      debugShowCheckedModeBanner: false,
      theme: buildNexusQTheme(),
      home: HomeScreen(controller: controller),
    );
  }
}
