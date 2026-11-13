import 'dart:math';

class SearchCursorPage<T> {
  const SearchCursorPage({
    required this.items,
    required this.total,
    required this.currentPage,
    required this.lastPage,
    required this.nextCursor,
    required this.metadata,
    this.expired = false,
  });

  final List<T> items;
  final int total;
  final int currentPage;
  final int lastPage;
  final String? nextCursor;
  final Map<String, dynamic> metadata;
  final bool expired;
}

/// Continues pages over an already filtered and globally sorted result snapshot.
/// The bounded Firestore candidate query runs once, so later pages cannot reorder
/// when source documents change and do not repeat the same candidate reads.
class SearchCursorCache<T> {
  SearchCursorCache({
    Duration timeToLive = const Duration(minutes: 2),
    int maxSnapshots = 4,
    DateTime Function()? clock,
    Random? random,
  }) : _timeToLive = timeToLive,
       _maxSnapshots = maxSnapshots,
       _clock = clock ?? DateTime.now,
       _random = random ?? Random.secure() {
    if (_timeToLive <= Duration.zero) {
      throw ArgumentError.value(timeToLive, 'timeToLive');
    }
    if (_maxSnapshots < 1) {
      throw ArgumentError.value(maxSnapshots, 'maxSnapshots');
    }
  }

  final Duration _timeToLive;
  final int _maxSnapshots;
  final DateTime Function() _clock;
  final Random _random;
  final Map<String, _SearchCursorSnapshot<T>> _snapshots = {};

  SearchCursorPage<T> begin({
    required String fingerprint,
    required List<T> items,
    required int pageSize,
    required Map<String, dynamic> metadata,
    int offset = 0,
  }) {
    _validatePageSize(pageSize);
    if (offset < 0) throw ArgumentError.value(offset, 'offset');
    _pruneExpired();
    final snapshotId = _newSnapshotId();
    final snapshot = _SearchCursorSnapshot<T>(
      fingerprint: fingerprint,
      items: List<T>.unmodifiable(items),
      metadata: Map<String, dynamic>.unmodifiable(metadata),
      createdAt: _clock(),
    );
    if (items.length > offset + pageSize) {
      _snapshots[snapshotId] = snapshot;
      _trimSnapshots();
    }
    return _page(snapshotId, snapshot, offset, pageSize);
  }

  SearchCursorPage<T> continueFrom({
    required String cursor,
    required String fingerprint,
    required int pageSize,
  }) {
    _validatePageSize(pageSize);
    _pruneExpired();
    final separator = cursor.lastIndexOf('.');
    if (separator < 1 || separator == cursor.length - 1) {
      return _expiredPage();
    }
    final snapshotId = cursor.substring(0, separator);
    final offset = int.tryParse(cursor.substring(separator + 1));
    final snapshot = _snapshots[snapshotId];
    if (offset == null ||
        snapshot == null ||
        snapshot.fingerprint != fingerprint) {
      return _expiredPage();
    }
    // Refresh insertion order for bounded LRU eviction without extending TTL.
    _snapshots.remove(snapshotId);
    _snapshots[snapshotId] = snapshot;
    return _page(snapshotId, snapshot, offset, pageSize);
  }

  SearchCursorPage<T> _page(
    String snapshotId,
    _SearchCursorSnapshot<T> snapshot,
    int offset,
    int pageSize,
  ) {
    final start = min(offset, snapshot.items.length);
    final end = min(start + pageSize, snapshot.items.length);
    final hasMore = end < snapshot.items.length;
    final lastPage = max(1, (snapshot.items.length / pageSize).ceil());
    return SearchCursorPage<T>(
      items: snapshot.items.sublist(start, end),
      total: snapshot.items.length,
      currentPage: (start ~/ pageSize) + 1,
      lastPage: lastPage,
      nextCursor: hasMore ? '$snapshotId.$end' : null,
      metadata: snapshot.metadata,
    );
  }

  SearchCursorPage<T> _expiredPage() => SearchCursorPage<T>(
    items: const [],
    total: 0,
    currentPage: 1,
    lastPage: 1,
    nextCursor: null,
    metadata: const {},
    expired: true,
  );

  String _newSnapshotId() {
    String id;
    do {
      id =
          List<String>.generate(
            4,
            (_) =>
                _random.nextInt(0x100000000).toRadixString(16).padLeft(8, '0'),
          ).join();
    } while (_snapshots.containsKey(id));
    return id;
  }

  void _pruneExpired() {
    final now = _clock();
    _snapshots.removeWhere(
      (_, snapshot) => now.difference(snapshot.createdAt) >= _timeToLive,
    );
  }

  void _trimSnapshots() {
    while (_snapshots.length > _maxSnapshots) {
      _snapshots.remove(_snapshots.keys.first);
    }
  }

  void _validatePageSize(int pageSize) {
    if (pageSize < 1) throw ArgumentError.value(pageSize, 'pageSize');
  }
}

class _SearchCursorSnapshot<T> {
  const _SearchCursorSnapshot({
    required this.fingerprint,
    required this.items,
    required this.metadata,
    required this.createdAt,
  });

  final String fingerprint;
  final List<T> items;
  final Map<String, dynamic> metadata;
  final DateTime createdAt;
}
