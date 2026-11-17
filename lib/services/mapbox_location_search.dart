import 'dart:convert';

import 'package:http/http.dart' as http;

import '../mapbox_config.dart';

class MapboxLocationResult {
  const MapboxLocationResult({
    required this.name,
    required this.placeName,
    required this.latitude,
    required this.longitude,
  });

  final String name;
  final String placeName;
  final double latitude;
  final double longitude;
}

Future<List<MapboxLocationResult>> searchMapboxLocations(
  String query, {
  double? latitude,
  double? longitude,
}) async {
  final searchText = query.trim().replaceAll(';', ' ');
  if (searchText.length < 2) return const [];
  if (!hasMapboxPublicToken) {
    throw const MapboxLocationSearchException(
      'Place search is unavailable because the map service is not configured.',
    );
  }

  final uri = Uri.parse(
    'https://api.mapbox.com/geocoding/v5/mapbox.places/${Uri.encodeComponent(searchText)}.json',
  ).replace(
    queryParameters: {
      'access_token': mapboxAccessToken,
      'autocomplete': 'false',
      'country': 'PH',
      'language': 'en',
      'limit': '5',
      if (latitude != null && longitude != null)
        'proximity': '$longitude,$latitude',
    },
  );

  final response = await http.get(uri).timeout(const Duration(seconds: 12));
  if (response.statusCode != 200) {
    throw const MapboxLocationSearchException(
      'Could not search places right now. Try again in a moment.',
    );
  }

  final payload = jsonDecode(response.body);
  if (payload is! Map || payload['features'] is! List) {
    throw const MapboxLocationSearchException(
      'The place search returned an invalid response.',
    );
  }

  return [
    for (final feature in payload['features'] as List)
      if (feature is Map &&
          feature['center'] is List &&
          (feature['center'] as List).length >= 2 &&
          feature['center'][0] is num &&
          feature['center'][1] is num)
        MapboxLocationResult(
          name: feature['text']?.toString() ?? 'Selected area',
          placeName: feature['place_name']?.toString() ?? 'Selected area',
          longitude: (feature['center'][0] as num).toDouble(),
          latitude: (feature['center'][1] as num).toDouble(),
        ),
  ];
}

class MapboxLocationSearchException implements Exception {
  const MapboxLocationSearchException(this.message);
  final String message;

  @override
  String toString() => message;
}
