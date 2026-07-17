import 'dart:async';
import 'package:flutter/material.dart';
import 'package:simple_icons/simple_icons.dart';
import '../debug/app_log.dart';
import '../protocol/client.dart';
import '../theme/nexusq_theme.dart';
import 'debug_log_screen.dart';
import 'service_log_screen.dart';

/// "Settings": the box's configuration that isn't Bluetooth pairing —
///  - Streaming services: turn Spotify / AirPlay / Roon on or off (only what you
///    switch on runs; off ones cost no memory or CPU), each with its own log.
///  - HDMI desktop: the on-demand desktop toggle.
///  - Developer: the in-app connection debug log.
///
/// Bluetooth pairing lives in its own Devices screen — it is a task, not a
/// setting (you go there to pair a thing, then leave).
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key, required this.client});
  final NexusQClient client;

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  List<Map<String, dynamic>> _services = [];
  final Set<String> _busyService = {};
  bool _desktop = false;
  String? _error;
  Timer? _poll;

  @override
  void initState() {
    super.initState();
    _refresh();
    _poll = Timer.periodic(const Duration(seconds: 3), (_) => _refresh());
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  /// Poll failures go to the log, not the red bar; only a user action (a toggle)
  /// shows a visible error.
  Future<Map<String, dynamic>?> _call(String method,
      [Map<String, dynamic>? params, bool silent = true]) async {
    try {
      final r = await widget.client.call(method, params);
      if (mounted && !silent) setState(() => _error = null);
      return r;
    } catch (e) {
      AppLog.add('settings', '$method failed: $e', warn: true);
      if (mounted && !silent) {
        setState(() => _error = 'Something went wrong. Try again.');
      }
      return null;
    }
  }

  Future<void> _refresh() async {
    final services = await _call('listServices');
    final desktop = await _call('getDesktop');
    if (!mounted) return;
    setState(() {
      if (services != null) {
        final fresh =
            (services['services'] as List? ?? []).cast<Map<String, dynamic>>();
        // Don't let a poll clobber a service the user is mid-toggle on.
        _services = [
          for (final s in fresh)
            _busyService.contains(s['id'])
                ? _services.firstWhere((o) => o['id'] == s['id'],
                    orElse: () => s)
                : s
        ];
      }
      if (desktop != null) _desktop = desktop['desktop'] == true;
    });
  }

  Future<void> _toggleService(String id, bool on) async {
    setState(() {
      _busyService.add(id);
      final i = _services.indexWhere((s) => s['id'] == id);
      if (i >= 0) _services[i] = {..._services[i], 'on': on};
    });
    final r = await _call('setService', {'id': id, 'on': on}, false);
    if (!mounted) return;
    setState(() {
      _busyService.remove(id);
      if (r != null) {
        final i = _services.indexWhere((s) => s['id'] == id);
        if (i >= 0) _services[i] = {..._services[i], 'on': r['on'] == true};
      }
    });
  }

  void _openLog(Map<String, dynamic> s) {
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => ServiceLogScreen(
        client: widget.client,
        id: s['id'] as String,
        name: s['name'] as String? ?? s['id'] as String,
      ),
    ));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
          title: const Text('Settings'), backgroundColor: Colors.transparent),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
          children: [
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Text(_error!,
                    style: const TextStyle(color: Colors.orangeAccent)),
              ),

            // --- streaming services ------------------------------------------
            _sectionTitle('Streaming services'),
            if (_services.isEmpty)
              const Padding(
                padding: EdgeInsets.all(12),
                child: Text('Loading…',
                    style: TextStyle(color: NexusQColors.dim, fontSize: 13)),
              )
            else
              Card(
                color: NexusQColors.surface,
                child: Column(
                  children: [
                    for (final s in _services)
                      SwitchListTile(
                        value: s['on'] == true,
                        onChanged: _busyService.contains(s['id'])
                            ? null
                            : (v) => _toggleService(s['id'] as String, v),
                        // Official brand mark, in the brand colour when on and
                        // greyed when off.
                        secondary: Icon(_serviceIcon(s['id'] as String?),
                            color: s['on'] == true
                                ? _serviceColor(s['id'] as String?)
                                : NexusQColors.dim),
                        title: Text(s['name'] as String? ?? s['id'] as String,
                            style: const TextStyle(color: NexusQColors.white)),
                        subtitle: Row(
                          children: [
                            Expanded(
                              child: Text(_serviceHint(s['id'] as String?),
                                  style: const TextStyle(
                                      color: NexusQColors.dim, fontSize: 12)),
                            ),
                            TextButton.icon(
                              onPressed: () => _openLog(s),
                              icon: const Icon(Icons.article_outlined, size: 16),
                              label: const Text('Log'),
                              style: TextButton.styleFrom(
                                  foregroundColor: NexusQColors.accent,
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 8),
                                  minimumSize: const Size(0, 32),
                                  tapTargetSize:
                                      MaterialTapTargetSize.shrinkWrap),
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
            const Padding(
              padding: EdgeInsets.only(top: 6, left: 4, right: 4),
              child: Text(
                'Only the services you switch on run — off ones use no memory or '
                'CPU. Your choice sticks across restarts.',
                style: TextStyle(color: NexusQColors.dim, fontSize: 11),
              ),
            ),

            // --- HDMI desktop ------------------------------------------------
            const SizedBox(height: 20),
            _sectionTitle('HDMI desktop'),
            Card(
              color: NexusQColors.surface,
              child: SwitchListTile(
                value: _desktop,
                onChanged: (v) async {
                  setState(() => _desktop = v); // optimistic; the poll corrects us
                  await _call('setDesktop', {'on': v}, false);
                  await _refresh();
                },
                secondary: Icon(Icons.desktop_windows_outlined,
                    color: _desktop ? NexusQColors.accent : NexusQColors.dim),
                title: const Text('Show the desktop on HDMI',
                    style: TextStyle(color: NexusQColors.white)),
                subtitle: const Text(
                  'Off by default — it costs power and heat with nothing plugged '
                  'in. Pair a mouse and keyboard (Devices) to actually use it. '
                  'Music keeps playing either way.',
                  style: TextStyle(color: NexusQColors.dim, fontSize: 12),
                ),
              ),
            ),

            // --- developer ---------------------------------------------------
            const SizedBox(height: 20),
            _sectionTitle('Developer'),
            Card(
              color: NexusQColors.surface,
              child: ValueListenableBuilder<bool>(
                valueListenable: AppLog.enabled,
                builder: (context, on, _) => Column(
                  children: [
                    SwitchListTile(
                      value: on,
                      onChanged: (v) => AppLog.enabled.value = v,
                      secondary: Icon(Icons.bug_report_outlined,
                          color: on ? NexusQColors.accent : NexusQColors.dim),
                      title: const Text('Debug mode',
                          style: TextStyle(color: NexusQColors.white)),
                      subtitle: const Text(
                        'Shows the connection log (recording is always on, this '
                        'just unlocks the viewer).',
                        style: TextStyle(color: NexusQColors.dim, fontSize: 12),
                      ),
                    ),
                    if (on)
                      ListTile(
                        leading: const Icon(Icons.receipt_long,
                            color: NexusQColors.dim),
                        title: const Text('View connection log',
                            style: TextStyle(color: NexusQColors.white)),
                        trailing: const Icon(Icons.chevron_right,
                            color: NexusQColors.dim),
                        onTap: () => Navigator.of(context).push(
                            MaterialPageRoute(
                                builder: (_) => const DebugLogScreen())),
                      ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _sectionTitle(String s) => Padding(
        padding: const EdgeInsets.only(left: 4, bottom: 6),
        child: Text(s,
            style: const TextStyle(
                color: NexusQColors.white,
                fontSize: 15,
                fontWeight: FontWeight.w300)),
      );

  // Official service marks. Spotify + Roon come from simple_icons (a CC0 brand-icon
  // set); AirPlay is Material's own `Icons.airplay` (the standard AirPlay glyph —
  // simple_icons has no AirPlay). Unknown ids fall back to a neutral speaker.
  IconData _serviceIcon(String? id) {
    switch (id) {
      case 'spotify':
        return SimpleIcons.spotify;
      case 'airplay':
        return Icons.airplay;
      case 'roon':
        return SimpleIcons.roon;
      default:
        return Icons.speaker;
    }
  }

  // The brand colour, used when the service is on.
  Color _serviceColor(String? id) {
    switch (id) {
      case 'spotify':
        return SimpleIconColors.spotify; // Spotify green
      case 'roon':
        return SimpleIconColors.roon;    // Roon blue
      case 'airplay':
        return NexusQColors.white;       // AirPlay has no signature colour
      default:
        return NexusQColors.accent;
    }
  }

  String _serviceHint(String? id) {
    switch (id) {
      case 'spotify':
        return 'Cast from Spotify to "Nexus Q".';
      case 'airplay':
        return 'Stream from an Apple device (AirPlay).';
      case 'roon':
        return 'A Roon Ready endpoint for your Roon Core.';
      default:
        return 'A streaming input.';
    }
  }
}
