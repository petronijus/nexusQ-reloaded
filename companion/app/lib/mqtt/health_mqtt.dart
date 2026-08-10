import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:mqtt_client/mqtt_client.dart';
import 'package:mqtt_client/mqtt_server_client.dart';

import '../debug/app_log.dart';
import 'mqtt_settings.dart';

/// Where the health feed connection currently stands, for the UI.
enum HealthLink { idle, connecting, connected, error }

/// Subscriber for the device's MQTT health telemetry
/// (`<prefix>/health/state` JSON + `<prefix>/status` availability) published
/// by the on-device nexusq-mqtt daemon. Read-only — the app never publishes.
///
/// Both topics are RETAINED on the broker, so a fresh subscription delivers
/// the last known state instantly — the panel never opens empty while the
/// device itself may even be asleep/offline (then `status` says "offline" and
/// the state shows its age).
class HealthMqtt extends ChangeNotifier {
  HealthLink link = HealthLink.idle;
  String? errorText;

  /// Parsed `<prefix>/health/state` JSON — the daemon omits fields whose
  /// source was unavailable, so read with `state['key']` null-aware access.
  Map<String, dynamic> state = {};

  /// `online` / `offline` from the retained availability topic (LWT-backed).
  bool? deviceOnline;

  /// Wall-clock instant the last state message arrived on THIS phone.
  DateTime? lastUpdate;

  MqttServerClient? _client;
  StreamSubscription? _updates;
  MqttSettings? _settings;

  bool get isConnected => link == HealthLink.connected;

  Future<void> connect(MqttSettings settings) async {
    await disconnect();
    _settings = settings;
    link = HealthLink.connecting;
    errorText = null;
    notifyListeners();

    final client = MqttServerClient.withPort(
        settings.host,
        // Unique per phone-ish: broker drops the OLDER session on a client-id
        // collision, so a fixed id would let two phones kick each other off.
        'nexusq-app-${DateTime.now().millisecondsSinceEpoch % 100000}',
        settings.port);
    client.logging(on: false);
    client.keepAlivePeriod = 60;
    client.autoReconnect = true;
    client.connectTimeoutPeriod = 8000;
    client.onConnected = _onConnected;
    client.onDisconnected = _onDisconnected;
    client.connectionMessage = MqttConnectMessage().startClean();
    _client = client;

    try {
      final status =
          await client.connect(settings.username, settings.password);
      if (status?.state != MqttConnectionState.connected) {
        throw Exception(status?.returnCode?.name ?? 'connection failed');
      }
    } catch (e) {
      AppLog.add('mqtt', 'connect failed: $e', warn: true);
      _client = null;
      link = HealthLink.error;
      // mqtt_client wraps a broker auth refusal in a NoConnectionException
      // whose text is noise; show something a human can act on.
      errorText = e.toString().contains('not authorized') ||
              e.toString().contains('badUsernameOrPassword') ||
              e.toString().contains('notAuthorized')
          ? 'Broker refused the username/password'
          : 'Cannot reach ${settings.host}:${settings.port}';
      notifyListeners();
      return;
    }

    client.subscribe('${settings.prefix}/health/state', MqttQos.atMostOnce);
    client.subscribe('${settings.prefix}/status', MqttQos.atMostOnce);
    _updates = client.updates?.listen(_onMessage);
    link = HealthLink.connected;
    notifyListeners();
    AppLog.add('mqtt', 'connected to ${settings.host}:${settings.port}');
  }

  Future<void> disconnect() async {
    await _updates?.cancel();
    _updates = null;
    _client?.disconnect();
    _client = null;
    if (link != HealthLink.idle) {
      link = HealthLink.idle;
      notifyListeners();
    }
  }

  void _onMessage(List<MqttReceivedMessage<MqttMessage?>> batch) {
    final prefix = _settings?.prefix ?? 'nexusq';
    for (final msg in batch) {
      final payload = msg.payload;
      if (payload is! MqttPublishMessage) continue;
      final text =
          MqttPublishPayload.bytesToStringAsString(payload.payload.message);
      if (msg.topic == '$prefix/status') {
        deviceOnline = text == 'online';
      } else if (msg.topic == '$prefix/health/state') {
        try {
          final parsed = jsonDecode(text);
          if (parsed is Map<String, dynamic>) {
            state = parsed;
            lastUpdate = DateTime.now();
          }
        } catch (e) {
          AppLog.add('mqtt', 'unparseable state payload: $e', warn: true);
        }
      }
    }
    notifyListeners();
  }

  void _onConnected() {
    link = HealthLink.connected;
    notifyListeners();
  }

  void _onDisconnected() {
    // autoReconnect keeps trying underneath; reflect the gap in the UI.
    if (link == HealthLink.connected) {
      link = HealthLink.connecting;
      notifyListeners();
    }
  }

  @override
  void dispose() {
    disconnect();
    super.dispose();
  }
}
