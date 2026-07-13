import 'dart:async';
import 'package:flutter/material.dart';
import '../../theme/nexusq_theme.dart';
import '../stock_assets.dart';

class WelcomeScreen extends StatefulWidget {
  const WelcomeScreen({super.key, required this.onNext});
  final VoidCallback onNext;

  @override
  State<WelcomeScreen> createState() => _WelcomeScreenState();
}

class _WelcomeScreenState extends State<WelcomeScreen> {
  Timer? _timer;
  int _frame = 0;

  @override
  void initState() {
    super.initState();
    if (StockAssets.available) {
      _timer = Timer.periodic(const Duration(milliseconds: 83), (_) {
        setState(() => _frame = (_frame + 1) % 36);
      });
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final frameName = 'q0${_frame.toString().padLeft(2, '0')}.png';
    return Padding(
      padding: const EdgeInsets.all(32),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          SizedBox(
              height: 220,
              child: stockImage(frameName, height: 220, fallback: Icons.circle_outlined)),
          const SizedBox(height: 40),
          const Text('Set up your Nexus Q',
              style: TextStyle(color: NexusQColors.white, fontSize: 22, fontWeight: FontWeight.w300)),
          const SizedBox(height: 12),
          const Text(
            'A few steps and your sphere is on the network and ready to play.',
            textAlign: TextAlign.center,
            style: TextStyle(color: NexusQColors.dim, fontSize: 14),
          ),
          const SizedBox(height: 48),
          FilledButton(onPressed: widget.onNext, child: const Text('Get started')),
        ],
      ),
    );
  }
}
