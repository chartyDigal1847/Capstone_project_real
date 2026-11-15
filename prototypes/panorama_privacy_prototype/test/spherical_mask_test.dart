import 'package:flutter_test/flutter_test.dart';
import 'package:panorama_privacy_prototype/spherical_mask.dart';

void main() {
  test('seam-crossing spherical mask splits across both equirectangular edges', () {
    final segments = SphericalMaskGeometry.horizontalSegments(.99, .035);
    expect(segments, hasLength(2));
    expect(segments[0].$1, closeTo(.99, 1e-9));
    expect(segments[0].$2, closeTo(.01, 1e-9));
    expect(segments[1].$1, 0);
    expect(segments[1].$2, closeTo(.025, 1e-9));
  });

  test('moving region wraps longitude and clamps latitude span at poles', () {
    final moved = SphericalMaskGeometry.move({'x': .99, 'y': .90, 'w': .08, 'h': .07}, .04, .20);
    expect(moved['x'], closeTo(.03, 1e-9));
    expect(moved['y'], closeTo(.93, 1e-9));
  });

  test('resize clamps angular spans to supported range', () {
    final enlarged = SphericalMaskGeometry.resize({'x': .2, 'y': .2, 'w': .49, 'h': .49}, .2, .2);
    expect(enlarged['w'], .5);
    expect(enlarged['h'], .5);
  });
}
