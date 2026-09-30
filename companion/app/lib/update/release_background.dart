// The platform half of release alerts: a periodic background task asks each
// remembered Nexus Q for its update status and posts a local notification for
// a new release (PROTOCOL §12c). The decisions are in release_alerts.dart;
// this file only wires them to WorkManager / BGTaskScheduler, the
// notification plugin and the TCP link.
//
// Android runs the task every 6 h when the network is up (WorkManager keeps
// its own schedule and survives reboots). iOS runs it when the system decides
// the app deserves a background refresh, which may be seldom; the app also
// checks every time it is opened, so an owner who uses it is never behind.
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:workmanager/workmanager.dart';

import '../protocol/client.dart';
import '../protocol/tcp_client.dart';
import 'release.dart';
import 'release_alerts.dart';

/// The background task, and on iOS its BGTaskScheduler identifier: the same
/// string is in Info.plist (BGTaskSchedulerPermittedIdentifiers) and
/// AppDelegate.swift.
const releaseCheckTask = 'org.nexusq.release-check';
const _checkEvery = Duration(hours: 6);

/// Plain preferences through SharedPreferencesAsync: it reads the platform
/// store on every call, so what the background isolate wrote is what the app
/// reads, with no per-isolate cache to go stale.
///
/// Created on first use, inside the call: where there is no platform store
/// (widget tests) the constructor throws, and that must reach the caller as a
/// failed Future it already handles, not as an error building a screen.
class SharedPrefsStore implements KeyValueStore {
  SharedPreferencesAsync? _p;
  SharedPreferencesAsync get _prefs => _p ??= SharedPreferencesAsync();

  @override
  Future<String?> getString(String key) async => _prefs.getString(key);
  @override
  Future<void> setString(String key, String value) async =>
      _prefs.setString(key, value);
  @override
  Future<void> remove(String key) async => _prefs.remove(key);
}

/// Ask one Q for its status: each of its addresses in turn, a few seconds
/// each. Null when it cannot be reached (another network, switched off), and
/// an answer from another Q (an address that moved to it) is no answer.
Future<UpdateStatus?> fetchUpdateStatus(KnownDevice d) async {
  for (final host in d.addresses) {
    final client = TcpClient(host: host, port: d.port);
    try {
      await client.connect().timeout(const Duration(seconds: 6));
      final r = await client
          .call('getUpdateStatus')
          .timeout(const Duration(seconds: 8));
      final s = UpdateStatus.fromJson(r);
      if (s.id == d.id) return s;
    } catch (_) {
      // try the next address
    } finally {
      unawaited(client.close());
    }
  }
  return null;
}

class ReleaseNotifications {
  ReleaseNotifications._();
  static final instance = ReleaseNotifications._();

  final _plugin = FlutterLocalNotificationsPlugin();
  bool _ready = false;

  static const _channel = AndroidNotificationDetails(
    'releases',
    'Nexus Q updates',
    channelDescription: 'A new Nexus Q release is ready to install.',
    importance: Importance.defaultImportance,
    priority: Priority.defaultPriority,
  );

  Future<void> init() async {
    if (_ready) return;
    await _plugin.initialize(
      settings: const InitializationSettings(
        android: AndroidInitializationSettings('@mipmap/ic_launcher'),
        // Asked for explicitly (requestPermission), never on first use.
        iOS: DarwinInitializationSettings(
          requestAlertPermission: false,
          requestBadgePermission: false,
          requestSoundPermission: false,
        ),
      ),
    );
    _ready = true;
  }

  /// Ask once, when the owner first has a Q to hear about (Android 13+ and
  /// iOS need it; older Android grants it with the install).
  Future<void> requestPermission() async {
    await init();
    await _plugin
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >()
        ?.requestNotificationsPermission();
    await _plugin
        .resolvePlatformSpecificImplementation<
          IOSFlutterLocalNotificationsPlugin
        >()
        ?.requestPermissions(alert: true, badge: false, sound: true);
  }

  Future<void> show(ReleaseAlert a) async {
    await init();
    await _plugin.show(
      // One notification per Q: a newer release replaces the older one.
      id: a.device.id.hashCode & 0x7fffffff,
      title: '${a.device.name}: Nexus Q ${a.release.version} is ready',
      body: a.release.headline,
      notificationDetails: const NotificationDetails(
        android: _channel,
        iOS: DarwinNotificationDetails(),
      ),
      payload: a.device.id,
    );
  }
}

/// The app reached a Q: remember it for the background check (a Q reached
/// through the mock or before its id is known is not), and ask for the
/// notification permission the first time there is a Q to hear about.
Future<void> onDeviceReached({
  required NexusQClient client,
  required String? id,
  required String name,
  String? hostname,
}) async {
  if (client is! TcpClient || id == null) return;
  final alerts = ReleaseAlerts(SharedPrefsStore());
  await alerts.remember(
    KnownDevice(
      id: id,
      name: name,
      host: client.host,
      port: client.port,
      hostname: hostname,
    ),
  );
  if (await alerts.firstPermissionAsk()) {
    await ReleaseNotifications.instance.requestPermission();
  }
}

/// One background pass over every remembered Q.
Future<void> runReleaseCheck({
  KeyValueStore? store,
  Future<UpdateStatus?> Function(KnownDevice)? fetch,
  Future<void> Function(ReleaseAlert)? post,
}) async {
  final alerts = ReleaseAlerts(store ?? SharedPrefsStore());
  if (!await alerts.enabled()) return;
  for (final d in await alerts.devices()) {
    final s = await (fetch ?? fetchUpdateStatus)(d);
    // Filed only under the Q that said it: never another's release, name or
    // "already rung" under this one's id.
    if (s == null || s.id != d.id) continue;
    final a = await alerts.observe(d, s);
    if (a != null) await (post ?? ReleaseNotifications.instance.show)(a);
  }
}

@pragma('vm:entry-point')
void releaseCheckDispatcher() {
  Workmanager().executeTask((task, input) async {
    WidgetsFlutterBinding.ensureInitialized();
    try {
      await runReleaseCheck();
    } catch (e) {
      debugPrint('release check failed: $e');
    }
    // Always "done": a Q that is not reachable is not a failure to retry
    // sooner; the next period asks again.
    return true;
  });
}

/// Schedule the periodic check. Idempotent: an existing schedule is kept.
Future<void> scheduleReleaseChecks() async {
  if (kIsWeb) return;
  if (defaultTargetPlatform != TargetPlatform.android &&
      defaultTargetPlatform != TargetPlatform.iOS) {
    return;
  }
  await Workmanager().initialize(releaseCheckDispatcher);
  await Workmanager().registerPeriodicTask(
    releaseCheckTask,
    releaseCheckTask,
    frequency: _checkEvery,
    initialDelay: const Duration(minutes: 15),
    constraints: Constraints(networkType: NetworkType.connected),
    existingWorkPolicy: ExistingPeriodicWorkPolicy.keep,
  );
}
