import 'dart:async';
import 'package:flutter/material.dart';
import '../../theme/nexusq_theme.dart';
import '../bt_setup_client.dart';
import '../setup_flow.dart';

class FindDeviceScreen extends StatefulWidget {
  const FindDeviceScreen(
      {super.key, required this.flow, required this.onNext, required this.onBack});
  final SetupFlowState flow;
  final VoidCallback onNext;
  final VoidCallback onBack;

  @override
  State<FindDeviceScreen> createState() => _FindDeviceScreenState();
}

class _FindDeviceScreenState extends State<FindDeviceScreen> {
  final _found = <String, BtScanResult>{};
  StreamSubscription? _sub;
  bool _scanning = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _start();
  }

  Future<void> _start() async {
    setState(() => _error = null);
    bool ok;
    try {
      ok = await widget.flow.client.ensurePermissions();
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = 'Bluetooth permission check failed — try again.');
      return;
    }
    if (!mounted) return;
    if (!ok) {
      setState(() => _error = 'Bluetooth permission is required to find the Q.');
      return;
    }
    await _sub?.cancel();
    _sub = widget.flow.client.scanResults.listen((r) {
      if (!mounted) return;
      setState(() => _found[r.mac] = r);
    });
    await widget.flow.client.startScan();
    if (!mounted) return;
    setState(() => _scanning = true);
  }

  @override
  void dispose() {
    _sub?.cancel();
    widget.flow.client.stopScan();
    super.dispose();
  }

  void _pick(BtScanResult r) {
    widget.flow.client.stopScan();
    widget.flow.deviceMac = r.mac;
    widget.onNext();
  }

  @override
  Widget build(BuildContext context) {
    final devices = _found.values.toList()
      ..sort((a, b) {
        final aq = a.name.startsWith('Nexus Q') ? 0 : 1;
        final bq = b.name.startsWith('Nexus Q') ? 0 : 1;
        return aq != bq ? aq - bq : a.name.compareTo(b.name);
      });
    return Padding(
      padding: const EdgeInsets.all(32),
      child: Column(
        children: [
          const SizedBox(height: 16),
          const Text('Looking for your Q…',
              style: TextStyle(color: NexusQColors.white, fontSize: 22, fontWeight: FontWeight.w300)),
          const SizedBox(height: 8),
          Text(_error ?? 'Make sure the ring is spinning blue (setup mode).',
              style: const TextStyle(color: NexusQColors.dim, fontSize: 13)),
          const SizedBox(height: 16),
          if (_scanning) const LinearProgressIndicator(minHeight: 2),
          Expanded(
            child: ListView(
              children: [
                for (final d in devices)
                  ListTile(
                    leading: const Icon(Icons.bluetooth, color: NexusQColors.accent),
                    title: Text(d.name.isEmpty ? d.mac : d.name,
                        style: const TextStyle(color: NexusQColors.white)),
                    subtitle: Text(d.mac, style: const TextStyle(color: NexusQColors.dim)),
                    onTap: () => _pick(d),
                  ),
              ],
            ),
          ),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              TextButton(onPressed: widget.onBack, child: const Text('Back')),
              TextButton(onPressed: _start, child: const Text('Rescan')),
            ],
          ),
        ],
      ),
    );
  }
}
