import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:multicast_dns/multicast_dns.dart';

/// A discovered device bridge endpoint.
class Discovered {
  const Discovered(this.name, this.host, this.port);
  final String name;
  final String host;
  final int port;

  /// Two records for the same bridge are the same device.
  String get key => '$host:$port';
}

const _serviceType = '_nexusq._tcp.local';

/// Native Bonjour bridge for platforms where multicast_dns cannot run — iOS
/// forbids raw port-5353 sockets without the restricted multicast entitlement,
/// so discovery goes through NWBrowser in the Runner (BonjourDiscovery.swift).
const _bonjourChannel = MethodChannel('nexusq/bonjour');

/// Browse the LAN for the device's `_nexusq._tcp` bridge (PROTOCOL.md §2):
/// PTR → SRV (host+port) → A (IPv4). Returns the first resolved endpoint, or
/// null on timeout. No-op on web (no raw sockets) — callers fall back to a
/// manual host there. On iOS the browse is delegated to the platform's Bonjour
/// API (same contract) instead of multicast_dns — see [_discoverNative].
Future<Discovered?> discoverNexusQ({
  Duration timeout = const Duration(seconds: 4),
}) async {
  if (kIsWeb) return null;
  if (defaultTargetPlatform == TargetPlatform.iOS) {
    return _discoverNative(timeout);
  }
  final client = MDnsClient();
  try {
    await client.start();
    await for (final ptr in client
        .lookup<PtrResourceRecord>(ResourceRecordQuery.serverPointer(_serviceType))
        .timeout(timeout, onTimeout: (sink) => sink.close())) {
      await for (final srv in client
          .lookup<SrvResourceRecord>(ResourceRecordQuery.service(ptr.domainName))
          .timeout(timeout, onTimeout: (sink) => sink.close())) {
        await for (final ip in client
            .lookup<IPAddressResourceRecord>(
                ResourceRecordQuery.addressIPv4(srv.target))
            .timeout(timeout, onTimeout: (sink) => sink.close())) {
          final name = ptr.domainName.split('.').first.replaceAll('\\032', ' ');
          return Discovered(name, ip.address.address, srv.port);
        }
      }
    }
  } catch (_) {
    // mDNS unavailable (permissions, no network) — caller handles null.
  } finally {
    client.stop();
  }
  return null;
}

/// iOS-only: browse + resolve via the `nexusq/bonjour` platform channel. The
/// native side owns the [timeout]; the outer `.timeout` is a belt against the
/// channel itself wedging (it then reads as "nothing found", never a throw).
Future<Discovered?> _discoverNative(Duration timeout) async {
  try {
    final r = await _bonjourChannel.invokeMapMethod<String, dynamic>(
      'discover',
      {'timeoutMs': timeout.inMilliseconds},
    ).timeout(timeout + const Duration(seconds: 2));
    final host = r?['host'] as String?;
    final port = r?['port'] as int?;
    if (host == null || host.isEmpty || port == null) return null;
    return Discovered((r?['name'] as String?) ?? 'Nexus Q', host, port);
  } catch (_) {
    // Channel absent (tests), local-network permission denied, or timeout —
    // caller falls back to manual entry, exactly like the multicast path.
    return null;
  }
}

/// Browse for EVERY `_nexusq._tcp` bridge on the LAN for the whole [timeout],
/// emitting each as it resolves (deduplicated by host:port) and closing when
/// the time is up. This is what the connect gate lists when there is more than
/// one Nexus Q; [discoverNexusQ] above is the single-shot form it used to
/// auto-connect with. On iOS the platform side (BonjourDiscovery.swift
/// `discoverAll`) collects for the same duration and answers with a list.
Stream<Discovered> discoverNexusQAll({
  Duration timeout = const Duration(seconds: 4),
}) {
  if (kIsWeb) return const Stream.empty();
  if (defaultTargetPlatform == TargetPlatform.iOS) {
    return _discoverAllNative(timeout);
  }
  final out = StreamController<Discovered>();
  () async {
    final seen = <String>{};
    final client = MDnsClient();
    try {
      await client.start();
      final deadline = DateTime.now().add(timeout);
      Duration left() {
        final d = deadline.difference(DateTime.now());
        return d.isNegative ? Duration.zero : d;
      }
      await for (final ptr in client
          .lookup<PtrResourceRecord>(ResourceRecordQuery.serverPointer(_serviceType))
          .timeout(timeout, onTimeout: (sink) => sink.close())) {
        await for (final srv in client
            .lookup<SrvResourceRecord>(ResourceRecordQuery.service(ptr.domainName))
            .timeout(left(), onTimeout: (sink) => sink.close())) {
          await for (final ip in client
              .lookup<IPAddressResourceRecord>(ResourceRecordQuery.addressIPv4(srv.target))
              .timeout(left(), onTimeout: (sink) => sink.close())) {
            final name = ptr.domainName.split('.').first.replaceAll('\\032', ' ');
            final d = Discovered(name, ip.address.address, srv.port);
            if (seen.add(d.key) && !out.isClosed) out.add(d);
            break; // one address per bridge is enough
          }
          break;
        }
      }
    } catch (_) {
      // mDNS unavailable (permissions, no network) — the stream just ends.
    } finally {
      client.stop();
      if (!out.isClosed) await out.close();
    }
  }();
  return out.stream;
}

Stream<Discovered> _discoverAllNative(Duration timeout) {
  final out = StreamController<Discovered>();
  () async {
    try {
      final list = await _bonjourChannel.invokeListMethod<dynamic>(
        'discoverAll',
        {'timeoutMs': timeout.inMilliseconds},
      ).timeout(timeout + const Duration(seconds: 2));
      final seen = <String>{};
      for (final r in list ?? const []) {
        if (r is! Map) continue;
        final host = r['host'] as String?;
        final port = r['port'] as int?;
        if (host == null || host.isEmpty || port == null) continue;
        final d = Discovered((r['name'] as String?) ?? 'Nexus Q', host, port);
        if (seen.add(d.key)) out.add(d);
      }
    } catch (_) {
      // Channel absent (tests), permission denied, or timeout — nothing found.
    } finally {
      await out.close();
    }
  }();
  return out.stream;
}
