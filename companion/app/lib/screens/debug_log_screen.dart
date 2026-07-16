import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../build_info.dart';
import '../debug/app_log.dart';
import '../theme/nexusq_theme.dart';

/// The debug-mode log viewer: the phone's side of the connection story.
///
/// Newest entries at the top (the flicker the user just saw is the first thing
/// on screen). Copy puts the whole buffer on the clipboard so it can be pasted
/// into a chat/issue verbatim.
class DebugLogScreen extends StatelessWidget {
  const DebugLogScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Debug log'),
        backgroundColor: Colors.transparent,
        actions: [
          IconButton(
            icon: const Icon(Icons.copy),
            tooltip: 'Copy all',
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: AppLog.dump()));
              if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Log copied to clipboard')));
              }
            },
          ),
          IconButton(
            icon: const Icon(Icons.delete_outline),
            tooltip: 'Clear',
            onPressed: AppLog.clear,
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            child: Row(
              children: [
                const Text(kBuildLabel,
                    style: TextStyle(color: NexusQColors.dim, fontSize: 11)),
                const Spacer(),
                ValueListenableBuilder<int>(
                  valueListenable: AppLog.revision,
                  builder: (_, _, _) => Text('${AppLog.snapshot().length} entries',
                      style: const TextStyle(color: NexusQColors.dim, fontSize: 11)),
                ),
              ],
            ),
          ),
          const Divider(height: 1, color: NexusQColors.divider),
          Expanded(
            child: ValueListenableBuilder<int>(
              valueListenable: AppLog.revision,
              builder: (context, _, _) {
                final items = AppLog.snapshot().reversed.toList();
                if (items.isEmpty) {
                  return const Center(
                      child: Text('Nothing logged yet',
                          style: TextStyle(color: NexusQColors.dim)));
                }
                return ListView.builder(
                  itemCount: items.length,
                  itemBuilder: (_, i) {
                    final e = items[i];
                    return Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
                      child: Text(
                        e.format(),
                        style: TextStyle(
                          color: e.warn ? Colors.orangeAccent : NexusQColors.dim,
                          fontSize: 11,
                          fontFamily: 'monospace',
                        ),
                      ),
                    );
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
