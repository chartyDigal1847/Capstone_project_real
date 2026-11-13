const _geohashBase32 = '0123456789bcdefghjkmnpqrstuvwxyz';

String encodeGeohash(double latitude, double longitude, {int precision = 4}) {
  if (!latitude.isFinite ||
      latitude < -90 ||
      latitude > 90 ||
      !longitude.isFinite ||
      longitude < -180 ||
      longitude > 180) {
    throw ArgumentError('Coordinates are outside their valid ranges.');
  }
  var south = -90.0;
  var north = 90.0;
  var west = -180.0;
  var east = 180.0;
  var even = true;
  var bits = 0;
  var value = 0;
  final hash = StringBuffer();
  while (hash.length < precision) {
    final midpoint = even ? (west + east) / 2 : (south + north) / 2;
    final coordinate = even ? longitude : latitude;
    final upper = coordinate >= midpoint;
    value = (value << 1) | (upper ? 1 : 0);
    if (even) {
      if (upper) {
        west = midpoint;
      } else {
        east = midpoint;
      }
    } else if (upper) {
      south = midpoint;
    } else {
      north = midpoint;
    }
    even = !even;
    bits++;
    if (bits == 5) {
      hash.write(_geohashBase32[value]);
      bits = 0;
      value = 0;
    }
  }
  return hash.toString();
}

List<String> nearbyGeohashPrefixes(double latitude, double longitude) {
  const precision = 4;
  final centerHash = encodeGeohash(latitude, longitude, precision: precision);
  var south = -90.0;
  var north = 90.0;
  var west = -180.0;
  var east = 180.0;
  var even = true;
  for (final character in centerHash.split('')) {
    final value = _geohashBase32.indexOf(character);
    for (var mask = 16; mask != 0; mask >>= 1) {
      final upper = (value & mask) != 0;
      if (even) {
        final midpoint = (west + east) / 2;
        if (upper) {
          west = midpoint;
        } else {
          east = midpoint;
        }
      } else {
        final midpoint = (south + north) / 2;
        if (upper) {
          south = midpoint;
        } else {
          north = midpoint;
        }
      }
      even = !even;
    }
  }
  final height = north - south;
  final width = east - west;
  final centerLat = (south + north) / 2;
  final centerLng = (west + east) / 2;
  final prefixes = <String>{};
  for (var dy = -1; dy <= 1; dy++) {
    for (var dx = -1; dx <= 1; dx++) {
      final lat = centerLat + dy * height;
      final lng = centerLng + dx * width;
      if (lat >= -90 && lat <= 90 && lng >= -180 && lng <= 180) {
        prefixes.add(encodeGeohash(lat, lng, precision: precision));
      }
    }
  }
  return prefixes.toList(growable: false);
}
