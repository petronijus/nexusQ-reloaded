import 'package:flutter/material.dart';
import '../debug/app_log.dart';
import '../protocol/models.dart';
import '../state/device_controller.dart';
import '../theme/nexusq_theme.dart';
import '../widgets/device_sphere.dart';
import 'debug_log_screen.dart';
import 'devices_screen.dart';
import 'settings_screen.dart';

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
              // Debug mode (Devices → Developer): quick access to the connection
              // log, right where the "Disconnected" banner appears — so the user
              // can open the evidence the moment they see the symptom.
              ValueListenableBuilder<bool>(
                valueListenable: AppLog.enabled,
                builder: (context, on, _) => on
                    ? IconButton(
                        icon: const Icon(Icons.bug_report_outlined),
                        tooltip: 'Debug log',
                        onPressed: () => Navigator.of(context).push(
                            MaterialPageRoute(builder: (_) => const DebugLogScreen())),
                      )
                    : const SizedBox.shrink(),
              ),
              // Bluetooth pairing. The app is the Q's only input device, so this
              // is its Bluetooth settings panel — there is no other way to pair a
              // mouse or keyboard to a screenless box.
              IconButton(
                icon: const Icon(Icons.devices_other),
                tooltip: 'Devices',
                onPressed: () => Navigator.of(context).push(MaterialPageRoute(
                    builder: (_) => DevicesScreen(client: controller.client))),
              ),
              // Settings: streaming-service toggles, the HDMI desktop, debug mode.
              IconButton(
                icon: const Icon(Icons.settings_outlined),
                tooltip: 'Settings',
                onPressed: () => Navigator.of(context).push(MaterialPageRoute(
                    builder: (_) => SettingsScreen(client: controller.client))),
              ),
              Padding(
                padding: const EdgeInsets.only(right: NexusQSpace.standardMargin),
                child: Icon(Icons.circle,
                    size: 10, color: s.connected ? NexusQColors.accent : NexusQColors.dim),
              ),
            ],
          ),
          body: SafeArea(
            child: Column(
              children: [
                if (!s.connected)
                  _ConnectionBanner(
                    reconnecting: s.reconnecting,
                    onRetry: controller.reconnectNow,
                  ),
                Expanded(
                  child: ListView(
                    padding: const EdgeInsets.fromLTRB(NexusQSpace.standardMargin,
                        8, NexusQSpace.standardMargin, 24),
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

                      // --- OUTPUT (PulseAudio sink routing) --------------------
                      const _SectionHeader('OUTPUT'),
                      _OutputSelector(
                        outputs: s.outputs,
                        active: s.output,
                        onSelect: controller.setOutput,
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
              ],
            ),
          ),
        );
      },
    );
  }
}

/// A slim Holo-dark strip under the app bar while the device link is down:
/// spinner + "reconnecting" while the controller retries on its own, a wifi-off
/// glyph once it is merely waiting (backgrounded), and a manual Retry that is
/// always available — the screen stays alive instead of appearing frozen.
class _ConnectionBanner extends StatelessWidget {
  const _ConnectionBanner({required this.reconnecting, required this.onRetry});
  final bool reconnecting;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(
          horizontal: NexusQSpace.standardMargin, vertical: 6),
      decoration: const BoxDecoration(
        color: NexusQColors.surface,
        border: Border(bottom: BorderSide(color: NexusQColors.divider)),
      ),
      child: Row(
        children: [
          if (reconnecting)
            const SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(
                  strokeWidth: 2, color: NexusQColors.accent),
            )
          else
            const Icon(Icons.wifi_off, size: 16, color: NexusQColors.dim),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              reconnecting ? 'Connection lost — reconnecting…' : 'Disconnected',
              style: const TextStyle(color: NexusQColors.dim, fontSize: 13),
            ),
          ),
          TextButton(onPressed: onRetry, child: const Text('Retry')),
        ],
      ),
    );
  }
}

/// Audio-output routing as a Holo-dark segmented control: one pill per available
/// PA sink (speaker / optical / HDMI), the active one glowing Holo-Blue. Selecting
/// one calls `setOutput`, which re-routes whatever is playing (input-agnostic).
/// Unavailable outputs render dimmed and non-tappable.
class _OutputSelector extends StatelessWidget {
  const _OutputSelector({
    required this.outputs,
    required this.active,
    required this.onSelect,
  });
  final List<AudioOutput> outputs;
  final String active;
  final ValueChanged<String> onSelect;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        for (final o in outputs) ...[
          Expanded(
            child: _OutputPill(
              output: o,
              selected: o.id == active,
              onTap: o.available ? () => onSelect(o.id) : null,
            ),
          ),
          if (o != outputs.last) const SizedBox(width: 10),
        ],
      ],
    );
  }
}

class _OutputPill extends StatelessWidget {
  const _OutputPill({required this.output, required this.selected, this.onTap});
  final AudioOutput output;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final enabled = onTap != null;
    final fg = !enabled
        ? NexusQColors.divider
        : selected
            ? NexusQColors.accent
            : NexusQColors.dim;
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 12),
        decoration: BoxDecoration(
          color: selected ? NexusQColors.accent.withValues(alpha: 0.10) : null,
          borderRadius: BorderRadius.circular(6),
          border: Border.all(
            color: selected ? NexusQColors.accent : NexusQColors.divider,
            width: selected ? 2 : 1,
          ),
          boxShadow: selected
              ? [BoxShadow(color: NexusQColors.accent.withValues(alpha: 0.5), blurRadius: 8)]
              : null,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(output.icon, size: 22, color: fg),
            const SizedBox(height: 6),
            Text(
              output.label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 11, color: fg),
            ),
          ],
        ),
      ),
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
