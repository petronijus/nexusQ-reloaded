import 'dart:math' as math;

/// Client-side model of the device's 7-band hardware EQ (PROTOCOL §14).
///
/// The response math below is the SAME RBJ cookbook the daemon uses to compute
/// the coefficients it writes into the TAS5713. That is deliberate: the curve
/// drawn here must not be able to disagree with what the amplifier actually
/// does. The device stays the source of truth — every gesture round-trips
/// through `setEq` and the reply is what is displayed — but between the gesture
/// and the reply this is what draws.
class EqBand {
  const EqBand({
    required this.type,
    required this.freqHz,
    required this.gainDb,
    required this.q,
    this.enabled = true,
  });

  final String type; // lowshelf | peaking | highshelf
  final double freqHz;
  final double gainDb;
  final double q; // Q for peaking; RBJ slope S for a shelf
  final bool enabled;

  bool get isShelf => type != 'peaking';
  bool get isFlat => !enabled || gainDb.abs() < 0.05;

  EqBand copyWith({double? freqHz, double? gainDb, double? q, bool? enabled}) =>
      EqBand(
        type: type,
        freqHz: freqHz ?? this.freqHz,
        gainDb: gainDb ?? this.gainDb,
        q: q ?? this.q,
        enabled: enabled ?? this.enabled,
      );

  static EqBand fromJson(Map<String, dynamic> j) => EqBand(
        type: j['type'] as String? ?? 'peaking',
        freqHz: (j['freq_hz'] as num?)?.toDouble() ?? 1000,
        gainDb: (j['gain_db'] as num?)?.toDouble() ?? 0,
        q: (j['q'] as num?)?.toDouble() ?? 0.707,
        enabled: j['enabled'] as bool? ?? true,
      );

  Map<String, dynamic> toJson() => {
        'type': type,
        'freq_hz': freqHz,
        'gain_db': gainDb,
        'q': q,
        'enabled': enabled,
      };

  /// |H(f)| in dB for this band alone. Returns 0 for a flat/disabled band
  /// rather than evaluating a unity filter — that is what the device writes.
  double responseDb(double f, {double fs = 48000}) {
    if (isFlat) return 0;
    final a = math.pow(10, gainDb / 40.0).toDouble();
    final w0 = 2 * math.pi * freqHz / fs;
    final cw = math.cos(w0), sw = math.sin(w0);
    double b0, b1, b2, a0, a1, a2;
    if (type == 'peaking') {
      final alpha = sw / (2 * math.max(0.3, q));
      b0 = 1 + alpha * a;
      b1 = -2 * cw;
      b2 = 1 - alpha * a;
      a0 = 1 + alpha / a;
      a1 = -2 * cw;
      a2 = 1 - alpha / a;
    } else {
      final s = q.clamp(0.1, 2.0);
      final alpha = sw / 2 * math.sqrt((a + 1 / a) * (1 / s - 1) + 2);
      final twoSqrtAAlpha = 2 * math.sqrt(a) * alpha;
      if (type == 'lowshelf') {
        b0 = a * ((a + 1) - (a - 1) * cw + twoSqrtAAlpha);
        b1 = 2 * a * ((a - 1) - (a + 1) * cw);
        b2 = a * ((a + 1) - (a - 1) * cw - twoSqrtAAlpha);
        a0 = (a + 1) + (a - 1) * cw + twoSqrtAAlpha;
        a1 = -2 * ((a - 1) + (a + 1) * cw);
        a2 = (a + 1) + (a - 1) * cw - twoSqrtAAlpha;
      } else {
        b0 = a * ((a + 1) + (a - 1) * cw + twoSqrtAAlpha);
        b1 = -2 * a * ((a - 1) + (a + 1) * cw);
        b2 = a * ((a + 1) + (a - 1) * cw - twoSqrtAAlpha);
        a0 = (a + 1) - (a - 1) * cw + twoSqrtAAlpha;
        a1 = 2 * ((a - 1) - (a + 1) * cw);
        a2 = (a + 1) - (a - 1) * cw - twoSqrtAAlpha;
      }
    }
    b0 /= a0;
    b1 /= a0;
    b2 /= a0;
    a1 /= a0;
    a2 /= a0;
    // H(e^-jw) evaluated directly — no complex type needed for a magnitude.
    final w = 2 * math.pi * f / fs;
    final cr = math.cos(-w), ci = math.sin(-w);
    final c2r = math.cos(-2 * w), c2i = math.sin(-2 * w);
    final nr = b0 + b1 * cr + b2 * c2r, ni = b1 * ci + b2 * c2i;
    final dr = 1 + a1 * cr + a2 * c2r, di = a1 * ci + a2 * c2i;
    final den = dr * dr + di * di;
    if (den <= 0) return 0;
    final mag = math.sqrt((nr * nr + ni * ni) / den);
    return mag <= 1e-12 ? -240 : 20 * (math.log(mag) / math.ln10);
  }
}

class EqState {
  const EqState({
    required this.supported,
    required this.bands,
    required this.preampDb,
    required this.headroomDb,
    required this.maxGainDb,
    required this.minFreqHz,
    required this.maxFreqHz,
    required this.minQ,
    required this.maxQ,
    required this.minPreampDb,
  });

  final bool supported;
  final List<EqBand> bands;
  final double preampDb;
  final double headroomDb;
  final double maxGainDb;
  final double minFreqHz;
  final double maxFreqHz;
  final double minQ;
  final double maxQ;
  final double minPreampDb;

  static const empty = EqState(
    supported: false,
    bands: [],
    preampDb: 0,
    headroomDb: 0,
    maxGainDb: 12,
    minFreqHz: 20,
    maxFreqHz: 20000,
    minQ: 0.3,
    maxQ: 8,
    minPreampDb: -24,
  );

  bool get isFlat =>
      preampDb.abs() < 0.05 && bands.every((b) => b.isFlat);

  /// True when the daemon predates the parametric verbs — it answers `getEq`
  /// but without a `bands` array. The card then falls back to bass/treble.
  bool get isParametric => bands.isNotEmpty;

  EqState copyWith({List<EqBand>? bands, double? preampDb}) {
    final b = bands ?? this.bands;
    final p = preampDb ?? this.preampDb;
    return EqState(
      supported: supported,
      bands: b,
      preampDb: p,
      headroomDb: headroomOf(b, p),
      maxGainDb: maxGainDb,
      minFreqHz: minFreqHz,
      maxFreqHz: maxFreqHz,
      minQ: minQ,
      maxQ: maxQ,
      minPreampDb: minPreampDb,
    );
  }

  static EqState fromJson(Map<String, dynamic> j) {
    final lim = (j['limits'] as Map?)?.cast<String, dynamic>() ?? const {};
    List<double> pair(String k, double a, double b) {
      final v = lim[k];
      if (v is List && v.length == 2 && v[0] is num && v[1] is num) {
        return [(v[0] as num).toDouble(), (v[1] as num).toDouble()];
      }
      return [a, b];
    }

    final freq = pair('freq_hz', 20, 20000);
    final q = pair('q', 0.3, 8);
    final pre = pair('preamp_db', -24, 0);
    return EqState(
      supported: j['supported'] as bool? ?? false,
      bands: (j['bands'] as List?)
              ?.whereType<Map>()
              .map((m) => EqBand.fromJson(m.cast<String, dynamic>()))
              .toList() ??
          const [],
      preampDb: (j['preamp_db'] as num?)?.toDouble() ?? 0,
      headroomDb: (j['headroom_db'] as num?)?.toDouble() ?? 0,
      maxGainDb: (lim['gain_db'] as num?)?.toDouble() ?? 12,
      minFreqHz: freq[0],
      maxFreqHz: freq[1],
      minQ: q[0],
      maxQ: q[1],
      minPreampDb: pre[0],
    );
  }

  /// Summed response of the whole chain at one frequency, preamp included.
  static double responseDb(List<EqBand> bands, double f, double preampDb) {
    var total = preampDb;
    for (final b in bands) {
      total += b.responseDb(f);
    }
    return total;
  }

  /// Peak of the summed response — mirrors the daemon's 1/12-octave grid, so
  /// the number shown next to "auto" is the one the device would compute.
  static double headroomOf(List<EqBand> bands, double preampDb) {
    var peak = -240.0;
    for (var i = 0; i <= 96; i++) {
      final f = 20 * math.pow(1000.0, i / 96.0).toDouble();
      final v = responseDb(bands, f, preampDb);
      if (v > peak) peak = v;
    }
    return peak;
  }
}

class EqPreset {
  const EqPreset({required this.id, required this.label, required this.bands,
      required this.preampDb, this.builtin = true});
  final String id;
  final String label;
  final List<EqBand> bands;
  final double preampDb;

  /// Ships with the device, so it cannot be deleted. A daemon that predates
  /// saved presets omits the field entirely — absent reads as built-in, which
  /// leaves the card offering delete on exactly nothing. (PROTOCOL §14.5)
  final bool builtin;

  static final RegExp _alnum = RegExp(r'[\p{L}\p{N}]', unicode: true);

  /// Mirrors the daemon's id derivation (PROTOCOL §14.6) so the app can tell,
  /// before sending, that a name is going to REPLACE an existing preset rather
  /// than add one. Unicode-aware on purpose: the daemon uses Python's
  /// `str.isalnum()`, so "Večer" must slug to `u:večer` here too, not `u:ve-er`.
  static String userIdFor(String name) {
    final buf = StringBuffer();
    for (final c in name.trim().toLowerCase().split('')) {
      buf.write(_alnum.hasMatch(c) ? c : '-');
    }
    final slug =
        buf.toString().split('-').where((part) => part.isNotEmpty).join('-');
    final cut = slug.length > 32 ? slug.substring(0, 32) : slug;
    return cut.isEmpty ? '' : 'u:$cut';
  }

  static EqPreset fromJson(Map<String, dynamic> j) => EqPreset(
        id: j['id'] as String? ?? '',
        label: j['label'] as String? ?? '',
        bands: (j['bands'] as List?)
                ?.whereType<Map>()
                .map((m) => EqBand.fromJson(m.cast<String, dynamic>()))
                .toList() ??
            const [],
        preampDb: (j['preamp_db'] as num?)?.toDouble() ?? 0,
        builtin: j['builtin'] as bool? ?? true,
      );
}
