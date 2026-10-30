import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;

import 'models.dart';

String defaultApiBaseUrl() {
  const override = String.fromEnvironment('API_BASE');
  if (override.isNotEmpty) return override;
  if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
    return 'http://10.0.2.2:8000/api/v1';
  }
  return 'http://127.0.0.1:8000/api/v1';
}

class ApiException implements Exception {
  ApiException(this.message, {this.status, Map<String, String>? fieldErrors})
      : fieldErrors = fieldErrors ?? const {};

  factory ApiException.fromResponse(int status, dynamic body) {
    final map = body is Map ? Map<String, dynamic>.from(body) : <String, dynamic>{};
    final errors = <String, String>{};
    final raw = map['errors'];
    if (raw is Map) {
      for (final entry in raw.entries) {
        final value = entry.value;
        errors[entry.key.toString()] = value is List && value.isNotEmpty
            ? value.first.toString()
            : value.toString();
      }
    }
    final message = map['message'] is String
        ? map['message'] as String
        : (errors.values.isNotEmpty ? errors.values.first : 'Request failed ($status)');
    return ApiException(message, status: status, fieldErrors: errors);
  }

  final String message;
  final int? status;
  final Map<String, String> fieldErrors;

  String? field(String key) => fieldErrors[key];

  @override
  String toString() => message;
}

class LocalSpotApi {
  LocalSpotApi({String? baseUrl}) : baseUrl = baseUrl ?? defaultApiBaseUrl();

  final String baseUrl;
  String? token;
  static const _tokenKey = 'localspot_sanctum_token';
  final _secure = const FlutterSecureStorage();

  Uri _uri(String path, [Map<String, String>? query]) {
    final normalized = path.startsWith('/') ? path : '/$path';
    return Uri.parse('$baseUrl$normalized').replace(queryParameters: query);
  }

  Map<String, String> _headers() => {
        'Accept': 'application/json',
        'Content-Type': 'application/json',
        if (token != null) 'Authorization': 'Bearer $token',
      };

  Future<dynamic> get(String path, [Map<String, String>? query]) async {
    final envelope = await getEnvelope(path, query);
    return envelope['data'];
  }

  Future<Map<String, dynamic>> getEnvelope(String path, [Map<String, String>? query]) async {
    final response = await http.get(_uri(path, query), headers: _headers()).timeout(const Duration(seconds: 8));
    return _decodeEnvelope(response);
  }

  Future<dynamic> post(String path, [Map<String, dynamic>? body]) async {
    final response = await http
        .post(_uri(path), headers: _headers(), body: jsonEncode(body ?? {}))
        .timeout(const Duration(seconds: 12));
    return _decode(response);
  }

  Future<void> persistToken(String? value) async {
    token = value;
    try {
      if (value == null) {
        await _secure.delete(key: _tokenKey);
      } else {
        await _secure.write(key: _tokenKey, value: value);
      }
    } catch (_) {}
  }

  Future<void> restoreToken() async {
    try {
      token = await _secure.read(key: _tokenKey);
    } catch (_) {}
  }

  Future<dynamic> delete(String path) async {
    final response = await http.delete(_uri(path), headers: _headers()).timeout(const Duration(seconds: 8));
    return _decode(response);
  }

  Future<dynamic> patch(String path, [Map<String, dynamic>? body]) async {
    final response = await http
        .patch(_uri(path), headers: _headers(), body: jsonEncode(body ?? {}))
        .timeout(const Duration(seconds: 12));
    return _decode(response);
  }

  dynamic _decode(http.Response response) {
    final envelope = _decodeEnvelope(response);
    return envelope.containsKey('data') ? envelope['data'] : envelope;
  }

  Map<String, dynamic> _decodeEnvelope(http.Response response) {
    final body = response.body.isEmpty ? {} : jsonDecode(response.body);
    if (response.statusCode >= 400) {
      throw ApiException.fromResponse(response.statusCode, body);
    }
    if (body is Map<String, dynamic>) return body;
    if (body is Map) return Map<String, dynamic>.from(body);
    return {'data': body};
  }
}

T _enum<T extends Enum>(List<T> values, String raw, T fallback) {
  final compact = raw.replaceAll('_', '');
  for (final value in values) {
    if (value.name.toLowerCase() == raw.toLowerCase() || value.name.toLowerCase() == compact.toLowerCase()) {
      return value;
    }
  }
  return fallback;
}

UserAccount userFromJson(Map<String, dynamic> json) {
  return UserAccount(
    id: json['id'] as int,
    name: json['name'] as String,
    email: json['email'] as String,
    password: '',
    role: _enum(AppRole.values, json['role'] as String, AppRole.customer),
    ownedStoreIds: [...?(json['owned_store_ids'] as List?)?.map((e) => e as int)],
    memberStoreIds: [...?(json['member_store_ids'] as List?)?.map((e) => e as int)],
    storeGrants: {
      for (final row in (json['store_grants'] as List? ?? []))
        (row as Map)['store_id'] as int: StoreGrant(
          inventory: row['inventory'] == true,
          promotions: row['promotions'] == true,
          location: row['location'] == true,
        ),
    },
  );
}

Store storeFromJson(Map<String, dynamic> json) {
  return Store(
    id: json['id'] as int,
    ownerId: json['owner_id'] as int,
    name: json['name'] as String,
    type: _enum(StoreType.values, json['type'] as String, StoreType.other),
    status: _enum(StoreStatus.values, json['status'] as String, StoreStatus.pending),
    lat: (json['lat'] as num).toDouble(),
    lng: (json['lng'] as num).toDouble(),
    barangay: json['barangay'] as String? ?? '',
    city: json['city'] as String? ?? '',
    address: json['address'] as String? ?? '',
    landmark: json['landmark'] as String? ?? '',
    schedule: json['schedule'] as String? ?? '',
    isMobile: json['is_mobile'] == true,
    image: json['image'] as String?,
    verificationNote: json['verification_note'] as String? ?? '',
    locationMode: _enum(LocationMode.values, json['location_mode'] as String? ?? (json['is_mobile'] == true ? 'regular' : 'fixed'), LocationMode.fixed),
    locationUpdatedAt: DateTime.tryParse(json['location_updated_at'] as String? ?? ''),
  );
}

RoutePreview routePreviewFromJson(Map<String, dynamic> json) {
  return RoutePreview(
    coordinates: [
      for (final row in (json['coordinates'] as List? ?? []))
        GeoPoint((row[0] as num).toDouble(), (row[1] as num).toDouble()),
    ],
    distanceKm: (json['distance_km'] as num?)?.toDouble() ?? 0,
    durationMinutes: json['duration_minutes'] as int?,
    provider: json['provider'] as String? ?? 'localspot',
    fallback: json['fallback'] == true,
  );
}

VendorSession? vendorSessionFromJson(Map<String, dynamic>? json) {
  if (json == null) return null;
  return VendorSession(
    id: json['id'] as int?,
    storeId: json['store_id'] as int,
    lat: (json['lat'] as num).toDouble(),
    lng: (json['lng'] as num).toDouble(),
    startedAt: DateTime.tryParse(json['started_at'] as String? ?? '') ?? DateTime.now(),
    lastUpdateAt: DateTime.tryParse(json['last_update_at'] as String? ?? '') ?? DateTime.now(),
    expiresAt: DateTime.tryParse(json['expires_at'] as String? ?? '') ?? DateTime.now().add(const Duration(hours: 2)),
    endedAt: DateTime.tryParse(json['ended_at'] as String? ?? ''),
  );
}

CatalogProduct productFromJson(Map<String, dynamic> json) {
  return CatalogProduct(
    id: json['id'] as int,
    name: json['name'] as String,
    category: json['category'] as String? ?? '',
    brand: json['brand'] as String? ?? '',
    packageSize: json['package_size'] as String? ?? '',
    aliases: [...?(json['aliases'] as List?)?.map((e) => e.toString())],
    barcode: json['barcode'] as String?,
    image: json['image'] as String? ?? '',
    attributes: {
      for (final entry in Map<String, dynamic>.from(json['attributes'] as Map? ?? {}).entries)
        entry.key: '${entry.value}',
    },
  );
}

StoreListing listingFromJson(Map<String, dynamic> json) {
  return StoreListing(
    id: json['id'] as int,
    storeId: json['store_id'] as int,
    productId: json['product_id'] as int,
    price: (json['price'] as num).toDouble(),
    unit: json['unit'] as String,
    quantity: json['quantity'] as int? ?? 0,
    availability: _enum(Availability.values, json['availability'] as String, Availability.inStock),
    lastConfirmed: DateTime.tryParse(json['last_confirmed_at'] as String? ?? '') ?? DateTime.now(),
    status: _enum(ListingStatus.values, json['status'] as String? ?? 'active', ListingStatus.active),
  );
}

Promotion promotionFromJson(Map<String, dynamic> json) {
  return Promotion(
    id: json['id'] as int,
    storeId: json['store_id'] as int,
    title: json['title'] as String,
    offer: json['offer'] as String,
    startsAt: DateTime.tryParse(json['starts_at'] as String? ?? '') ?? DateTime.now(),
    endsAt: DateTime.tryParse(json['ends_at'] as String? ?? '') ?? DateTime.now(),
    sponsored: json['sponsored'] == true,
    status: _enum(PromotionStatus.values, json['status'] as String, PromotionStatus.pending),
  );
}

StoreTour tourFromJson(Map<String, dynamic> json) {
  return StoreTour(
    id: json['id'] as int,
    storeId: json['store_id'] as int,
    title: json['title'] as String,
    status: _enum(TourStatus.values, json['status'] as String, TourStatus.draft),
    nodes: [
      for (final node in (json['nodes'] as List? ?? []))
        TourNode(
          id: node['id'] as int,
          title: node['title'] as String,
          image: node['image'] as String? ?? '',
          connections: [...?(node['connections'] as List?)?.map((e) => e as int)],
          privacyStatus: _enum(PrivacyStatus.values, node['privacy_status'] as String? ?? 'ready', PrivacyStatus.ready),
          ownerReviewed: node['owner_reviewed'] == true,
          manualBlur: node['manual_blur'] == true,
          originalRetained: node['original_retained'] == true,
          blurRegions: [
            for (final region in (node['blur_regions'] as List? ?? []))
              BlurRegion(
                x: (region['x'] as num).toDouble(),
                y: (region['y'] as num).toDouble(),
                w: (region['w'] as num).toDouble(),
                h: (region['h'] as num).toDouble(),
              ),
          ],
        ),
    ],
  );
}

String availabilityApi(Availability value) => switch (value) {
      Availability.inStock => 'in_stock',
      Availability.low => 'low',
      Availability.unavailable => 'unavailable',
    };
