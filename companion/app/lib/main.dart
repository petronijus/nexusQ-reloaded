import 'package:flutter/material.dart';
import 'nfc/device_tap.dart';
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

class NexusQApp extends StatefulWidget {
  const NexusQApp({super.key, this.initialClient});
  final NexusQClient? initialClient;

  @override
  State<NexusQApp> createState() => _NexusQAppState();
}

class _NexusQAppState extends State<NexusQApp> {
  /// App-level messenger so NFC (HCE) messages can surface as a SnackBar from
  /// any screen, independent of the current Scaffold.
  final _messengerKey = GlobalKey<ScaffoldMessengerState>();

  /// App-level navigator so an NFC tap can route (push the setup wizard, or
  /// replace the stack with a freshly-addressed ConnectGate) from anywhere,
  /// without depending on a possibly-deactivated BuildContext.
  final _navigatorKey = GlobalKey<NavigatorState>();

  /// The Q re-emits its NFC connection-info every ~8 s while the phone rests on
  /// the dome, and every app resume re-drains the last tap — so onDeviceTap
  /// fires repeatedly for the SAME device. Without a guard each fire pushed a
  /// fresh SetupFlow, restarting the wizard mid-flow (notably right after the
  /// BT-permission dialog resumed the app). Track the setup we already routed
  /// and ignore duplicates until that flow is dismissed.
  String? _activeSetupMac;

  void _onDeviceTap(DeviceTap tap) {
    final nav = _navigatorKey.currentState;
    if (nav == null) return;
    if (!tap.provisioned && tap.btMac.isNotEmpty) {
      if (_activeSetupMac == tap.btMac) return; // already setting this one up
      _activeSetupMac = tap.btMac;
      nav
          .push(MaterialPageRoute(
              builder: (_) => SetupFlow(initialMac: tap.btMac)))
          .whenComplete(() {
        if (_activeSetupMac == tap.btMac) _activeSetupMac = null;
      });
    } else {
      final host = tap.ip ?? '${tap.host}.local';
      nav.pushAndRemoveUntil(
        MaterialPageRoute(
            builder: (_) => ConnectGate(initialClient: TcpClient(host: host))),
        (route) => false,
      );
    }
  }

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
        onDeviceTap: _onDeviceTap,
        child: ConnectGate(initialClient: widget.initialClient),
      ),
    );
  }
}
