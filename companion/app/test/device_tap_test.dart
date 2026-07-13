import 'package:flutter_test/flutter_test.dart';
import 'package:nexusq_companion/nfc/device_tap.dart';

void main() {
  test('parses provisioned payload', () {
    final t = DeviceTap.tryParse(
        '{"v":1,"bt":"F8:8F:CA:20:49:E5","host":"steelhead","ip":"192.168.20.195","prov":true}');
    expect(t, isNotNull);
    expect(t!.btMac, 'F8:8F:CA:20:49:E5');
    expect(t.ip, '192.168.20.195');
    expect(t.provisioned, isTrue);
  });

  test('parses unprovisioned payload with null ip', () {
    final t = DeviceTap.tryParse(
        '{"v":1,"bt":"F8:8F:CA:20:49:E5","host":"steelhead","ip":null,"prov":false}');
    expect(t!.ip, isNull);
    expect(t.provisioned, isFalse);
  });

  test('rejects plain text and wrong version', () {
    expect(DeviceTap.tryParse('Ahoj z Nexus Q!'), isNull);
    expect(DeviceTap.tryParse('{"v":2,"bt":"x"}'), isNull);
  });

  test('rejects wrong-typed fields instead of throwing', () {
    expect(DeviceTap.tryParse('{"v":1,"bt":42,"host":"x","ip":null,"prov":true}'), isNull);
    expect(DeviceTap.tryParse('{"v":1,"bt":"aa","host":[],"ip":7,"prov":"yes"}'), isNull);
  });

  test('missing prov defaults to not provisioned', () {
    final t = DeviceTap.tryParse('{"v":1,"bt":"aa","host":"h","ip":null}');
    expect(t, isNotNull);
    expect(t!.provisioned, isFalse);
  });
}
