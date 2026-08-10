import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Broker connection settings for the health telemetry feed, entered by hand
/// in the Health screen's "Connect to MQTT" dialog (the user's decision: no
/// auto-provisioning from the device, no protocol verb — you type the broker
/// credentials once per phone and can edit them any time).
///
/// Persisted in the platform secure store (Android Keystore / iOS Keychain) —
/// the broker password also guards zigbee2mqtt and the rest of the home
/// broker, so it does not belong in plaintext SharedPreferences.
class MqttSettings {
  const MqttSettings({
    required this.host,
    this.port = 1883,
    required this.username,
    required this.password,
    this.prefix = 'nexusq',
  });

  final String host;
  final int port;
  final String username;
  final String password;

  /// Topic prefix the device publishes under: `<prefix>/health/state` +
  /// `<prefix>/status`. Matches the device's /etc/nexusq/mqtt.json "prefix".
  final String prefix;

  bool get isComplete =>
      host.isNotEmpty && username.isNotEmpty && password.isNotEmpty;

  static const _store = FlutterSecureStorage();
  static const _kHost = 'mqtt.host';
  static const _kPort = 'mqtt.port';
  static const _kUser = 'mqtt.username';
  static const _kPass = 'mqtt.password';
  static const _kPrefix = 'mqtt.prefix';

  static Future<MqttSettings?> load() async {
    final host = await _store.read(key: _kHost);
    if (host == null || host.isEmpty) return null;
    return MqttSettings(
      host: host,
      port: int.tryParse(await _store.read(key: _kPort) ?? '') ?? 1883,
      username: await _store.read(key: _kUser) ?? '',
      password: await _store.read(key: _kPass) ?? '',
      prefix: (await _store.read(key: _kPrefix))?.trim().isNotEmpty == true
          ? (await _store.read(key: _kPrefix))!.trim()
          : 'nexusq',
    );
  }

  Future<void> save() async {
    await _store.write(key: _kHost, value: host);
    await _store.write(key: _kPort, value: '$port');
    await _store.write(key: _kUser, value: username);
    await _store.write(key: _kPass, value: password);
    await _store.write(key: _kPrefix, value: prefix);
  }

  static Future<void> clear() async {
    for (final k in [_kHost, _kPort, _kUser, _kPass, _kPrefix]) {
      await _store.delete(key: k);
    }
  }
}
