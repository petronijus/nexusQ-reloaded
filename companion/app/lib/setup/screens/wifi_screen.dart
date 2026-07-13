import 'package:flutter/material.dart';
import '../../theme/nexusq_theme.dart';
import '../bt_setup_client.dart';
import '../setup_flow.dart';
import '../stock_assets.dart';

class WifiScreen extends StatefulWidget {
  const WifiScreen(
      {super.key, required this.flow, required this.onNext, required this.onBack});
  final SetupFlowState flow;
  final VoidCallback onNext;
  final VoidCallback onBack;

  @override
  State<WifiScreen> createState() => _WifiScreenState();
}

class _WifiScreenState extends State<WifiScreen> {
  List<Map<String, dynamic>> _networks = [];
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _scan();
  }

  Future<void> _scan() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final r = await widget.flow.client.call('scanNetworks');
      if (!mounted) return;
      setState(() => _networks = (r['networks'] as List).cast<Map<String, dynamic>>());
    } on BtSetupError catch (e) {
      if (!mounted) return;
      setState(() => _error = 'Scan failed: ${e.message}');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String _iconFor(int signal, bool locked) {
    final level = signal > 75 ? 4 : signal > 50 ? 3 : signal > 25 ? 2 : 1;
    return locked ? 'ic_wifi_lock_signal_$level.png' : 'ic_wifi_signal_$level.png';
  }

  Future<void> _join(Map<String, dynamic> net) async {
    final locked = net['security'] == 'wpa-psk';
    String psk = '';
    if (locked) {
      final entered = await showModalBottomSheet<String>(
        context: context,
        isScrollControlled: true,
        backgroundColor: NexusQColors.surface,
        builder: (ctx) => _PasswordSheet(ssid: net['ssid'] as String),
      );
      if (!mounted) return;
      if (entered == null || entered.isEmpty) return;
      psk = entered;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final r = await widget.flow.client.call('setWifi', {
        'ssid': net['ssid'],
        'psk': psk,
        'security': net['security'],
      });
      widget.flow.wifiResult = r;
      widget.onNext();
    } on BtSetupError catch (e) {
      if (!mounted) return;
      setState(() => _error = switch (e.code) {
            'wrong_password' => 'Wrong password — try again.',
            'not_found' => 'Network not found. Is it 2.4 GHz and in range?',
            'timeout' => 'Joining timed out. Try again.',
            _ => 'Join failed: ${e.message}',
          });
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(32),
      child: Column(
        children: [
          const SizedBox(height: 16),
          const Text('Choose a WiFi network',
              style: TextStyle(color: NexusQColors.white, fontSize: 22, fontWeight: FontWeight.w300)),
          const SizedBox(height: 8),
          Text(_error ?? 'The Q will join this network.',
              style: TextStyle(
                  color: _error != null ? Colors.redAccent : NexusQColors.dim, fontSize: 13)),
          const SizedBox(height: 12),
          if (_busy) const LinearProgressIndicator(minHeight: 2),
          Expanded(
            child: ListView(
              children: [
                for (final n in _networks)
                  ListTile(
                    leading: stockImage(
                        _iconFor(n['signal'] as int, n['security'] == 'wpa-psk'),
                        width: 28,
                        fallback: n['security'] == 'wpa-psk' ? Icons.wifi_lock : Icons.wifi),
                    title: Text(n['ssid'] as String,
                        style: const TextStyle(color: NexusQColors.white)),
                    subtitle: Text('${n['signal']}%',
                        style: const TextStyle(color: NexusQColors.dim)),
                    enabled: !_busy,
                    onTap: () => _join(n),
                  ),
              ],
            ),
          ),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              TextButton(onPressed: widget.onBack, child: const Text('Back')),
              TextButton(onPressed: _busy ? null : _scan, child: const Text('Rescan')),
            ],
          ),
        ],
      ),
    );
  }
}

class _PasswordSheet extends StatefulWidget {
  const _PasswordSheet({required this.ssid});
  final String ssid;

  @override
  State<_PasswordSheet> createState() => _PasswordSheetState();
}

class _PasswordSheetState extends State<_PasswordSheet> {
  final _ctrl = TextEditingController();
  bool _show = false;

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(
          left: 24, right: 24, top: 24, bottom: MediaQuery.of(context).viewInsets.bottom + 24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Password for ${widget.ssid}',
              style: const TextStyle(color: NexusQColors.white, fontSize: 16)),
          const SizedBox(height: 12),
          TextField(
            controller: _ctrl,
            obscureText: !_show,
            autofocus: true,
            style: const TextStyle(color: NexusQColors.white),
            decoration: InputDecoration(
              suffixIcon: IconButton(
                icon: Icon(_show ? Icons.visibility_off : Icons.visibility,
                    color: NexusQColors.dim),
                onPressed: () => setState(() => _show = !_show),
              ),
            ),
            onSubmitted: (v) => Navigator.pop(context, v),
          ),
          const SizedBox(height: 16),
          FilledButton(
            onPressed: () => Navigator.pop(context, _ctrl.text),
            child: const Text('Join'),
          ),
        ],
      ),
    );
  }
}
