import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexusq_companion/screens/connect_gate.dart';

void main() {
  testWidgets(
      'ConnectGate offers "Set up new device" after discovery fails, and it pushes SetupFlow',
      (tester) async {
    await tester.pumpWidget(const MaterialApp(home: ConnectGate()));
    // Discovery starts immediately (no initialClient supplied).
    expect(find.text('Searching for Nexus Q…'), findsOneWidget);

    // There is no _nexusq._tcp bridge reachable from the test sandbox, so
    // discovery times out (mDNS lookup timeout is 4s, plus bind/teardown
    // overhead) and the gate falls back to the manual-entry UI, which
    // carries the "Set up new device" entry point under test. Discovery
    // does real socket I/O (not a fake Timer), so progressing it needs the
    // real clock (via runAsync) interleaved with pump() so the resulting
    // setState is reflected in the tree; GlowingRing also runs a continuous
    // animation, so pumpAndSettle would never converge either way.
    final deadline = DateTime.now().add(const Duration(seconds: 15));
    while (find.text('Set up new device').evaluate().isEmpty &&
        DateTime.now().isBefore(deadline)) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
      await tester.pump();
    }
    expect(find.text('Set up new device'), findsOneWidget);

    await tester.tap(find.text('Set up new device'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300)); // page route transition

    // SetupFlow's first page (WelcomeScreen) is now on top of the stack.
    expect(find.text('Set up your Nexus Q'), findsOneWidget);
  }, timeout: const Timeout(Duration(seconds: 30)));
}
