import 'dart:async';
import 'package:flutter/material.dart';
import 'package:simple_icons/simple_icons.dart';
import '../build_info.dart';
import '../debug/app_log.dart';
import '../protocol/client.dart';
import '../theme/nexusq_theme.dart';
import '../update/app_update.dart';
import 'debug_log_screen.dart';
import 'health_screen.dart';
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

  // --- device identity (name / room) ---
  String _deviceName = '';
  String _deviceRoom = '';
  bool _renaming = false;

  // --- app update state ---
  bool _checkingUpdate = false;
  AppRelease? _update; // non-null = a newer app version is available
  bool _downloading = false; // true for the whole download (gates the UI)
  double? _downloadProgress; // 0..1 when length known; null = indeterminate
  int _downloadBytes = 0; // bytes received so far (shown when length unknown)
  String? _updateError;

  // --- Nexus Q (device) daemon-update state ---
  Map<String, dynamic>? _nexusCheck; // result of checkNexusUpdate
  bool _checkingNexus = false;
  bool _installingNexus = false;
  String? _nexusError;

  bool get _nexusUpdateAvailable => _nexusCheck?['updateAvailable'] == true;

  // --- full-system (apt-like) update state; checked on demand (heavier) ---
  Map<String, dynamic>? _systemCheck; // result of checkSystemUpdate
  bool _checkingSystem = false;
  bool _installingSystem = false;
  String? _systemError;
  String? _systemProgress; // live phase message shown while installing

  bool get _systemUpdateAvailable => _systemCheck?['updateAvailable'] == true;

  // The "App update" card merges the phone app AND the device daemons: ONE
  // indicator, one button. It's "available" when EITHER the app or a device
  // daemon has a newer build; the install does whichever is needed (device
  // daemons first, then the app — the app install restarts the phone, so it goes
  // last, onto an already-updated device).
  bool get _companionUpdateAvailable => _update != null || _nexusUpdateAvailable;
  bool get _companionBusy => _downloading || _installingNexus;

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
    // No app-track outside Android (see AppUpdate.selfUpdateSupported): _update
    // stays null, so the merged card degrades to the device-daemon track alone.
    if (!AppUpdate.selfUpdateSupported) return;
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
      } else if (!AppUpdate.knowsOwnVersion) {
        // A build with no APP_VERSION cannot compare itself to anything. Saying
        // so beats offering an update it would install forever (see AppUpdate).
        _update = null;
        _updateError = 'This build has no version stamp — build with '
            'build-apk.sh to enable update checks.';
      } else if (rel.versionCode <= AppUpdate.currentVersionCode!) {
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
    final r = await _call('checkNexusUpdate', null, true);
    if (!mounted) return;
    setState(() {
      _checkingNexus = false;
      _nexusCheck = r;
    });
  }

  Future<void> _installNexusUpdate() async {
    if (_installingNexus) return;
    setState(() {
      _installingNexus = true; // UI shows "Installing…" until verified
      _nexusError = null;
      // keep _nexusCheck: its package list is what the UI shows as "what's
      // installing"; clearing it hid the whole install block (it was gated on
      // _nexusUpdateAvailable) so the app showed no feedback during an install.
    });
    // Installing upgrades the daemons and RESTARTS them — including the control
    // bridge, which necessarily drops THIS connection. So a null/timeout from
    // the call is EXPECTED, not a failure: the device may well have succeeded.
    // We confirm the real outcome by reconnecting and re-checking the version,
    // never by this call's return value (which used to be read as "failed").
    await _call('installNexusUpdate', null, true);
    if (!mounted) return;
    await Future.delayed(const Duration(seconds: 8)); // daemons restart + relink
    await _verifyNexusInstall();
  }

  /// Confirm an install by re-checking the device: no update pending == success;
  /// still pending after a few retries == genuinely failed. Retries because the
  /// device may still be settling and the link still reconnecting.
  Future<void> _verifyNexusInstall() async {
    for (var attempt = 0; attempt < 4; attempt++) {
      if (!mounted) return;
      final r = await _call('checkNexusUpdate', null, true);
      if (!mounted) return;
      if (r != null) {
        final stillPending = r['updateAvailable'] == true;
        setState(() {
          _installingNexus = false;
          _nexusCheck = r;
          _nexusError =
              stillPending ? 'Device update failed. Try again.' : null;
        });
        return;
      }
      await Future.delayed(const Duration(seconds: 3)); // link not back yet, retry
    }
    // Couldn't reach the device after retries — inconclusive, not a hard failure.
    if (mounted) {
      setState(() {
        _installingNexus = false;
        _nexusError = 'Update sent — reopen Settings to confirm.';
      });
    }
  }

  // --- full-system update (checked on demand — apk version -l is heavier) ---
  Future<void> _checkSystemUpdate() async {
    if (_checkingSystem || _installingSystem) return;
    setState(() {
      _checkingSystem = true;
      _systemError = null;
    });
    final r = await _call('checkSystemUpdate', null, true);
    if (!mounted) return;
    setState(() {
      _checkingSystem = false;
      // busy=true means the device is mid-install (control r26 serializes apk):
      // don't overwrite the last known result, just say so.
      if (r != null && r['busy'] == true) {
        _systemError = 'An update is already in progress — try again shortly.';
      } else {
        _systemCheck = r;
      }
    });
  }

  Future<void> _installSystemUpdate() async {
    if (_installingSystem) return;
    setState(() {
      _installingSystem = true;
      _systemError = null;
      _systemProgress = 'Downloading & installing packages on the Q…';
    });
    // A full-system upgrade restarts the daemons — and may REBOOT the Q (base
    // libc/init churn) — so the call's disconnect is EXPECTED, not a failure.
    // apk exposes no percentage, so we narrate the phases we DO know instead:
    // installing → applying/restarting → reconnecting → verifying.
    await _call('installSystemUpdate', null, true);
    if (!mounted) return;
    setState(() =>
        _systemProgress = 'Applying updates — the Q may restart to finish…');
    await Future.delayed(const Duration(seconds: 12));
    await _verifySystemInstall();
  }

  Future<void> _verifySystemInstall() async {
    for (var attempt = 0; attempt < 8; attempt++) {
      if (!mounted) return;
      setState(() => _systemProgress = attempt == 0
          ? 'Reconnecting to the Q…'
          : 'Reconnecting to the Q… (${attempt + 1}/8)');
      final r = await _call('checkSystemUpdate', null, true);
      if (!mounted) return;
      // Wait past a transient disconnect (reboot) OR a busy reply (control still
      // finishing its install lock) before judging.
      if (r != null && r['busy'] != true) {
        final stillPending = r['updateAvailable'] == true;
        setState(() {
          _installingSystem = false;
          _systemProgress = null;
          _systemCheck = r;
          // A leftover upgradable package is NOT a failure (the install ran and
          // the device came back) — only nudge the user to run it again.
          _systemError = stillPending
              ? 'Installed — a few packages still pending; tap Update system '
                  'again to finish them.'
              : null;
        });
        return;
      }
      await Future.delayed(const Duration(seconds: 5)); // device still rebooting
    }
    if (mounted) {
      setState(() {
        _installingSystem = false;
        _systemProgress = null;
        _systemError = 'Update sent — reopen Settings to confirm it applied.';
      });
    }
  }

  String _systemStatusLine() {
    final c = _systemCheck;
    if (c == null) return 'Tap ⟳ to check the kernel + all system packages.';
    final kernel = c['kernel'] ?? '?';
    final pkgs = (c['packages'] as List?)?.cast<Map<String, dynamic>>() ?? [];
    if (_systemUpdateAvailable) {
      return 'Kernel $kernel · ${pkgs.length} package'
          '${pkgs.length == 1 ? '' : 's'} can be updated';
    }
    return 'Kernel $kernel · up to date';
  }

  // --- the merged "App update" (phone app + device daemons) ----------------
  Future<void> _checkCompanion() async {
    await Future.wait([_checkUpdate(), _checkNexusUpdate()]);
  }

  /// One "Update" action for the whole companion. Device daemons go FIRST (the
  /// app drives that over the link, and installing the app restarts the phone),
  /// then the phone app. Whichever side has no update is simply skipped.
  Future<void> _installCompanion() async {
    if (_companionBusy) return;
    if (_nexusUpdateAvailable) {
      await _installNexusUpdate(); // ring narration + verify-by-recheck
    }
    if (!mounted) return;
    if (_update != null) {
      await _installUpdate(); // download + hand to the OS installer (restarts app)
    }
  }

  /// Merged release notes: the app's notes + which device daemons are upgrading.
  String _companionStatusLine() {
    final parts = <String>[];
    if (_update != null) {
      parts.add(_update!.notes.isNotEmpty
          ? 'App v${_update!.version} — ${_update!.notes}'
          : 'App v${_update!.version}');
    }
    if (_nexusUpdateAvailable) {
      final pkgs =
          (_nexusCheck?['packages'] as List?)?.cast<Map<String, dynamic>>() ?? [];
      final up = pkgs
          .where((p) => p['upgradable'] == true)
          .map((p) => '${p['name']} → ${p['available']}');
      parts.add('Device software: ${up.join(', ')}');
    }
    if (parts.isNotEmpty) return parts.join('\n');
    // up to date — anchor on both installed versions
    final ctrl = ((_nexusCheck?['packages'] as List?)
                ?.cast<Map<String, dynamic>>() ??
            [])
        .firstWhere((p) => p['name'] == 'nexusq-control',
            orElse: () => {'installed': '?'});
    // On iOS the app binary is App Store/TestFlight-managed and never fetched
    // for comparison here, so qualify it rather than implying a completed check.
    final app = AppUpdate.selfUpdateSupported
        ? 'App v$kAppVersion'
        : 'App v$kAppVersion (App Store)';
    return '$app · device nexusq-control ${ctrl['installed']}';
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
    final info = await _call('getDeviceInfo');
    if (!mounted) return;
    setState(() {
      // A poll must never clobber the field the user is typing into.
      if (info != null && !_renaming) {
        _deviceName = info['name'] as String? ?? _deviceName;
        _deviceRoom = info['room'] as String? ?? _deviceRoom;
      }
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

            // --- this device -------------------------------------------------
            _sectionTitle('This device'),
            Card(
              color: NexusQColors.surface,
              child: ListTile(
                leading: const Icon(Icons.label_outline,
                    color: NexusQColors.dim),
                title: Text(_deviceName.isEmpty ? 'Nexus Q' : _deviceName,
                    style: const TextStyle(color: NexusQColors.white)),
                subtitle: Text(
                  _deviceRoom.isEmpty
                      ? 'Tap to rename. The name is what you see when the app '
                          'finds it on the network, and what Spotify Connect shows.'
                      : 'In $_deviceRoom · tap to rename',
                  style: const TextStyle(color: NexusQColors.dim, fontSize: 12),
                ),
                trailing: _renaming
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.edit_outlined, color: NexusQColors.dim),
                onTap: _renaming ? null : _promptRename,
              ),
            ),

            // --- streaming services ------------------------------------------
            const SizedBox(height: 20),
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

            // --- Sound: the TAS5713 hardware EQ (PROTOCOL §14) ---------------
            const SizedBox(height: 20),
            _sectionTitle('Sound'),

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

            // --- Health: the MQTT telemetry panel ----------------------------
            const SizedBox(height: 20),
            _sectionTitle('Health'),
            Card(
              color: NexusQColors.surface,
              child: ListTile(
                leading: const Icon(Icons.monitor_heart_outlined,
                    color: NexusQColors.dim),
                title: const Text('Device health',
                    style: TextStyle(color: NexusQColors.white)),
                subtitle: const Text(
                  'Live telemetry over your home MQTT broker — temperature, '
                  'CPU, WiFi, services. Works even when the direct link to '
                  'the Q is down.',
                  style: TextStyle(color: NexusQColors.dim, fontSize: 12),
                ),
                trailing:
                    const Icon(Icons.chevron_right, color: NexusQColors.dim),
                onTap: () => Navigator.of(context).push(MaterialPageRoute(
                    builder: (_) => HealthScreen(client: widget.client))),
              ),
            ),

            // --- Update cluster: App / Device / System -----------------------
            const SizedBox(height: 20),
            _sectionTitle('Update'),
            Card(
              color: NexusQColors.surface,
              child: Column(
                children: [
                  ListTile(
                    leading: Icon(
                        _companionBusy
                            ? Icons.downloading
                            : (_companionUpdateAvailable
                                ? Icons.system_update
                                : Icons.check_circle_outline),
                        color: (_companionUpdateAvailable || _companionBusy)
                            ? NexusQColors.accent
                            : NexusQColors.dim),
                    title: Text(
                        _companionBusy
                            ? 'Updating…'
                            : (_companionUpdateAvailable
                                // On iOS the phone-app track is never checked
                                // (App Store-managed), so the card speaks only
                                // for the device software it actually verified.
                                ? (AppUpdate.selfUpdateSupported
                                    ? 'App update available'
                                    : 'Device update available')
                                : (AppUpdate.selfUpdateSupported
                                    ? 'App is up to date'
                                    : 'Device software is up to date')),
                        style: const TextStyle(color: NexusQColors.white)),
                    subtitle: Text(_companionStatusLine(),
                        style: const TextStyle(
                            color: NexusQColors.dim, fontSize: 12)),
                    trailing: (_checkingUpdate ||
                            _checkingNexus ||
                            _companionBusy)
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2))
                        : IconButton(
                            icon: const Icon(Icons.refresh,
                                color: NexusQColors.dim),
                            tooltip: 'Check for updates',
                            onPressed: _checkCompanion),
                  ),
                  if (_updateError != null || _nexusError != null)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                      child: Text(_updateError ?? _nexusError!,
                          style: const TextStyle(
                              color: Colors.orangeAccent, fontSize: 12)),
                    ),
                  // Progress area — device daemons first (activity bar), then the
                  // phone app download (determinate bar), then the Update button.
                  if (_installingNexus)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: const [
                          ClipRRect(
                            borderRadius: BorderRadius.all(Radius.circular(4)),
                            child: LinearProgressIndicator(
                              minHeight: 8,
                              color: NexusQColors.accent,
                              backgroundColor: NexusQColors.divider,
                            ),
                          ),
                          SizedBox(height: 6),
                          Text(
                            'Updating the device — the Q restarts its services '
                            'and the app reconnects. This is normal.',
                            style:
                                TextStyle(color: NexusQColors.dim, fontSize: 11),
                          ),
                        ],
                      ),
                    )
                  else if (_downloading)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          // Explicit colours: the M3 default track sits close to
                          // the blue accent fill, so a partial bar read as one
                          // solid blue strip that "never moved". Dim track vs
                          // bright accent makes progress unmistakable.
                          ClipRRect(
                            borderRadius: BorderRadius.circular(4),
                            child: LinearProgressIndicator(
                              value: _downloadProgress,
                              minHeight: 8,
                              color: NexusQColors.accent,
                              backgroundColor: NexusQColors.divider,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                              _downloadProgress != null
                                  ? 'Downloading app… ${(_downloadProgress! * 100).round()}%'
                                  : 'Downloading app… ${(_downloadBytes / 1048576).toStringAsFixed(1)} MB',
                              style: const TextStyle(
                                  color: NexusQColors.dim, fontSize: 11)),
                        ],
                      ),
                    )
                  else if (_companionUpdateAvailable)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                      child: SizedBox(
                        width: double.infinity,
                        child: FilledButton.icon(
                          onPressed: _installCompanion,
                          icon: const Icon(Icons.download, size: 18),
                          label: const Text('Update'),
                        ),
                      ),
                    ),
                ],
              ),
            ),

            // System (kernel + all packages) — third item in the Update cluster
            const SizedBox(height: 10),
            Card(
              color: NexusQColors.surface,
              child: Column(
                children: [
                  ListTile(
                    leading: Icon(
                        _installingSystem
                            ? Icons.downloading
                            : (_systemUpdateAvailable
                                ? Icons.system_update_alt
                                : Icons.dns),
                        color: (_installingSystem || _systemUpdateAvailable)
                            ? NexusQColors.accent
                            : NexusQColors.dim),
                    title: Text(
                        _installingSystem
                            ? 'Installing system update…'
                            : (_systemUpdateAvailable
                                ? 'System update available'
                                : 'System software'),
                        style: const TextStyle(color: NexusQColors.white)),
                    subtitle: Text(_systemStatusLine(),
                        style: const TextStyle(
                            color: NexusQColors.dim, fontSize: 12)),
                    trailing: (_checkingSystem || _installingSystem)
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2))
                        : IconButton(
                            icon: const Icon(Icons.refresh,
                                color: NexusQColors.dim),
                            tooltip: 'Check for system updates',
                            onPressed: _checkSystemUpdate),
                  ),
                  if (_systemError != null)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                      child: Text(_systemError!,
                          style: const TextStyle(
                              color: Colors.orangeAccent, fontSize: 12)),
                    ),
                  if (_installingSystem)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const ClipRRect(
                            borderRadius: BorderRadius.all(Radius.circular(4)),
                            child: LinearProgressIndicator(
                              minHeight: 8,
                              color: NexusQColors.accent,
                              backgroundColor: NexusQColors.divider,
                            ),
                          ),
                          const SizedBox(height: 8),
                          // Live phase message (installing → applying/restarting
                          // → reconnecting → verifying); apk has no % so we narrate
                          // the stages we know.
                          Text(
                            _systemProgress ??
                                'Upgrading all packages on the device.',
                            style: const TextStyle(
                                color: NexusQColors.white, fontSize: 12),
                          ),
                          const SizedBox(height: 2),
                          const Text(
                            'The Q may restart services or reboot to finish; the '
                            'app reconnects when it is back.',
                            style:
                                TextStyle(color: NexusQColors.dim, fontSize: 11),
                          ),
                        ],
                      ),
                    )
                  else if (_systemUpdateAvailable)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                      child: SizedBox(
                        width: double.infinity,
                        child: FilledButton.icon(
                          onPressed: _installSystemUpdate,
                          icon: const Icon(Icons.download, size: 18),
                          label: const Text('Update system'),
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

  /// Rename the Q. The device keeps serving this very connection through the
  /// rename (nexusq-control re-advertises mDNS in-process rather than
  /// restarting itself), so there is no reconnect to wait out — but the mDNS
  /// name DOES change, which is what a *next* launch will discover it by.
  Future<void> _promptRename() async {
    setState(() => _renaming = true);
    final res = await showDialog<(String, String)>(
      context: context,
      builder: (_) => _RenameDialog(name: _deviceName, room: _deviceRoom),
    );
    if (!mounted) return;
    if (res == null || res.$1.isEmpty) {
      setState(() => _renaming = false);
      return;
    }
    // silent: false — a rename is a user action, so a failure belongs on screen.
    final r = await _call('setName', {'name': res.$1, 'room': res.$2}, false);
    if (!mounted) return;
    setState(() {
      _renaming = false;
      // Trust the device's echo, not what was typed: it is the side that
      // decides (it trims, and it is the one that actually renamed).
      if (r != null) {
        _deviceName = r['name'] as String? ?? res.$1;
        _deviceRoom = r['room'] as String? ?? res.$2;
      }
    });
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

/// The rename dialog, as its own widget so it OWNS its controllers.
///
/// It used to build the TextFields inline and dispose their controllers as soon
/// as showDialog returned — which throws "A TextEditingController was used after
/// being disposed": the dialog is still animating out, and still rebuilding
/// those fields, for a couple of hundred milliseconds after the pop. Owning them
/// here ties their lifetime to the route's, which is the only correct answer.
///
/// Pops `(name, room)` — both trimmed — or null when cancelled.
class _RenameDialog extends StatefulWidget {
  const _RenameDialog({required this.name, required this.room});
  final String name;
  final String room;

  @override
  State<_RenameDialog> createState() => _RenameDialogState();
}

class _RenameDialogState extends State<_RenameDialog> {
  late final TextEditingController _name =
      TextEditingController(text: widget.name);
  late final TextEditingController _room =
      TextEditingController(text: widget.room);

  @override
  void dispose() {
    _name.dispose();
    _room.dispose();
    super.dispose();
  }

  void _submit() =>
      Navigator.of(context).pop((_name.text.trim(), _room.text.trim()));

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: NexusQColors.surface,
      title: const Text('Rename this Nexus Q',
          style: TextStyle(color: NexusQColors.white)),
      // Scrollable: with a software keyboard up (or a short test viewport) two
      // TextFields plus their counters do not fit, and an AlertDialog gives its
      // content a tight height — an unscrollable Column just overflows.
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _name,
              autofocus: true,
              maxLength: 48,
              style: const TextStyle(color: NexusQColors.white),
              decoration: const InputDecoration(
                labelText: 'Name',
                labelStyle: TextStyle(color: NexusQColors.dim),
                counterStyle: TextStyle(color: NexusQColors.dim),
              ),
              onSubmitted: (_) => _submit(),
            ),
            TextField(
              controller: _room,
              maxLength: 48,
              style: const TextStyle(color: NexusQColors.white),
              decoration: const InputDecoration(
                labelText: 'Room (optional)',
                labelStyle: TextStyle(color: NexusQColors.dim),
                counterStyle: TextStyle(color: NexusQColors.dim),
              ),
              onSubmitted: (_) => _submit(),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel')),
        TextButton(onPressed: _submit, child: const Text('Save')),
      ],
    );
  }
}
