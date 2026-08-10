import 'package:flutter_test/flutter_test.dart';
import 'package:nexusq_companion/screens/health_screen.dart';

/// The health-state payload is SPARSE by contract (the daemon omits fields
/// whose source is unavailable) and entirely empty until the first retained
/// message arrives — every consumer must tolerate absent keys. The empty-map
/// case is exactly the v1.12.0 grey-screen crash (null cast in _problems on
/// the first build after saving broker settings).
void main() {
  test('empty state (first build before any message) yields no problems', () {
    expect(healthProblems({}), isEmpty);
  });

  test('healthy full payload yields no problems', () {
    expect(
        healthProblems({
          'nexusqd_alive': true,
          'healthd_fresh': true,
          'led_stall': 0,
          'pstore': 0,
        }),
        isEmpty);
  });

  test('each problem flag is reported', () {
    expect(healthProblems({'nexusqd_alive': false}),
        contains('LED daemon (nexusqd) is down'));
    expect(healthProblems({'healthd_fresh': false}),
        contains('Health sampler (nq-healthd) is stale'));
    expect(healthProblems({'led_stall': 6}),
        contains('LED ring frame is stalled'));
    expect(healthProblems({'pstore': 2}),
        contains('Crash dump present (pstore)'));
  });

  test('sub-threshold and wrong-typed values are ignored', () {
    expect(
        healthProblems({'led_stall': 5, 'pstore': 0, 'nexusqd_alive': true}),
        isEmpty);
    // hostile/garbage payload must never throw
    expect(healthProblems({'led_stall': 'x', 'pstore': null}), isEmpty);
  });
}
