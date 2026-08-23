import 'dart:async';
import 'package:flutter/material.dart';
import '../protocol/client.dart';
import '../theme/nexusq_theme.dart';

/// Hardware equalizer card (PROTOCOL §14): bass + treble shelving sliders,
/// executed by the TAS5713 amplifier's own DSP on the device — one EQ for
/// every source, no CPU cost, no added latency.
///
/// Self-contained like the health panel: loads `getEq` on mount, pushes
/// `setEq` at the end of each slider gesture (not per tick — every send is an
/// I2C coefficient write on the amp), and reconciles from `eqChanged` events
/// so several open apps agree. On a kernel without the biquad controls
/// (`supported=false`, pre-r49) the sliders render disabled with a hint
/// instead of hiding — the feature stays discoverable.
class EqCard extends StatefulWidget {
  const EqCard({super.key, required this.client});
  final NexusQClient client;

  @override
  State<EqCard> createState() => _EqCardState();
}

class _EqCardState extends State<EqCard> {
  static const double _maxDb = 12;

  bool _loaded = false;
  bool _supported = false;
  double _bass = 0;
  double _treble = 0;
  bool _sending = false;
  String? _error;
  StreamSubscription? _evSub;

  @override
  void initState() {
    super.initState();
    _load();
    _evSub = widget.client.events.listen((e) {
      if (e.event != 'eqChanged' || !mounted) return;
      setState(() => _apply(e.data));
    });
  }

  @override
  void dispose() {
    _evSub?.cancel();
    super.dispose();
  }

  void _apply(Map<String, dynamic> d) {
    if (d['supported'] is bool) _supported = d['supported'] as bool;
    if (d['bass_db'] is num) _bass = (d['bass_db'] as num).toDouble();
    if (d['treble_db'] is num) _treble = (d['treble_db'] as num).toDouble();
  }

  Future<void> _load() async {
    try {
      final r = await widget.client.call('getEq');
      if (!mounted) return;
      setState(() {
        _apply(r);
        _loaded = true;
        _error = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loaded = true;
        _error = 'EQ unavailable: $e';
      });
    }
  }

  Future<void> _send(Map<String, dynamic> params) async {
    if (_sending) return;
    setState(() {
      _sending = true;
      _error = null;
    });
    try {
      final r = await widget.client.call('setEq', params);
      if (!mounted) return;
      setState(() => _apply(r));
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = 'EQ write failed: $e');
      _load(); // resync the sliders with what the amp actually runs
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  String _fmtDb(double v) =>
      '${v >= 0 ? '+' : '−'}${v.abs().toStringAsFixed(1)} dB';

  Widget _slider(String label, IconData icon, double value,
      ValueChanged<double> onLocal, VoidCallback onDone) {
    final enabled = _loaded && _supported && !_sending;
    return Row(
      children: [
        Icon(icon, size: 20, color: enabled ? NexusQColors.accent : NexusQColors.dim),
        const SizedBox(width: 8),
        SizedBox(
          width: 48,
          child: Text(label,
              style: const TextStyle(color: NexusQColors.white, fontSize: 13)),
        ),
        Expanded(
          child: Slider(
            value: value,
            min: -_maxDb,
            max: _maxDb,
            divisions: 48, // 0.5 dB steps
            onChanged: enabled ? onLocal : null,
            onChangeEnd: enabled ? (_) => onDone() : null,
          ),
        ),
        SizedBox(
          width: 62,
          child: Text(_fmtDb(value),
              textAlign: TextAlign.right,
              style: TextStyle(
                  color: value.abs() < 0.05 ? NexusQColors.dim : NexusQColors.white,
                  fontSize: 12,
                  fontFeatures: const [FontFeature.tabularFigures()])),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final flat = _bass.abs() < 0.05 && _treble.abs() < 0.05;
    return Card(
      color: NexusQColors.surface,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Expanded(
                  child: Text('Equalizer',
                      style: TextStyle(color: NexusQColors.white)),
                ),
                TextButton(
                  onPressed: (_loaded && _supported && !_sending && !flat)
                      ? () {
                          setState(() {
                            _bass = 0;
                            _treble = 0;
                          });
                          _send({'bass_db': 0, 'treble_db': 0});
                        }
                      : null,
                  style: TextButton.styleFrom(
                      foregroundColor: NexusQColors.accent,
                      minimumSize: const Size(0, 32),
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap),
                  child: const Text('Flat'),
                ),
              ],
            ),
            if (!_loaded)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 12),
                child: Text('Loading…',
                    style: TextStyle(color: NexusQColors.dim, fontSize: 13)),
              )
            else ...[
              _slider('Bass', Icons.graphic_eq, _bass,
                  (v) => setState(() => _bass = v),
                  () => _send({'bass_db': _bass})),
              _slider('Treble', Icons.music_note_outlined, _treble,
                  (v) => setState(() => _treble = v),
                  () => _send({'treble_db': _treble})),
              Padding(
                padding: const EdgeInsets.only(top: 2, bottom: 4),
                child: Text(
                  _error ??
                      (!_supported
                          ? 'Needs a device system update (kernel r49+) — '
                              'run Update below, then reboot the Q.'
                          : 'Runs in the amplifier hardware — applies to every '
                              'source, costs no CPU and adds no delay.'),
                  style: TextStyle(
                      color: _error != null
                          ? Colors.orangeAccent
                          : NexusQColors.dim,
                      fontSize: 11),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
