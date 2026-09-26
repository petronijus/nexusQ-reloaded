import 'package:flutter/material.dart';
import '../protocol/models.dart';
import '../theme/nexusq_theme.dart';

/// The ambient brightness switch under the brightness slider (PROTOCOL §4).
///
/// On: the slider above it is the daytime MAXIMUM, and the Nexus Q dims the
/// ring through dusk to a quarter of it by the sun at its own location (taken
/// from its time zone), then brings it back at dawn. It never switches the
/// ring off — that is the LED ring schedule's job.
class AmbientBrightnessTile extends StatelessWidget {
  const AmbientBrightnessTile({
    super.key,
    required this.ambient,
    required this.maximum,
    required this.onChanged,
    this.error,
  });

  final AmbientState ambient;
  /// The slider's value, 0..255 — the ceiling ambient dims under.
  final int maximum;
  final ValueChanged<bool> onChanged;
  final String? error;

  static const _hint = TextStyle(color: NexusQColors.dim, fontSize: 13);

  String _subtitle() {
    if (!ambient.available) {
      return "Unavailable — the Nexus Q's time zone has no known location";
    }
    if (!ambient.enabled) {
      return 'Dims the ring after sunset (${ambient.zone})';
    }
    if (!ambient.clockSynced) {
      return 'Waiting for network time — full brightness until then';
    }
    final pct = maximum <= 0 ? 100 : (ambient.level * 100 / maximum).round().clamp(0, 100);
    return pct >= 100
        ? 'Daylight: at the slider maximum'
        : 'Dimmed for the time of day: $pct % of the slider maximum';
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SwitchListTile(
          key: const Key('ambient-switch'),
          contentPadding: EdgeInsets.zero,
          value: ambient.enabled,
          onChanged: ambient.available ? onChanged : null,
          title: const Text('Ambient brightness', style: TextStyle(color: NexusQColors.white)),
          subtitle: Text(_subtitle(), style: _hint),
        ),
        if (error != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(error!, style: const TextStyle(color: NexusQColors.ledOrange, fontSize: 13)),
          ),
      ],
    );
  }
}
