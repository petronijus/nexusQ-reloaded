import 'dart:async';
import 'package:flutter/material.dart';
import 'package:simple_icons/simple_icons.dart';
import '../debug/app_log.dart';
import '../protocol/client.dart';
import '../spotify/spotify_auth.dart';
import '../theme/nexusq_theme.dart';
import '../update/app_update.dart';
import '../update/update_coordinator.dart';
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

  // --- the update flows live in UpdateCoordinator (they survive this screen) ---
  late final UpdateCoordinator _upd = UpdateCoordinator.forClient(widget.client);
  void _onUpdate() {
    if (mounted) setState(() {});
  }

  @override
  void initState() {
    super.initState();
    _refresh();
    _poll = Timer.periodic(const Duration(seconds: 3), (_) => _refresh());
    _upd.addListener(_onUpdate);
    // Silent auto-check on open (app track + device track — else the section
    // reads empty until you tap Check). A flow already in flight from a previous
    // visit simply keeps going; its state is what this screen now shows.
    if (!_upd.busy) {
      _upd.checkUpdate();
      _upd.checkNexusUpdate();
    }
  }

  @override
  void dispose() {
    _poll?.cancel();
    _upd.removeListener(_onUpdate);
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

            // --- Spotify: the account that drives Spotify Connect on the Q ---
            // librespot has no local transport API (PROTOCOL §5), so the
            // play/pause/next buttons for Spotify go through Spotify's Web API
            // from THIS phone, which needs a linked account (Premium, as Spotify
            // requires for playback control). Read-only playback state + control
            // scopes, nothing else.
            const SizedBox(height: 20),
            _sectionTitle('Spotify'),
            ListenableBuilder(
              listenable: SpotifyLink.instance,
              builder: (context, _) {
                final link = SpotifyLink.instance;
                final String subtitle;
                if (!link.isConfigured) {
                  subtitle = 'Not configured in this build (no Spotify client ID). '
                      'Spotify playback can still be controlled from the Spotify app.';
                } else if (link.isLinked) {
                  subtitle = 'Connected${link.userDisplayName.isEmpty ? '' : ' as ${link.userDisplayName}'} — '
                      'the Now Playing buttons drive Spotify on this Nexus Q.';
                } else {
                  subtitle = 'Not connected. Needed for the Now Playing buttons while '
                      'Spotify plays; the device itself cannot control Spotify.';
                }
                return Card(
                  color: NexusQColors.surface,
                  child: ListTile(
                    leading: Icon(SimpleIcons.spotify,
                        color: link.isLinked ? NexusQColors.accent : NexusQColors.dim),
                    title: const Text('Spotify account',
                        style: TextStyle(color: NexusQColors.white)),
                    subtitle: Text(subtitle,
                        style: const TextStyle(color: NexusQColors.dim, fontSize: 12)),
                    trailing: !link.isConfigured
                        ? null
                        : TextButton(
                            onPressed: () async {
                              final messenger = ScaffoldMessenger.of(context);
                              try {
                                if (link.isLinked) {
                                  await link.unlink();
                                } else {
                                  await link.beginLogin();
                                }
                              } catch (e) {
                                messenger.showSnackBar(SnackBar(
                                    content: Text('$e'.replaceFirst('SpotifyAuthException: ', ''))));
                              }
                            },
                            child: Text(link.isLinked ? 'Disconnect' : 'Connect'),
                          ),
                  ),
                );
              },
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
                        _upd.companionBusy
                            ? Icons.downloading
                            : (_upd.companionUpdateAvailable
                                ? Icons.system_update
                                : Icons.check_circle_outline),
                        color: (_upd.companionUpdateAvailable || _upd.companionBusy)
                            ? NexusQColors.accent
                            : NexusQColors.dim),
                    title: Text(
                        _upd.companionBusy
                            ? 'Updating…'
                            : (_upd.companionUpdateAvailable
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
                    subtitle: Text(_upd.companionStatusLine(),
                        style: const TextStyle(
                            color: NexusQColors.dim, fontSize: 12)),
                    trailing: (_upd.checkingUpdate ||
                            _upd.checkingNexus ||
                            _upd.companionBusy)
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2))
                        : IconButton(
                            icon: const Icon(Icons.refresh,
                                color: NexusQColors.dim),
                            tooltip: 'Check for updates',
                            onPressed: _upd.checkCompanion),
                  ),
                  if (_upd.updateError != null || _upd.nexusError != null)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                      child: Text(_upd.updateError ?? _upd.nexusError!,
                          style: const TextStyle(
                              color: Colors.orangeAccent, fontSize: 12)),
                    ),
                  // Progress area — device daemons first (activity bar), then the
                  // phone app download (determinate bar), then the Update button.
                  if (_upd.installingNexus)
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
                  else if (_upd.downloading)
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
                              value: _upd.downloadProgress,
                              minHeight: 8,
                              color: NexusQColors.accent,
                              backgroundColor: NexusQColors.divider,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                              _upd.downloadProgress != null
                                  ? 'Downloading app… ${(_upd.downloadProgress! * 100).round()}%'
                                  : 'Downloading app… ${(_upd.downloadBytes / 1048576).toStringAsFixed(1)} MB',
                              style: const TextStyle(
                                  color: NexusQColors.dim, fontSize: 11)),
                        ],
                      ),
                    )
                  else if (_upd.companionUpdateAvailable)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                      child: SizedBox(
                        width: double.infinity,
                        child: FilledButton.icon(
                          onPressed: _upd.installCompanion,
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
                        _upd.installingSystem
                            ? Icons.downloading
                            : (_upd.systemUpdateAvailable
                                ? Icons.system_update_alt
                                : Icons.dns),
                        color: (_upd.installingSystem || _upd.systemUpdateAvailable)
                            ? NexusQColors.accent
                            : NexusQColors.dim),
                    title: Text(
                        _upd.installingSystem
                            ? 'Installing system update…'
                            : (_upd.systemUpdateAvailable
                                ? 'System update available'
                                : 'System software'),
                        style: const TextStyle(color: NexusQColors.white)),
                    subtitle: Text(_upd.systemStatusLine(),
                        style: const TextStyle(
                            color: NexusQColors.dim, fontSize: 12)),
                    trailing: (_upd.checkingSystem || _upd.installingSystem)
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2))
                        : IconButton(
                            icon: const Icon(Icons.refresh,
                                color: NexusQColors.dim),
                            tooltip: 'Check for system updates',
                            onPressed: _upd.checkSystemUpdate),
                  ),
                  if (_upd.systemError != null)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                      child: Text(_upd.systemError!,
                          style: const TextStyle(
                              color: Colors.orangeAccent, fontSize: 12)),
                    ),
                  if (_upd.installingSystem)
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
                            _upd.systemProgress ??
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
                  else if (_upd.systemUpdateAvailable)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                      child: SizedBox(
                        width: double.infinity,
                        child: FilledButton.icon(
                          onPressed: _upd.installSystemUpdate,
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
