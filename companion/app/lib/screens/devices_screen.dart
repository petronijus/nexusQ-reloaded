import 'dart:async';
import 'package:flutter/material.dart';
import '../protocol/client.dart';
import '../theme/nexusq_theme.dart';

/// "Devices": Bluetooth pairing + the HDMI desktop toggle.
///
/// This screen is the Q's Bluetooth settings panel. That is not a figure of
/// speech: the Q has no screen and no input device, so **the app is the only way
/// to pair anything to it** — a phone for music, or a mouse and keyboard to use
/// the desktop. Hence both halves live here:
///
///   * inbound  — "Pair a phone": open a 120 s window, the phone comes to us.
///   * outbound — scan, and pair a mouse/keyboard ourselves.
///
/// The desktop toggle sits alongside on purpose: pairing a keyboard is what makes
/// the desktop worth switching on, and switching the desktop off is what keeps an
/// idle appliance from heating the sphere for nothing.
class DevicesScreen extends StatefulWidget {
  const DevicesScreen({super.key, required this.client});
  final NexusQClient client;

  @override
  State<DevicesScreen> createState() => _DevicesScreenState();
}

class _DevicesScreenState extends State<DevicesScreen> {
  List<Map<String, dynamic>> _paired = [];
  List<Map<String, dynamic>> _found = [];
  bool _pairing = false;      // an inbound window is open
  bool _scanning = false;
  bool _desktop = false;
  String? _busyMac;           // a pair/forget is in flight for this device
  String? _error;
  Timer? _poll;

  @override
  void initState() {
    super.initState();
    _refresh();
    // The pairing window and the desktop can change without us (bluez's own
    // 120 s timer closes the window; the desktop can be stopped elsewhere), so
    // poll rather than trust our last write.
    _poll = Timer.periodic(const Duration(seconds: 3), (_) => _refreshQuiet());
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  Future<T?> _call<T>(String method, [Map<String, dynamic>? params]) async {
    try {
      final r = await widget.client.call(method, params);
      if (mounted) setState(() => _error = null);
      return r as T?;
    } catch (e) {
      if (mounted) setState(() => _error = _humanError(e));
      return null;
    }
  }

  /// Device error codes are for machines. Say what the user can DO instead.
  String _humanError(Object e) {
    final s = e.toString();
    if (s.contains('not_found')) {
      return 'Device not found — is it still in pairing mode?';
    }
    if (s.contains('AlreadyExists') || s.contains('already')) {
      return 'Already paired.';  // not a failure — it is the outcome they wanted
    }
    if (s.contains('pair_failed')) {
      return 'Pairing failed. Put the device back in pairing mode and retry.';
    }
    if (s.contains('unavailable')) return 'The Q\'s Bluetooth is not responding.';
    return 'Something went wrong. Try again.';
  }

  Future<void> _refresh() async {
    await _refreshQuiet();
  }

  Future<void> _refreshQuiet() async {
    final paired = await _call<Map<String, dynamic>>('listPairedDevices');
    final pairing = await _call<Map<String, dynamic>>('getPairingState');
    final desktop = await _call<Map<String, dynamic>>('getDesktop');
    if (!mounted) return;
    setState(() {
      if (paired != null) {
        _paired = (paired['devices'] as List? ?? []).cast<Map<String, dynamic>>();
      }
      if (pairing != null) _pairing = pairing['pairing'] == true;
      if (desktop != null) _desktop = desktop['desktop'] == true;
    });
    if (_scanning) {
      final r = await _call<Map<String, dynamic>>('listBtScanResults');
      if (r != null && mounted) {
        setState(() => _found = (r['devices'] as List? ?? [])
            .cast<Map<String, dynamic>>()
            .where((d) => d['paired'] != true)
            .toList());
      }
    }
  }

  Future<void> _togglePairing() async {
    await _call(_pairing ? 'stopPairing' : 'startPairing');
    await _refresh();
  }

  Future<void> _scan() async {
    setState(() { _scanning = true; _found = []; });
    await _call('startBtScan', {'secs': 25});
    // The scan self-stops on the device; mirror that here so the UI does not
    // claim to be searching after the radio has stopped.
    Timer(const Duration(seconds: 26), () {
      if (mounted) setState(() => _scanning = false);
    });
  }

  Future<void> _pair(Map<String, dynamic> d) async {
    setState(() => _busyMac = d['mac'] as String?);
    final r = await _call<Map<String, dynamic>>('pairBtDevice', {'mac': d['mac']});
    if (!mounted) return;
    setState(() => _busyMac = null);
    if (r != null) {
      // Done: stop searching and drop the results. Leaving the list up left a
      // live "Pair" button on a device that had just paired — tapping it again
      // asked bluez to pair an already-paired device, which came back as an
      // error and told the user their successful pairing had failed.
      setState(() {
        _scanning = false;
        _found = [];
      });
      // `bonded` is the honest answer to "will this still be here tomorrow?".
      // `paired` alone lies: a session-only pairing reports paired and then
      // evaporates on the next reboot. Say so rather than quietly promise.
      final bonded = r['bonded'] == true;
      _toast(bonded
          ? '${d['name']} paired'
          : '${d['name']} connected, but the pairing will not survive a restart');
    }
    await _refresh();
  }

  Future<void> _forget(Map<String, dynamic> d) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        backgroundColor: NexusQColors.surface,
        title: Text('Forget ${d['name']}?',
            style: const TextStyle(color: NexusQColors.white)),
        content: Text(
          d['connected'] == true
              ? 'It is connected now — this will disconnect it.'
              : 'You will have to pair it again to use it.',
          style: const TextStyle(color: NexusQColors.dim),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(c, true), child: const Text('Forget')),
        ],
      ),
    );
    if (ok != true) return;
    setState(() => _busyMac = d['mac'] as String?);
    await _call('removePairedDevice', {'mac': d['mac']});
    if (mounted) setState(() => _busyMac = null);
    await _refresh();
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  IconData _icon(String? kind) => switch (kind) {
        'mouse' => Icons.mouse,
        'keyboard' => Icons.keyboard,
        'phone' => Icons.smartphone,
        'headphones' => Icons.headphones,
        'audio' => Icons.speaker,
        'computer' => Icons.computer,
        'input' => Icons.videogame_asset,
        _ => Icons.bluetooth,
      };

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Devices'),
        backgroundColor: Colors.transparent,
      ),
      body: ListView(
        padding: const EdgeInsets.all(NexusQSpace.standardMargin),
        children: [
          if (_error != null) _errorBar(),

          // --- inbound: a phone comes to us ---------------------------------
          _sectionTitle('Pair a phone'),
          Card(
            color: NexusQColors.surface,
            child: ListTile(
              leading: Icon(_pairing ? Icons.bluetooth_searching : Icons.bluetooth,
                  color: _pairing ? NexusQColors.accent : NexusQColors.dim),
              title: Text(_pairing ? 'Ready to pair' : 'Pair a phone',
                  style: const TextStyle(color: NexusQColors.white)),
              subtitle: Text(
                _pairing
                    // The ring is the device-side half of this message; say the
                    // same thing the user is looking at.
                    ? 'The ring is spinning blue. Pick the Q in your phone\'s '
                        'Bluetooth settings. Closes itself after 2 minutes.'
                    : 'Opens a 2-minute window so a phone can pair for music.',
                style: const TextStyle(color: NexusQColors.dim, fontSize: 12),
              ),
              trailing: FilledButton(
                onPressed: _togglePairing,
                child: Text(_pairing ? 'Stop' : 'Open'),
              ),
            ),
          ),

          // --- outbound: we go to a mouse/keyboard --------------------------
          const SizedBox(height: 20),
          _sectionTitle('Add a mouse or keyboard'),
          Card(
            color: NexusQColors.surface,
            child: Column(
              children: [
                ListTile(
                  leading: const Icon(Icons.search, color: NexusQColors.dim),
                  title: Text(_scanning ? 'Searching…' : 'Search for devices',
                      style: const TextStyle(color: NexusQColors.white)),
                  subtitle: const Text(
                    'Put the device in pairing mode first (usually hold its '
                    'button until it blinks).',
                    style: TextStyle(color: NexusQColors.dim, fontSize: 12),
                  ),
                  trailing: _scanning
                      ? const SizedBox(
                          width: 18, height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2))
                      : TextButton(onPressed: _scan, child: const Text('Search')),
                ),
                for (final d in _found) _deviceTile(d, paired: false),
                if (_scanning && _found.isEmpty)
                  const Padding(
                    padding: EdgeInsets.only(bottom: 12),
                    child: Text('Nothing yet…',
                        style: TextStyle(color: NexusQColors.dim, fontSize: 12)),
                  ),
              ],
            ),
          ),

          // --- what is already paired ---------------------------------------
          const SizedBox(height: 20),
          _sectionTitle('Paired'),
          Card(
            color: NexusQColors.surface,
            child: _paired.isEmpty
                ? const ListTile(
                    title: Text('Nothing paired yet',
                        style: TextStyle(color: NexusQColors.dim)))
                : Column(children: [for (final d in _paired) _deviceTile(d, paired: true)]),
          ),

          // --- the desktop ---------------------------------------------------
          const SizedBox(height: 20),
          _sectionTitle('HDMI desktop'),
          Card(
            color: NexusQColors.surface,
            child: SwitchListTile(
              value: _desktop,
              onChanged: (v) async {
                setState(() => _desktop = v);  // optimistic; the poll corrects us
                await _call('setDesktop', {'on': v});
                await _refresh();
              },
              title: const Text('Show the desktop on HDMI',
                  style: TextStyle(color: NexusQColors.white)),
              subtitle: const Text(
                'Off by default — it costs power and heat with nothing plugged '
                'in. Pair a mouse and keyboard above to actually use it. Music '
                'keeps playing either way.',
                style: TextStyle(color: NexusQColors.dim, fontSize: 12),
              ),
            ),
          ),
          const SizedBox(height: 24),
        ],
      ),
    );
  }

  Widget _sectionTitle(String s) => Padding(
        padding: const EdgeInsets.only(left: 4, bottom: 6),
        child: Text(s,
            style: const TextStyle(
                color: NexusQColors.white, fontSize: 15, fontWeight: FontWeight.w300)),
      );

  Widget _errorBar() => Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: Colors.red.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Text(_error!,
              style: const TextStyle(color: Colors.redAccent, fontSize: 12)),
        ),
      );

  Widget _deviceTile(Map<String, dynamic> d, {required bool paired}) {
    final busy = _busyMac == d['mac'];
    final connected = d['connected'] == true;
    // A paired-but-not-bonded device is a trap: it works now and is gone after a
    // reboot. Surface it rather than let the user rediscover it the hard way.
    final flaky = paired && d['bonded'] != true;
    return ListTile(
      leading: Icon(_icon(d['kind'] as String?),
          color: connected ? NexusQColors.accent : NexusQColors.dim),
      title: Text(d['name'] as String? ?? d['mac'] as String? ?? '?',
          style: const TextStyle(color: NexusQColors.white)),
      subtitle: Text(
        [
          if (connected) 'Connected',
          if (flaky) 'Will not survive a restart — pair again',
          if (!connected && !flaky && paired) 'Paired',
        ].join(' · '),
        style: TextStyle(
            color: flaky ? Colors.orangeAccent : NexusQColors.dim, fontSize: 12),
      ),
      trailing: busy
          ? const SizedBox(
              width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
          : paired
              ? TextButton(onPressed: () => _forget(d), child: const Text('Forget'))
              : FilledButton(onPressed: () => _pair(d), child: const Text('Pair')),
    );
  }
}
