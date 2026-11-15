import 'package:flutter_test/flutter_test.dart';
import 'package:panorama_privacy_prototype/review_model.dart';
import 'package:shared_preferences/shared_preferences.dart';

class TestOwnerContext implements AuthenticatedOwnerContext {
  TestOwnerContext(this.authenticatedUid);
  @override
  final String authenticatedUid;
}

void main() {
  const digest =
      '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';
  const changedDigest =
      'abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789';
  late LocalOwnerReviewStore store;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    store = LocalOwnerReviewStore();
  });

  test(
    'review persists authenticated UID, time, digest, version and approval',
    () async {
      final time = DateTime.utc(2026, 11, 15, 14);
      await store.save(
        owner: TestOwnerContext('firebase-uid-1'),
        derivativeSha256: digest,
        processingVersion: 'privacy-v2',
        approved: true,
        reviewedAt: time,
      );
      final record = await store.loadForDerivative(digest);
      expect(record?.ownerUid, 'firebase-uid-1');
      expect(record?.reviewedAt, time);
      expect(record?.derivativeSha256, digest);
      expect(record?.processingVersion, 'privacy-v2');
      expect(record?.approved, isTrue);
      expect(await store.loadForDerivative(changedDigest), isNull);
    },
  );

  test('empty authenticated identity cannot create a review record', () async {
    await expectLater(
      store.save(
        owner: TestOwnerContext(' '),
        derivativeSha256: digest,
        processingVersion: 'privacy-v2',
        approved: true,
      ),
      throwsStateError,
    );
    expect(await store.loadForDerivative(digest), isNull);
  });

  test('invalidating derivative removes previous review', () async {
    await store.save(
      owner: TestOwnerContext('uid'),
      derivativeSha256: digest,
      processingVersion: 'privacy-v2',
      approved: true,
    );
    await store.invalidate(digest);
    expect(await store.loadForDerivative(digest), isNull);
  });

  test(
    'local prototype review has no invented UID and is explicitly labelled',
    () async {
      await store.saveLocalPrototype(
        derivativeSha256: digest,
        processingVersion: 'privacy-v2',
        approved: true,
        reviewedAt: DateTime.utc(2026, 11, 16),
      );
      final record = await store.loadForDerivative(digest);
      expect(record?.ownerUid, isNull);
      expect(record?.recordType, 'local-prototype-review');
      expect(record?.approved, isTrue);
      expect(record?.reviewedAt, DateTime.utc(2026, 11, 16));
    },
  );

  test(
    'coverage persists and derivative invalidation clears review and progress',
    () async {
      await store.saveCoverage(
        derivativeSha256: digest,
        inspected: {0, 3, 47, -1, 99},
      );
      expect(await store.loadCoverage(digest), {0, 3, 47});
      await store.saveLocalPrototype(
        derivativeSha256: digest,
        processingVersion: 'privacy-v2',
        approved: true,
      );
      await store.invalidate(digest);
      expect(await store.loadCoverage(digest), isEmpty);
      expect(await store.loadForDerivative(digest), isNull);
    },
  );
}
