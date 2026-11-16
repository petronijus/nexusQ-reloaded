// The update flows, lifted out of the Settings screen so they survive it.
//
// WHY. Until 1.18.1 the three update tracks (phone app, device daemons, full
// system) lived in `_SettingsScreenState`: local bools, `setState`, and an
// `if (!mounted) return;` before every step that followed an await. Leaving the
// screen mid-update therefore did not stop the DEVICE (the bridge had the job),
// but it did stop the phone's side of it: the verify loop returned at the first
// `!mounted`, the progress was gone, and a re-opened Settings started from
// scratch — "update available" again, over an install that was still running,
// so the user tapped Update once more (Petr, 2026-09-06: "když dám update a
// odejdu ze stránky, tak update přestane a musím to celý dělat znova").
//
// Now the flow is a [ChangeNotifier] owned per client, kept alive for as long as
// the client is (see [forClient]); Settings only renders it and calls into it,
// and the home screen shows a small indicator while anything is in flight.
// Behaviour and wording are unchanged from the screen-local version; what
// changed is who owns the state.
import 'dart:async';

import 'package:flutter/foundation.dart';

import '../build_info.dart';
import '../debug/app_log.dart';
import '../protocol/client.dart';
import 'app_update.dart';
import 'release.dart';
import 'update_job.dart';

class UpdateCoordinator extends ChangeNotifier {
  UpdateCoordinator(this.client, {Future<void> Function(Duration)? sleep})
    : _sleep = sleep ?? ((d) => Future<void>.delayed(d)) {
    // The Q pushes a change of its release status (PROTOCOL §12c) to every
    // client; the coordinator lives as long as the client, so it listens for
    // as long as the link can carry one.
    _events = client.events.listen((e) {
      switch (e.event) {
        case 'updateStatusChanged':
          _set(() => _release = UpdateStatus.fromJson(e.data));
        case 'updateProgress':
          final job = UpdateJob.fromJson(e.data);
          if (job != null && job.running) _set(() => _job = job);
        case 'updateFinished':
          final job = UpdateJob.fromJson(e.data);
          if (job != null) unawaited(_onJobFinished(job));
      }
    });
    // An install job (PROTOCOL §12d) restarts the bridge and may reboot the
    // Q: the link drops, comes back, and the job is asked for again.
    _connection = client.connection.listen((up) {
      _set(() => _linkUp = up);
      if (up) unawaited(refreshJob());
    });
  }

  final NexusQClient client;
  final Future<void> Function(Duration) _sleep;
  late final StreamSubscription<NexusQEvent> _events;
  late final StreamSubscription<bool> _connection;

  @override
  void dispose() {
    _events.cancel();
    _connection.cancel();
    super.dispose();
  }

  /// One coordinator per client, for the lifetime of that client — the same
  /// instance whether Settings is open, closed, or reopened.
  static final Map<NexusQClient, UpdateCoordinator> _byClient = {};
  static UpdateCoordinator forClient(NexusQClient client) =>
      _byClient.putIfAbsent(client, () => UpdateCoordinator(client));

  @visibleForTesting
  static void resetForTests() => _byClient.clear();

  // --- app (phone) update state ------------------------------------------
  bool _checkingUpdate = false;
  AppRelease? _update; // non-null = a newer app version is available
  bool _downloading = false; // whole download (gates the UI)
  double? _downloadProgress; // 0..1 when length known; null = indeterminate
  int _downloadBytes = 0;
  String? _updateError;

  bool get checkingUpdate => _checkingUpdate;
  AppRelease? get update => _update;
  bool get downloading => _downloading;
  double? get downloadProgress => _downloadProgress;
  int get downloadBytes => _downloadBytes;
  String? get updateError => _updateError;

  // --- Nexus Q (device) daemon-update state --------------------------------
  Map<String, dynamic>? _nexusCheck;
  bool _checkingNexus = false;
  bool _installingNexus = false;
  String? _nexusError;

  Map<String, dynamic>? get nexusCheck => _nexusCheck;
  bool get checkingNexus => _checkingNexus;
  bool get installingNexus =>
      _installingNexus || _starting == 'daemons' || nexusJob != null;
  String? get nexusError => _nexusError;
  bool get nexusUpdateAvailable => _nexusCheck?['updateAvailable'] == true;

  // --- full-system update state --------------------------------------------
  Map<String, dynamic>? _systemCheck;
  bool _checkingSystem = false;
  bool _installingSystem = false;
  String? _systemError;
  String? _systemProgress;

  Map<String, dynamic>? get systemCheck => _systemCheck;
  bool get checkingSystem => _checkingSystem;
  bool get installingSystem =>
      _installingSystem || _starting == 'system' || systemJob != null;
  String? get systemError => _systemError;
  String? get systemProgress => _systemProgress;
  bool get systemUpdateAvailable => _systemCheck?['updateAvailable'] == true;

  // The "App update" card merges the phone app AND the device daemons: ONE
  // indicator, one button. Available when EITHER has a newer build; the install
  // does whichever is needed (daemons first — installing the app restarts the
  // phone, so it goes last, onto an already-updated device).
  bool get companionUpdateAvailable => _update != null || nexusUpdateAvailable;
  bool get companionBusy => _downloading || installingNexus;

  // --- install jobs (PROTOCOL §12d, nexusq-control r70+) --------------------
  // The job the Q runs, with its real progress; null when none runs (and on a
  // bridge before r70, which installs inside one blocking call instead).
  UpdateJob? _job;
  bool _linkUp = true;
  // The install asked for and not answered yet (`system` / `daemons`): busy
  // from the tap on, so the card never looks idle while the Q decides, and a
  // second tap is ignored. A bridge before r70 answers only when apk is done.
  String? _starting;

  /// The running job, of either kind.
  UpdateJob? get job => _job != null && _job!.running ? _job : null;
  UpdateJob? get systemJob => job != null && job!.isSystem ? job : null;
  UpdateJob? get nexusJob => job != null && !job!.isSystem ? job : null;

  /// False while the link to the Q is down (a job restarts the bridge).
  bool get linkUp => _linkUp;

  /// Ask the Q for its job: after a (re)connect, or when the app opens.
  Future<void> refreshJob() async {
    Map<String, dynamic>? r;
    try {
      r = await client.call('getUpdateJob');
    } on NexusQError catch (e) {
      // unknown_method: a bridge before r70, which has no jobs.
      if (e.code != 'unknown_method') {
        AppLog.add('update', 'getUpdateJob failed: $e', warn: true);
      }
      return;
    } catch (e) {
      AppLog.add('update', 'getUpdateJob failed: $e', warn: true);
      return;
    }
    final fresh = UpdateJob.fromJson(r['job']);
    if (fresh == null) return;
    if (fresh.running) {
      _set(() => _job = fresh);
    } else if (_job != null && _job!.id == fresh.id && _job!.running) {
      // It ended while the link was down (the bridge restarted, the Q
      // rebooted): the next bridge told an empty room.
      await _onJobFinished(fresh);
    }
  }

  Future<void> _onJobFinished(UpdateJob finished) async {
    // A job this app watched gets its outcome said; one it never saw (Home
    // Assistant started it, or it ended before the app opened) only moves
    // the versions, so the checks are refreshed quietly.
    final watched = _job != null && _job!.id == finished.id;
    _set(() => _job = null);
    // A System update moves our daemons too (upgrade --available), so the
    // device track is read again after either kind.
    if (finished.isSystem) await checkSystemUpdate();
    await checkNexusUpdate();
    if (watched && finished.failed) {
      final message =
          'The update failed: ${finished.error ?? 'the Q gave no reason'}';
      _set(() {
        if (finished.isSystem) {
          _systemError = message;
        } else {
          _nexusError = message;
        }
      });
    }
    await refreshRelease();
  }

  /// Start a job of [method]; true when the Q answered with one. False means a
  /// bridge before r70 (it ignores `async` and blocks; the 60 s slow-call
  /// timeout ends the wait) or a lost answer: the caller narrates the old way.
  Future<bool> _startJob(String method, void Function(String) error) async {
    Map<String, dynamic>? r;
    try {
      r = await client.call(method, {'async': true});
    } on NexusQError catch (e) {
      if (e.code == 'busy') {
        error('An update is already in progress on the Q.');
        await refreshJob();
        return true; // its progress shows; nothing else to narrate
      }
      AppLog.add('update', '$method failed: $e', warn: true);
      // No answer: a bridge before r70 still working, or a lost link.
      if (_noAnswer(e)) return false;
      // The Q answered with a reason (the job could not start, apk failed on
      // a bridge before r70): say it, do not narrate an install that is not
      // happening.
      _set(() => _starting = null);
      error('The update did not start: ${e.message}');
      return true;
    } catch (e) {
      AppLog.add('update', '$method failed: $e', warn: true);
      return false;
    }
    final started = UpdateJob.fromJson(r['job']);
    if (started == null) return false;
    _set(() {
      _job = started;
      _starting = null;
    });
    return true;
  }

  /// No answer from the Q, as opposed to an answer that says no: the client's
  /// own timeout (a bridge before r70 blocks until apk is done) or the link.
  static bool _noAnswer(NexusQError e) =>
      e.code == 'internal' ||
      e.code == 'disconnected' ||
      (e.code == 'unavailable' &&
          const [
            'not connected',
            'connection closed',
            'client closed',
          ].contains(e.message));

  // --- release watch (PROTOCOL §12c) ---------------------------------------
  // Whether a new Nexus Q release is out, as the Q itself knows it. Null
  // before the first answer, and on a bridge older than r64, which has no
  // release watch: the app then shows nothing about releases at all.
  UpdateStatus? _release;
  bool _checkingRelease = false;

  UpdateStatus? get release => _release;
  bool get checkingRelease => _checkingRelease;

  /// The Q's answer from its last check, or, with [check], a check made now.
  Future<void> refreshRelease({bool check = false}) async {
    if (_checkingRelease) return;
    _set(() => _checkingRelease = true);
    Map<String, dynamic>? r;
    try {
      r = await client.call(
        'getUpdateStatus',
        check ? {'refresh': true} : null,
      );
    } on NexusQError catch (e) {
      // unknown_method: a bridge before r64. Not an error to show.
      if (e.code != 'unknown_method') {
        AppLog.add('update', 'getUpdateStatus failed: $e', warn: true);
      }
    } catch (e) {
      AppLog.add('update', 'getUpdateStatus failed: $e', warn: true);
    }
    _set(() {
      _checkingRelease = false;
      if (r != null) _release = UpdateStatus.fromJson(r);
    });
  }

  /// Anything in flight on any track — what the home screen indicator shows.
  bool get busy => companionBusy || installingSystem;

  void _set(void Function() change) {
    change();
    notifyListeners();
  }

  Future<Map<String, dynamic>?> _call(String method) async {
    try {
      return await client.call(method);
    } catch (e) {
      AppLog.add('update', '$method failed: $e', warn: true);
      return null;
    }
  }

  // --- app track -------------------------------------------------------------

  Future<void> checkUpdate() async {
    // No app-track outside Android (AppUpdate.selfUpdateSupported): the binary
    // is App Store/TestFlight-managed there.
    if (!AppUpdate.selfUpdateSupported) return;
    if (_checkingUpdate) return;
    _set(() {
      _checkingUpdate = true;
      _updateError = null;
    });
    final rel = await AppUpdate.fetchLatest();
    _set(() {
      _checkingUpdate = false;
      // fetchLatest (not checkForUpdate) so a network/parse failure is DISTINCT
      // from "up to date": null here == fetch failed -> say so.
      if (rel == null) {
        _update = null;
        _updateError = 'Update check failed — check your connection.';
      } else if (!AppUpdate.knowsOwnVersion) {
        // A build with no APP_VERSION cannot compare itself to anything. Saying
        // so beats offering an update it would install forever (see AppUpdate).
        _update = null;
        _updateError =
            'This build has no version stamp — build with '
            'build-apk.sh to enable update checks.';
      } else if (rel.versionCode <= AppUpdate.currentVersionCode!) {
        _update = null; // genuinely up to date
      } else {
        _update = rel;
      }
    });
  }

  Future<void> installUpdate() async {
    final rel = _update;
    if (rel == null || _downloading) return;
    _set(() {
      _downloading = true;
      _downloadProgress = 0;
      _downloadBytes = 0;
      _updateError = null;
    });
    try {
      final path = await AppUpdate.downloadApk(rel, (frac, received) {
        _set(() {
          _downloadProgress = frac;
          _downloadBytes = received;
        });
      });
      await AppUpdate.install(path); // OS installer takes over
      _set(() => _downloading = false);
    } catch (e) {
      AppLog.add('update', 'install failed: $e', warn: true);
      _set(() {
        _downloading = false;
        _updateError = 'Update failed. Try again.';
      });
    }
  }

  // --- device daemon track ---------------------------------------------------

  Future<void> checkNexusUpdate() async {
    if (_checkingNexus || installingNexus) return;
    _set(() {
      _checkingNexus = true;
      _nexusError = null;
    });
    final r = await _call('checkNexusUpdate');
    _set(() {
      _checkingNexus = false;
      _nexusCheck = r;
    });
  }

  Future<void> installNexusUpdate() async {
    if (installingNexus) return;
    _set(() {
      _nexusError = null;
      _starting = 'daemons';
    });
    // r70+: a job, whose progress and end arrive as events.
    if (await _startJob('installNexusUpdate', (m) => _nexusError = m)) {
      _set(() => _starting = null);
      return;
    }
    _set(() {
      _starting = null;
      _installingNexus = true; // "Installing…" until verified
      // keep _nexusCheck: its package list is what the UI shows as "what's
      // installing"; clearing it hid the whole install block.
    });
    // A bridge before r70: the call above WAS the install (it ignores `async`).
    // It upgrades the daemons and RESTARTS them — including the control
    // bridge, which necessarily drops THIS connection. So a null/timeout from
    // the call is EXPECTED, not a failure: the device may well have succeeded.
    // The real outcome is confirmed by reconnecting and re-checking, never by
    // that call's return value — and never by calling it again.
    await _sleep(const Duration(seconds: 8)); // daemons restart + relink
    await _verifyNexusInstall();
  }

  Future<void> _verifyNexusInstall() async {
    for (var attempt = 0; attempt < 4; attempt++) {
      final r = await _call('checkNexusUpdate');
      if (r != null) {
        final stillPending = r['updateAvailable'] == true;
        _set(() {
          _installingNexus = false;
          _nexusCheck = r;
          _nexusError = stillPending
              ? 'Device update failed. Try again.'
              : null;
        });
        return;
      }
      await _sleep(const Duration(seconds: 3)); // link not back yet, retry
    }
    // Couldn't reach the device after retries — inconclusive, not a hard failure.
    _set(() {
      _installingNexus = false;
      _nexusError = 'Update sent — tap ⟳ to confirm.';
    });
  }

  // --- full-system track -----------------------------------------------------

  Future<void> checkSystemUpdate() async {
    if (_checkingSystem || installingSystem) return;
    // The ⟳ asks both: the packages (apk) and the release (its notes).
    unawaited(refreshRelease(check: true));
    _set(() {
      _checkingSystem = true;
      _systemError = null;
    });
    final r = await _call('checkSystemUpdate');
    _set(() {
      _checkingSystem = false;
      // busy=true means the device is mid-install (control r26 serializes apk):
      // don't overwrite the last known result, just say so.
      if (r != null && r['busy'] == true) {
        _systemError = 'An update is already in progress — try again shortly.';
      } else {
        _systemCheck = r;
      }
    });
  }

  Future<void> installSystemUpdate() async {
    if (installingSystem) return;
    _set(() {
      _systemError = null;
      _starting = 'system';
    });
    // r70+: a job, whose progress and end arrive as events.
    if (await _startJob('installSystemUpdate', (m) => _systemError = m)) {
      _set(() => _starting = null);
      return;
    }
    // A bridge before r70: one blocking call, then reconnect and re-check.
    // The call usually timed out (60 s) long before apk was done; the install
    // went on and the re-check below waits for it.
    _set(() {
      _starting = null;
      _installingSystem = true;
      _systemProgress = 'Downloading & installing packages on the Q…';
    });
    _set(
      () => _systemProgress = 'Applying updates — the Q may restart to finish…',
    );
    await _sleep(const Duration(seconds: 12));
    await _verifySystemInstall();
  }

  Future<void> _verifySystemInstall() async {
    for (var attempt = 0; attempt < 8; attempt++) {
      _set(
        () => _systemProgress = attempt == 0
            ? 'Reconnecting to the Q…'
            : 'Reconnecting to the Q… (${attempt + 1}/8)',
      );
      final r = await _call('checkSystemUpdate');
      // Wait past a transient disconnect (reboot) OR a busy reply (control still
      // finishing its install lock) before judging.
      if (r != null && r['busy'] != true) {
        final stillPending = r['updateAvailable'] == true;
        _set(() {
          _installingSystem = false;
          _systemProgress = null;
          _systemCheck = r;
          // A leftover upgradable package is NOT a failure (the install ran and
          // the device came back) — only nudge the user to run it again.
          _systemError = stillPending
              ? 'Installed — a few packages still pending; tap Update system '
                    'again to finish them.'
              : null;
        });
        // The Q compared the release with what is installed as the install
        // ended; this reconnected link has not heard it yet.
        await refreshRelease();
        return;
      }
      await _sleep(const Duration(seconds: 5)); // device still rebooting
    }
    _set(() {
      _installingSystem = false;
      _systemProgress = null;
      _systemError = 'Update sent — tap ⟳ to confirm it applied.';
    });
  }

  // --- the merged "App update" (phone app + device daemons) ------------------

  Future<void> checkCompanion() =>
      Future.wait([checkUpdate(), checkNexusUpdate()]);

  /// One "Update" action for the whole companion: device daemons FIRST, then
  /// the phone app. Whichever side has no update is simply skipped.
  Future<void> installCompanion() async {
    if (companionBusy) return;
    if (nexusUpdateAvailable) await installNexusUpdate();
    if (_update != null) await installUpdate();
  }

  String companionStatusLine() {
    final parts = <String>[];
    if (_update != null) {
      parts.add(
        _update!.notes.isNotEmpty
            ? 'App v${_update!.version} — ${_update!.notes}'
            : 'App v${_update!.version}',
      );
    }
    if (nexusUpdateAvailable) {
      final pkgs =
          (_nexusCheck?['packages'] as List?)?.cast<Map<String, dynamic>>() ??
          [];
      final up = pkgs
          .where((p) => p['upgradable'] == true)
          .map((p) => '${p['name']} → ${p['available']}');
      parts.add('Device software: ${up.join(', ')}');
    }
    if (parts.isNotEmpty) return parts.join('\n');
    final ctrl =
        ((_nexusCheck?['packages'] as List?)?.cast<Map<String, dynamic>>() ??
                [])
            .firstWhere(
              (p) => p['name'] == 'nexusq-control',
              orElse: () => {'installed': '?'},
            );
    // On iOS the app binary is App Store/TestFlight-managed and never fetched
    // for comparison here, so qualify it rather than implying a completed check.
    final app = AppUpdate.selfUpdateSupported
        ? 'App v$kAppVersion'
        : 'App v$kAppVersion (App Store)';
    return '$app · device nexusq-control ${ctrl['installed']}';
  }

  String systemStatusLine() {
    final c = _systemCheck;
    if (c == null) return 'Tap ⟳ to check the kernel + all system packages.';
    final kernel = c['kernel'] ?? '?';
    final pkgs = (c['packages'] as List?)?.cast<Map<String, dynamic>>() ?? [];
    if (systemUpdateAvailable) {
      return 'Kernel $kernel · ${pkgs.length} package${pkgs.length == 1 ? '' : 's'} can be updated';
    }
    return 'Kernel $kernel · up to date';
  }
}
