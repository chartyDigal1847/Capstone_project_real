import 'dart:convert';
import 'dart:math' as math;

import 'package:http/http.dart' as http;

import '../mapbox_config.dart';
import '../models.dart';

class DirectionsException implements Exception {
  const DirectionsException(this.message);

  final String message;

  @override
  String toString() => message;
}

class DirectionsService {
  DirectionsService({http.Client? client, String? accessToken})
    : _client = client ?? http.Client(),
      _accessToken = accessToken ?? mapboxAccessToken;

  final http.Client _client;
  final String _accessToken;

  Future<RoutePreview> getDrivingRoute({
    required double originLat,
    required double originLng,
    required double destinationLat,
    required double destinationLng,
  }) async {
    if (!_validCoordinates(originLat, originLng) ||
        !_validCoordinates(destinationLat, destinationLng)) {
      throw const DirectionsException(
        'The origin or destination coordinates are invalid.',
      );
    }
    if (!_accessToken.startsWith('pk.') || _accessToken.startsWith('sk.')) {
      throw const DirectionsException(
        'Add a public Mapbox token with --dart-define=ACCESS_TOKEN=pk.… to load road directions.',
      );
    }

    final path = '$originLng,$originLat;$destinationLng,$destinationLat';
    final uri =
        Uri.https('api.mapbox.com', '/directions/v5/mapbox/driving/$path', {
          'alternatives': 'false',
          'geometries': 'geojson',
          'overview': 'full',
          'steps': 'false',
          'access_token': _accessToken,
        });

    final response = await _client
        .get(uri, headers: const {'Accept': 'application/json'})
        .timeout(const Duration(seconds: 12));
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw DirectionsException(
        'Mapbox Directions request failed (${response.statusCode}). Check the public token and its Directions scope.',
      );
    }

    final decoded = jsonDecode(response.body);
    if (decoded is! Map) {
      throw const DirectionsException(
        'Mapbox returned an invalid directions response.',
      );
    }
    if (decoded['code'] != 'Ok') {
      final code = decoded['code']?.toString();
      throw DirectionsException(
        code == 'NoRoute'
            ? 'No driving route is available between these locations.'
            : 'Mapbox could not calculate a driving route${code == null ? '' : ' ($code)'}.',
      );
    }

    final routes = decoded['routes'];
    if (routes is! List || routes.isEmpty || routes.first is! Map) {
      throw const DirectionsException('Mapbox did not return a driving route.');
    }
    final route = Map<String, dynamic>.from(routes.first as Map);
    final geometry = route['geometry'];
    final rawCoordinates = geometry is Map ? geometry['coordinates'] : null;
    if (geometry is! Map ||
        geometry['type'] != 'LineString' ||
        rawCoordinates is! List ||
        rawCoordinates.length < 2) {
      throw const DirectionsException(
        'Mapbox returned route geometry that could not be displayed.',
      );
    }

    final coordinates = <GeoPoint>[];
    for (final coordinate in rawCoordinates) {
      if (coordinate is! List ||
          coordinate.length < 2 ||
          coordinate[0] is! num ||
          coordinate[1] is! num) {
        throw const DirectionsException(
          'Mapbox returned invalid route coordinates.',
        );
      }
      coordinates.add(
        GeoPoint(
          (coordinate[1] as num).toDouble(),
          (coordinate[0] as num).toDouble(),
        ),
      );
    }

    final distanceMeters = route['distance'];
    final durationSeconds = route['duration'];
    if (distanceMeters is! num || durationSeconds is! num) {
      throw const DirectionsException(
        'Mapbox returned incomplete route information.',
      );
    }

    return RoutePreview(
      coordinates: coordinates,
      distanceKm: distanceMeters.toDouble() / 1000,
      durationMinutes: math.max(1, (durationSeconds.toDouble() / 60).round()),
      provider: 'Mapbox Directions · driving',
      fallback: false,
    );
  }

  bool _validCoordinates(double latitude, double longitude) =>
      latitude.isFinite &&
      longitude.isFinite &&
      latitude >= -90 &&
      latitude <= 90 &&
      longitude >= -180 &&
      longitude <= 180;
}
