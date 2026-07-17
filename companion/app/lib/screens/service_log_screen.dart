import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../protocol/client.dart';
import '../theme/nexusq_theme.dart';

/// The recent journal of one streaming service (Spotify / AirPlay / Roon), pulled
/// live from the device via `serviceLog`. Read-only: it is the "what is this
/// service actually doing" window next to its on/off switch. Newest lines are at
/// the bottom (journal order); the view starts scrolled there.
class ServiceLogScreen extends StatefulWidget {
  const ServiceLogScreen(
      {super.key, required this.client, required this.id, required this.name});
  final NexusQClient client;
  final String id;
  final String name;

  @override
  State<ServiceLogScreen> createState() => _ServiceLogScreenState();
}

class _ServiceLogScreenState extends State<ServiceLogScreen> {
  List<String> _lines = [];
  bool _loading = true;
  String? _error;
  final _scroll = ScrollController();

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final r = await widget.client
          .call('serviceLog', {'id': widget.id, 'lines': 300});
      if (!mounted) return;
      setState(() {
        _lines = (r['lines'] as List? ?? []).map((e) => '$e').toList();
        _error = null;
        _loading = false;
      });
      // Jump to the newest line once the list has laid out.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_scroll.hasClients) {
          _scroll.jumpTo(_scroll.position.maxScrollExtent);
        }
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = 'Could not load the log — is the service reachable?';
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('${widget.name} log'),
        backgroundColor: Colors.transparent,
        actions: [
          IconButton(
            icon: const Icon(Icons.copy),
            tooltip: 'Copy all',
            onPressed: _lines.isEmpty
                ? null
                : () async {
                    await Clipboard.setData(
                        ClipboardData(text: _lines.join('\n')));
                    if (context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                          content: Text('Log copied to clipboard')));
                    }
                  },
          ),
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Refresh',
            onPressed: _loading ? null : _load,
          ),
        ],
      ),
      body: _body(),
    );
  }

  Widget _body() {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return Center(
          child: Text(_error!,
              style: const TextStyle(color: NexusQColors.dim)));
    }
    if (_lines.isEmpty) {
      return const Center(
          child: Text('No log entries yet',
              style: TextStyle(color: NexusQColors.dim)));
    }
    return ListView.builder(
      controller: _scroll,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      itemCount: _lines.length,
      itemBuilder: (_, i) {
        final l = _lines[i];
        final warn = l.contains('Warn') ||
            l.contains('Error') ||
            l.contains('error') ||
            l.contains('failed');
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 2),
          child: Text(
            l,
            style: TextStyle(
              color: warn ? Colors.orangeAccent : NexusQColors.dim,
              fontSize: 11,
              fontFamily: 'monospace',
            ),
          ),
        );
      },
    );
  }
}
