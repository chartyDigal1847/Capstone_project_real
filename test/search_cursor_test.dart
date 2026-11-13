import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:localspot/firebase/search_cursor.dart';

void main() {
  group('SearchCursorCache', () {
    test(
      'continues through a stable sorted snapshot without repeating rows',
      () {
        final cache = SearchCursorCache<int>(random: Random(7));
        final first = cache.begin(
          fingerprint: 'q=rice&sort=price',
          items: [1, 2, 3, 4, 5],
          pageSize: 2,
          metadata: const {'candidate_truncated': true},
        );

        expect(first.items, [1, 2]);
        expect(first.currentPage, 1);
        expect(first.lastPage, 3);
        expect(first.metadata['candidate_truncated'], isTrue);
        expect(first.nextCursor, isNotNull);

        final second = cache.continueFrom(
          cursor: first.nextCursor!,
          fingerprint: 'q=rice&sort=price',
          pageSize: 2,
        );
        expect(second.items, [3, 4]);
        expect(second.currentPage, 2);
        expect(second.nextCursor, isNotNull);

        final third = cache.continueFrom(
          cursor: second.nextCursor!,
          fingerprint: 'q=rice&sort=price',
          pageSize: 2,
        );
        expect(third.items, [5]);
        expect(third.currentPage, 3);
        expect(third.nextCursor, isNull);
      },
    );

    test('rejects a cursor used with different search filters', () {
      final cache = SearchCursorCache<int>(random: Random(9));
      final first = cache.begin(
        fingerprint: 'q=rice&sort=price',
        items: [1, 2, 3],
        pageSize: 2,
        metadata: const {},
      );

      final mismatched = cache.continueFrom(
        cursor: first.nextCursor!,
        fingerprint: 'q=rice&sort=freshness',
        pageSize: 2,
      );
      expect(mismatched.expired, isTrue);
      expect(mismatched.items, isEmpty);
      expect(mismatched.nextCursor, isNull);
    });

    test('expires snapshots after the configured lifetime', () {
      var now = DateTime.utc(2026, 11, 13);
      final cache = SearchCursorCache<int>(
        timeToLive: const Duration(seconds: 30),
        clock: () => now,
        random: Random(11),
      );
      final first = cache.begin(
        fingerprint: 'q=rice',
        items: [1, 2, 3],
        pageSize: 2,
        metadata: const {},
      );

      now = now.add(const Duration(seconds: 31));
      final expired = cache.continueFrom(
        cursor: first.nextCursor!,
        fingerprint: 'q=rice',
        pageSize: 2,
      );
      expect(expired.expired, isTrue);
      expect(expired.items, isEmpty);
    });
  });
}
