import 'package:flutter/material.dart';
import '../../theme/nexusq_theme.dart';
import '../stock_assets.dart';

class CablesScreen extends StatelessWidget {
  const CablesScreen({super.key, required this.onNext, required this.onBack});
  final VoidCallback onNext;
  final VoidCallback onBack;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(32),
      child: Column(
        children: [
          const SizedBox(height: 16),
          const Text('Connect your Nexus Q',
              style: TextStyle(color: NexusQColors.white, fontSize: 22, fontWeight: FontWeight.w300)),
          const SizedBox(height: 24),
          Expanded(
            child: ListView(children: [
              stockImage('cables_diagram_01.png', fallback: Icons.cable),
              const SizedBox(height: 16),
              stockImage('cables_diagram_02.png', fallback: Icons.speaker),
              const SizedBox(height: 16),
              const Text(
                'Plug in power. Connect speakers to the banana terminals, or use '
                'the optical output. The LED ring spins blue while the Q starts up.',
                style: TextStyle(color: NexusQColors.dim, fontSize: 14),
              ),
            ]),
          ),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              TextButton(onPressed: onBack, child: const Text('Back')),
              FilledButton(onPressed: onNext, child: const Text('Next')),
            ],
          ),
        ],
      ),
    );
  }
}
