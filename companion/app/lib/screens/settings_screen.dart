import 'dart:async';
import 'package:flutter/material.dart';
import 'package:simple_icons/simple_icons.dart';
import '../build_info.dart';
import '../debug/app_log.dart';
import '../protocol/client.dart';
import '../theme/nexusq_theme.dart';
import '../update/app_update.dart';
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

  // --- app update state ---
  bool _checkingUpdate = false;
  AppRelease? _update; // non-null = a newer app version is available
  bool _downloading = false; // true for the whole download (gates the UI)
  double? _downloadProgress; // 0..1 when length known; null = indeterminate
  int _downloadBytes = 0; // bytes received so far (shown when length unknown)
  String? _updateError;

  // --- Nexus Q (device) system-update state ---
  Map<String, dynamic>? _nexusCheck; // result of checkNexusUpdate
  bool _checkingNexus = false;
  bool _installingNexus = false;
  String? _nexusError;

  bool get _nexusUpdateAvailable => _nexusCheck?['updateAvailable'] == true;

  @override
  void initState() {
    super.initState();
    _refresh();
    _poll = Timer.periodic(const Duration(seconds: 3), (_) => _refresh());
    _checkUpdate(); // silent auto-check on open (app track)
    _checkNexusUpdate(); // and the device track — else the section reads empty
    // every time Settings is reopened until you tap Check again.
  }

  Future<void> _checkUpdate() async {
    if (_checkingUpdate) return;
    setState(() {
      _checkingUpdate = true;
      _updateError = null;
    });
    // fetchLatest (not checkForUpdate) so a network/parse failure is DISTINCT from
    // "up to date": returning null from checkForUpdate meant both, so a failed
    // check silently read as up-to-date. Here null == fetch failed -> show it.
    final rel = await AppUpdate.fetchLatest();
    if (!mounted) return;
    setState(() {
      _checkingUpdate = false;
      if (rel == null) {
        _update = null;
        _updateError = 'Update check failed — check your connection.';
      } else if (rel.versionCode <= AppUpdate.currentVersionCode) {
        _update = null; // genuinely up to date
      } else {
        _update = rel;
      }
    });
  }

  Future<void> _installUpdate() async {
    final rel = _update;
    if (rel == null || _downloading) return;
    setState(() {
      _downloading = true;
      _downloadProgress = 0;
      _downloadBytes = 0;
      _updateError = null;
    });
    try {
      final path = await AppUpdate.downloadApk(rel, (frac, received) {
        if (mounted) {
          setState(() {
            _downloadProgress = frac;
            _downloadBytes = received;
          });
        }
      });
      await AppUpdate.install(path); // OS installer takes over
      if (mounted) setState(() => _downloading = false);
    } catch (e) {
      AppLog.add('update', 'install failed: $e', warn: true);
      if (mounted) {
        setState(() {
          _downloading = false;
          _updateError = 'Update failed. Try again.';
        });
      }
    }
  }

  Future<void> _checkNexusUpdate() async {
    if (_checkingNexus || _installingNexus) return;
    setState(() {
      _checkingNexus = true;
      _nexusError = null;
    });
    final r = await _call('checkNexusUpdate', null, false);
    if (!mounted) return;
    setState(() {
      _checkingNexus = false;
      _nexusCheck = r;
    });
  }

  Future<void> _installNexusUpdate() async {
    if (_installingNexus) return;
    setState(() {
      _installingNexus = true;
      _nexusError = null;
    });
    final r = await _call('installNexusUpdate', null, false);
    if (!mounted) return;
    setState(() {
      _installingNexus = false;
      if (r != null) {
        _nexusCheck = null; // daemons restarting; re-check after it settles
      } else {
        _nexusError = 'Device update failed. Try again.';
      }
    });
    // nexusq-control restarts itself — the link drops and reconnects; re-check.
    Future.delayed(const Duration(seconds: 8), () {
      if (mounted) _checkNexusUpdate();
    });
  }

  String _nexusStatusLine() {
    final pkgs =
        (_nexusCheck?['packages'] as List?)?.cast<Map<String, dynamic>>() ?? [];
    if (pkgs.isEmpty) return 'Tap ⟳ to check for device software updates.';
    if (_nexusUpdateAvailable) {
      final up = pkgs.where((p) => p['upgradable'] == true).map((p) =>
          '${p['name']} → ${p['available']}');
      return up.join(', ');
    }
    // up to date — show the installed control version as the anchor
    final ctrl = pkgs.firstWhere((p) => p['name'] == 'nexusq-control',
        orElse: () => {'installed': '?'});
    return 'Up to date (nexusq-control ${ctrl['installed']})';
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

            // --- app updates -------------------------------------------------
            const SizedBox(height: 20),
            _sectionTitle('App'),
            Card(
              color: NexusQColors.surface,
              child: Column(
                children: [
                  ListTile(
                    leading: Icon(
                        _update != null
                            ? Icons.system_update
                            : Icons.check_circle_outline,
                        color: _update != null
                            ? NexusQColors.accent
                            : NexusQColors.dim),
                    title: Text(
                        _update != null
                            ? 'Update available — v${_update!.version}'
                            : 'App is up to date',
                        style: const TextStyle(color: NexusQColors.white)),
                    subtitle: Text(
                        _update != null && _update!.notes.isNotEmpty
                            ? _update!.notes
                            : 'Installed v$kAppVersion',
                        style: const TextStyle(
                            color: NexusQColors.dim, fontSize: 12)),
                    trailing: _checkingUpdate
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2))
                        : IconButton(
                            icon: const Icon(Icons.refresh,
                                color: NexusQColors.dim),
                            tooltip: 'Check for updates',
                            onPressed: _checkUpdate),
                  ),
                  if (_updateError != null)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                      child: Text(_updateError!,
                          style: const TextStyle(
                              color: Colors.orangeAccent, fontSize: 12)),
                    ),
                  if (_update != null)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                      child: !_downloading
                          ? SizedBox(
                              width: double.infinity,
                              child: FilledButton.icon(
                                onPressed: _installUpdate,
                                icon: const Icon(Icons.download, size: 18),
                                label: Text(
                                    'Download & install v${_update!.version}'),
                              ),
                            )
                          : Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                // value:null -> animated indeterminate bar (used
                                // when the server sent no Content-Length)
                                LinearProgressIndicator(
                                    value: _downloadProgress),
                                const SizedBox(height: 4),
                                Text(
                                    _downloadProgress != null
                                        ? 'Downloading… ${(_downloadProgress! * 100).round()}%'
                                        : 'Downloading… ${(_downloadBytes / 1048576).toStringAsFixed(1)} MB',
                                    style: const TextStyle(
                                        color: NexusQColors.dim, fontSize: 11)),
                              ],
                            ),
                    ),
                ],
              ),
            ),

            // --- Nexus Q system update ---------------------------------------
            const SizedBox(height: 20),
            _sectionTitle('Nexus Q'),
            Card(
              color: NexusQColors.surface,
              child: Column(
                children: [
                  ListTile(
                    leading: Icon(
                        _nexusUpdateAvailable
                            ? Icons.system_update_alt
                            : Icons.memory,
                        color: _nexusUpdateAvailable
                            ? NexusQColors.accent
                            : NexusQColors.dim),
                    title: Text(
                        _nexusUpdateAvailable
                            ? 'Device update available'
                            : 'Device software',
                        style: const TextStyle(color: NexusQColors.white)),
                    subtitle: Text(_nexusStatusLine(),
                        style: const TextStyle(
                            color: NexusQColors.dim, fontSize: 12)),
                    trailing: _checkingNexus
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2))
                        : IconButton(
                            icon: const Icon(Icons.refresh,
                                color: NexusQColors.dim),
                            tooltip: 'Check for device updates',
                            onPressed: _checkNexusUpdate),
                  ),
                  if (_nexusError != null)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                      child: Text(_nexusError!,
                          style: const TextStyle(
                              color: Colors.orangeAccent, fontSize: 12)),
                    ),
                  if (_nexusUpdateAvailable)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                      child: SizedBox(
                        width: double.infinity,
                        child: FilledButton.icon(
                          onPressed:
                              _installingNexus ? null : _installNexusUpdate,
                          icon: _installingNexus
                              ? const SizedBox(
                                  width: 16,
                                  height: 16,
                                  child: CircularProgressIndicator(
                                      strokeWidth: 2))
                              : const Icon(Icons.download, size: 18),
                          label: Text(_installingNexus
                              ? 'Installing… (the Q reconnects)'
                              : 'Install device update'),
                        ),
                      ),
                    ),
                ],
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
      case 'usbaudio':
        return Icons.usb;
      default:
        return Icons.speaker;
    }
  }

  // The brand colour, used when the service is on.
  Color _serviceColor(String? id) {
    switch (id) {
      case 'spotify':
        return SimpleIconColors.spotify; // Spotify green — reads fine on dark
      case 'roon':
        return NexusQColors.white;       // Roon blue reads too dark on the theme
      case 'airplay':
        return NexusQColors.white;       // AirPlay has no signature colour
      case 'usbaudio':
        return NexusQColors.white;       // generic USB input, no brand colour
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
      case 'usbaudio':
        return 'Play from a USB-connected computer or phone (Q as a USB DAC).';
      default:
        return 'A streaming input.';
    }
  }
}
