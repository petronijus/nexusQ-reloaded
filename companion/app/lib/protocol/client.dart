import 'dart:async';

/// A device-pushed event: `{ "event": "...", "data": {...} }`.
class NexusQEvent {
  NexusQEvent(this.event, this.data);
  final String event;
  final Map<String, dynamic> data;
}

/// The companion↔device contract (see companion/PROTOCOL.md). Implemented by
/// [TcpClient] (real, line-JSON over TCP) and [MockClient] (local dev).
abstract class NexusQClient {
  /// Unsolicited device events (volumeChanged, nowPlayingChanged, …).
  Stream<NexusQEvent> get events;

  /// Connection state stream (true = connected).
  Stream<bool> get connection;

  Future<void> connect();
  Future<void> close();

  /// Send a request and await its correlated response `result` (or throw on error).
  Future<Map<String, dynamic>> call(String method, [Map<String, dynamic>? params]);

  /// Fire-and-forget (no id, no awaited response).
  void notify(String method, [Map<String, dynamic>? params]);
}

class NexusQError implements Exception {
  NexusQError(this.code, this.message);
  final String code;
  final String message;
  @override
  String toString() => 'NexusQError($code): $message';
}
