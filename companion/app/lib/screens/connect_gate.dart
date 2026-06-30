import 'package:flutter/material.dart';
import '../protocol/client.dart';
import '../protocol/discovery.dart';
import '../protocol/mock_client.dart';
import '../protocol/tcp_client.dart';
import '../state/device_controller.dart';
import '../theme/nexusq_theme.dart';
import '../widgets/glowing_ring.dart';
import 'home_screen.dart';

enum _Phase { discovering, ready, needInput }

/// Bootstraps the connection: an explicit [initialClient] (forced host / mock)
/// goes straight through; otherwise it browses mDNS for the device and, on
/// timeout, offers a manual host entry / demo-mock fallback. Renders [HomeScreen]
/// once a controller is live.
class ConnectGate extends StatefulWidget {
  const ConnectGate({super.key, this.initialClient});
  final NexusQClient? initialClient;

  @override
  State<ConnectGate> createState() => _ConnectGateState();
}

class _ConnectGateState extends State<ConnectGate> {
  _Phase _phase = _Phase.discovering;
  DeviceController? _controller;
  final _hostCtrl = TextEditingController();

  @override
  void initState() {
    super.initState();
    if (widget.initialClient != null) {
      _use(widget.initialClient!);
    } else {
      _discover();
    }
  }

  @override
  void dispose() {
    _hostCtrl.dispose();
    _controller?.dispose();
    super.dispose();
  }

  void _use(NexusQClient client) {
    final c = DeviceController(client)..start();
    setState(() {
      _controller = c;
      _phase = _Phase.ready;
    });
  }

  Future<void> _discover() async {
    setState(() => _phase = _Phase.discovering);
    final found = await discoverNexusQ();
    if (!mounted) return;
    if (found != null) {
      _use(TcpClient(host: found.host, port: found.port));
    } else {
      setState(() => _phase = _Phase.needInput);
    }
  }

  void _connectManual() {
    final raw = _hostCtrl.text.trim();
    if (raw.isEmpty) return;
    final parts = raw.split(':');
    final host = parts.first;
    final port = parts.length > 1 ? int.tryParse(parts[1]) ?? 45015 : 45015;
    _use(TcpClient(host: host, port: port));
  }

  @override
  Widget build(BuildContext context) {
    final ctrl = _controller;
    if (_phase == _Phase.ready && ctrl != null) {
      return HomeScreen(controller: ctrl);
    }
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(NexusQSpace.standardMargin * 2),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              SizedBox(
                height: 160,
                width: 160,
                child: GlowingRing(
                  volume: _phase == _Phase.discovering ? 0.6 : 0.15,
                  child: Icon(
                    _phase == _Phase.discovering ? Icons.wifi_find : Icons.wifi_off,
                    color: NexusQColors.accent,
                  ),
                ),
              ),
              const SizedBox(height: 32),
              Text(
                _phase == _Phase.discovering ? 'Searching for Nexus Q…' : 'No Nexus Q found',
                style: const TextStyle(
                    color: NexusQColors.white, fontSize: 18, fontWeight: FontWeight.w300),
              ),
              const SizedBox(height: 8),
              const Text(
                'Make sure the device is on the same network.',
                textAlign: TextAlign.center,
                style: TextStyle(color: NexusQColors.dim, fontSize: 13),
              ),
              const SizedBox(height: 28),
              if (_phase == _Phase.needInput) ..._fallback(),
            ],
          ),
        ),
      ),
    );
  }

  List<Widget> _fallback() => [
        TextField(
          controller: _hostCtrl,
          style: const TextStyle(color: NexusQColors.white),
          keyboardType: TextInputType.url,
          decoration: const InputDecoration(
            labelText: 'Device address (host or host:port)',
            labelStyle: TextStyle(color: NexusQColors.dim),
            enabledBorder: UnderlineInputBorder(
                borderSide: BorderSide(color: NexusQColors.divider)),
            focusedBorder: UnderlineInputBorder(
                borderSide: BorderSide(color: NexusQColors.accent)),
          ),
          onSubmitted: (_) => _connectManual(),
        ),
        const SizedBox(height: 20),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: [
            TextButton(onPressed: _discover, child: const Text('Search again')),
            TextButton(onPressed: () => _use(MockClient()), child: const Text('Demo')),
            FilledButton(onPressed: _connectManual, child: const Text('Connect')),
          ],
        ),
      ];
}
