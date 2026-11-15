typedef SphericalMask = Map<String, double>;

/// Equirectangular storage of spherical coordinates: x is wrapped longitude
/// (0..1), y is latitude from north to south, and width/height are angular spans.
class SphericalMaskGeometry {
  static List<(double, double)> horizontalSegments(double x, double width) {
    final start = x % 1.0;
    final end = start + width;
    if (end <= 1.0) return [(start, width)];
    return [(start, 1.0 - start), (0.0, end - 1.0)];
  }

  static SphericalMask move(SphericalMask region, double deltaLongitude, double deltaLatitude) {
    final height = region['h']!;
    return {
      ...region,
      'x': (region['x']! + deltaLongitude) % 1.0,
      'y': (region['y']! + deltaLatitude).clamp(0.0, 1.0 - height),
    };
  }

  static SphericalMask resize(SphericalMask region, double deltaLongitude, double deltaLatitude) => {
    ...region,
    'w': (region['w']! + deltaLongitude).clamp(.01, .5),
    'h': (region['h']! + deltaLatitude).clamp(.01, .5),
  };
}
