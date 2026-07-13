import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexusq_companion/setup/setup_flow.dart';

void main() {
  testWidgets('wizard starts on Welcome and advances to Cables', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: SetupFlow()));
    expect(find.text('Set up your Nexus Q'), findsOneWidget);
    await tester.tap(find.text('Get started'));
    await tester.pumpAndSettle();
    expect(find.text('Connect your Nexus Q'), findsOneWidget);
  });

  testWidgets('NFC-tapped mac skips the find screen', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: SetupFlow(initialMac: 'F8:8F:CA:20:49:E5')));
    final state = tester.state<SetupFlowScreenState>(find.byType(SetupFlow));
    expect(state.flow.deviceMac, 'F8:8F:CA:20:49:E5');
  });
}
