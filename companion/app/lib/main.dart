import 'package:flutter/material.dart';
import 'nfc/hce_listener.dart';
import 'protocol/client.dart';
import 'protocol/mock_client.dart';
import 'protocol/tcp_client.dart';
import 'screens/connect_gate.dart';
import 'setup/setup_flow.dart';
import 'setup/stock_assets.dart';
import 'theme/nexusq_theme.dart';

/// Connection source, chosen at launch:
///   --dart-define=NEXUSQ_HOST=192.168.x.y  → connect to that bridge directly
///   --dart-define=NEXUSQ_MOCK=true         → in-process demo device (no hardware)
///   (neither)                              → auto-discover via mDNS, with a
///                                            manual-host / demo fallback
const _host = String.fromEnvironment('NEXUSQ_HOST');
const _mock = bool.fromEnvironment('NEXUSQ_MOCK');

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await StockAssets.init();
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

  /// App-level navigator so an NFC tap can route (push the setup wizard, or
  /// replace the stack with a freshly-addressed ConnectGate) from anywhere,
  /// without depending on a possibly-deactivated BuildContext.
  final _navigatorKey = GlobalKey<NavigatorState>();

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'nexusQ-reloaded',
      debugShowCheckedModeBanner: false,
      navigatorKey: _navigatorKey,
      theme: buildNexusQTheme(),
      scaffoldMessengerKey: _messengerKey,
      home: HceListener(
        messengerKey: _messengerKey,
        onDeviceTap: (tap) {
          final nav = _navigatorKey.currentState;
          if (nav == null) return;
          if (!tap.provisioned && tap.btMac.isNotEmpty) {
            nav.push(MaterialPageRoute(
                builder: (_) => SetupFlow(initialMac: tap.btMac)));
          } else {
            final host = tap.ip ?? '${tap.host}.local';
            nav.pushAndRemoveUntil(
              MaterialPageRoute(
                  builder: (_) => ConnectGate(initialClient: TcpClient(host: host))),
              (route) => false,
            );
          }
        },
        child: ConnectGate(initialClient: initialClient),
      ),
    );
  }
}
