import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';
import '../../protocol/tcp_client.dart';
import '../../screens/connect_gate.dart';
import '../../theme/nexusq_theme.dart';
import '../setup_flow.dart';
import '../stock_assets.dart';

/// Final wizard step: closes out setup on the device, plays the stock outro
/// clip (or a static fallback icon), then hands off straight to [ConnectGate]
/// on the freshly-provisioned LAN address. No Back — setup is committed.
class OutroScreen extends StatefulWidget {
  const OutroScreen({super.key, required this.flow});
  final SetupFlowState flow;

  @override
  State<OutroScreen> createState() => _OutroScreenState();
}

class _OutroScreenState extends State<OutroScreen> {
  VideoPlayerController? _video;
  bool _finished = false;
  bool _navigated = false;

  @override
  void initState() {
    super.initState();
    _run();
  }

  Future<void> _run() async {
    try {
      await widget.flow.client.call('finishSetup');
    } catch (_) {
      // device may already have closed setup mode; proceed regardless
    }
    widget.flow.client.disconnect();
    if (!mounted) return;
    if (StockAssets.available) {
      try {
        final v = VideoPlayerController.asset('assets/stock/raw/q_outro.mp4');
        await v.initialize();
        if (!mounted) {
          v.dispose();
          return;
        }
        setState(() => _video = v);
        await v.play();
        if (!mounted) return;
        v.addListener(() {
          if (!mounted) return;
          if (v.value.position >= v.value.duration && !_finished) {
            setState(() => _finished = true);
          }
        });
      } catch (_) {
        // asset missing or plugin failed to init (e.g. no platform impl in
        // tests / unsupported platform) — degrade to the static fallback.
        if (mounted) setState(() => _finished = true);
      }
    } else {
      setState(() => _finished = true);
    }
  }

  void _done() {
    if (_navigated) return;
    _navigated = true;
    final host = (widget.flow.wifiResult?['ip'] as String?) ??
        (widget.flow.wifiResult?['mdns'] as String?) ??
        '';
    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute(
          builder: (_) => ConnectGate(
              initialClient: host.isEmpty ? null : TcpClient(host: host))),
      (route) => false,
    );
  }

  @override
  void dispose() {
    _video?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final v = _video;
    return Padding(
      padding: const EdgeInsets.all(32),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          if (v != null && v.value.isInitialized)
            AspectRatio(aspectRatio: v.value.aspectRatio, child: VideoPlayer(v))
          else
            stockImage('setup_static.png', height: 200, fallback: Icons.check_circle_outline),
          const SizedBox(height: 32),
          Text('${widget.flow.deviceName} is ready',
              style: const TextStyle(color: NexusQColors.white, fontSize: 22, fontWeight: FontWeight.w300)),
          const SizedBox(height: 40),
          FilledButton(onPressed: _done, child: const Text('Start listening')),
        ],
      ),
    );
  }
}
