import 'dart:convert';

/// Parsed NFC tap payload (PROTOCOL.md §7): the Q's connection info.
class DeviceTap {
  DeviceTap({required this.btMac, required this.host, this.ip, required this.provisioned});

  final String btMac;
  final String host;
  final String? ip;
  final bool provisioned;

  /// Returns null for non-JSON / unknown-version payloads (those remain
  /// plain-text messages shown as a SnackBar).
  static DeviceTap? tryParse(String text) {
    if (!text.trimLeft().startsWith('{')) return null;
    try {
      final obj = jsonDecode(text);
      if (obj is! Map<String, dynamic> || obj['v'] != 1) return null;
      return DeviceTap(
        btMac: (obj['bt'] as String?) ?? '',
        host: (obj['host'] as String?) ?? '',
        ip: obj['ip'] as String?,
        provisioned: obj['prov'] == true,
      );
    } on FormatException {
      return null;
    }
  }
}
