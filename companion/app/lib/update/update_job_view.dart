// The progress of an install job on the Q (PROTOCOL §12d): what it is doing,
// how far it is, what it is at and how long it has left — in the colours the
// Q's ring uses for the same phase, so the phone and the room agree.
import 'package:flutter/material.dart';

import '../theme/nexusq_theme.dart';
import 'update_job.dart';

class UpdateJobProgressView extends StatelessWidget {
  const UpdateJobProgressView({
    super.key,
    required this.job,
    required this.linkUp,
  });

  final UpdateJob job;

  /// False while the link to the Q is down: the job restarts the bridge, and
  /// a reboot takes the Q away for a minute. The last progress stays shown.
  final bool linkUp;

  Color get _barColor => switch (job.phase) {
    UpdatePhase.downloading => NexusQColors.otaDownload,
    UpdatePhase.installing => NexusQColors.otaInstall,
    _ => NexusQColors.accent,
  };

  @override
  Widget build(BuildContext context) {
    final detail = job.detail;
    return Semantics(
      label: '${job.headline}, ${job.percent} percent',
      value: detail,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  job.headline,
                  style: const TextStyle(
                    color: NexusQColors.white,
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              Text(
                '${job.percent}%',
                style: TextStyle(
                  color: _barColor,
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          ClipRRect(
            borderRadius: const BorderRadius.all(Radius.circular(4)),
            child: TweenAnimationBuilder<double>(
              // Events come about twice a second; ease between them so the
              // bar moves instead of stepping.
              tween: Tween(end: job.fraction),
              duration: const Duration(milliseconds: 450),
              curve: Curves.easeOut,
              builder: (context, value, _) => LinearProgressIndicator(
                value: value,
                minHeight: 8,
                color: _barColor,
                backgroundColor: NexusQColors.divider,
              ),
            ),
          ),
          if (detail.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(
              detail,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: NexusQColors.dim, fontSize: 12),
            ),
          ],
          if (job.stalled) ...[
            const SizedBox(height: 6),
            const Text(
              'No progress for a while. The Q keeps going — leave it powered.',
              style: TextStyle(color: Colors.orangeAccent, fontSize: 12),
            ),
          ],
          if (!linkUp) ...[
            const SizedBox(height: 6),
            const Text(
              'Waiting for the Q to answer…',
              style: TextStyle(
                color: NexusQColors.dim,
                fontSize: 12,
                fontStyle: FontStyle.italic,
              ),
            ),
          ],
          const SizedBox(height: 4),
          const Text(
            'You can close the app — the Q finishes on its own, and its ring '
            'shows how far it is.',
            style: TextStyle(color: NexusQColors.dim, fontSize: 11),
          ),
        ],
      ),
    );
  }
}
