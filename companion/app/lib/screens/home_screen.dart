import 'package:flutter/material.dart';
import '../protocol/models.dart';
import '../state/device_controller.dart';
import '../theme/nexusq_theme.dart';
import '../widgets/device_sphere.dart';

/// Faithful to the original Nexus Q app: the black "drop ball" sphere as the
/// device, over a Holo-dark settings list (volume, brightness, light theme),
/// plus a now-playing block (our addition, from librespot).
class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key, required this.controller});
  final DeviceController controller;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final s = controller.state;
        final theme = themeByName(s.theme);
        final np = s.nowPlaying;
        return Scaffold(
          appBar: AppBar(
            title: Text(s.deviceName.toUpperCase()),
            actions: [
              Padding(
                padding: const EdgeInsets.only(right: NexusQSpace.standardMargin),
                child: Icon(Icons.circle,
                    size: 10, color: s.connected ? NexusQColors.accent : NexusQColors.dim),
              ),
            ],
          ),
          body: SafeArea(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(NexusQSpace.standardMargin, 8,
                  NexusQSpace.standardMargin, 24),
              children: [
                // --- the device, as the original showed it ----------------
                const SizedBox(height: 12),
                Center(
                  child: DeviceSphere(
                    on: !s.muted && s.theme != 'off',
                    colors: theme.colors, // base glow reflects the LED theme palette
                    size: 184,
                  ),
                ),
                const SizedBox(height: 14),
                Center(
                  child: Text(s.deviceName,
                      style: const TextStyle(
                          color: NexusQColors.white, fontSize: 20, fontWeight: FontWeight.w300)),
                ),
                if (!np.isEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Center(
                      child: Text('${np.track} · ${np.artist}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(color: NexusQColors.dim, fontSize: 13)),
                    ),
                  ),
                const SizedBox(height: 20),

                // --- VOLUME ----------------------------------------------
                const _SectionHeader('VOLUME'),
                Row(
                  children: [
                    IconButton(
                      onPressed: controller.toggleMute,
                      icon: Icon(s.muted ? Icons.volume_off : Icons.volume_up),
                      color: s.muted ? NexusQColors.dim : NexusQColors.accent,
                    ),
                    Expanded(
                      child: Slider(
                        value: s.volume.toDouble(),
                        max: 100,
                        onChanged: (v) => controller.setVolume(v.round()),
                      ),
                    ),
                    SizedBox(
                      width: 36,
                      child: Text('${s.volume}',
                          textAlign: TextAlign.right,
                          style: const TextStyle(color: NexusQColors.dim)),
                    ),
                  ],
                ),

                // --- BRIGHTNESS ------------------------------------------
                const _SectionHeader('BRIGHTNESS'),
                Row(
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

                // --- LIGHT THEME -----------------------------------------
                const _SectionHeader('LIGHT THEME'),
                SizedBox(
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

                // --- VISUALIZATION (music-reactive scenes) ---------------
                const _SectionHeader('VISUALIZATION'),
                SizedBox(
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

                // --- NOW PLAYING -----------------------------------------
                const _SectionHeader('NOW PLAYING'),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    IconButton(
                        onPressed: controller.previous,
                        icon: const Icon(Icons.skip_previous),
                        color: NexusQColors.white),
                    const SizedBox(width: 8),
                    IconButton(
                      iconSize: 40,
                      onPressed: controller.playPause,
                      icon: Icon(np.playing ? Icons.pause_circle_filled : Icons.play_circle_filled),
                      color: NexusQColors.accent,
                    ),
                    const SizedBox(width: 8),
                    IconButton(
                        onPressed: controller.next,
                        icon: const Icon(Icons.skip_next),
                        color: NexusQColors.white),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// A Holo-style section header: a Holo-Blue label over a thin divider — matching
/// the original device-settings screens.
class _SectionHeader extends StatelessWidget {
  const _SectionHeader(this.label);
  final String label;
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 20, bottom: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label,
              style: const TextStyle(
                  color: NexusQColors.accent,
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                  letterSpacing: 1.2)),
          const SizedBox(height: 4),
          Container(height: 1, color: NexusQColors.divider),
        ],
      ),
    );
  }
}
