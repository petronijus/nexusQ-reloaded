import 'dart:async';
import 'package:flutter/material.dart';
import '../../build_info.dart';
import '../../theme/nexusq_theme.dart';
import '../stock_assets.dart';

class WelcomeScreen extends StatefulWidget {
  const WelcomeScreen({super.key, required this.onNext});
  final VoidCallback onNext;

  @override
  State<WelcomeScreen> createState() => _WelcomeScreenState();
}

class _WelcomeScreenState extends State<WelcomeScreen> {
  static const _frameCount = 36;
  Timer? _timer;
  int _frame = 0;
  bool _precached = false;

  String _frameName(int i) => 'q0${i.toString().padLeft(2, '0')}.png';

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Precache every frame ONCE up front, then start the loop — otherwise the
    // first revolution decodes each frame on demand and stutters. gaplessPlayback
    // (in stockImage) covers any residual swap; together the sphere spins smooth.
    if (_precached || !StockAssets.available) return;
    _precached = true;
    Future.wait([
      for (var i = 0; i < _frameCount; i++)
        precacheImage(AssetImage('assets/stock/drawable/${_frameName(i)}'), context),
    ]).whenComplete(() {
      if (!mounted) return;
      _timer = Timer.periodic(const Duration(milliseconds: 83), (_) {
        setState(() => _frame = (_frame + 1) % _frameCount);
      });
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(32),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          // Original size: height 220, natural width (no width clamp so the
          // sphere keeps its full scale). Centered so it sits dead-centre.
          Center(
            child: SizedBox(
              height: 220,
              child: stockImage(_frameName(_frame),
                  height: 220, fallback: Icons.circle_outlined),
            ),
          ),
          const SizedBox(height: 40),
          const Text('Set up your Nexus Q',
              textAlign: TextAlign.center,
              style: TextStyle(color: NexusQColors.white, fontSize: 22, fontWeight: FontWeight.w300)),
          const SizedBox(height: 12),
          const Text(
            'A few steps and your sphere is on the network and ready to play.',
            textAlign: TextAlign.center,
            style: TextStyle(color: NexusQColors.dim, fontSize: 14),
          ),
          const SizedBox(height: 48),
          FilledButton(onPressed: widget.onNext, child: const Text('Get started')),
          const Spacer(),
          // Version + build stamp — lets us confirm at a glance exactly which
          // apk is on the phone (the version alone was stuck at 1.0.0 for ages).
          const Text(kBuildLabel,
              style: TextStyle(color: NexusQColors.dim, fontSize: 10)),
        ],
      ),
    );
  }
}
