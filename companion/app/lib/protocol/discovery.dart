import 'package:flutter/foundation.dart';
import 'package:multicast_dns/multicast_dns.dart';

/// A discovered device bridge endpoint.
class Discovered {
  const Discovered(this.name, this.host, this.port);
  final String name;
  final String host;
  final int port;
}

const _serviceType = '_nexusq._tcp.local';

/// Browse the LAN for the device's `_nexusq._tcp` bridge (PROTOCOL.md §2):
/// PTR → SRV (host+port) → A (IPv4). Returns the first resolved endpoint, or
/// null on timeout. No-op on web (no raw sockets) — callers fall back to a
/// manual host there.
Future<Discovered?> discoverNexusQ({
  Duration timeout = const Duration(seconds: 4),
}) async {
  if (kIsWeb) return null;
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
