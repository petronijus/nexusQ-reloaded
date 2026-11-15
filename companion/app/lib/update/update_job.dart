// An install job on the Q (PROTOCOL §12d, nexusq-control r70+).
//
// The bridge no longer installs inside one blocking call: it starts a job that
// downloads everything first, then installs, and pushes its progress
// (`updateProgress`, `updateFinished`). This is that job as the app shows it:
// the phase in words, a percent that never goes back, the package the Q is at
// and an estimate of the time left.

/// Where a job is. `rebooting` still counts as running: the Q comes back on
/// its own, and the next bridge reports the job done.
enum UpdatePhase {
  preparing,
  downloading,
  installing,
  applying,
  rebooting,
  done,
  failed,
}

class UpdateJob {
  UpdateJob({
    required this.id,
    required this.kind,
    required this.state,
    required this.phase,
    this.attempt = 1,
    this.resumed = false,
    this.stalled = false,
    this.percent = 0,
    this.phasePercent = 0,
    this.packagesDone = 0,
    this.packagesTotal = 0,
    this.current,
    this.bytesDone,
    this.bytesTotal,
    this.etaS,
    this.error,
    this.rebootRecommended = false,
  });

  /// Null for anything that is not a job object the app can read.
  static UpdateJob? fromJson(Object? json) {
    if (json is! Map) return null;
    final id = json['id'];
    final kind = json['kind'];
    final state = json['state'];
    if (id is! String || kind is! String || state is! String) return null;
    final p = json['progress'] is Map ? json['progress'] as Map : const {};
    final result = json['result'] is Map ? json['result'] as Map : const {};
    int asInt(Object? v, [int fallback = 0]) => v is num ? v.toInt() : fallback;
    int? asIntOrNull(Object? v) => v is num ? v.toInt() : null;
    return UpdateJob(
      id: id,
      kind: kind,
      state: state,
      phase: _phase(json['phase'], state),
      attempt: asInt(json['attempt'], 1),
      resumed: json['resumed'] == true,
      stalled: json['stalled'] == true,
      percent: asInt(p['percent']).clamp(0, 100),
      phasePercent: asInt(p['phasePercent']).clamp(0, 100),
      packagesDone: asInt(p['packagesDone']),
      packagesTotal: asInt(p['packagesTotal']),
      current: p['current'] is String ? p['current'] as String : null,
      bytesDone: asIntOrNull(p['bytesDone']),
      bytesTotal: asIntOrNull(p['bytesTotal']),
      etaS: asIntOrNull(p['etaS']),
      error: json['error'] is String ? json['error'] as String : null,
      rebootRecommended: result['rebootRecommended'] == true,
    );
  }

  static UpdatePhase _phase(Object? phase, String state) {
    for (final p in UpdatePhase.values) {
      if (p.name == phase) return p;
    }
    // An unknown phase from a newer bridge: say what the state allows.
    return state == 'done'
        ? UpdatePhase.done
        : state == 'failed'
        ? UpdatePhase.failed
        : UpdatePhase.preparing;
  }

  final String id;

  /// `system` (every package but the kernel) or `daemons` (the four daemons).
  final String kind;

  /// `running`, `done` or `failed`.
  final String state;
  final UpdatePhase phase;
  final int attempt;
  final bool resumed;
  final bool stalled;

  /// Overall, 0–100, never goes back.
  final int percent;
  final int phasePercent;
  final int packagesDone;
  final int packagesTotal;
  final String? current;
  final int? bytesDone;
  final int? bytesTotal;
  final int? etaS;
  final String? error;
  final bool rebootRecommended;

  bool get running => state == 'running';
  bool get done => state == 'done';
  bool get failed => state == 'failed';
  bool get isSystem => kind == 'system';

  /// 0.0–1.0 for a progress bar.
  double get fraction => percent / 100.0;

  /// What the Q is doing, as a heading.
  String get headline => switch (phase) {
    UpdatePhase.preparing =>
      resumed ? 'Finishing an interrupted update' : 'Preparing the update',
    UpdatePhase.downloading => 'Downloading the update',
    UpdatePhase.installing => 'Installing the update',
    UpdatePhase.applying => 'Restarting the Q’s services',
    UpdatePhase.rebooting => 'Rebooting the Q to finish',
    UpdatePhase.done => 'Update installed',
    UpdatePhase.failed => 'The update failed',
  };

  /// The numbers behind the heading: how far, what, how long.
  String get detail {
    final parts = <String>[];
    switch (phase) {
      case UpdatePhase.downloading:
        final total = bytesTotal;
        if (total != null && total > 0) {
          parts.add('${_mb(bytesDone ?? 0)} of ${_mb(total)}');
        }
        if (packagesTotal > 0) {
          parts.add('$packagesTotal package${packagesTotal == 1 ? '' : 's'}');
        }
      case UpdatePhase.installing:
        if (packagesTotal > 0) {
          parts.add('$packagesDone of $packagesTotal packages');
        }
        if (current != null) parts.add(current!);
      case UpdatePhase.applying:
        parts.add('the app reconnects in a moment');
      case UpdatePhase.rebooting:
        parts.add('the app reconnects when the Q is back');
      case UpdatePhase.preparing:
        parts.add('checking what is new');
      case UpdatePhase.done:
      case UpdatePhase.failed:
        break;
    }
    final eta = etaText;
    if (eta != null) parts.add(eta);
    return parts.join(' · ');
  }

  /// "about 4 min left", or null while the Q cannot tell yet.
  String? get etaText {
    final s = etaS;
    if (!running || s == null || s <= 0) return null;
    if (s < 90) return 'about a minute left';
    return 'about ${(s / 60).round()} min left';
  }

  static String _mb(int bytes) {
    final mb = bytes / (1024 * 1024);
    return mb >= 10 ? '${mb.round()} MB' : '${mb.toStringAsFixed(1)} MB';
  }
}
