import 'dart:collection';
import 'package:flutter/foundation.dart';

/// One diagnostic log line. [warn] marks the interesting ones (drops, timeouts,
/// failures) so the UI can colour them without parsing the text.
class AppLogEntry {
  AppLogEntry(this.tag, this.message, {this.warn = false}) : time = DateTime.now();
  final DateTime time;
  final String tag;
  final String message;
  final bool warn;

  String format() {
    final t = time.toIso8601String();
    // HH:MM:SS.mmm — the date is noise inside a session log.
    return '${t.substring(11, 23)} [$tag] $message';
  }
}

/// In-memory diagnostic log for the app's connection machinery.
///
/// Built to answer "why does the app say *disconnected* when the device, the
/// bridge and the WiFi link all measure healthy" (2026-07-16): the device side
/// showed ONE stable TCP connection and zero bridge restarts, so whatever
/// flips the banner is only visible from the phone. This is the phone's side
/// of the story.
///
/// Design decisions, deliberate:
///  * **Collection is ALWAYS on** — a 600-entry ring of short strings costs
///    nothing. The [enabled] toggle only reveals the viewer UI. That way the
///    history *leading up to* a flicker already exists when the user turns
///    debug mode on; a collect-only-when-enabled log would always miss the
///    event it was built for.
///  * **Never log request params.** `setWifi` carries the WiFi PSK; method
///    names only. (Standing rule: credentials never reach any log.)
///  * Each entry is mirrored to [debugPrint], so the same trace is readable
///    over `adb logcat` while the phone is in someone's hand.
class AppLog {
  AppLog._();

  static const _cap = 600;
  static final ListQueue<AppLogEntry> _entries = ListQueue();

  /// Bumped on every mutation; the viewer rebuilds off this.
  static final revision = ValueNotifier<int>(0);

  /// Debug mode: reveals the log viewer in the UI. Session-only on purpose —
  /// the log itself is session-only too, so persisting the switch would
  /// suggest history that does not exist. DEFAULT ON during active
  /// development/bring-up (the log's whole value is being there before a symptom
  /// shows); flip to false to hide the debug surface once things are stable.
  static final enabled = ValueNotifier<bool>(true);

  static void add(String tag, String message, {bool warn = false}) {
    final e = AppLogEntry(tag, message, warn: warn);
    _entries.addLast(e);
    while (_entries.length > _cap) {
      _entries.removeFirst();
    }
    revision.value++;
    debugPrint('[AppLog] ${e.format()}');
  }

  /// Newest-last snapshot for the viewer.
  static List<AppLogEntry> snapshot() => List.unmodifiable(_entries);

  static void clear() {
    _entries.clear();
    revision.value++;
  }

  static String dump() => _entries.map((e) => e.format()).join('\n');
}
