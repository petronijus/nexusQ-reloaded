import 'package:flutter/material.dart';
import '../protocol/models.dart';
import '../state/device_controller.dart';
import '../theme/nexusq_theme.dart';
import '../widgets/glowing_ring.dart';

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
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: NexusQSpace.standardMargin),
              child: Column(
                children: [
                  const SizedBox(height: 8),
                  // --- hero: glowing ring with now-playing inside -----------
                  Expanded(
                    child: Center(
                      child: GlowingRing(
                        volume: s.muted ? 0 : s.volume / 100,
                        color: theme.primary,
                        muted: s.muted,
                        child: _NowPlayingCore(np: np),
                      ),
                    ),
                  ),
                  // --- transport -------------------------------------------
                  _Transport(controller: controller, np: np),
                  const SizedBox(height: 8),
                  // --- volume row ------------------------------------------
                  _VolumeRow(controller: controller, state: s),
                  const SizedBox(height: 4),
                  // --- theme picker ----------------------------------------
                  _ThemePicker(controller: controller, current: s.theme),
                  // --- brightness ------------------------------------------
                  _BrightnessRow(controller: controller, brightness: s.brightness),
                  const SizedBox(height: 8),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

class _NowPlayingCore extends StatelessWidget {
  const _NowPlayingCore({required this.np});
  final NowPlaying np;
  @override
  Widget build(BuildContext context) {
    if (np.isEmpty) {
      return const Text('Nothing playing',
          style: TextStyle(color: NexusQColors.dim, fontWeight: FontWeight.w300));
    }
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 48),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(np.track,
              textAlign: TextAlign.center,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: NexusQColors.white, fontSize: 18, fontWeight: FontWeight.w400)),
          const SizedBox(height: 4),
          Text(np.artist,
              textAlign: TextAlign.center,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: NexusQColors.dim, fontSize: 13)),
        ],
      ),
    );
  }
}

class _Transport extends StatelessWidget {
  const _Transport({required this.controller, required this.np});
  final DeviceController controller;
  final NowPlaying np;
  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        IconButton(onPressed: controller.previous, icon: const Icon(Icons.skip_previous), color: NexusQColors.white),
        const SizedBox(width: 8),
        IconButton(
          iconSize: 44,
          onPressed: controller.playPause,
          icon: Icon(np.playing ? Icons.pause_circle_filled : Icons.play_circle_filled),
          color: NexusQColors.accent,
        ),
        const SizedBox(width: 8),
        IconButton(onPressed: controller.next, icon: const Icon(Icons.skip_next), color: NexusQColors.white),
      ],
    );
  }
}

class _VolumeRow extends StatelessWidget {
  const _VolumeRow({required this.controller, required this.state});
  final DeviceController controller;
  final DeviceState state;
  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        IconButton(
          onPressed: controller.toggleMute,
          icon: Icon(state.muted ? Icons.volume_off : Icons.volume_up),
          color: state.muted ? NexusQColors.dim : NexusQColors.accent,
        ),
        Expanded(
          child: Slider(
            value: state.volume.toDouble(),
            max: 100,
            onChanged: (v) => controller.setVolume(v.round()),
          ),
        ),
        SizedBox(
          width: 34,
          child: Text('${state.volume}',
              textAlign: TextAlign.right, style: const TextStyle(color: NexusQColors.dim)),
        ),
      ],
    );
  }
}

class _ThemePicker extends StatelessWidget {
  const _ThemePicker({required this.controller, required this.current});
  final DeviceController controller;
  final String current;
  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 56,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: kLedThemes.length,
        separatorBuilder: (_, _) => const SizedBox(width: 10),
        itemBuilder: (context, i) {
          final t = kLedThemes[i];
          final selected = t.name == current;
          return GestureDetector(
            onTap: () => controller.setTheme(t.name),
            child: Container(
              width: 44,
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
                    ? [BoxShadow(color: NexusQColors.accent.withValues(alpha: 0.6), blurRadius: 10)]
                    : null,
              ),
            ),
          );
        },
      ),
    );
  }
}

class _BrightnessRow extends StatelessWidget {
  const _BrightnessRow({required this.controller, required this.brightness});
  final DeviceController controller;
  final int brightness;
  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        const Icon(Icons.brightness_low, color: NexusQColors.dim, size: 20),
        Expanded(
          child: Slider(
            value: brightness.toDouble(),
            max: 255,
            onChanged: (v) => controller.setBrightness(v.round()),
          ),
        ),
        const Icon(Icons.brightness_high, color: NexusQColors.dim, size: 20),
      ],
    );
  }
}
