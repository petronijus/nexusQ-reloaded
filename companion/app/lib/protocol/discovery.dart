import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:multicast_dns/multicast_dns.dart';

/// A discovered device bridge endpoint.
class Discovered {
  const Discovered(this.name, this.host, this.port);
  final String name;
  final String host;
  final int port;
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
