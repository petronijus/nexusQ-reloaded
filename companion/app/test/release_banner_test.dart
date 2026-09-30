// The home screen tells its owner a release is ready (the demo Q waits for
// 2.0.0, see MockClient getUpdateStatus) and opens its "what's new" with the
// Update button; and it shows "what's new" by itself once, after the Q was
// seen waiting for a release and now runs it.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexusq_companion/protocol/mock_client.dart';
import 'package:nexusq_companion/screens/home_screen.dart';
import 'package:nexusq_companion/state/device_controller.dart';
import 'package:nexusq_companion/update/release_alerts.dart';
import 'package:nexusq_companion/update/update_coordinator.dart';

void main() {
  setUp(UpdateCoordinator.resetForTests);

  testWidgets('a pending release shows as a banner that opens its notes', (
    tester,
  ) async {
    final store = MemoryStore();
    final controller = DeviceController(MockClient());
    await tester.runAsync(controller.start);
    await tester.pumpWidget(
      MaterialApp(
        home: HomeScreen(controller: controller, releaseStore: store),
      ),
    );
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 300)),
    );
    await tester.pump();

    expect(find.text('Nexus Q 2.0.0 is ready'), findsOneWidget);
    // Seen in the app: the background check will not ring for it.
    expect(store.values['release.notified.nexusq_mock'], '2.0.0');

    await tester.tap(find.text('Nexus Q 2.0.0 is ready'));
    // Not pumpAndSettle: the sphere's glow animates forever.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('Update ready'), findsOneWidget);
    expect(find.text('Quiet when idle'), findsOneWidget);
    expect(find.text('Update now'), findsOneWidget);

    controller.dispose();
  });
}
