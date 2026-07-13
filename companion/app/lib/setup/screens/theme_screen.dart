import 'package:flutter/material.dart';
import '../../theme/nexusq_theme.dart';
import '../setup_flow.dart';

/// Mirrors the device bridge's THEME_CMDS hues exactly (PROTOCOL.md /
/// nq-bridge theme table): blue #0099CC, warm 255/90/10, cool 0/200/140,
/// rose 255/40/90, smoke 110/115/135, off.
const _themes = [
  ('blue', 'Blue', Color(0xFF0099CC)),
  ('warm', 'Warm', Color(0xFFFF5A0A)),
  ('cool', 'Cool', Color(0xFF00C88C)),
  ('rose', 'Rose', Color(0xFFFF285A)),
  ('smoke', 'Smoke', Color(0xFF6E7387)),
  ('off', 'Off', Color(0xFF222222)),
];

class ThemeScreen extends StatefulWidget {
  const ThemeScreen(
      {super.key, required this.flow, required this.onNext, required this.onBack});
  final SetupFlowState flow;
  final VoidCallback onNext;
  final VoidCallback onBack;

  @override
  State<ThemeScreen> createState() => _ThemeScreenState();
}

class _ThemeScreenState extends State<ThemeScreen> {
  String? _selected;

  Future<void> _pick(String theme) async {
    setState(() => _selected = theme);
    try {
      await widget.flow.client.call('setTheme', {'theme': theme});
      if (!mounted) return;
      widget.flow.theme = theme;
    } catch (_) {
      // theme preview failing must not block setup
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(32),
      child: Column(
        children: [
          const SizedBox(height: 16),
          const Text('Pick a light theme',
              style: TextStyle(color: NexusQColors.white, fontSize: 22, fontWeight: FontWeight.w300)),
          const SizedBox(height: 8),
          const Text('The ring previews your choice live.',
              style: TextStyle(color: NexusQColors.dim, fontSize: 13)),
          const SizedBox(height: 24),
          Expanded(
            child: GridView.count(
              crossAxisCount: 3,
              mainAxisSpacing: 16,
              crossAxisSpacing: 16,
              children: [
                for (final (id, label, color) in _themes)
                  InkWell(
                    onTap: () => _pick(id),
                    child: Column(
                      children: [
                        Container(
                          width: 64,
                          height: 64,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: color,
                            border: Border.all(
                                color: _selected == id
                                    ? NexusQColors.white
                                    : Colors.transparent,
                                width: 2),
                          ),
                        ),
                        const SizedBox(height: 8),
                        Text(label,
                            style: const TextStyle(color: NexusQColors.dim, fontSize: 12)),
                      ],
                    ),
                  ),
              ],
            ),
          ),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              TextButton(onPressed: widget.onBack, child: const Text('Back')),
              FilledButton(onPressed: widget.onNext, child: const Text('Next')),
            ],
          ),
        ],
      ),
    );
  }
}
