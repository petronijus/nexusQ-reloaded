import 'dart:async';

import 'package:flutter/material.dart';
import 'package:simple_icons/simple_icons.dart';

import '../debug/app_log.dart';
import '../mqtt/health_mqtt.dart';
import '../mqtt/mqtt_settings.dart';
import '../protocol/client.dart';
import '../theme/nexusq_theme.dart';

/// Problem flags the daemon/HA treat as "something is wrong". Top-level (not a
/// State method) so tests can pin it against sparse payloads: the daemon OMITS
/// fields whose source is unavailable, and the state map is entirely empty
/// until the first retained message lands — every read here must tolerate an
/// absent key. (`(x ?? 0) is num && (x as num) …` looked guarded but tested
/// the FALLBACK and cast the ORIGINAL — null cast crashed the first build,
/// v1.12.0's grey screen.)
List<String> healthProblems(Map<String, dynamic> s) {
  final out = <String>[];
  if (s['nexusqd_alive'] == false) out.add('LED daemon (nexusqd) is down');
  if (s['healthd_fresh'] == false) {
    out.add('Health sampler (nq-healthd) is stale');
  }
  final stall = s['led_stall'];
  if (stall is num && stall >= 6) out.add('LED ring frame is stalled');
  final pstore = s['pstore'];
  if (pstore is num && pstore > 0) out.add('Crash dump present (pstore)');
  return out;
}

/// "Health": the live device-health panel fed by the MQTT telemetry the
/// on-device nexusq-mqtt daemon publishes (die temp, CPU, per-OPP residency,
/// WiFi, volume, streaming services, problem flags).
///
/// Deliberately decoupled from the nexusq-control TCP link — it reads the home
/// broker, so it works whenever the phone can reach the broker, even when the
/// direct device link is down (that being down is exactly when you WANT the
/// health panel). Broker credentials are entered by hand via the
/// "Connect to MQTT" dialog and kept in the platform secure store.
class HealthScreen extends StatefulWidget {
  const HealthScreen({super.key, this.client});

  /// The device control link, when the app currently has one. Saving broker
  /// settings ALSO provisions them to the Q over it (`setMqttConfig`,
  /// PROTOCOL §13) — the app is the device's only credential input; there is
  /// nothing baked into the image and no hand-edited file.
  final NexusQClient? client;

  @override
  State<HealthScreen> createState() => _HealthScreenState();
}

class _HealthScreenState extends State<HealthScreen> {
  final HealthMqtt _mqtt = HealthMqtt();
  MqttSettings? _settings;
  bool _loadingSettings = true;
  Timer? _ageTicker;

  @override
  void initState() {
    super.initState();
    _mqtt.addListener(_onMqtt);
    // repaint the "updated Ns ago" line while the screen is open
    _ageTicker = Timer.periodic(
        const Duration(seconds: 5), (_) => setState(() {}));
    _init();
  }

  Future<void> _init() async {
    final s = await MqttSettings.load();
    setState(() {
      _settings = s;
      _loadingSettings = false;
    });
    if (s != null && s.isComplete) {
      await _mqtt.connect(s);
    }
  }

  void _onMqtt() => setState(() {});

  @override
  void dispose() {
    _ageTicker?.cancel();
    _mqtt.removeListener(_onMqtt);
    _mqtt.dispose();
    super.dispose();
  }

  // ------------------------------------------------------------------ UI --

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: NexusQColors.canvas,
      appBar: AppBar(
        backgroundColor: NexusQColors.canvas,
        title: const Text('Health'),
        actions: [
          if (_settings != null)
            IconButton(
              icon: const Icon(Icons.edit, color: NexusQColors.dim),
              tooltip: 'Edit MQTT connection',
              onPressed: _openConnectDialog,
            ),
        ],
      ),
      body: _loadingSettings
          ? const Center(child: CircularProgressIndicator())
          : _settings == null
              ? _connectPrompt()
              : _panel(),
    );
  }

  /// First run: nothing configured yet — one clear call to action.
  Widget _connectPrompt() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.monitor_heart_outlined,
              size: 56, color: NexusQColors.dim),
          const SizedBox(height: 16),
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 40),
            child: Text(
              'The Nexus Q publishes its health to your home MQTT broker. '
              'Connect to it to see live telemetry here and in Home '
              'Assistant.',
              textAlign: TextAlign.center,
              style: TextStyle(color: NexusQColors.dim),
            ),
          ),
          const SizedBox(height: 24),
          FilledButton.icon(
            icon: const Icon(Icons.link),
            label: const Text('Connect to MQTT'),
            onPressed: _openConnectDialog,
          ),
        ],
      ),
    );
  }

  Widget _panel() {
    final s = _mqtt.state;
    return RefreshIndicator(
      onRefresh: () async {
        final st = _settings;
        if (st != null) await _mqtt.connect(st);
      },
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.all(NexusQSpace.standardMargin),
        children: [
          _statusCard(),
          const SizedBox(height: 12),
          if (_problems(s).isNotEmpty) ...[
            _problemsCard(_problems(s)),
            const SizedBox(height: 12),
          ],
          _vitalsCard(s),
          const SizedBox(height: 12),
          _oppCard(s),
          const SizedBox(height: 12),
          _servicesCard(s),
          const SizedBox(height: 12),
          _linkCard(s),
        ],
      ),
    );
  }

  Widget _statusCard() {
    final (icon, color, text) = switch (_mqtt.link) {
      HealthLink.connecting => (
          Icons.sync,
          NexusQColors.ledYellow,
          'Connecting to broker…'
        ),
      HealthLink.error => (
          Icons.error_outline,
          NexusQColors.ledRed,
          _mqtt.errorText ?? 'Connection failed'
        ),
      HealthLink.connected when _mqtt.deviceOnline == false => (
          Icons.cloud_off,
          NexusQColors.ledOrange,
          'Broker OK — device is offline'
        ),
      HealthLink.connected => (
          Icons.check_circle_outline,
          NexusQColors.ledGreen,
          'Live'
        ),
      _ => (Icons.link_off, NexusQColors.dim, 'Not connected'),
    };
    final age = _lastUpdateAge();
    return Card(
      color: NexusQColors.surface,
      child: ListTile(
        leading: Icon(icon, color: color),
        title: Text(text, style: const TextStyle(color: NexusQColors.white)),
        subtitle: Text(
          [
            '${_settings!.host}:${_settings!.port}',
            if (age != null) 'updated $age ago',
          ].join('  ·  '),
          style: const TextStyle(color: NexusQColors.dim, fontSize: 12),
        ),
        trailing: _mqtt.link == HealthLink.error
            ? IconButton(
                icon: const Icon(Icons.refresh, color: NexusQColors.dim),
                onPressed: () {
                  final st = _settings;
                  if (st != null) _mqtt.connect(st);
                })
            : null,
      ),
    );
  }

  List<String> _problems(Map<String, dynamic> s) => healthProblems(s);

  Widget _problemsCard(List<String> problems) {
    return Card(
      color: NexusQColors.surface,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final p in problems)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Row(children: [
                  const Icon(Icons.warning_amber_rounded,
                      color: NexusQColors.ledOrange, size: 18),
                  const SizedBox(width: 8),
                  Expanded(
                      child: Text(p,
                          style: const TextStyle(
                              color: NexusQColors.white, fontSize: 13))),
                ]),
              ),
          ],
        ),
      ),
    );
  }

  Widget _vitalsCard(Map<String, dynamic> s) {
    final temp = (s['temp_c'] as num?)?.toDouble();
    final tempColor = temp == null
        ? NexusQColors.dim
        : temp >= 95
            ? NexusQColors.ledRed
            : temp >= 80
                ? NexusQColors.ledOrange
                : NexusQColors.ledGreen;
    return Card(
      color: NexusQColors.surface,
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(children: [
          Row(children: [
            Expanded(
                child: _bigStat('Die temp',
                    temp != null ? '${temp.toStringAsFixed(1)} °C' : '—',
                    color: tempColor)),
            Expanded(
                child: _bigStat(
                    'CPU',
                    s['freq_mhz'] != null ? '${s['freq_mhz']} MHz' : '—',
                    sub: s['governor'] as String?)),
          ]),
          const SizedBox(height: 10),
          Row(children: [
            Expanded(child: _smallStat('Load', '${s['load1'] ?? '—'}')),
            Expanded(
                child: _smallStat(
                    'Mem free',
                    s['mem_avail_mb'] != null
                        ? '${s['mem_avail_mb']} MB'
                        : '—')),
            Expanded(
                child: _smallStat(
                    'Volume',
                    s['volume_pct'] != null
                        ? '${s['volume_pct']}%'
                            '${s['muted'] == true ? ' 🔇' : ''}'
                        : '—')),
            Expanded(
                child: _smallStat('Up', _fmtUptime(s['uptime_s'] as num?))),
          ]),
        ]),
      ),
    );
  }

  /// Per-OPP residency bars — "podíl frekvencí" over the publish window.
  Widget _oppCard(Map<String, dynamic> s) {
    const opps = [350, 700, 920, 1200];
    final values = [
      for (final mhz in opps) (s['opp${mhz}_pct'] as num?)?.toDouble()
    ];
    if (values.every((v) => v == null)) return const SizedBox.shrink();
    return Card(
      color: NexusQColors.surface,
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('CPU frequency share',
                style: TextStyle(color: NexusQColors.dim, fontSize: 12)),
            const SizedBox(height: 8),
            for (var i = 0; i < opps.length; i++)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 3),
                child: Row(children: [
                  SizedBox(
                      width: 70,
                      child: Text('${opps[i]} MHz',
                          style: const TextStyle(
                              color: NexusQColors.white, fontSize: 12))),
                  Expanded(
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(3),
                      child: LinearProgressIndicator(
                        value: (values[i] ?? 0) / 100.0,
                        minHeight: 6,
                        backgroundColor: NexusQColors.canvas,
                        color: NexusQColors.accent,
                      ),
                    ),
                  ),
                  SizedBox(
                      width: 52,
                      child: Text(
                          values[i] != null
                              ? '${values[i]!.toStringAsFixed(1)}%'
                              : '—',
                          textAlign: TextAlign.right,
                          style: const TextStyle(
                              color: NexusQColors.dim, fontSize: 12))),
                ]),
              ),
          ],
        ),
      ),
    );
  }

  Widget _servicesCard(Map<String, dynamic> s) {
    final services = s['services'];
    if (services is! Map) return const SizedBox.shrink();
    const meta = [
      ('spotify', 'Spotify', SimpleIcons.spotify),
      ('airplay', 'AirPlay', Icons.airplay),
      ('roon', 'Roon', SimpleIcons.roon),
      ('usbaudio', 'USB Audio', Icons.usb),
    ];
    return Card(
      color: NexusQColors.surface,
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Streaming services',
                style: TextStyle(color: NexusQColors.dim, fontSize: 12)),
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final (id, label, icon) in meta)
                  Chip(
                    avatar: Icon(icon,
                        size: 16,
                        color: services[id] == true
                            ? NexusQColors.accent
                            : NexusQColors.dim),
                    label: Text(label,
                        style: TextStyle(
                            fontSize: 12,
                            color: services[id] == true
                                ? NexusQColors.white
                                : NexusQColors.dim)),
                    backgroundColor: NexusQColors.canvas,
                    side: BorderSide(
                        color: services[id] == true
                            ? NexusQColors.accent
                            : NexusQColors.divider),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _linkCard(Map<String, dynamic> s) {
    final rssi = s['wifi_rssi_dbm'] as num?;
    return Card(
      color: NexusQColors.surface,
      child: ListTile(
        leading: Icon(Icons.wifi,
            color: rssi == null
                ? NexusQColors.dim
                : rssi >= -60
                    ? NexusQColors.ledGreen
                    : rssi >= -75
                        ? NexusQColors.ledYellow
                        : NexusQColors.ledOrange),
        title: Text(rssi != null ? '$rssi dBm' : 'WiFi —',
            style: const TextStyle(color: NexusQColors.white)),
        subtitle: Text(s['wifi_ssid'] as String? ?? '',
            style: const TextStyle(color: NexusQColors.dim, fontSize: 12)),
      ),
    );
  }

  Widget _bigStat(String label, String value, {Color? color, String? sub}) {
    return Column(children: [
      Text(label,
          style: const TextStyle(color: NexusQColors.dim, fontSize: 12)),
      const SizedBox(height: 2),
      Text(value,
          style: TextStyle(
              color: color ?? NexusQColors.white,
              fontSize: 24,
              fontWeight: FontWeight.w300)),
      if (sub != null)
        Text(sub,
            style: const TextStyle(color: NexusQColors.dim, fontSize: 11)),
    ]);
  }

  Widget _smallStat(String label, String value) {
    return Column(children: [
      Text(label,
          style: const TextStyle(color: NexusQColors.dim, fontSize: 11)),
      const SizedBox(height: 2),
      Text(value,
          style: const TextStyle(color: NexusQColors.white, fontSize: 14)),
    ]);
  }

  String? _lastUpdateAge() {
    final t = _mqtt.lastUpdate;
    if (t == null) return null;
    final d = DateTime.now().difference(t);
    if (d.inSeconds < 60) return '${d.inSeconds}s';
    if (d.inMinutes < 60) return '${d.inMinutes}m';
    return '${d.inHours}h';
  }

  String _fmtUptime(num? seconds) {
    if (seconds == null) return '—';
    final s = seconds.toInt();
    final days = s ~/ 86400;
    final hours = (s % 86400) ~/ 3600;
    final mins = (s % 3600) ~/ 60;
    if (days > 0) return '${days}d ${hours}h';
    if (hours > 0) return '${hours}h ${mins}m';
    return '${mins}m';
  }

  // ------------------------------------------------- connect/edit dialog --

  Future<void> _openConnectDialog() async {
    final s = _settings;
    final host = TextEditingController(text: s?.host ?? '');
    final port = TextEditingController(text: '${s?.port ?? 1883}');
    final user = TextEditingController(text: s?.username ?? '');
    final pass = TextEditingController(text: s?.password ?? '');
    final prefix = TextEditingController(text: s?.prefix ?? 'nexusq');

    final saved = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: NexusQColors.surface,
        title: const Text('Connect to MQTT',
            style: TextStyle(color: NexusQColors.white)),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _field(host, 'Broker host', hint: 'e.g. 192.168.20.102'),
              _field(port, 'Port', keyboard: TextInputType.number),
              _field(user, 'Username'),
              _field(pass, 'Password', obscure: true),
              _field(prefix, 'Topic prefix'),
            ],
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Save & connect')),
        ],
      ),
    );
    if (saved != true) return;

    final settings = MqttSettings(
      host: host.text.trim(),
      port: int.tryParse(port.text.trim()) ?? 1883,
      username: user.text.trim(),
      password: pass.text,
      prefix: prefix.text.trim().isEmpty ? 'nexusq' : prefix.text.trim(),
    );
    if (!settings.isComplete) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('Host, username and password are required')));
      }
      return;
    }
    await settings.save();
    setState(() => _settings = settings);
    // Provision the DEVICE first (it is the reason this dialog exists), then
    // connect the phone's own subscriber. Device unreachable is not fatal —
    // the phone-side subscription still works and the user is told.
    await _provisionDevice(settings);
    await _mqtt.connect(settings);
  }

  /// Hand the saved broker credentials to the Q (`setMqttConfig`, §13).
  Future<void> _provisionDevice(MqttSettings s) async {
    final client = widget.client;
    if (client == null) return;
    String msg;
    try {
      final st = await client.call('setMqttConfig', {
        'host': s.host,
        'port': s.port,
        'username': s.username,
        'password': s.password,
        'prefix': s.prefix,
      });
      msg = st['active'] == 'active'
          ? 'Nexus Q provisioned — telemetry running'
          : 'Nexus Q provisioned (service: ${st['active']})';
      AppLog.add('mqtt', 'device provisioned, service ${st['active']}');
    } catch (e) {
      // An old device build (control < r28) answers bad_request/unknown — say
      // so instead of a generic failure.
      final old = e.toString().contains('bad_request') ||
          e.toString().contains('unknown');
      msg = old
          ? 'Saved on phone. The Q needs a software update before the app '
              'can provision it (Settings → Update).'
          : 'Saved on phone, but provisioning the Q failed: '
              '${e.toString().replaceFirst('Exception: ', '')}';
      AppLog.add('mqtt', 'device provisioning failed: $e', warn: true);
    }
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
    }
  }

  Widget _field(TextEditingController c, String label,
      {String? hint, bool obscure = false, TextInputType? keyboard}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: TextField(
        controller: c,
        obscureText: obscure,
        keyboardType: keyboard,
        style: const TextStyle(color: NexusQColors.white),
        decoration: InputDecoration(
          labelText: label,
          hintText: hint,
          labelStyle: const TextStyle(color: NexusQColors.dim),
          hintStyle: const TextStyle(color: NexusQColors.dim),
        ),
      ),
    );
  }
}
