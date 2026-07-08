import 'package:flutter/material.dart';
import 'nfc/hce_listener.dart';
import 'protocol/client.dart';
import 'protocol/mock_client.dart';
import 'protocol/tcp_client.dart';
import 'screens/connect_gate.dart';
import 'theme/nexusq_theme.dart';

/// Connection source, chosen at launch:
///   --dart-define=NEXUSQ_HOST=192.168.x.y  → connect to that bridge directly
///   --dart-define=NEXUSQ_MOCK=true         → in-process demo device (no hardware)
///   (neither)                              → auto-discover via mDNS, with a
///                                            manual-host / demo fallback
const _host = String.fromEnvironment('NEXUSQ_HOST');
const _mock = bool.fromEnvironment('NEXUSQ_MOCK');

void main() {
  NexusQClient? initial;
  if (_host.isNotEmpty) {
    initial = TcpClient(host: _host);
  } else if (_mock) {
    initial = MockClient();
  }
  runApp(NexusQApp(initialClient: initial));
}

class NexusQApp extends StatelessWidget {
  NexusQApp({super.key, this.initialClient});
  final NexusQClient? initialClient;

  /// App-level messenger so NFC (HCE) messages can surface as a SnackBar from
  /// any screen, independent of the current Scaffold.
  final _messengerKey = GlobalKey<ScaffoldMessengerState>();

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'nexusQ-reloaded',
      debugShowCheckedModeBanner: false,
      theme: buildNexusQTheme(),
      scaffoldMessengerKey: _messengerKey,
      home: HceListener(
        messengerKey: _messengerKey,
        child: ConnectGate(initialClient: initialClient),
      ),
    );
  }
}
