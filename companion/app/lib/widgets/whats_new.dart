import 'package:flutter/material.dart';

import '../theme/nexusq_theme.dart';
import '../update/release.dart';
import '../update/release_icons.dart';

/// A release's "what's new": the headline, then each item as a coloured icon
/// badge with a bold title and one sentence. Short on purpose; the CHANGELOG is
/// where the engineering lives.
class WhatsNewList extends StatelessWidget {
  const WhatsNewList({super.key, required this.release});

  final Release release;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          release.headline,
          style: const TextStyle(
            color: NexusQColors.white,
            fontSize: 16,
            fontWeight: FontWeight.w600,
            height: 1.25,
          ),
        ),
        const SizedBox(height: 14),
        for (final item in release.items) ...[
          _Item(item: item),
          const SizedBox(height: 12),
        ],
      ],
    );
  }
}

class _Item extends StatelessWidget {
  const _Item({required this.item});

  final ReleaseItem item;

  @override
  Widget build(BuildContext context) {
    final color = releaseIconColor(item.icon);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 36,
          height: 36,
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.16),
            shape: BoxShape.circle,
          ),
          child: Icon(releaseIcon(item.icon), color: color, size: 20),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                item.title,
                style: const TextStyle(
                  color: NexusQColors.white,
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                item.text,
                style: const TextStyle(
                  color: NexusQColors.dim,
                  fontSize: 13,
                  height: 1.3,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// The version as a small accent pill, e.g. "2.0.0".
class ReleaseVersionPill extends StatelessWidget {
  const ReleaseVersionPill({super.key, required this.version});

  final String version;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: NexusQColors.accent.withValues(alpha: 0.18),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(
        version,
        style: const TextStyle(
          color: NexusQColors.accent,
          fontSize: 12,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

/// A bottom sheet with a release's "what's new". [installed] titles it for a
/// release this Q already runs ("What's new"); otherwise it offers
/// [onUpdate] ("Update now") for one it waits for.
Future<void> showWhatsNewSheet(
  BuildContext context, {
  required String deviceName,
  required Release release,
  required bool installed,
  VoidCallback? onUpdate,
}) {
  return showModalBottomSheet<void>(
    context: context,
    backgroundColor: NexusQColors.surface,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (ctx) => SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    installed ? "What's new" : 'Update ready',
                    style: const TextStyle(
                      color: NexusQColors.white,
                      fontSize: NexusQSpace.titleSize,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                ReleaseVersionPill(version: release.version),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              installed
                  ? '$deviceName now runs Nexus Q ${release.version}.'
                  : '$deviceName can update to Nexus Q ${release.version}.',
              style: const TextStyle(color: NexusQColors.dim, fontSize: 13),
            ),
            const SizedBox(height: 18),
            WhatsNewList(release: release),
            const SizedBox(height: 8),
            SizedBox(
              width: double.infinity,
              child: installed || onUpdate == null
                  ? FilledButton(
                      onPressed: () => Navigator.of(ctx).pop(),
                      child: const Text('Nice'),
                    )
                  : FilledButton.icon(
                      onPressed: () {
                        Navigator.of(ctx).pop();
                        onUpdate();
                      },
                      icon: const Icon(Icons.download, size: 18),
                      label: const Text('Update now'),
                    ),
            ),
          ],
        ),
      ),
    ),
  );
}
