import 'package:flutter/material.dart';
import '../../theme/nexusq_theme.dart';
import '../pairing_color.dart';
import '../setup_flow.dart';

class ConfirmColorScreen extends StatefulWidget {
  const ConfirmColorScreen(
      {super.key, required this.flow, required this.onNext, required this.onBack});
  final SetupFlowState flow;
  final VoidCallback onNext;
  final VoidCallback onBack;

  @override
  State<ConfirmColorScreen> createState() => _ConfirmColorScreenState();
}

class _ConfirmColorScreenState extends State<ConfirmColorScreen> {
  Color? _color;
  String? _status;
  bool _ledUnavailable = false;

  @override
  void initState() {
    super.initState();
    _connect();
  }

  Future<void> _connect() async {
    final mac = widget.flow.deviceMac;
    if (mac == null) return;
    setState(() {
      _status = 'Connecting over Bluetooth…';
      _color = pairingColor(mac); // show immediately; device confirms below
    });
    try {
      await widget.flow.client.connect(mac);
      final r = await widget.flow.client.call('confirmColor');
      final rgb = (r['rgb'] as List).cast<int>();
      if (!mounted) return;
      setState(() {
        _color = Color.fromARGB(255, rgb[0], rgb[1], rgb[2]);
        _status = null;
      });
    } on Object catch (e) {
      // nexusqd down = LED unavailable, but setup can continue.
      if (!mounted) return;
      setState(() {
        _ledUnavailable = true;
        _status = 'Could not light the ring ($e). You can continue anyway.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(32),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Text('Is your sphere glowing this color?',
              textAlign: TextAlign.center,
              style: TextStyle(color: NexusQColors.white, fontSize: 22, fontWeight: FontWeight.w300)),
          const SizedBox(height: 40),
          Container(
            width: 160,
            height: 160,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: _color ?? Colors.transparent,
              boxShadow: [
                if (_color != null)
                  BoxShadow(color: _color!.withValues(alpha: 0.6), blurRadius: 48, spreadRadius: 8),
              ],
            ),
          ),
          const SizedBox(height: 32),
          if (_status != null)
            Text(_status!,
                textAlign: TextAlign.center,
                style: const TextStyle(color: NexusQColors.dim, fontSize: 13)),
          const SizedBox(height: 32),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              TextButton(onPressed: widget.onBack, child: const Text('Back')),
              FilledButton(
                onPressed: (_status == null || _ledUnavailable) ? widget.onNext : null,
                child: Text(_ledUnavailable ? 'Continue anyway' : "Yes, that's it"),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
