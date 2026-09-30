// A Nexus Q release as the device reports it (PROTOCOL §12c): the short
// "what's new" of the published release.json, and whether this Q still waits
// for it or already runs it.

/// One line of "what's new": an icon, a title and one sentence.
class ReleaseItem {
  const ReleaseItem({
    required this.icon,
    required this.title,
    required this.text,
  });

  final String icon;
  final String title;
  final String text;

  static ReleaseItem? fromJson(Object? j) {
    if (j is! Map) return null;
    final title = j['title'], text = j['text'], icon = j['icon'];
    if (title is! String || text is! String) return null;
    return ReleaseItem(
      icon: icon is String ? icon : 'new',
      title: title,
      text: text,
    );
  }
}

class Release {
  const Release({
    required this.version,
    required this.date,
    required this.headline,
    required this.items,
  });

  final String version;
  final String date;
  final String headline;
  final List<ReleaseItem> items;

  /// Null for anything that is not a release: the Q sends `null` for "none",
  /// and a malformed object must not become a half-drawn card.
  static Release? fromJson(Object? j) {
    if (j is! Map) return null;
    final version = j['version'], headline = j['headline'];
    if (version is! String || headline is! String) return null;
    final items = [
      for (final i in (j['items'] is List ? j['items'] as List : const []))
        ?ReleaseItem.fromJson(i),
    ];
    if (items.isEmpty) return null;
    return Release(
      version: version,
      date: j['date'] is String ? j['date'] as String : '',
      headline: headline,
      items: items,
    );
  }
}

/// `getUpdateStatus` / `updateStatusChanged`.
class UpdateStatus {
  const UpdateStatus({
    this.id,
    this.checkedAt,
    this.available,
    this.current,
    this.error,
  });

  /// Which Q answered (its `getDeviceInfo` id). The background check drops an
  /// answer from a Q other than the one it asked: an address can move.
  final String? id;

  /// When the Q last reached the release manifest; null before it ever did.
  final DateTime? checkedAt;

  /// The published release while this Q waits for it.
  final Release? available;

  /// The published release once this Q runs it.
  final Release? current;

  /// Why the Q's last check did not count; its last good answer still holds.
  final String? error;

  static UpdateStatus fromJson(Map<String, dynamic> j) {
    final at = j['checkedAt'];
    return UpdateStatus(
      id: j['id'] is String ? j['id'] as String : null,
      checkedAt: at is num
          ? DateTime.fromMillisecondsSinceEpoch(at.toInt() * 1000)
          : null,
      available: Release.fromJson(j['available']),
      current: Release.fromJson(j['current']),
      error: j['error'] is String ? j['error'] as String : null,
    );
  }
}
