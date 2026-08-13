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
    expect(healthProblems({'led_stalled': true}),
        contains('LED ring is stalled'));
    expect(healthProblems({'pstore': 2}),
        contains('Crash dump present (pstore)'));
  });

  test('sub-threshold and wrong-typed values are ignored', () {
    expect(healthProblems({'pstore': 0, 'nexusqd_alive': true}), isEmpty);
    // hostile/garbage payload must never throw
    expect(healthProblems({'led_stall': 'x', 'pstore': null}), isEmpty);
  });

  /// The regression this rule exists for: a locked/blanked screensaver drives
  /// `led_stall` arbitrarily high on a HEALTHY device (the 1 Hz AVR keepalive
  /// re-commits identical bytes), so the raw counter must never raise an alarm
  /// on its own — only the device's qualified `led_stalled` verdict may.
  test('a high led_stall counter alone is NOT a problem (idle screensaver)', () {
    expect(
        healthProblems({
          'nexusqd_alive': true,
          'healthd_fresh': true,
          'led_stall': 9751,
          'led_stalled': false,
          'pstore': 0,
        }),
        isEmpty);
    // and with the verdict field absent entirely (device too old to send it)
    expect(healthProblems({'led_stall': 9751, 'nexusqd_alive': true}), isEmpty);
  });

  test('led_stalled only fires on a real boolean true', () {
    expect(healthProblems({'led_stalled': false}), isEmpty);
    expect(healthProblems({'led_stalled': null}), isEmpty);
    expect(healthProblems({'led_stalled': 'yes'}), isEmpty);
    expect(healthProblems({'led_stalled': 1}), isEmpty);
  });
}
