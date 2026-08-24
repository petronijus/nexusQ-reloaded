import 'dart:async';

import 'package:flutter/material.dart';

import '../models/eq.dart';
import '../protocol/client.dart';
import '../theme/nexusq_theme.dart';
import 'eq_curve.dart';

/// Hardware equalizer (PROTOCOL §14): a 7-band parametric EQ executed by the
/// TAS5713 amplifier's own DSP — one EQ for every source, no CPU cost, no added
/// latency.
///
/// Every gesture round-trips through `setEq` and the card renders the reply, so
/// what you see is what the amplifier runs. Sends fire on release, never per
/// tick: each one is an I2C coefficient write across 14 registers.
///
/// Against a daemon that predates the parametric verbs the reply has no `bands`
/// array; the card then builds the two shelves locally from `bass_db`/
/// `treble_db` and commits in the old shape. Same curve, two handles instead of
/// seven — an app updated ahead of its device still has a working EQ.
class EqCard extends StatefulWidget {
  const EqCard({super.key, required this.client, this.compact = false});
  final NexusQClient client;

  /// Home-screen form: curve + presets, no per-band editing.
  final bool compact;

  @override
  State<EqCard> createState() => _EqCardState();
}

class _EqCardState extends State<EqCard> {
  EqState _st = EqState.empty;
  List<EqPreset> _presets = const [];
  int _selected = 0;
  bool _loaded = false;
  bool _sending = false;
  String? _error;
  StreamSubscription? _evSub;

  @override
  void initState() {
    super.initState();
    _load();
    _evSub = widget.client.events.listen((e) {
      if (e.event != 'eqChanged' || !mounted || _sending) return;
      setState(() => _st = _hydrate(e.data));
    });
  }

  @override
  void dispose() {
    _evSub?.cancel();
    super.dispose();
  }

  /// Reply -> state, inventing the two legacy shelves when the daemon is old.
  EqState _hydrate(Map<String, dynamic> d) {
    final s = EqState.fromJson(d);
    if (s.isParametric || !s.supported) return s;
    final bass = (d['bass_db'] as num?)?.toDouble() ?? 0;
    final treble = (d['treble_db'] as num?)?.toDouble() ?? 0;
    return s.copyWith(bands: [
      EqBand(type: 'lowshelf', freqHz: 100, gainDb: bass, q: 1),
      EqBand(type: 'highshelf', freqHz: 8000, gainDb: treble, q: 1),
    ]);
  }

  /// True when the daemon answered `getEq` without a `bands` array — the
  /// pre-parametric build. Drives both the hint and the commit shape.
  bool _legacyDaemon = false;

  Future<void> _load() async {
    try {
      final r = await widget.client.call('getEq');
      List<EqPreset> presets = const [];
      try {
        final p = await widget.client.call('listEqPresets');
        presets = (p['presets'] as List?)
                ?.whereType<Map>()
                .map((m) => EqPreset.fromJson(m.cast<String, dynamic>()))
                .toList() ??
            const [];
      } catch (_) {
        // Old daemon: no presets. Not an error — the EQ still works.
      }
      if (!mounted) return;
      setState(() {
        _legacyDaemon = (r['bands'] as List?) == null;
        _st = _hydrate(r);
        _presets = presets;
        _selected = 0;
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
      setState(() => _st = _hydrate(r));
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = 'EQ write failed: $e');
      _load(); // resync with what the amp actually runs
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  void _commit() {
    if (_legacyDaemon) {
      _send({
        'bass_db': _st.bands[0].gainDb,
        'treble_db': _st.bands.length > 1 ? _st.bands[1].gainDb : 0.0,
      });
    } else {
      _send({
        'bands': _st.bands.map((b) => b.toJson()).toList(),
        'preamp_db': _st.preampDb,
      });
    }
  }

  void _editBand(int i, {double? freqHz, double? gainDb, double? q}) {
    final bands = [..._st.bands];
    // A shelf that can be dragged across the whole spectrum is a foot-gun; keep
    // the outer bands in the half they belong to.
    double? f = freqHz;
    if (f != null && bands[i].isShelf) {
      f = bands[i].type == 'lowshelf' ? f.clamp(20.0, 1000.0) : f.clamp(1000.0, 20000.0);
    }
    bands[i] = bands[i].copyWith(freqHz: f, gainDb: gainDb, q: q);
    setState(() => _st = _st.copyWith(bands: bands));
  }

  String _fmtDb(double v) =>
      '${v >= 0 ? '+' : '−'}${v.abs().toStringAsFixed(1)} dB';

  String _fmtHz(double f) =>
      f >= 1000 ? '${(f / 1000).toStringAsFixed(f >= 10000 ? 0 : 1)} kHz' : '${f.round()} Hz';

  Widget _hint() {
    final clipping = _st.headroomDb > 0.1;
    final String text;
    Color color = NexusQColors.dim;
    if (_error != null) {
      text = _error!;
      color = Colors.orangeAccent;
    } else if (!_st.supported) {
      text = 'Needs a device system update (kernel r50+) — run Update in '
          'Settings, then reboot the Q.';
    } else if (_legacyDaemon) {
      text = 'Device software predates the parametric EQ — bass and treble only. '
          'Update the Q for all seven bands.';
    } else if (clipping) {
      text = 'Boosted by ${_fmtDb(_st.headroomDb)} overall — loud material can '
          'clip. Tap auto to pull the preamp down.';
      color = Colors.orangeAccent;
    } else {
      text = 'Runs in the amplifier hardware — applies to every source, costs no '
          'CPU and adds no delay.';
    }
    return Padding(
      padding: const EdgeInsets.only(top: 6, bottom: 2),
      child: Text(text, style: TextStyle(color: color, fontSize: 11)),
    );
  }

  Widget _presetChips() {
    if (_presets.isEmpty) return const SizedBox.shrink();
    final enabled = _loaded && _st.supported && !_sending;
    return SizedBox(
      height: 36,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: _presets.length,
        separatorBuilder: (_, _) => const SizedBox(width: 6),
        itemBuilder: (context, i) {
          final p = _presets[i];
          return ActionChip(
            label: Text(p.label, style: const TextStyle(fontSize: 12)),
            backgroundColor: NexusQColors.surface,
            side: BorderSide(color: NexusQColors.dim.withValues(alpha: 0.4)),
            onPressed: enabled
                ? () {
                    setState(() {
                      _st = _st.copyWith(bands: p.bands, preampDb: p.preampDb);
                      _selected = 0;
                    });
                    _commit();
                  }
                : null,
          );
        },
      ),
    );
  }

  Widget _bandEditor() {
    if (_st.bands.isEmpty) return const SizedBox.shrink();
    final i = _selected.clamp(0, _st.bands.length - 1);
    final b = _st.bands[i];
    final enabled = _loaded && _st.supported && !_sending;
    final label = b.type == 'peaking'
        ? 'Band ${i + 1}'
        : (b.type == 'lowshelf' ? 'Low shelf' : 'High shelf');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text('$label · ${_fmtHz(b.freqHz)}',
                style: const TextStyle(color: NexusQColors.white, fontSize: 13)),
            const Spacer(),
            Text(_fmtDb(b.gainDb),
                style: TextStyle(
                    color: b.isFlat ? NexusQColors.dim : NexusQColors.white,
                    fontSize: 12,
                    fontFeatures: const [FontFeature.tabularFigures()])),
          ],
        ),
        Row(
          children: [
            SizedBox(
              width: 58,
              child: Text(b.isShelf ? 'Slope' : 'Width',
                  style: const TextStyle(color: NexusQColors.dim, fontSize: 12)),
            ),
            Expanded(
              child: Slider(
                value: b.q.clamp(_st.minQ, _st.maxQ),
                min: _st.minQ,
                max: _st.maxQ,
                onChanged: enabled ? (v) => _editBand(i, q: v) : null,
                onChangeEnd: enabled ? (_) => _commit() : null,
              ),
            ),
            SizedBox(
              width: 40,
              child: Text(b.q.toStringAsFixed(2),
                  textAlign: TextAlign.right,
                  style: const TextStyle(
                      color: NexusQColors.dim,
                      fontSize: 11,
                      fontFeatures: [FontFeature.tabularFigures()])),
            ),
          ],
        ),
      ],
    );
  }

  Widget _preampRow() {
    final enabled = _loaded && _st.supported && !_sending && !_legacyDaemon;
    return Row(
      children: [
        const SizedBox(
          width: 58,
          child: Text('Preamp',
              style: TextStyle(color: NexusQColors.dim, fontSize: 12)),
        ),
        Expanded(
          child: Slider(
            value: _st.preampDb.clamp(_st.minPreampDb, 0),
            min: _st.minPreampDb,
            max: 0,
            onChanged:
                enabled ? (v) => setState(() => _st = _st.copyWith(preampDb: v)) : null,
            onChangeEnd: enabled ? (_) => _commit() : null,
          ),
        ),
        SizedBox(
          width: 56,
          child: Text(_fmtDb(_st.preampDb),
              textAlign: TextAlign.right,
              style: const TextStyle(
                  color: NexusQColors.dim,
                  fontSize: 11,
                  fontFeatures: [FontFeature.tabularFigures()])),
        ),
        TextButton(
          onPressed: enabled && _st.headroomDb > 0.1
              ? () => _send({
                    'bands': _st.bands.map((b) => b.toJson()).toList(),
                    'auto_preamp': true,
                  })
              : null,
          style: TextButton.styleFrom(
              foregroundColor: NexusQColors.accent,
              minimumSize: const Size(0, 32),
              padding: const EdgeInsets.symmetric(horizontal: 8),
              tapTargetSize: MaterialTapTargetSize.shrinkWrap),
          child: const Text('auto'),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final enabled = _loaded && _st.supported && !_sending;
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
                  onPressed: enabled && !_st.isFlat
                      ? () {
                          final flat = _presets.isNotEmpty
                              ? _presets
                                  .firstWhere((p) => p.id == 'flat',
                                      orElse: () => _presets.first)
                                  .bands
                              : _st.bands
                                  .map((b) => b.copyWith(gainDb: 0))
                                  .toList();
                          setState(() =>
                              _st = _st.copyWith(bands: flat, preampDb: 0));
                          _commit();
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
                padding: EdgeInsets.symmetric(vertical: 24),
                child: Text('Loading…',
                    style: TextStyle(color: NexusQColors.dim, fontSize: 13)),
              )
            else ...[
              EqCurve(
                state: _st,
                selected: _selected,
                enabled: enabled,
                height: widget.compact ? 140 : 190,
                onSelect: (i) => setState(() => _selected = i),
                onChanged: (i, f, g) => _editBand(i, freqHz: f, gainDb: g),
                onCommit: _commit,
              ),
              const SizedBox(height: 4),
              _presetChips(),
              if (!widget.compact) ...[
                const SizedBox(height: 4),
                _bandEditor(),
                if (!_legacyDaemon) _preampRow(),
              ],
              _hint(),
            ],
          ],
        ),
      ),
    );
  }
}
