import 'package:flutter/material.dart';
import '../theme/nexusq_theme.dart';
import 'bt_setup_client.dart';
import 'screens/welcome_screen.dart';
import 'screens/cables_screen.dart';
import 'screens/find_device_screen.dart';
import 'screens/confirm_color_screen.dart';
import 'screens/wifi_screen.dart';

/// Shared wizard state. Screens mutate it and call [next]/[back].
class SetupFlowState extends ChangeNotifier {
  SetupFlowState({String? initialMac}) : deviceMac = initialMac;

  final client = BtSetupClient();
  String? deviceMac; // chosen/NFC-provided device
  Map<String, dynamic>? wifiResult; // {ip, mdns} after setWifi ok
  String deviceName = 'Nexus Q';
  String room = '';
  String? theme;

  @override
  void dispose() {
    client.disconnect();
    client.dispose();
    super.dispose();
  }
}

class SetupFlow extends StatefulWidget {
  const SetupFlow({super.key, this.initialMac});
  final String? initialMac;

  @override
  State<SetupFlow> createState() => SetupFlowScreenState();
}

class SetupFlowScreenState extends State<SetupFlow> {
  late final SetupFlowState flow = SetupFlowState(initialMac: widget.initialMac);
  final _page = PageController();
  int _index = 0;

  List<Widget> get _pages => [
        WelcomeScreen(onNext: next),
        CablesScreen(onNext: next, onBack: back),
        if (widget.initialMac == null) FindDeviceScreen(flow: flow, onNext: next, onBack: back),
        ConfirmColorScreen(flow: flow, onNext: next, onBack: back),
        WifiScreen(flow: flow, onNext: next, onBack: back),
        // Task 13 appends: NameRoomScreen, ThemeScreen, OutroScreen
      ];

  void next() {
    if (_index < _pages.length - 1) {
      setState(() => _index++);
      _page.animateToPage(_index,
          duration: const Duration(milliseconds: 250), curve: Curves.easeOut);
    }
  }

  void back() {
    if (_index > 0) {
      setState(() => _index--);
      _page.animateToPage(_index,
          duration: const Duration(milliseconds: 250), curve: Curves.easeOut);
    }
  }

  @override
  void dispose() {
    flow.dispose();
    _page.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: NexusQColors.canvas,
      body: SafeArea(
        child: PageView(
          controller: _page,
          physics: const NeverScrollableScrollPhysics(),
          children: _pages,
        ),
      ),
    );
  }
}
