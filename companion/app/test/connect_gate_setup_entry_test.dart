import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexusq_companion/screens/connect_gate.dart';

void main() {
  testWidgets(
      'ConnectGate offers "Set up new device" after discovery fails, and it pushes SetupFlow',
      (tester) async {
    // Discovery is STUBBED, deliberately. This test used to let the real mDNS
    // browse run and simply assume "there is no _nexusq._tcp bridge reachable
    // from the test sandbox" — which is false on a developer machine on the
    // same LAN as a powered-on Q: the browse succeeds (it resolved a live
    // device at 192.168.20.246:45015 on 2026-08-13), the gate jumps straight
    // to HomeScreen, and the fallback UI under test never renders. The test
    // therefore passed or failed according to whether the appliance was
    // switched on, which is not a property of the code. It also spent ~4 s of
    // real network timeout per run. The stub pins the one behaviour this test
    // is actually about: what the gate does when nothing is found.
    await tester.pumpWidget(MaterialApp(
      home: ConnectGate(discover: () async => null),
    ));

    // Discovery starts immediately (no initialClient supplied).
    expect(find.text('Searching for Nexus Q…'), findsOneWidget);

    // The stub completes on a microtask, so one pump lands the setState.
    await tester.pump();
    expect(find.text('Set up new device'), findsOneWidget);

    await tester.tap(find.text('Set up new device'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300)); // page route transition

    // SetupFlow's first page (WelcomeScreen) is now on top of the stack.
    expect(find.text('Set up your Nexus Q'), findsOneWidget);
  });

  // The success branch is deliberately NOT tested here. Returning a Discovered
  // makes the gate build a real TcpClient and dial the host, so the test would
  // do live socket I/O and leak a pending connect timer — the same class of
  // ambient dependency this file was just cured of. Covering it properly needs
  // a client-injection seam, which is not worth widening the widget's API for.
}
