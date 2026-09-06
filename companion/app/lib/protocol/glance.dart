import 'dart:async';

import 'client.dart';
import 'discovery.dart';
import 'models.dart';
import 'tcp_client.dart';

/// What the connect gate learns about a discovered Q *before* anyone connects
/// to it, so the picker can draw each box the way the home screen does — the
/// sphere lit in that box's own colour theme (Petr, 2026-09-06: "místo ikonky
/// obrázky těch koulí, a pokud má některá jinou ambientní barvu, ať je vidět").
///
/// mDNS carries no theme (and a TXT record could only ever be as fresh as the
/// last re-announce), so the gate asks the box itself: one short `getState`
/// over a throw-away connection. The answer is the live truth, and a box that
/// does not answer is shown dark — which is also exactly what it is.
///
/// Deliberately NOT the device name: `getState.name` is the bridge's start-up
/// snapshot and goes stale after a rename (see [DeviceState.applyJson]); the
/// mDNS record the picker already has is the fresh one.
class DeviceGlance {
  const DeviceGlance({required this.theme, this.muted = false});

  /// The box's colour theme name (`kLedThemes`), as the bridge reports it.
  final String theme;
  final bool muted;

  /// Whether the ring shows anything at all — the same rule the home screen
  /// applies to its sphere.
  bool get on => !muted && theme != 'off';

  LedTheme get ledTheme => themeByName(theme);

  factory DeviceGlance.fromJson(Map<String, dynamic> j) => DeviceGlance(
        theme: j['theme'] is String ? j['theme'] as String : 'blue',
        muted: j['muted'] == true,
      );
}

/// How long the gate waits for one box to answer. Well under the 4 s browse,
/// so a slow box still lights up before the list settles.
const kGlanceTimeout = Duration(seconds: 3);

/// Ask [d] for its state over a throw-away [TcpClient]; `null` when it does
/// not answer in time (or answers nonsense). Never throws: the picker shows
/// the row either way, lit or dark.
Future<DeviceGlance?> glanceAt(Discovered d, {NexusQClient? client}) async {
  final c = client ?? TcpClient(host: d.host, port: d.port);
  try {
    await c.connect().timeout(kGlanceTimeout);
    final s = await c.call('getState').timeout(kGlanceTimeout);
    return DeviceGlance.fromJson(s);
  } catch (_) {
    return null;
  } finally {
    try {
      await c.close();
    } catch (_) {
      // a link that died under us has nothing left to close
    }
  }
}
