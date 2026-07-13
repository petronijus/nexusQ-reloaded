import 'dart:async';

import 'package:flutter/material.dart';

import '../theme/nexusq_theme.dart';
import 'device_tap.dart';
import 'hce_channel.dart';

/// Wraps the app and surfaces every NFC-received text as a Holo-dark SnackBar.
///
/// It listens two ways so no tap is lost:
///   - the live [HceChannel.messages] stream, while the app is foregrounded;
///   - [HceChannel.takeLast] on resume / first build, to catch a tap that
///     landed while the app was backgrounded or not yet listening.
///
/// SnackBars are shown through the app-level [scaffoldMessengerKey] so they work
/// from any screen, independent of the current Scaffold.
class HceListener extends StatefulWidget {
  const HceListener({
    super.key,
    required this.messengerKey,
    required this.child,
    this.onDeviceTap,
  });

  final GlobalKey<ScaffoldMessengerState> messengerKey;
  final Widget child;

  /// Called with the parsed device connection info when the tapped payload is
  /// a Task-7 JSON connection-info payload (PROTOCOL.md §7). When set, this
  /// replaces the plain-text SnackBar for JSON taps; non-JSON payloads keep
  /// showing the SnackBar regardless.
  final void Function(DeviceTap tap)? onDeviceTap;

  @override
  State<HceListener> createState() => _HceListenerState();
}

class _HceListenerState extends State<HceListener> with WidgetsBindingObserver {
  StreamSubscription<HceMessage>? _sub;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _sub = HceChannel.instance.messages.listen(_show);
    // Catch a message delivered before we were listening (cold start).
    WidgetsBinding.instance.addPostFrameCallback((_) => _drainLast());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _sub?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _drainLast();
  }

  Future<void> _drainLast() async {
    final msg = await HceChannel.instance.takeLast();
    debugPrint('[HCE] drainLast -> ${msg ?? "nothing stored"}');
    if (msg != null) _show(msg);
  }

  void _show(HceMessage msg) {
    debugPrint('[HCE] show "${msg.text}" (messenger=${widget.messengerKey.currentState != null})');
    final tap = DeviceTap.tryParse(msg.text);
    if (tap != null && widget.onDeviceTap != null) {
      widget.onDeviceTap!(tap);
      return;
    }
    final messenger = widget.messengerKey.currentState;
    if (messenger == null) return;
    messenger
      ..clearSnackBars()
      ..showSnackBar(
        SnackBar(
          backgroundColor: NexusQColors.surface,
          behavior: SnackBarBehavior.floating,
          duration: const Duration(seconds: 5),
          content: Row(
            children: [
              const Icon(Icons.nfc, color: NexusQColors.accent, size: 20),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'From Nexus Q',
                      style: TextStyle(
                        color: NexusQColors.accent,
                        fontSize: 11,
                        fontWeight: FontWeight.w500,
                        letterSpacing: 1.0,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      msg.text,
                      style: const TextStyle(color: NexusQColors.white, fontSize: 15),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      );
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
