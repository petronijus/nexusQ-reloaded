import 'package:flutter/material.dart';
import '../../theme/nexusq_theme.dart';
import '../bt_setup_client.dart';
import '../setup_flow.dart';
import '../stock_assets.dart';

const _rooms = [
  ('livingroom', 'Living room'), ('bedroom', 'Bedroom'), ('kitchen', 'Kitchen'),
  ('diningroom', 'Dining room'), ('familyroom', 'Family room'), ('mediaroom', 'Media room'),
  ('office', 'Office'), ('garage', 'Garage'), ('bathroom', 'Bathroom'), ('closet', 'Closet'),
];

/// Maps a room id to its stock icon asset filename. Every id matches the
/// extracted `ic_menu_location_<id>.png` name except `kitchen`, whose real
/// apktool asset is `ic_menu_location_kitchenroom.png` (see task-11-report.md
/// reconciliation table) — the device-facing room id sent via `setName`
/// stays the semantic `kitchen`.
String _roomIconAsset(String id) =>
    'ic_menu_location_${id == 'kitchen' ? 'kitchenroom' : id}.png';

class NameRoomScreen extends StatefulWidget {
  const NameRoomScreen(
      {super.key, required this.flow, required this.onNext, required this.onBack});
  final SetupFlowState flow;
  final VoidCallback onNext;
  final VoidCallback onBack;

  @override
  State<NameRoomScreen> createState() => _NameRoomScreenState();
}

class _NameRoomScreenState extends State<NameRoomScreen> {
  late final _name = TextEditingController(text: widget.flow.deviceName);
  String _room = '';
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _apply() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final r = await widget.flow.client.call('setName', {'name': _name.text.trim(), 'room': _room});
      if (!mounted) return;
      widget.flow.deviceName = _name.text.trim();
      widget.flow.room = _room;
      // setName changes the device's hostname, so its mDNS name changes too:
      // refresh the flow's cached wifiResult with the fresh value from the
      // response so the outro screen doesn't fall back to the stale
      // pre-rename mdns when ip is null.
      final freshMdns = r['mdns'] as String?;
      if (freshMdns != null && widget.flow.wifiResult != null) {
        widget.flow.wifiResult!['mdns'] = freshMdns;
      }
      widget.onNext();
    } on BtSetupError catch (e) {
      if (!mounted) return;
      setState(() => _error = 'Could not set the name: ${e.message}');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(32),
      child: Column(
        children: [
          const SizedBox(height: 16),
          const Text('Name your Nexus Q',
              style: TextStyle(color: NexusQColors.white, fontSize: 22, fontWeight: FontWeight.w300)),
          const SizedBox(height: 16),
          TextField(
            controller: _name,
            style: const TextStyle(color: NexusQColors.white),
            decoration: const InputDecoration(labelText: 'Device name'),
          ),
          const SizedBox(height: 8),
          if (_error != null)
            Text(_error!, style: const TextStyle(color: Colors.redAccent, fontSize: 13)),
          const SizedBox(height: 8),
          Expanded(
            child: GridView.count(
              crossAxisCount: 3,
              children: [
                for (final (id, label) in _rooms)
                  InkWell(
                    onTap: () => setState(() => _room = id),
                    child: Container(
                      decoration: BoxDecoration(
                        border: Border.all(
                            color: _room == id ? NexusQColors.accent : Colors.transparent),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      padding: const EdgeInsets.all(8),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          stockImage(_roomIconAsset(id), width: 40, fallback: Icons.home),
                          const SizedBox(height: 6),
                          Text(label,
                              textAlign: TextAlign.center,
                              style: const TextStyle(color: NexusQColors.dim, fontSize: 11)),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
          ),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              TextButton(onPressed: widget.onBack, child: const Text('Back')),
              FilledButton(
                  onPressed: _busy || _room.isEmpty ? null : _apply, child: const Text('Next')),
            ],
          ),
        ],
      ),
    );
  }
}
