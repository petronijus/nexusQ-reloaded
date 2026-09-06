// An update must outlive the Settings screen. Before 1.18.1 the flow lived in
// the screen's State: leaving mid-install returned at the first `!mounted`, the
// verify loop never ran, and a reopened Settings started over — offering the
// same update again, over an install that was still running on the device.
//
// These tests drive the coordinator with no widget at all, with a client that
// behaves like the real bridge (the install call drops the link; the re-check
// only answers once the daemons are back), and with sleeps collapsed.
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:nexusq_companion/protocol/client.dart';
import 'package:nexusq_companion/update/update_coordinator.dart';

class _BridgeLikeClient implements NexusQClient {
  _BridgeLikeClient({this.checksUntilBack = 2});

  /// How many checkNexusUpdate/checkSystemUpdate calls fail (link down) before
  /// the device answers again.
  int checksUntilBack;
  bool stillPending = false;
  bool busyOnce = false;
  final List<String> calls = [];

  @override
  Future<Map<String, dynamic>> call(String method, [Map<String, dynamic>? params]) async {
    calls.add(method);
    switch (method) {
      case 'installNexusUpdate':
      case 'installSystemUpdate':
        throw NexusQError('disconnected', 'link dropped by the restart'); // as the real bridge does
      case 'checkNexusUpdate':
      case 'checkSystemUpdate':
        if (checksUntilBack > 0) {
          checksUntilBack--;
          throw NexusQError('disconnected', 'not back yet');
        }
        if (busyOnce) {
          busyOnce = false;
          return {'busy': true};
        }
        return {'updateAvailable': stillPending, 'packages': [], 'kernel': '6.18.48-r0'};
    }
    return {};
  }

  @override
  Stream<NexusQEvent> get events => const Stream.empty();
  @override
  Stream<bool> get connection => const Stream.empty();
  @override
  bool get needsSupervision => false;
  @override
  Future<void> connect() async {}
  @override
  Future<void> close() async {}
  @override
  void disconnect() {}
  @override
  void notify(String method, [Map<String, dynamic>? params]) {}
}

void main() {
  setUp(UpdateCoordinator.resetForTests);

  test('one coordinator per client, the same one after "reopening Settings"', () {
    final c = _BridgeLikeClient();
    expect(identical(UpdateCoordinator.forClient(c), UpdateCoordinator.forClient(c)), isTrue);
    expect(identical(UpdateCoordinator.forClient(c), UpdateCoordinator.forClient(_BridgeLikeClient())), isFalse);
  });

  test('device install runs to a verified end with no screen listening', () async {
    final c = _BridgeLikeClient(checksUntilBack: 2);
    final u = UpdateCoordinator(c, sleep: (_) async {});
    final states = <bool>[];
    u.addListener(() => states.add(u.installingNexus));
    await u.installNexusUpdate();
    expect(u.installingNexus, isFalse);
    expect(u.nexusError, isNull, reason: 'the re-check came back clean');
    expect(u.busy, isFalse);
    // install → (link down, link down) → answered
    expect(c.calls, ['installNexusUpdate', 'checkNexusUpdate', 'checkNexusUpdate', 'checkNexusUpdate']);
    expect(states.first, isTrue, reason: 'it was busy in between — what the home indicator shows');
  });

  test('device install that leaves the update pending is reported, not hidden', () async {
    final c = _BridgeLikeClient(checksUntilBack: 0)..stillPending = true;
    final u = UpdateCoordinator(c, sleep: (_) async {});
    await u.installNexusUpdate();
    expect(u.installingNexus, isFalse);
    expect(u.nexusError, 'Device update failed. Try again.');
  });

  test('device never comes back → inconclusive, busy released', () async {
    final c = _BridgeLikeClient(checksUntilBack: 99);
    final u = UpdateCoordinator(c, sleep: (_) async {});
    await u.installNexusUpdate();
    expect(u.installingNexus, isFalse);
    expect(u.nexusError, contains('Update sent'));
  });

  test('system install waits past a reboot AND a busy reply, then reads the result', () async {
    final c = _BridgeLikeClient(checksUntilBack: 3)..busyOnce = true;
    final u = UpdateCoordinator(c, sleep: (_) async {});
    final progress = <String?>[];
    u.addListener(() => progress.add(u.systemProgress));
    await u.installSystemUpdate();
    expect(u.installingSystem, isFalse);
    expect(u.systemError, isNull);
    expect(u.systemProgress, isNull);
    expect(progress.where((p) => p != null && p.startsWith('Reconnecting')).length, greaterThanOrEqualTo(4));
    expect(u.systemStatusLine(), 'Kernel 6.18.48-r0 · up to date');
  });

  test('a second tap while installing is ignored', () async {
    final c = _BridgeLikeClient(checksUntilBack: 1);
    final u = UpdateCoordinator(c, sleep: (_) async {});
    final first = u.installNexusUpdate();
    await u.installNexusUpdate(); // returns immediately
    await first;
    expect(c.calls.where((m) => m == 'installNexusUpdate').length, 1);
  });
}
