import 'package:flutter_test/flutter_test.dart';
import 'package:panorama_privacy_prototype/review_flow.dart';

void main() {
  test(
    '48 actual viewpoints span all longitudes, seam, and both polar caps',
    () {
      expect(reviewDirections, hasLength(48));
      expect(reviewDirections.map((d) => d.index).toSet(), hasLength(48));
      expect(reviewDirections.map((d) => d.longitude).toSet(), hasLength(8));
      expect(reviewDirections.map((d) => d.latitude).toSet(), {
        -75,
        -45,
        -15,
        15,
        45,
        75,
      });
      expect(reviewDirections.any((d) => d.longitude == -157.5), isTrue);
      expect(reviewDirections.any((d) => d.longitude == 157.5), isTrue);
    },
  );

  test(
    'coverage advances only when an explicit index is marked and can reset',
    () {
      final coverage = ReviewCoverage();
      expect(coverage.completed, 0);
      for (var i = 0; i < 47; i++) {
        coverage.markInspected(i);
      }
      expect(coverage.completed, 47);
      expect(coverage.isComplete, isFalse);
      expect(coverage.nextUninspected.index, 47);
      coverage.markInspected(47);
      expect(coverage.isComplete, isTrue);
      coverage.reset();
      expect(coverage.completed, 0);
    },
  );

  test('approval requires every independent review condition', () {
    const baseline = ReviewEligibility(
      allDirectionsInspected: true,
      derivativeExists: true,
      digestMatches: true,
      processingIdle: true,
      missRiskAcknowledged: true,
      manualInspectionConfirmed: true,
    );
    expect(baseline.canApprove, isTrue);
    const missing = [
      ReviewEligibility(
        allDirectionsInspected: false,
        derivativeExists: true,
        digestMatches: true,
        processingIdle: true,
        missRiskAcknowledged: true,
        manualInspectionConfirmed: true,
      ),
      ReviewEligibility(
        allDirectionsInspected: true,
        derivativeExists: false,
        digestMatches: true,
        processingIdle: true,
        missRiskAcknowledged: true,
        manualInspectionConfirmed: true,
      ),
      ReviewEligibility(
        allDirectionsInspected: true,
        derivativeExists: true,
        digestMatches: false,
        processingIdle: true,
        missRiskAcknowledged: true,
        manualInspectionConfirmed: true,
      ),
      ReviewEligibility(
        allDirectionsInspected: true,
        derivativeExists: true,
        digestMatches: true,
        processingIdle: false,
        missRiskAcknowledged: true,
        manualInspectionConfirmed: true,
      ),
      ReviewEligibility(
        allDirectionsInspected: true,
        derivativeExists: true,
        digestMatches: true,
        processingIdle: true,
        missRiskAcknowledged: false,
        manualInspectionConfirmed: true,
      ),
      ReviewEligibility(
        allDirectionsInspected: true,
        derivativeExists: true,
        digestMatches: true,
        processingIdle: true,
        missRiskAcknowledged: true,
        manualInspectionConfirmed: false,
      ),
    ];
    expect(missing.every((item) => !item.canApprove), isTrue);
  });
}
