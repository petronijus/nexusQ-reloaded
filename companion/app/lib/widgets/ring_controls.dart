import 'package:flutter/material.dart';
import '../protocol/models.dart';
import '../theme/nexusq_theme.dart';

/// The LED ring switch and its schedule (PROTOCOL §4, "LED ring on/off").
///
/// Off keeps the ring dark except for what answers the user — the music
/// visualiser and the volume-knob overlay. The schedule switches it by the
/// Q's own clock; flipping the main switch by hand turns the schedule off
/// (the bridge's rule, mirrored here so the UI never shows both "on").
class RingControls extends StatelessWidget {
  const RingControls({
    super.key,
    required this.ring,
    required this.onRingChanged,
    required this.onScheduleChanged,
    this.error,
  });

  final RingState ring;
  final ValueChanged<bool> onRingChanged;
  final void Function({required bool enabled, String? offAt, String? onAt}) onScheduleChanged;
  final String? error;

  static const _title = TextStyle(color: NexusQColors.white);
  static const _hint = TextStyle(color: NexusQColors.dim, fontSize: 13);

  @override
  Widget build(BuildContext context) {
    return Card(
      color: NexusQColors.surface,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SwitchListTile(
            key: const Key('ring-switch'),
            value: ring.on,
            onChanged: onRingChanged,
            title: const Text('LED ring', style: _title),
            subtitle: Text(
                ring.on
                    ? 'Idle light, theme and notifications'
                    : 'Dark — lights only for music and the volume knob',
                style: _hint),
          ),
          SwitchListTile(
            key: const Key('ring-schedule-switch'),
            value: ring.scheduleEnabled,
            onChanged: (v) => onScheduleChanged(enabled: v),
            title: const Text('Schedule', style: _title),
            subtitle: Text('Off at ${ring.offAt}, on at ${ring.onAt}', style: _hint),
          ),
          if (ring.scheduleEnabled)
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
              child: Row(
                children: [
                  Expanded(
                    child: _TimeButton(
                      key: const Key('ring-off-at'),
                      label: 'Off at',
                      value: ring.offAt,
                      onPicked: (t) => onScheduleChanged(enabled: true, offAt: t),
                    ),
                  ),
                  Expanded(
                    child: _TimeButton(
                      key: const Key('ring-on-at'),
                      label: 'On at',
                      value: ring.onAt,
                      onPicked: (t) => onScheduleChanged(enabled: true, onAt: t),
                    ),
                  ),
                ],
              ),
            ),
          if (ring.scheduleEnabled && !ring.clockSynced)
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 0, 16, 12),
              child: Text(
                  'Waiting for network time — the schedule starts once the '
                  'Nexus Q has set its clock.',
                  style: _hint),
            ),
          if (error != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
              child: Text(error!,
                  style: const TextStyle(color: NexusQColors.ledOrange, fontSize: 13)),
            ),
        ],
      ),
    );
  }
}

/// 'HH:MM' <-> [TimeOfDay], the bridge's wire format for the schedule.
TimeOfDay parseRingTime(String hhmm) {
  final parts = hhmm.split(':');
  return TimeOfDay(hour: int.parse(parts[0]), minute: int.parse(parts[1]));
}

String formatRingTime(TimeOfDay t) =>
    '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

/// One end of the schedule: shows 'HH:MM' and opens a 24-hour picker. The
/// times are the Nexus Q's local time, so the picker never shows AM/PM.
class _TimeButton extends StatelessWidget {
  const _TimeButton({super.key, required this.label, required this.value, required this.onPicked});

  final String label;
  final String value;
  final ValueChanged<String> onPicked;

  Future<void> _pick(BuildContext context) async {
    final picked = await showTimePicker(
      context: context,
      initialTime: parseRingTime(value),
      helpText: label.toUpperCase(),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(alwaysUse24HourFormat: true),
        child: child!,
      ),
    );
    if (picked != null) {
      final t = formatRingTime(picked);
      if (t != value) onPicked(t);
    }
  }

  @override
  Widget build(BuildContext context) {
    return TextButton(
      onPressed: () => _pick(context),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(label, style: const TextStyle(color: NexusQColors.dim, fontSize: 12)),
          Text(value,
              style: const TextStyle(
                  color: NexusQColors.accent, fontSize: 22, fontWeight: FontWeight.w300)),
        ],
      ),
    );
  }
}
