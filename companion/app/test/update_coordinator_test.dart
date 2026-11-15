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
  Future<Map<String, dynamic>> call(
    String method, [
    Map<String, dynamic>? params,
  ]) async {
    calls.add(method);
    switch (method) {
      case 'installNexusUpdate':
      case 'installSystemUpdate':
        throw NexusQError(
          'disconnected',
          'link dropped by the restart',
        ); // as the real bridge does
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
        return {
          'updateAvailable': stillPending,
          'packages': [],
          'kernel': '6.18.48-r0',
        };
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

/// A bridge with install jobs (control r70+, PROTOCOL §12d): an `async`
/// install answers at once with the job, whose progress and end come as
/// events; the link can drop and come back.
class _JobBridgeClient implements NexusQClient {
  final events_ = StreamController<NexusQEvent>.broadcast();
  final connection_ = StreamController<bool>.broadcast();
  final List<String> calls = [];
  final List<Map<String, dynamic>?> params = [];
  Map<String, dynamic>? jobNow; // what getUpdateJob answers
  bool busy = false;
  bool refuse = false;
  final Completer<void> installAnswered = Completer<void>();
  Completer<void>? holdInstall;

  static Map<String, dynamic> job({
    String kind = 'system',
    String state = 'running',
    String phase = 'downloading',
    int percent = 10,
    String? error,
  }) => {
    'id': 'j-$kind',
    'kind': kind,
    'state': state,
    'phase': phase,
    'stalled': false,
    'resumed': false,
    'progress': {'percent': percent, 'phasePercent': percent},
    'result': state == 'done' ? {'rebootRecommended': false} : null,
    'error': error,
  };

  void emit(String event, Map<String, dynamic> data) =>
      events_.add(NexusQEvent(event, data));

  @override
  Future<Map<String, dynamic>> call(
    String method, [
    Map<String, dynamic>? p,
  ]) async {
    calls.add(method);
    params.add(p);
    switch (method) {
      case 'installSystemUpdate':
      case 'installNexusUpdate':
        if (holdInstall != null) await holdInstall!.future;
        if (busy) throw NexusQError('busy', 'an update is already installing');
        if (refuse) {
          throw NexusQError('unavailable', 'cannot start the update: no unit');
        }
        final kind = method == 'installSystemUpdate' ? 'system' : 'daemons';
        jobNow = job(kind: kind, phase: 'preparing', percent: 0);
        return {'started': true, 'job': jobNow};
      case 'getUpdateJob':
        return {'job': jobNow};
      case 'checkSystemUpdate':
        return {'updateAvailable': false, 'packages': [], 'kernel': 'k'};
      case 'checkNexusUpdate':
        return {'updateAvailable': false, 'packages': []};
      case 'getUpdateStatus':
        return {'available': null, 'current': null};
    }
    return {};
  }

  @override
  Stream<NexusQEvent> get events => events_.stream;
  @override
  Stream<bool> get connection => connection_.stream;
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

Future<void> settle() => Future<void>.delayed(Duration.zero);

void main() {
  setUp(UpdateCoordinator.resetForTests);

  test(
    'one coordinator per client, the same one after "reopening Settings"',
    () {
      final c = _BridgeLikeClient();
      expect(
        identical(
          UpdateCoordinator.forClient(c),
          UpdateCoordinator.forClient(c),
        ),
        isTrue,
      );
      expect(
        identical(
          UpdateCoordinator.forClient(c),
          UpdateCoordinator.forClient(_BridgeLikeClient()),
        ),
        isFalse,
      );
    },
  );

  test(
    'device install runs to a verified end with no screen listening',
    () async {
      final c = _BridgeLikeClient(checksUntilBack: 2);
      final u = UpdateCoordinator(c, sleep: (_) async {});
      final states = <bool>[];
      u.addListener(() => states.add(u.installingNexus));
      await u.installNexusUpdate();
      expect(u.installingNexus, isFalse);
      expect(u.nexusError, isNull, reason: 'the re-check came back clean');
      expect(u.busy, isFalse);
      // install → (link down, link down) → answered
      expect(c.calls, [
        'installNexusUpdate',
        'checkNexusUpdate',
        'checkNexusUpdate',
        'checkNexusUpdate',
      ]);
      expect(
        states.first,
        isTrue,
        reason: 'it was busy in between — what the home indicator shows',
      );
    },
  );

  test(
    'device install that leaves the update pending is reported, not hidden',
    () async {
      final c = _BridgeLikeClient(checksUntilBack: 0)..stillPending = true;
      final u = UpdateCoordinator(c, sleep: (_) async {});
      await u.installNexusUpdate();
      expect(u.installingNexus, isFalse);
      expect(u.nexusError, 'Device update failed. Try again.');
    },
  );

  test('device never comes back → inconclusive, busy released', () async {
    final c = _BridgeLikeClient(checksUntilBack: 99);
    final u = UpdateCoordinator(c, sleep: (_) async {});
    await u.installNexusUpdate();
    expect(u.installingNexus, isFalse);
    expect(u.nexusError, contains('Update sent'));
  });

  test(
    'system install waits past a reboot AND a busy reply, then reads the result',
    () async {
      final c = _BridgeLikeClient(checksUntilBack: 3)..busyOnce = true;
      final u = UpdateCoordinator(c, sleep: (_) async {});
      final progress = <String?>[];
      u.addListener(() => progress.add(u.systemProgress));
      await u.installSystemUpdate();
      expect(u.installingSystem, isFalse);
      expect(u.systemError, isNull);
      expect(u.systemProgress, isNull);
      expect(
        progress.where((p) => p != null && p.startsWith('Reconnecting')).length,
        greaterThanOrEqualTo(4),
      );
      expect(u.systemStatusLine(), 'Kernel 6.18.48-r0 · up to date');
    },
  );

  test('a second tap while installing is ignored', () async {
    final c = _BridgeLikeClient(checksUntilBack: 1);
    final u = UpdateCoordinator(c, sleep: (_) async {});
    final first = u.installNexusUpdate();
    await u.installNexusUpdate(); // returns immediately
    await first;
    expect(c.calls.where((m) => m == 'installNexusUpdate').length, 1);
  });

  group('install jobs (control r70+)', () {
    test('an install asks for a job and shows it at once', () async {
      final c = _JobBridgeClient();
      final u = UpdateCoordinator(c, sleep: (_) async {});
      await u.installSystemUpdate();
      expect(c.params.first, {'async': true});
      expect(u.systemJob?.phase.name, 'preparing');
      expect(u.installingSystem, isTrue);
      expect(u.busy, isTrue);
      expect(c.calls, [
        'installSystemUpdate',
      ], reason: 'no blind re-checks: the job tells');
    });

    test(
      'busy from the tap, before the Q answers; a second tap is ignored',
      () async {
        final c = _JobBridgeClient()..holdInstall = Completer<void>();
        final u = UpdateCoordinator(c, sleep: (_) async {});
        final first = u.installSystemUpdate();
        expect(u.installingSystem, isTrue);
        await u.installSystemUpdate();
        c.holdInstall!.complete();
        await first;
        expect(c.calls.where((m) => m == 'installSystemUpdate').length, 1);
      },
    );

    test(
      'progress events move the job, its end refreshes the checks',
      () async {
        final c = _JobBridgeClient();
        final u = UpdateCoordinator(c, sleep: (_) async {});
        await u.installSystemUpdate();
        c.emit(
          'updateProgress',
          _JobBridgeClient.job(phase: 'installing', percent: 71),
        );
        await settle();
        expect(u.systemJob?.percent, 71);
        c.emit(
          'updateFinished',
          _JobBridgeClient.job(state: 'done', phase: 'done', percent: 100),
        );
        await settle();
        await settle();
        expect(u.systemJob, isNull);
        expect(u.installingSystem, isFalse);
        expect(u.systemError, isNull);
        expect(c.calls, containsAll(['checkSystemUpdate', 'getUpdateStatus']));
      },
    );

    test('a failed job says why', () async {
      final c = _JobBridgeClient();
      final u = UpdateCoordinator(c, sleep: (_) async {});
      await u.installSystemUpdate();
      c.emit(
        'updateFinished',
        _JobBridgeClient.job(
          state: 'failed',
          phase: 'failed',
          error: 'not enough space: the update needs about 900 MiB free',
        ),
      );
      await settle();
      await settle();
      expect(u.systemError, contains('not enough space'));
    });

    test(
      'a job that ended while the link was down is read on reconnect',
      () async {
        final c = _JobBridgeClient();
        final u = UpdateCoordinator(c, sleep: (_) async {});
        await u.installSystemUpdate();
        c.connection_.add(false);
        await settle();
        expect(u.linkUp, isFalse);
        expect(u.systemJob, isNotNull, reason: 'the last progress stays shown');
        c.jobNow = _JobBridgeClient.job(state: 'done', phase: 'done');
        c.connection_.add(true);
        await settle();
        await settle();
        await settle();
        expect(u.linkUp, isTrue);
        expect(u.systemJob, isNull);
        expect(c.calls, contains('getUpdateJob'));
        expect(c.calls, contains('checkSystemUpdate'));
      },
    );

    test('a job already running when the app connects is shown', () async {
      final c = _JobBridgeClient()
        ..jobNow = _JobBridgeClient.job(kind: 'daemons', percent: 40);
      final u = UpdateCoordinator(c, sleep: (_) async {});
      await u.refreshJob();
      expect(u.nexusJob?.percent, 40);
      expect(u.installingNexus, isTrue);
      expect(u.systemJob, isNull);
    });

    test('an install refused as busy shows the job that runs', () async {
      final c = _JobBridgeClient()
        ..busy = true
        ..jobNow = _JobBridgeClient.job(percent: 55);
      final u = UpdateCoordinator(c, sleep: (_) async {});
      await u.installSystemUpdate();
      expect(u.systemJob?.percent, 55);
      expect(u.systemError, contains('already in progress'));
    });

    test('a job the Q could not start is said, not narrated', () async {
      final c = _JobBridgeClient()..refuse = true;
      final u = UpdateCoordinator(c, sleep: (_) async {});
      await u.installSystemUpdate();
      expect(u.installingSystem, isFalse);
      expect(u.systemError, contains('cannot start the update'));
      expect(
        c.calls.where((m) => m == 'checkSystemUpdate'),
        isEmpty,
        reason: 'no blind re-checks of an install that is not happening',
      );
    });

    test('a bridge before r70 has no jobs: getUpdateJob is quiet', () async {
      final c = _BridgeLikeClient();
      final u = UpdateCoordinator(c, sleep: (_) async {});
      await u.refreshJob();
      expect(u.job, isNull);
    });
  });
}
