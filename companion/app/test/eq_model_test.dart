import 'package:flutter_test/flutter_test.dart';
import 'package:nexusq_companion/models/eq.dart';

/// The curve the app draws must not be able to disagree with what the amplifier
/// actually runs, so these check the client-side response math against the same
/// properties the device's Python suite checks its coefficients against:
/// shelves reach full gain at their edge and unity at the far one, peaking
/// filters peak at f0 and vanish away from it, and higher Q is narrower.
EqBand peak(double f, double g, [double q = 0.707]) =>
    EqBand(type: 'peaking', freqHz: f, gainDb: g, q: q);

void main() {
  group('band response', () {
    test('a flat or disabled band contributes nothing', () {
      expect(peak(1000, 0).responseDb(1000), 0);
      expect(EqBand(type: 'peaking', freqHz: 1000, gainDb: 9, q: 1, enabled: false)
          .responseDb(1000), 0);
    });

    test('peaking hits its gain at f0 and fades away from it', () {
      for (final g in [6.0, -6.0, 12.0]) {
        final b = peak(1000, g);
        expect(b.responseDb(1000), closeTo(g, 0.1));
        expect(b.responseDb(30), closeTo(0, 0.4));
        expect(b.responseDb(18000), closeTo(0, 0.6));
      }
    });

    test('higher Q is narrower', () {
      final wide = peak(1000, 6, 0.5);
      final tight = peak(1000, 6, 4);
      expect(tight.responseDb(2000), lessThan(wide.responseDb(2000) - 1));
      // ...but both still reach full gain on the centre
      expect(tight.responseDb(1000), closeTo(6, 0.1));
      expect(wide.responseDb(1000), closeTo(6, 0.1));
    });

    test('low shelf lifts DC and leaves the top alone', () {
      const b = EqBand(type: 'lowshelf', freqHz: 100, gainDb: 6, q: 1);
      expect(b.responseDb(20), closeTo(6, 0.6));
      expect(b.responseDb(100), closeTo(3, 0.4)); // half gain at the corner
      expect(b.responseDb(15000), closeTo(0, 0.2));
    });

    test('high shelf lifts the top and leaves DC alone', () {
      const b = EqBand(type: 'highshelf', freqHz: 8000, gainDb: -8, q: 1);
      expect(b.responseDb(20000), closeTo(-8, 0.6));
      expect(b.responseDb(8000), closeTo(-4, 0.5));
      expect(b.responseDb(50), closeTo(0, 0.2));
    });
  });

  group('chain', () {
    final bands = [
      const EqBand(type: 'lowshelf', freqHz: 100, gainDb: 6, q: 1),
      peak(1000, -4, 1.5),
      const EqBand(type: 'highshelf', freqHz: 8000, gainDb: 3, q: 1),
    ];

    test('sums the bands', () {
      expect(EqState.responseDb(bands, 1000, 0), closeTo(-4, 0.6));
      expect(EqState.responseDb(bands, 20, 0), closeTo(6, 0.7));
    });

    test('preamp shifts the whole curve by exactly its value', () {
      for (final f in [50.0, 1000.0, 12000.0]) {
        expect(EqState.responseDb(bands, f, -6) - EqState.responseDb(bands, f, 0),
            closeTo(-6, 1e-9));
      }
    });

    test('headroom finds the peak and auto-preamp would cancel it', () {
      final h = EqState.headroomOf(bands, 0);
      expect(h, closeTo(6, 0.7));
      expect(EqState.headroomOf(bands, -h), closeTo(0, 1e-6));
    });

    test('a flat chain has no headroom problem', () {
      expect(EqState.headroomOf([peak(1000, 0)], 0), closeTo(0, 0.01));
    });
  });

  group('parsing', () {
    test('reads the device shape including limits', () {
      final s = EqState.fromJson({
        'supported': true,
        'bands': [
          {'type': 'lowshelf', 'freq_hz': 100, 'gain_db': 3, 'q': 1, 'enabled': true},
        ],
        'preamp_db': -2.0,
        'headroom_db': 1.0,
        'limits': {
          'gain_db': 12,
          'freq_hz': [20, 20000],
          'q': [0.3, 8],
          'preamp_db': [-24, 0],
        },
      });
      expect(s.supported, isTrue);
      expect(s.isParametric, isTrue);
      expect(s.bands.single.gainDb, 3);
      expect(s.preampDb, -2.0);
      expect(s.maxGainDb, 12);
      expect(s.minPreampDb, -24);
    });

    test('an old daemon reply parses as non-parametric rather than throwing', () {
      final s = EqState.fromJson(
          {'supported': true, 'bass_db': 4.0, 'treble_db': -2.0});
      expect(s.isParametric, isFalse);
      expect(s.bands, isEmpty);
      expect(s.maxGainDb, 12); // falls back to sane limits
    });

    test('round-trips a band through json', () {
      final b = peak(1234, -5.5, 2.25);
      final back = EqBand.fromJson(b.toJson());
      expect(back.freqHz, b.freqHz);
      expect(back.gainDb, b.gainDb);
      expect(back.q, b.q);
      expect(back.type, b.type);
    });

    test('isFlat covers gain, disabled and preamp', () {
      final flat = EqState.empty.copyWith(bands: [peak(1000, 0)]);
      expect(flat.isFlat, isTrue);
      expect(flat.copyWith(preampDb: -3).isFlat, isFalse);
      expect(flat.copyWith(bands: [peak(1000, 5)]).isFlat, isFalse);
    });
  });
}
