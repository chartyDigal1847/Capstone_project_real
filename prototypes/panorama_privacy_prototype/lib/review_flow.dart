import 'package:flutter/foundation.dart';

@immutable
class ReviewDirection {
  const ReviewDirection(this.index, this.longitude, this.latitude);
  final int index;
  final double longitude;
  final double latitude;
  String get label =>
      'Direction ${index + 1} · ${latitude > 0 ? 'upper' : 'lower'} sphere';
}

/// 8 evenly spaced longitudes × 6 latitude levels. The ±75° viewpoints
/// include the polar caps in their camera field of view; the panorama viewer
/// itself remains freely navigable between these review checkpoints.
final reviewDirections = List<ReviewDirection>.unmodifiable([
  for (var lat = 0; lat < 6; lat++)
    for (var lon = 0; lon < 8; lon++)
      ReviewDirection(lat * 8 + lon, -157.5 + lon * 45, -75 + lat * 30),
]);

class ReviewCoverage {
  ReviewCoverage([Set<int>? inspected]) : inspected = {...?inspected};
  final Set<int> inspected;
  int get completed => inspected.length;
  bool get isComplete => inspected.length == reviewDirections.length;
  ReviewDirection get nextUninspected =>
      reviewDirections.firstWhere((d) => !inspected.contains(d.index));
  void markInspected(int index) {
    if (index < 0 || index >= reviewDirections.length)
      throw RangeError.index(index, reviewDirections);
    inspected.add(index);
  }

  void reset() => inspected.clear();
}

@immutable
class ReviewEligibility {
  const ReviewEligibility({
    required this.allDirectionsInspected,
    required this.derivativeExists,
    required this.digestMatches,
    required this.processingIdle,
    required this.missRiskAcknowledged,
    required this.manualInspectionConfirmed,
  });
  final bool allDirectionsInspected;
  final bool derivativeExists;
  final bool digestMatches;
  final bool processingIdle;
  final bool missRiskAcknowledged;
  final bool manualInspectionConfirmed;
  bool get canApprove =>
      allDirectionsInspected &&
      derivativeExists &&
      digestMatches &&
      processingIdle &&
      missRiskAcknowledged &&
      manualInspectionConfirmed;
}

/// Local processing and owner-attestation receipt returned to an integrating
/// host application. This is client data only; it is not backend verification.
@immutable
class PanoramaPrivacyReceipt {
  const PanoramaPrivacyReceipt({
    required this.sourcePath,
    required this.sourceName,
    required this.sourceSha256,
    required this.derivativePath,
    required this.derivativeSha256,
    required this.processingVersion,
    required this.reviewedAt,
    required this.inspectedDirections,
    required this.acknowledgedMissRisk,
    required this.acknowledgedManualInspection,
  });

  final String sourcePath;
  final String sourceName;
  final String sourceSha256;
  final String derivativePath;
  final String derivativeSha256;
  final String processingVersion;
  final DateTime reviewedAt;
  final Set<int> inspectedDirections;
  final bool acknowledgedMissRisk;
  final bool acknowledgedManualInspection;
}
