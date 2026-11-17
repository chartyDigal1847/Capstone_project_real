import 'dart:convert';

import 'package:flutter/services.dart' show rootBundle;

class PsgcBarangay {
  const PsgcBarangay({
    required this.code,
    required this.name,
    this.latitude,
    this.longitude,
  });

  final String code;
  final String name;
  final double? latitude;
  final double? longitude;
}

class PsgcCityMunicipality {
  const PsgcCityMunicipality({
    required this.code,
    required this.name,
    required this.adminArea,
    required this.region,
    required this.barangays,
    this.latitude,
    this.longitude,
  });

  final String code;
  final String name;
  final String adminArea;
  final String region;
  final List<PsgcBarangay> barangays;
  final double? latitude;
  final double? longitude;

  String get searchLabel => '$name $adminArea $region';
  String get displayLabel => '$name · $adminArea';
}

class OfflinePsgcLocations {
  const OfflinePsgcLocations({required this.cities, required this.published});

  final List<PsgcCityMunicipality> cities;
  final String published;

  static Future<OfflinePsgcLocations> load() async {
    final json = jsonDecode(
      await rootBundle.loadString('assets/data/ph_psgc_locations.json'),
    );
    if (json is! Map || json['cities'] is! List) {
      throw const FormatException('Offline PSGC location data is invalid.');
    }
    final cities = <PsgcCityMunicipality>[];
    for (final rawCity in json['cities'] as List) {
      if (rawCity is! Map || rawCity['barangays'] is! List) continue;
      final rawBarangays = rawCity['barangays'] as List;
      final barangays = <PsgcBarangay>[];
      for (final rawBarangay in rawBarangays) {
        if (rawBarangay is! Map) continue;
        final point = rawBarangay['point'];
        barangays.add(
          PsgcBarangay(
            code: rawBarangay['code']?.toString() ?? '',
            name: rawBarangay['name']?.toString() ?? '',
            latitude:
                point is List && point.length >= 2
                    ? (point[0] as num?)?.toDouble()
                    : null,
            longitude:
                point is List && point.length >= 2
                    ? (point[1] as num?)?.toDouble()
                    : null,
          ),
        );
      }
      final point = rawCity['point'];
      cities.add(
        PsgcCityMunicipality(
          code: rawCity['code']?.toString() ?? '',
          name: rawCity['name']?.toString() ?? '',
          adminArea: rawCity['adminArea']?.toString() ?? '',
          region: rawCity['region']?.toString() ?? '',
          barangays: List.unmodifiable(barangays),
          latitude:
              point is List && point.length >= 2
                  ? (point[0] as num?)?.toDouble()
                  : null,
          longitude:
              point is List && point.length >= 2
                  ? (point[1] as num?)?.toDouble()
                  : null,
        ),
      );
    }
    return OfflinePsgcLocations(
      cities: List.unmodifiable(cities),
      published: json['published']?.toString() ?? 'PSGC',
    );
  }
}
