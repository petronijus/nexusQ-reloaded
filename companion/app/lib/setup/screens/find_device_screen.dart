import 'dart:async';
import 'package:flutter/material.dart';
import '../../theme/nexusq_theme.dart';
import '../../widgets/glowing_ring.dart';
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
          // Hero: a centered, slowly-rotating glow while we search — echoes the
          // ring the user is looking at on the device.
          //
          // Centre when the content is short, SCROLL when it is not: the found-
          // device list is unbounded, and a Column cannot scroll, so a busy RF
          // environment (many phones/headphones/TVs in range) overflowed the
          // viewport and painted Flutter's yellow overflow stripes. minHeight =
          // the viewport keeps the glow optically centred while nothing (or
          // little) has been found, which is the whole point of this layout.
          Expanded(
            child: LayoutBuilder(
              builder: (context, constraints) => SingleChildScrollView(
                child: ConstrainedBox(
                  constraints: BoxConstraints(minHeight: constraints.maxHeight),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                  SizedBox(
                    width: 160,
                    height: 160,
                    child: GlowingRing(
                      // volume 0: no equator arc — just the dim sphere outline
                      // and the slow rotating highlight tick, our "searching…"
                      // motion. Dims out if a permission/scan error is showing.
                      volume: 0.0,
                      muted: _error != null,
                    ),
                  ),
                  const SizedBox(height: 32),
                  const Text('Looking for your Q…',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                          color: NexusQColors.white,
                          fontSize: 22,
                          fontWeight: FontWeight.w300)),
                  const SizedBox(height: 8),
                  Text(_error ?? 'Make sure the ring is spinning blue (setup mode).',
                      textAlign: TextAlign.center,
                      style: const TextStyle(color: NexusQColors.dim, fontSize: 13)),
                  if (_scanning && devices.isEmpty) ...[
                    const SizedBox(height: 20),
                    const SizedBox(
                      width: 120,
                      child: LinearProgressIndicator(minHeight: 2),
                    ),
                  ],
                      // Found devices appear directly under the glow, still
                      // centred. The Q sorts to the top (see the sort above).
                      for (final d in devices)
                        Padding(
                          padding: const EdgeInsets.only(top: 8),
                          child: ListTile(
                            leading: const Icon(Icons.bluetooth,
                                color: NexusQColors.accent),
                            title: Text(d.name.isEmpty ? d.mac : d.name,
                                style: const TextStyle(color: NexusQColors.white)),
                            subtitle: Text(d.mac,
                                style: const TextStyle(color: NexusQColors.dim)),
                            onTap: () => _pick(d),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
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
