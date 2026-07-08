import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// A text received from the Nexus Q over NFC (HCE), with the moment it landed.
@immutable
class HceMessage {
  const HceMessage(this.text, this.receivedAt);

  final String text;
  final DateTime receivedAt;

  @override
  String toString() => 'HceMessage("$text" @ $receivedAt)';
}

/// Dart-side of the native HCE bridge (see `NqHceService` / `HceBridge` /
/// `MainActivity` on Android).
///
/// - [messages] is a broadcast stream that emits each text the moment the
///   card-emulation service forwards it while the app is running.
/// - [takeLast] pulls the last-received text out of native SharedPreferences —
///   used on resume / cold start to catch a tap that happened while no Dart
///   listener was attached. It clears the stored value so the same message is
///   not surfaced twice.
///
/// The whole surface is Android-only and degrades to no-ops elsewhere, so the
/// UI can wire it unconditionally.
class HceChannel {
  HceChannel._();
  static final HceChannel instance = HceChannel._();

  static const _events = EventChannel('nexusq/hce/messages');
  static const _methods = MethodChannel('nexusq/hce');

  Stream<HceMessage>? _stream;

  bool get _supported => !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  /// Live texts as they arrive. Native forwards a plain [String]; we stamp the
  /// arrival time on the Dart side.
  Stream<HceMessage> get messages {
    if (!_supported) return const Stream<HceMessage>.empty();
    return _stream ??= _events
        .receiveBroadcastStream()
        .map((event) => HceMessage(event as String, DateTime.now()))
        .asBroadcastStream();
  }

  /// Returns and clears the last text stored natively, or null if none.
  Future<HceMessage?> takeLast() async {
    if (!_supported) return null;
    try {
      final res = await _methods.invokeMapMethod<String, Object?>('getLastMessage');
      if (res == null) return null;
      final text = res['text'] as String?;
      if (text == null) return null;
      final ts = (res['timestamp'] as num?)?.toInt() ?? 0;
      await _methods.invokeMethod<void>('clearLastMessage');
      return HceMessage(
        text,
        DateTime.fromMillisecondsSinceEpoch(ts == 0 ? DateTime.now().millisecondsSinceEpoch : ts),
      );
    } on PlatformException catch (e) {
      debugPrint('HceChannel.takeLast failed: $e');
      return null;
    }
  }

  /// Whether the phone actually has an NFC adapter (HCE routing needs one).
  Future<bool> isNfcAvailable() async {
    if (!_supported) return false;
    try {
      return await _methods.invokeMethod<bool>('isNfcAvailable') ?? false;
    } on PlatformException {
      return false;
    }
  }
}
