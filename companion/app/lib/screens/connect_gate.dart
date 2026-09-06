import 'dart:async';

import 'package:flutter/material.dart';
import '../nfc/tap_capture.dart';
import '../protocol/client.dart';
import '../protocol/discovery.dart';
import '../protocol/glance.dart';
import '../protocol/mock_client.dart';
import '../protocol/tcp_client.dart';
import '../setup/bt_setup_client.dart';
import '../setup/setup_flow.dart';
import '../state/device_controller.dart';
import '../build_info.dart';
import '../theme/nexusq_theme.dart';
import '../widgets/device_sphere.dart';
import '../widgets/glowing_ring.dart';
import 'home_screen.dart';

enum _Phase { discovering, choose, ready, needInput }

/// Bootstraps the connection: an explicit [initialClient] (forced host / mock)
/// goes straight through; otherwise it browses mDNS for EVERY Nexus Q on the
/// LAN, lists them as they appear, and — once the browse is over — connects to
/// the only one, or lets the user pick when there are several (Petr,
/// 2026-09-06: "když máš víc nexusů, tak chci na úvodní obrazovku je pod sebou,
/// kde si vybíráš jeden a ten konfiguruješ"). Nothing found → manual host entry
/// / demo-mock fallback. Renders [HomeScreen] once a controller is live.
class ConnectGate extends StatefulWidget {
  const ConnectGate({
    super.key,
    this.initialClient,
    this.discover,
    this.discoverAll,
    this.clientFactory,
    this.glance,
    this.pickerOnly = false,
  });

  final NexusQClient? initialClient;

  /// Legacy single-shot injection seam (kept for the "nothing found" widget
  /// test): when given, it replaces the browse entirely and its null result is
  /// the fallback. Prefer [discoverAll].
  final Future<Discovered?> Function()? discover;

  /// Injection seam for the multi-device browse, defaulting to the real one.
  /// Widget tests of the picker cannot rely on the ambient network — see the
  /// note on [discover] — so they hand in a stream of fake devices here.
  final Stream<Discovered> Function()? discoverAll;

  /// How a picked device becomes a client. Defaults to a [TcpClient]; tests
  /// inject a fake so choosing a device does not dial a socket.
  final NexusQClient Function(Discovered)? clientFactory;

  /// How the gate learns a found device's colour theme for its sphere in the
  /// list — one `getState` over a throw-away connection ([glanceAt]) by
  /// default. Tests inject canned answers; a real glance would dial a socket
  /// and, under the test clock, leave its timeout pending.
  final Future<DeviceGlance?> Function(Discovered)? glance;

  /// Always show the list, even for a single device — the "Switch Nexus Q"
  /// action from the home screen, where auto-connecting would be a loop.
  final bool pickerOnly;

  @override
  State<ConnectGate> createState() => _ConnectGateState();
}

class _ConnectGateState extends State<ConnectGate> {
  _Phase _phase = _Phase.discovering;
  DeviceController? _controller;
  final _hostCtrl = TextEditingController();

  /// What the browse has found so far, in the order it arrived.
  final List<Discovered> _found = [];
  StreamSubscription<Discovered>? _browse;

  /// Each found device's answer to the glance, by [Discovered.key]: absent =
  /// still asking, `null` = did not answer (drawn dark), else its theme.
  final Map<String, DeviceGlance?> _glances = {};

  /// Which discovery round a glance belongs to, so an answer from a device
  /// found before "Search again" cannot light a row of the new list.
  int _round = 0;

  @override
  void initState() {
    super.initState();
    if (widget.initialClient != null) {
      _use(widget.initialClient!);
    } else {
      // This screen IS the "waiting to be tapped" state: no Q yet, so a tap on
      // the dome is exactly what we expect. Claiming NFC priority here (and
      // nowhere else) is what lets the Q's reader through — see TapCapture.
      TapCapture.set(true);
      _discover();
    }
  }

  @override
  void dispose() {
    // Never leave the claim behind us.
    TapCapture.set(false);
    _browse?.cancel();
    _hostCtrl.dispose();
    _controller?.dispose();
    super.dispose();
  }

  void _use(NexusQClient client) {
    // Connected: no tap expected any more. Hand NFC back before we even build
    // the home screen — the app has no business holding it while playing music.
    TapCapture.set(false);
    _browse?.cancel();
    final c = DeviceController(client)..start();
    setState(() {
      _controller = c;
      _phase = _Phase.ready;
    });
  }

  void _pick(Discovered d) =>
      _use((widget.clientFactory ?? (d) => TcpClient(host: d.host, port: d.port))(d));

  Future<void> _discover() async {
    // Back to waiting for a Q — a tap is expected again.
    TapCapture.set(true);
    _browse?.cancel();
    final round = ++_round;
    setState(() {
      _phase = _Phase.discovering;
      _found.clear();
      _glances.clear();
    });

    // Legacy seam: a single-shot browse decides everything.
    if (widget.discover != null) {
      final found = await widget.discover!();
      if (!mounted) return;
      if (found != null) {
        _pick(found);
      } else {
        setState(() => _phase = _Phase.needInput);
      }
      return;
    }

    final seen = <String>{};
    _browse = (widget.discoverAll ?? discoverNexusQAll)().listen(
      (d) {
        if (!mounted || !seen.add(d.key)) return;
        setState(() => _found.add(d));
        _glanceAt(d, round);
      },
      onDone: () {
        if (!mounted || _phase != _Phase.discovering) return;
        if (_found.isEmpty) {
          setState(() => _phase = _Phase.needInput);
        } else if (_found.length == 1 && !widget.pickerOnly) {
          _pick(_found.single); // the only Q: no question to ask
        } else {
          setState(() => _phase = _Phase.choose);
        }
      },
      onError: (_) {
        if (!mounted || _phase != _Phase.discovering) return;
        setState(() => _phase = _found.isEmpty ? _Phase.needInput : _Phase.choose);
      },
    );
  }

  /// Ask [d] for its theme and light its sphere when the answer lands. The
  /// picker never waits for this: a row appears the moment mDNS resolves it,
  /// dark, and colours in when the box replies.
  Future<void> _glanceAt(Discovered d, int round) async {
    final g = await (widget.glance ?? glanceAt)(d);
    if (!mounted || round != _round) return;
    setState(() => _glances[d.key] = g);
  }

  void _connectManual() {
    final raw = _hostCtrl.text.trim();
    if (raw.isEmpty) return;
    final parts = raw.split(':');
    final host = parts.first;
    final port = parts.length > 1 ? int.tryParse(parts[1]) ?? 45015 : 45015;
    _use(TcpClient(host: host, port: port));
  }

  String get _headline {
    switch (_phase) {
      case _Phase.discovering:
        return _found.isEmpty ? 'Searching for Nexus Q…' : 'Searching for more…';
      case _Phase.choose:
        return _found.length == 1 ? 'Your Nexus Q' : 'Choose your Nexus Q';
      case _Phase.needInput:
        return 'No Nexus Q found';
      case _Phase.ready:
        return '';
    }
  }

  @override
  Widget build(BuildContext context) {
    final ctrl = _controller;
    if (_phase == _Phase.ready && ctrl != null) {
      return HomeScreen(controller: ctrl);
    }
    final searching = _phase == _Phase.discovering;
    return Scaffold(
      body: SafeArea(
        child: Stack(
          children: [
            // Build stamp, bottom-centre: confirms which build is installed
            // (the app's versionName is a static 1.0.0).
            Align(
              alignment: Alignment.bottomCenter,
              child: Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: const Text(kBuildLabel,
                    style: TextStyle(color: NexusQColors.dim, fontSize: 10)),
              ),
            ),
            // Positioned.fill: a NON-positioned Stack child is given LOOSE
            // constraints and parked at the Stack's alignment (default
            // topStart) — so this Column shrink-wrapped to its intrinsic width
            // and sat against the LEFT edge instead of centring. Filling the
            // Stack gives it the full width back, so the ring centres again.
            Positioned.fill(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(NexusQSpace.standardMargin * 2),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    const SizedBox(height: 24),
                    // While searching (and when nothing was found) the ring is
                    // the picture. Once there is a list, the devices' own
                    // spheres are — a generic icon above them would only
                    // compete with them.
                    if (_phase != _Phase.choose) ...[
                      SizedBox(
                        height: 160,
                        width: 160,
                        child: GlowingRing(
                          volume: searching ? 0.6 : 0.15,
                          child: Icon(
                            searching ? Icons.wifi_find : Icons.wifi_off,
                            color: NexusQColors.accent,
                          ),
                        ),
                      ),
                      const SizedBox(height: 32),
                    ],
                    Text(
                      _headline,
                      style: const TextStyle(
                          color: NexusQColors.white, fontSize: 18, fontWeight: FontWeight.w300),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      _phase == _Phase.choose
                          ? 'Tap the one you want to control.'
                          : 'Make sure the device is on the same network.',
                      textAlign: TextAlign.center,
                      style: const TextStyle(color: NexusQColors.dim, fontSize: 13),
                    ),
                    const SizedBox(height: 28),
                    // The devices found so far, under each other. Shown while
                    // still searching too, so a slow second Q does not hide a
                    // fast first one — but the auto-connect waits for the
                    // browse to end, so a tap is the only early exit.
                    if (_found.isNotEmpty) ..._deviceList(),
                    if (_phase == _Phase.choose) ...[
                      const SizedBox(height: 12),
                      TextButton(onPressed: _discover, child: const Text('Search again')),
                    ],
                    if (_phase == _Phase.needInput) ..._fallback(),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// The devices under each other, each drawn as the home screen draws it:
  /// the sphere lit in that box's own theme, its name in the theme's colour,
  /// the address underneath. Dark until the box answers the glance; a box
  /// that never answers stays dark and says so.
  List<Widget> _deviceList() => [
        for (final d in _found)
          _DeviceRow(
            key: ValueKey('device-${d.key}'),
            device: d,
            glance: _glances[d.key],
            answered: _glances.containsKey(d.key),
            onTap: () => _pick(d),
          ),
      ];

  List<Widget> _fallback() => [
        TextField(
          controller: _hostCtrl,
          style: const TextStyle(color: NexusQColors.white),
          keyboardType: TextInputType.url,
          decoration: const InputDecoration(
            labelText: 'Device address (host or host:port)',
            labelStyle: TextStyle(color: NexusQColors.dim),
            enabledBorder: UnderlineInputBorder(
                borderSide: BorderSide(color: NexusQColors.divider)),
            focusedBorder: UnderlineInputBorder(
                borderSide: BorderSide(color: NexusQColors.accent)),
          ),
          onSubmitted: (_) => _connectManual(),
        ),
        const SizedBox(height: 20),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: [
            TextButton(onPressed: _discover, child: const Text('Search again')),
            TextButton(onPressed: () => _use(MockClient()), child: const Text('Demo')),
            FilledButton(onPressed: _connectManual, child: const Text('Connect')),
          ],
        ),
        const SizedBox(height: 12),
        // The wizard's transport is BT Classic RFCOMM — Android-only (see
        // BtSetupClient.supported). Elsewhere, say so instead of offering a
        // button that dies on the first platform-channel call.
        if (BtSetupClient.supported)
          TextButton(
            onPressed: () => Navigator.of(context)
                .push(MaterialPageRoute(builder: (_) => const SetupFlow())),
            child: const Text('Set up new device'),
          )
        else
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 8),
            child: Text(
              'Setting up a brand-new Nexus Q uses Bluetooth, which only the '
              'Android app can do. Once the device is on WiFi it works here too.',
              textAlign: TextAlign.center,
              style: TextStyle(color: NexusQColors.dim, fontSize: 12),
            ),
          ),
      ];
}

class _DeviceRow extends StatelessWidget {
  const _DeviceRow({
    super.key,
    required this.device,
    required this.glance,
    required this.answered,
    required this.onTap,
  });

  final Discovered device;
  final DeviceGlance? glance;
  final bool answered;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final g = glance;
    final theme = g?.ledTheme;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(16),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            DeviceSphere(
              on: g?.on ?? false,
              colors: theme?.colors ?? const [],
              size: 132,
            ),
            const SizedBox(height: 10),
            Text(device.name,
                style: TextStyle(
                    color: theme == null ? NexusQColors.white : nameColorFor(theme),
                    fontSize: 18,
                    fontWeight: FontWeight.w300)),
            const SizedBox(height: 2),
            Text(
              answered && g == null ? '${device.host}:${device.port} · not answering' : '${device.host}:${device.port}',
              style: const TextStyle(color: NexusQColors.dim, fontSize: 12),
            ),
          ],
        ),
      ),
    );
  }
}
