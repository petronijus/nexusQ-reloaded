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
  const EqCard({super.key, required this.client, this.armed, this.curveKey});
  final NexusQClient client;

  /// Which band owns gestures, or null when the page may scroll. Shared with
  /// the host so it can freeze its scrollable while a band is armed; the card
  /// makes its own if it has no host to cooperate with.
  final ValueNotifier<int?>? armed;

  /// Attached to the plot so the host can tell a tap inside from one outside.
  final Key? curveKey;

  @override
  State<EqCard> createState() => _EqCardState();
}

class _EqCardState extends State<EqCard> {
  EqState _st = EqState.empty;
  List<EqPreset> _presets = const [];

  /// Whether the device can store presets of its own. A daemon that predates
  /// saveEqPreset marks nothing `builtin`, and there is no point offering a
  /// save button that can only fail. (PROTOCOL §14.5)
  bool _presetsEditable = false;
  int _selected = 0;
  bool _loaded = false;
  bool _sending = false;
  Map<String, dynamic>? _pending;
  String? _error;
  StreamSubscription? _evSub;
  StreamSubscription? _connSub;

  @override
  void initState() {
    super.initState();
    _load();
    _evSub = widget.client.events.listen((e) {
      if (!mounted) return;
      if (e.event == 'eqPresetsChanged') {
        // Another client — or another phone — saved or deleted one.
        final list = _parsePresets(e.data);
        if (list != null) setState(() => _presets = list);
        return;
      }
      if (e.event != 'eqChanged' || _sending || _pending != null) return;
      setState(() => _st = _hydrate(e.data));
    });
    // The card mounts before the link is up, so the first getEq usually fails
    // with "not connected". That is not an EQ fault and must not be reported as
    // one — wait for the link and load then.
    _connSub = widget.client.connection.listen((up) {
      if (!mounted) return;
      if (up) {
        _load();
      } else {
        setState(() => _loaded = false);
      }
    });
  }

  @override
  void dispose() {
    _evSub?.cancel();
    _connSub?.cancel();
    if (widget.armed == null) _armed.dispose();
    super.dispose();
  }

  /// Reply -> state, inventing the two legacy shelves when the daemon is old.
  EqState _hydrate(Map<String, dynamic> d) {
    var s = EqState.fromJson(d);
    // `supported` comes from an amixer probe on the device; a transient failure
    // in one reply must not permanently disable a card that was working.
    if (!s.supported && _st.supported && _loaded) {
      s = EqState.fromJson({...d, 'supported': true});
    }
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
  late final ValueNotifier<int?> _armed = widget.armed ?? ValueNotifier<int?>(null);

  /// A `presets` payload -> models, or null when it carries none. Also decides
  /// whether this daemon can save: it can exactly when it bothered to tell us
  /// which of the presets are built in.
  List<EqPreset>? _parsePresets(Map<String, dynamic> d) {
    final raw = (d['presets'] as List?)?.whereType<Map>().toList();
    if (raw == null) return null;
    _presetsEditable = raw.any((m) => m.containsKey('builtin'));
    return raw.map((m) => EqPreset.fromJson(m.cast<String, dynamic>())).toList();
  }

  Future<void> _load() async {
    try {
      final r = await widget.client.call('getEq');
      List<EqPreset> presets = const [];
      // Re-decided from this reply alone: a device that got downgraded must not
      // keep a save button it can no longer honour.
      _presetsEditable = false;
      try {
        presets =
            _parsePresets(await widget.client.call('listEqPresets')) ?? const [];
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
      // Includes the ordinary "not connected" on a cold mount. Stay in the
      // waiting state rather than accusing the EQ; the connection banner above
      // already says what is wrong, and _connSub will retry.
      if (!mounted) return;
      setState(() => _loaded = false);
    }
  }

  /// One write at a time, but never drop one: a setEq is ~300 ms (fourteen I2C
  /// coefficient writes), and dropping whatever arrives during it is what made
  /// the card feel dead after the first drag. Later gestures supersede earlier
  /// ones — only the newest queued state is worth sending, since each carries
  /// the whole EQ.
  Future<void> _send(Map<String, dynamic> params) async {
    if (_sending) {
      _pending = params;
      return;
    }
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
      if (mounted) {
        setState(() => _sending = false);
        final next = _pending;
        _pending = null;
        if (next != null) _send(next);
      }
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

  /// Band frequencies are fixed — only gain and width are user-editable, so a
  /// drag cannot silently retune a band.
  void _editBand(int i, {double? gainDb, double? q}) {
    final bands = [..._st.bands];
    bands[i] = bands[i].copyWith(gainDb: gainDb, q: q);
    setState(() => _st = _st.copyWith(bands: bands));
  }

  String _fmtDb(double v) =>
      '${v >= 0 ? '+' : '−'}${v.abs().toStringAsFixed(1)} dB';

  String _fmtHz(double f) =>
      f >= 1000 ? '${(f / 1000).toStringAsFixed(f >= 10000 ? 0 : 1)} kHz' : '${f.round()} Hz';

  /// Problems only. The line used to explain, permanently, that the EQ runs in
  /// the amplifier — true, but it is a fact you read once, and it sat under the
  /// card forever after. Nothing wrong means nothing shown.
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
      return const SizedBox.shrink();
    }
    return Padding(
      padding: const EdgeInsets.only(top: 6, bottom: 2),
      child: Text(text, style: TextStyle(color: color, fontSize: 11)),
    );
  }

  /// Every band to 0 dB and the preamp with it. Widths are left alone — a reset
  /// that also threw away tuned Q values would be a bigger hammer than the
  /// button reads as.
  void _resetFlat() {
    setState(() => _st = _st.copyWith(
        bands: _st.bands.map((b) => b.copyWith(gainDb: 0)).toList(),
        preampDb: 0));
    _commit();
  }

  void _applyPreset(EqPreset p) {
    setState(() {
      _st = _st.copyWith(bands: p.bands, preampDb: p.preampDb);
      _selected = 0;
    });
    _commit();
  }

  /// saveEqPreset and deleteEqPreset both answer with the whole list, so one
  /// helper covers both: send, adopt the reply, and surface a failure in the
  /// hint line rather than a toast that scrolls away unseen.
  Future<void> _presetCall(String method, Map<String, dynamic> params) async {
    try {
      final r = await widget.client.call(method, params);
      if (!mounted) return;
      final list = _parsePresets(r);
      setState(() {
        if (list != null) _presets = list;
        _error = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = '$e');
    }
  }

  /// Sends the bands the CARD is showing, not the device's idea of them: a
  /// gesture can still be queued behind a ~300 ms write, and saving what the
  /// user is looking at is the only answer that is never surprising.
  Future<void> _savePreset() async {
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => _SavePresetDialog(existingUserIds: {
        for (final p in _presets)
          if (!p.builtin) p.id,
      }),
    );
    if (name == null || !mounted) return;
    await _presetCall('saveEqPreset', {
      'name': name,
      'bands': _st.bands.map((b) => b.toJson()).toList(),
      'preamp_db': _st.preampDb,
    });
  }

  Future<void> _deletePreset(EqPreset p) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: NexusQColors.surface,
        title: Text('Delete "${p.label}"?',
            style: const TextStyle(color: NexusQColors.white, fontSize: 16)),
        content: const Text(
            'The preset is stored on the Q, so this removes it for every phone.',
            style: TextStyle(color: NexusQColors.dim, fontSize: 13)),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('Cancel')),
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              style: TextButton.styleFrom(foregroundColor: Colors.orangeAccent),
              child: const Text('Delete')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    await _presetCall('deleteEqPreset', {'id': p.id});
  }

  Widget _presetChips() {
    final enabled = _loaded && _st.supported;
    final canSave = enabled && _presetsEditable && !_legacyDaemon;
    if (_presets.isEmpty && !canSave) return const SizedBox.shrink();
    final side = BorderSide(color: NexusQColors.dim.withValues(alpha: 0.4));
    // Save sits OUTSIDE the scroller, pinned to the end of the row: inside it,
    // every preset you save pushes it further off-screen — and the moment you
    // need it most is when you already have several.
    return SizedBox(
      height: 40,
      child: Row(children: [
        Expanded(child: _presetScroller(side, enabled)),
        if (canSave) ...[
          const SizedBox(width: 6),
          ActionChip(
            avatar:
                const Icon(Icons.add, size: 16, color: NexusQColors.accent),
            label: const Text('Save', style: TextStyle(fontSize: 12)),
            backgroundColor: NexusQColors.surface,
            side: side,
            onPressed: _savePreset,
          ),
        ],
      ]),
    );
  }

  Widget _presetScroller(BorderSide side, bool enabled) {
    return ListView.separated(
      scrollDirection: Axis.horizontal,
      itemCount: _presets.length,
      separatorBuilder: (_, _) => const SizedBox(width: 6),
      itemBuilder: (context, i) {
        final p = _presets[i];
        if (p.builtin) {
          return ActionChip(
            label: Text(p.label, style: const TextStyle(fontSize: 12)),
            backgroundColor: NexusQColors.surface,
            side: side,
            onPressed: enabled ? () => _applyPreset(p) : null,
          );
        }
        // Yours: tap applies it, the × removes it. Only these carry a ×, so the
        // affordance itself says which presets are yours to delete.
        return InputChip(
          label: Text(p.label, style: const TextStyle(fontSize: 12)),
          backgroundColor: NexusQColors.surface,
          side: side,
          deleteIcon: const Icon(Icons.close, size: 16),
          deleteButtonTooltipMessage: 'Delete ${p.label}',
          onPressed: enabled ? () => _applyPreset(p) : null,
          onDeleted: enabled ? () => _deletePreset(p) : null,
        );
      },
    );
  }

  Widget _bandEditor() {
    if (_st.bands.isEmpty) return const SizedBox.shrink();
    final i = _selected.clamp(0, _st.bands.length - 1);
    final b = _st.bands[i];
    final enabled = _loaded && _st.supported;
    final label = b.type == 'peaking'
        ? 'Band ${i + 1}'
        : (b.type == 'lowshelf' ? 'Low shelf' : 'High shelf');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            // Flexible + ellipsis: the label is a band name plus a frequency and
            // the gain is beside it, which overflows a narrow phone outright.
            Flexible(
              child: Text('$label · ${_fmtHz(b.freqHz)}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style:
                      const TextStyle(color: NexusQColors.white, fontSize: 13)),
            ),
            const SizedBox(width: 8),
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
              width: 52,
              child: Text(b.isShelf ? 'Slope' : 'Width',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
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
    final enabled = _loaded && _st.supported && !_legacyDaemon;
    return Row(
      children: [
        const SizedBox(
          width: 52,
          child: Text('Preamp',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
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
          width: 52,
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
    // Deliberately NOT gated on _sending: a ~300 ms lockout after every gesture
    // reads as "the EQ stopped working", and the queue above means a gesture
    // made during a write is not lost.
    final enabled = _loaded && _st.supported;
    return Card(
      // Black, not the usual grey surface: the plot is most of this card, and
      // on the page's own black it stops reading as a panel bolted on top.
      color: NexusQColors.canvas,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                // No title here: the section header above the card already says
                // Equalizer, and having it twice just eats vertical space.
                const Spacer(),
                // Reset, not a "Flat" preset chip in disguise: flat is where the
                // EQ starts, so undoing your edits is an action, not a choice
                // among presets — and an icon leaves the width for the ones
                // that are.
                IconButton(
                  onPressed: enabled && !_st.isFlat ? _resetFlat : null,
                  icon: const Icon(Icons.restart_alt, size: 20),
                  tooltip: 'Reset to flat',
                  visualDensity: VisualDensity.compact,
                  color: NexusQColors.accent,
                  disabledColor: NexusQColors.dim.withValues(alpha: 0.4),
                  constraints: const BoxConstraints(minWidth: 36, minHeight: 32),
                  padding: EdgeInsets.zero,
                ),
              ],
            ),
            if (!_loaded)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 24),
                child: Text('Waiting for the Q…',
                    style: TextStyle(color: NexusQColors.dim, fontSize: 13)),
              )
            else ...[
              EqCurve(
                key: widget.curveKey,
                state: _st,
                selected: _selected,
                armed: _armed,
                enabled: enabled,
                height: 190,
                onSelect: (i) => setState(() => _selected = i),
                onChanged: (i, g) => _editBand(i, gainDb: g),
                onCommit: _commit,
              ),
              const SizedBox(height: 4),
              _presetChips(),
              const SizedBox(height: 4),
              _bandEditor(),
              if (!_legacyDaemon) _preampRow(),
              _hint(),
            ],
          ],
        ),
      ),
    );
  }
}

/// Names a preset. Kept separate so the text field owns its own rebuilds — the
/// card is expensive to rebuild on every keystroke, and it must not be, mid-EQ.
class _SavePresetDialog extends StatefulWidget {
  const _SavePresetDialog({required this.existingUserIds});
  final Set<String> existingUserIds;

  @override
  State<_SavePresetDialog> createState() => _SavePresetDialogState();
}

class _SavePresetDialogState extends State<_SavePresetDialog> {
  final _ctl = TextEditingController();

  @override
  void dispose() {
    _ctl.dispose();
    super.dispose();
  }

  /// The daemon derives the id from the name, so a name that slugs to one you
  /// already have REPLACES it. Say so before the tap, not after.
  bool get _replaces =>
      widget.existingUserIds.contains(EqPreset.userIdFor(_ctl.text));

  /// Blank or all-punctuation slugs to nothing and the daemon would refuse it —
  /// disable the button rather than round-trip for the error.
  bool get _valid => EqPreset.userIdFor(_ctl.text).isNotEmpty;

  void _submit() {
    if (_valid) Navigator.of(context).pop(_ctl.text.trim());
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: NexusQColors.surface,
      title: const Text('Save preset',
          style: TextStyle(color: NexusQColors.white, fontSize: 16)),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            controller: _ctl,
            autofocus: true,
            maxLength: 24,
            textCapitalization: TextCapitalization.sentences,
            textInputAction: TextInputAction.done,
            onChanged: (_) => setState(() {}),
            onSubmitted: (_) => _submit(),
            style: const TextStyle(color: NexusQColors.white),
            decoration: const InputDecoration(
                hintText: 'Vinyl, Night, Kitchen…', counterText: ''),
          ),
          const SizedBox(height: 4),
          Text(
            _replaces
                ? 'Replaces the preset you already saved under this name.'
                : 'Stored on the Q, so it is there on every phone.',
            style: TextStyle(
                color: _replaces ? Colors.orangeAccent : NexusQColors.dim,
                fontSize: 11),
          ),
        ],
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel')),
        TextButton(
            onPressed: _valid ? _submit : null,
            style: TextButton.styleFrom(foregroundColor: NexusQColors.accent),
            child: Text(_replaces ? 'Replace' : 'Save')),
      ],
    );
  }
}
