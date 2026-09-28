import 'package:flutter/material.dart';
import '../protocol/models.dart';
import '../state/device_controller.dart';
import '../theme/nexusq_theme.dart';
import 'ambient_brightness.dart';
import 'ring_controls.dart';

/// Everything that decides what the LED ring shows, as one LIGHTS category on
/// the home screen (Petr, 2026-09-28): whether it is lit and when, how bright
/// it is, its idle colour and what it does to music. Flat rows on the page
/// background, not cards — the ring switch comes first because it overrides
/// everything under it.
///
/// Order: LED ring, schedule, brightness, ambient brightness, light theme,
/// visualisation. The ring rows exist only when the bridge reports a ring
/// state (an older Q has no `dark` gate, and a switch it cannot honour would
/// only lie); the same goes for ambient.
class LightsSection extends StatelessWidget {
  const LightsSection({super.key, required this.controller});

  final DeviceController controller;

  @override
  Widget build(BuildContext context) {
    final s = controller.state;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (s.ring != null)
          RingControls(
            ring: s.ring!,
            error: controller.ringError,
            onRingChanged: controller.setRingOn,
            onScheduleChanged: controller.setRingSchedule,
          ),

        const _RowLabel('Brightness'),
        Row(
          key: const Key('lights-brightness'),
          children: [
            const Icon(Icons.brightness_low, color: NexusQColors.dim, size: 20),
            Expanded(
              child: Slider(
                value: s.brightness.toDouble(),
                max: 255,
                onChanged: (v) => controller.setBrightness(v.round()),
              ),
            ),
            const Icon(Icons.brightness_high, color: NexusQColors.dim, size: 20),
          ],
        ),
        if (s.ambient != null)
          AmbientBrightnessTile(
            ambient: s.ambient!,
            maximum: s.brightness,
            error: controller.ambientError,
            onChanged: controller.setAmbient,
          ),

        const _RowLabel('Light theme'),
        SizedBox(
          key: const Key('lights-theme'),
          height: 66,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            itemCount: kLedThemes.length,
            separatorBuilder: (_, _) => const SizedBox(width: 12),
            itemBuilder: (context, i) {
              final t = kLedThemes[i];
              final selected = t.name == s.theme;
              return GestureDetector(
                onTap: () => controller.setTheme(t.name),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 38,
                      height: 38,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        gradient: t.colors.length > 1
                            ? SweepGradient(colors: [...t.colors, t.colors.first])
                            : null,
                        color: t.colors.length == 1 ? t.colors.first : null,
                        border: Border.all(
                          color: selected ? NexusQColors.accent : NexusQColors.divider,
                          width: selected ? 3 : 1,
                        ),
                        boxShadow: selected
                            ? [BoxShadow(color: NexusQColors.accent.withValues(alpha: 0.6), blurRadius: 8)]
                            : null,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(t.label,
                        style: TextStyle(
                            fontSize: 10,
                            color: selected ? NexusQColors.accent : NexusQColors.dim)),
                  ],
                ),
              );
            },
          ),
        ),

        const _RowLabel('Visualization'),
        SizedBox(
          key: const Key('lights-visualization'),
          height: 66,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            itemCount: kVisualizations.length,
            separatorBuilder: (_, _) => const SizedBox(width: 12),
            itemBuilder: (context, i) {
              final v = kVisualizations[i];
              final selected = v.name == s.scene;
              return GestureDetector(
                onTap: () => controller.setScene(v.name),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 38,
                      height: 38,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: selected ? NexusQColors.accent : NexusQColors.divider,
                          width: selected ? 3 : 1,
                        ),
                        boxShadow: selected
                            ? [BoxShadow(color: NexusQColors.accent.withValues(alpha: 0.6), blurRadius: 8)]
                            : null,
                      ),
                      child: Icon(v.icon,
                          size: 20,
                          color: selected ? NexusQColors.accent : NexusQColors.dim),
                    ),
                    const SizedBox(height: 4),
                    Text(v.label,
                        style: TextStyle(
                            fontSize: 10,
                            color: selected ? NexusQColors.accent : NexusQColors.dim)),
                  ],
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}

/// A row's title inside the category, styled like the switch tiles' titles so
/// the slider and the two pickers read as rows of LIGHTS, not as categories of
/// their own (those are the blue section headers).
class _RowLabel extends StatelessWidget {
  const _RowLabel(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(top: 12, bottom: 2),
        child: Text(text, style: const TextStyle(color: NexusQColors.white, fontSize: 16)),
      );
}
