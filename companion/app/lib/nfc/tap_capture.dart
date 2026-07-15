import 'package:flutter/services.dart';

/// Tells the platform when a Nexus Q tap is actually expected.
///
/// Claiming NFC priority is what lets the Q's reader through at all — the phone
/// otherwise sits in observe mode and never answers (see MainActivity for the
/// measurement). But it also means this app is influencing the phone's NFC while
/// the claim is held, and this phone pays for groceries. So the claim is scoped:
/// on while we are waiting to be tapped (not yet connected to a Q), off the
/// moment we are connected — and the platform side additionally releases it on
/// every onPause and keeps the HCE service component disabled outside that.
///
/// Fail-quiet by design: NFC bookkeeping must never break the UI, and this is a
/// no-op on platforms without the channel (iOS/desktop/tests).
class TapCapture {
  static const _channel = MethodChannel('nexusq/hce');

  static bool _last = false;

  static Future<void> set(bool expected) async {
    if (_last == expected) return;
    _last = expected;
    try {
      await _channel.invokeMethod('setTapCapture', expected);
    } on MissingPluginException {
      // Not Android — nothing to claim.
    } catch (_) {
      // Never let NFC bookkeeping surface as a UI error.
    }
  }
}
