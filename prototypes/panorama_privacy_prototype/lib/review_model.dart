import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// The host application must adapt its authenticated Firebase Auth user to this
/// interface. A display name or UID supplied by a text field is not sufficient.
abstract interface class AuthenticatedOwnerContext {
  String get authenticatedUid;
}

class OwnerReviewRecord {
  const OwnerReviewRecord({
    required this.ownerUid,
    required this.recordType,
    required this.reviewedAt,
    required this.derivativeSha256,
    required this.processingVersion,
    required this.approved,
  });

  final String? ownerUid;
  final String recordType;
  final DateTime reviewedAt;
  final String derivativeSha256;
  final String processingVersion;
  final bool approved;

  Map<String, Object?> toJson() => {
    'ownerUid': ownerUid,
    'recordType': recordType,
    'reviewedAt': reviewedAt.toUtc().toIso8601String(),
    'derivativeSha256': derivativeSha256,
    'processingVersion': processingVersion,
    'approved': approved,
  };

  static OwnerReviewRecord? fromJson(String value) {
    try {
      final json = jsonDecode(value) as Map<String, dynamic>;
      return OwnerReviewRecord(
        ownerUid: json['ownerUid'] as String?,
        recordType:
            json['recordType'] as String? ?? 'authenticated-owner-review',
        reviewedAt: DateTime.parse(json['reviewedAt'] as String).toUtc(),
        derivativeSha256: json['derivativeSha256'] as String,
        processingVersion: json['processingVersion'] as String,
        approved: json['approved'] as bool,
      );
    } catch (_) {
      return null;
    }
  }
}

class LocalOwnerReviewStore {
  Future<void> save({
    required AuthenticatedOwnerContext owner,
    required String derivativeSha256,
    required String processingVersion,
    required bool approved,
    DateTime? reviewedAt,
  }) async {
    final uid = owner.authenticatedUid.trim();
    if (uid.isEmpty) {
      throw StateError(
        'An authenticated owner UID is required to record review.',
      );
    }
    if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(derivativeSha256)) {
      throw ArgumentError.value(
        derivativeSha256,
        'derivativeSha256',
        'Expected lowercase SHA-256 hex.',
      );
    }
    final record = OwnerReviewRecord(
      ownerUid: uid,
      recordType: 'authenticated-owner-review',
      reviewedAt: (reviewedAt ?? DateTime.now()).toUtc(),
      derivativeSha256: derivativeSha256,
      processingVersion: processingVersion,
      approved: approved,
    );
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_key(derivativeSha256), jsonEncode(record.toJson()));
  }

  /// Prototype-only local acknowledgement. A missing UID is explicit; this
  /// record must never be interpreted as authenticated production approval.
  Future<void> saveLocalPrototype({
    required String derivativeSha256,
    required String processingVersion,
    required bool approved,
    DateTime? reviewedAt,
  }) async {
    _validateDigest(derivativeSha256);
    final record = OwnerReviewRecord(
      ownerUid: null,
      recordType: 'local-prototype-review',
      reviewedAt: (reviewedAt ?? DateTime.now()).toUtc(),
      derivativeSha256: derivativeSha256,
      processingVersion: processingVersion,
      approved: approved,
    );
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_key(derivativeSha256), jsonEncode(record.toJson()));
  }

  Future<void> saveCoverage({
    required String derivativeSha256,
    required Set<int> inspected,
  }) async {
    _validateDigest(derivativeSha256);
    final clean = inspected.where((i) => i >= 0 && i < 48).toSet().toList()
      ..sort();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_coverageKey(derivativeSha256), jsonEncode(clean));
  }

  Future<Set<int>> loadCoverage(String derivativeSha256) async {
    if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(derivativeSha256)) return {};
    final prefs = await SharedPreferences.getInstance();
    final value = prefs.getString(_coverageKey(derivativeSha256));
    if (value == null) return {};
    try {
      return (jsonDecode(value) as List)
          .whereType<num>()
          .map((n) => n.toInt())
          .where((i) => i >= 0 && i < 48)
          .toSet();
    } catch (_) {
      return {};
    }
  }

  Future<void> clearCoverage(String derivativeSha256) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_coverageKey(derivativeSha256));
  }

  void _validateDigest(String digest) {
    if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(digest)) {
      throw ArgumentError.value(
        digest,
        'derivativeSha256',
        'Expected lowercase SHA-256 hex.',
      );
    }
  }

  Future<OwnerReviewRecord?> loadForDerivative(
    String currentDerivativeSha256,
  ) async {
    if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(currentDerivativeSha256)) {
      return null;
    }
    final prefs = await SharedPreferences.getInstance();
    final stored = prefs.getString(_key(currentDerivativeSha256));
    if (stored == null) return null;
    final record = OwnerReviewRecord.fromJson(stored);
    if (record == null || record.derivativeSha256 != currentDerivativeSha256) {
      return null;
    }
    return record;
  }

  Future<void> invalidate(String derivativeSha256) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_key(derivativeSha256));
    await prefs.remove(_coverageKey(derivativeSha256));
  }

  String _key(String digest) => 'pano.ownerReview.$digest';
  String _coverageKey(String digest) => 'pano.reviewCoverage.$digest';
}
