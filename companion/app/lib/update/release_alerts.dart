// Release alerts (PROTOCOL §12c): which Nexus Qs this phone knows, and what
// it has already told its owner about each.
//
// The Q checks for a release itself; the app only has to ask it. For that it
// has to reach the Q from the background, when no discovery screen ran, so it
// remembers every Q it talked to: its last address and its <hostname>.local
// (the address moves with a DHCP lease; the name does not). Nothing here is
// secret, so it lives in plain preferences, behind [KeyValueStore] so the
// logic is tested without a platform.
//
// Two memories per Q, both keyed by its id (getDeviceInfo `id`):
//  * notified: the release a notification was posted for, so each release
//    rings once, not every six hours;
//  * pending:  the release last seen waiting on it. When that same version
//    later shows as installed, the owner updated, and "what's new" is shown
//    once. A Q first met already on a release says nothing: nobody here
//    updated it.
import 'dart:convert';

import 'release.dart';

/// The little persistence release alerts need. [SharedPrefsStore] is the real
/// one; tests use [MemoryStore].
abstract class KeyValueStore {
  Future<String?> getString(String key);
  Future<void> setString(String key, String value);
  Future<void> remove(String key);
}

class MemoryStore implements KeyValueStore {
  final Map<String, String> values = {};
  @override
  Future<String?> getString(String key) async => values[key];
  @override
  Future<void> setString(String key, String value) async => values[key] = value;
  @override
  Future<void> remove(String key) async => values.remove(key);
}

/// A Nexus Q this phone has talked to.
class KnownDevice {
  const KnownDevice({
    required this.id,
    required this.name,
    required this.host,
    required this.port,
    this.hostname,
  });

  /// Its stable identity (DeviceState.deviceId).
  final String id;
  final String name;

  /// The address the app last reached it at.
  final String host;
  final int port;

  /// Its `<hostname>.local` name, from bridge r64 on (`getDeviceInfo`).
  final String? hostname;

  /// Where to try it, most recent first.
  List<String> get addresses => [
    host,
    if (hostname != null && hostname!.isNotEmpty && '$hostname.local' != host)
      '$hostname.local',
  ];

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'host': host,
    'port': port,
    if (hostname != null) 'hostname': hostname,
  };

  static KnownDevice? fromJson(Object? j) {
    if (j is! Map) return null;
    final id = j['id'], host = j['host'], port = j['port'];
    if (id is! String || id.isEmpty || host is! String || port is! int) {
      return null;
    }
    return KnownDevice(
      id: id,
      name: j['name'] is String ? j['name'] as String : 'Nexus Q',
      host: host,
      port: port,
      hostname: j['hostname'] is String ? j['hostname'] as String : null,
    );
  }
}

/// One notification to post.
class ReleaseAlert {
  const ReleaseAlert(this.device, this.release);
  final KnownDevice device;
  final Release release;
}

class ReleaseAlerts {
  ReleaseAlerts(this.store);

  final KeyValueStore store;

  static const _devicesKey = 'release.devices';
  static const _enabledKey = 'release.alerts.enabled';
  static String _notifiedKey(String id) => 'release.notified.$id';
  static String _pendingKey(String id) => 'release.pending.$id';
  static String _shownKey(String id) => 'release.shown.$id';

  /// At most this many Qs are remembered; the oldest go first.
  static const maxDevices = 8;

  Future<List<KnownDevice>> devices() async {
    final raw = await store.getString(_devicesKey);
    if (raw == null) return [];
    try {
      final list = jsonDecode(raw);
      return [
        for (final d in (list is List ? list : const []))
          ?KnownDevice.fromJson(d),
      ];
    } on FormatException {
      return [];
    }
  }

  /// Remember [d] (or refresh it: a new address, a new name), newest first.
  Future<void> remember(KnownDevice d) async {
    final list = [
      d,
      for (final o in await devices())
        if (o.id != d.id) o,
    ].take(maxDevices).toList();
    await store.setString(
      _devicesKey,
      jsonEncode([for (final k in list) k.toJson()]),
    );
  }

  Future<bool> enabled() async => (await store.getString(_enabledKey)) != 'off';

  static const _askedKey = 'release.permission.asked';

  /// True the first time only: the notification permission is asked once,
  /// when the first Q is reached, never at every connect.
  Future<bool> firstPermissionAsk() async {
    if (await store.getString(_askedKey) != null) return false;
    await store.setString(_askedKey, 'yes');
    return true;
  }

  Future<void> setEnabled(bool on) =>
      store.setString(_enabledKey, on ? 'on' : 'off');

  /// Record what a Q said; returns the alert to post, if this is news.
  /// Called from the background check and from the app while connected, so
  /// whichever sees a release first rings, and only once.
  Future<ReleaseAlert?> observe(KnownDevice d, UpdateStatus s) async {
    final available = s.available;
    if (available == null) return null;
    await store.setString(_pendingKey(d.id), available.version);
    if (await store.getString(_notifiedKey(d.id)) == available.version) {
      return null;
    }
    await store.setString(_notifiedKey(d.id), available.version);
    return ReleaseAlert(d, available);
  }

  /// The release to show "what's new" for, once: the one this Q was seen
  /// waiting for and now runs. Marks it shown.
  Future<Release?> whatsNewToShow(String id, UpdateStatus s) async {
    final current = s.current;
    if (current == null) return null;
    if (await store.getString(_pendingKey(id)) != current.version) {
      return null;
    }
    if (await store.getString(_shownKey(id)) == current.version) {
      return null;
    }
    await store.setString(_shownKey(id), current.version);
    return current;
  }
}
