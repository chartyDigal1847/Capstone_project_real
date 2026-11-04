// api.dart — shared data-transfer utilities for LocalSpot.
//
// The HTTP-based Laravel client has been removed as part of the Firebase
// migration.  Only the exception type, JSON helpers and from-JSON
// constructors remain here so the rest of the codebase is unaffected.

import 'models.dart';

class ApiException implements Exception {
  ApiException(this.message, {this.status, Map<String, String>? fieldErrors})
      : fieldErrors = fieldErrors ?? const {};

  factory ApiException.fromResponse(int status, dynamic body) {
    final map =
        body is Map ? Map<String, dynamic>.from(body) : <String, dynamic>{};
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
        : (errors.values.isNotEmpty
            ? errors.values.first
            : 'Request failed ($status)');
    return ApiException(message, status: status, fieldErrors: errors);
  }

  final String message;
  final int? status;
  final Map<String, String> fieldErrors;

  String? field(String key) => fieldErrors[key];

  @override
  String toString() => message;
}

// ── JSON helpers ──────────────────────────────────────────────────────

int asInt(dynamic value, [int fallback = 0]) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  return int.tryParse('$value') ?? fallback;
}

T _enum<T extends Enum>(List<T> values, String raw, T fallback) {
  final compact = raw.replaceAll('_', '');
  for (final v in values) {
    if (v.name.toLowerCase() == raw.toLowerCase() ||
        v.name.toLowerCase() == compact.toLowerCase()) {
      return v;
    }
  }
  return fallback;
}

UserAccount userFromJson(Map<String, dynamic> json) {
  return UserAccount(
    id: asInt(json['id']),
    name: json['name'] as String,
    email: json['email'] as String,
    password: '',
    role: _enum(AppRole.values, json['role'] as String, AppRole.customer),
    ownedStoreIds: [...?(json['owned_store_ids'] as List?)?.map(asInt)],
    memberStoreIds: [...?(json['member_store_ids'] as List?)?.map(asInt)],
    storeGrants: {
      for (final row in (json['store_grants'] as List? ?? []))
        asInt((row as Map)['store_id']): StoreGrant(
          inventory: row['inventory'] == true,
          promotions: row['promotions'] == true,
          location: row['location'] == true,
        ),
    },
  );
}

Store storeFromJson(Map<String, dynamic> json) {
  return Store(
    id: asInt(json['id']),
    ownerId: asInt(json['owner_id']),
    name: json['name'] as String? ?? '',
    type: _enum(StoreType.values, json['type'] as String? ?? 'other', StoreType.other),
    status:
        _enum(StoreStatus.values, json['status'] as String? ?? 'pending', StoreStatus.pending),
    lat: (json['lat'] as num?)?.toDouble() ?? 0.0,
    lng: (json['lng'] as num?)?.toDouble() ?? 0.0,
    barangay: json['barangay'] as String? ?? '',
    city: json['city'] as String? ?? '',
    address: json['address'] as String? ?? '',
    landmark: json['landmark'] as String? ?? '',
    schedule: json['schedule'] as String? ?? '',
    isMobile: json['is_mobile'] == true,
    image: json['image'] as String?,
    verificationNote: json['verification_note'] as String? ?? '',
    locationMode: _enum(
      LocationMode.values,
      json['location_mode'] as String? ??
          (json['is_mobile'] == true ? 'regular' : 'fixed'),
      LocationMode.fixed,
    ),
    locationUpdatedAt:
        DateTime.tryParse(json['location_updated_at'] as String? ?? ''),
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
    id: json['id'] == null ? null : asInt(json['id']),
    storeId: asInt(json['store_id']),
    lat: (json['lat'] as num).toDouble(),
    lng: (json['lng'] as num).toDouble(),
    startedAt:
        DateTime.tryParse(json['started_at'] as String? ?? '') ?? DateTime.now(),
    lastUpdateAt:
        DateTime.tryParse(json['last_update_at'] as String? ?? '') ??
            DateTime.now(),
    expiresAt: DateTime.tryParse(json['expires_at'] as String? ?? '') ??
        DateTime.now().add(const Duration(hours: 2)),
    endedAt: DateTime.tryParse(json['ended_at'] as String? ?? ''),
  );
}

CatalogProduct productFromJson(Map<String, dynamic> json) {
  return CatalogProduct(
    id: asInt(json['id']),
    name: json['name'] as String,
    category: json['category'] as String? ?? '',
    brand: json['brand'] as String? ?? '',
    packageSize: json['package_size'] as String? ?? '',
    aliases: [...?(json['aliases'] as List?)?.map((e) => e.toString())],
    barcode: json['barcode'] as String?,
    image: json['image'] as String? ?? '',
    attributes: {
      for (final entry in Map<String, dynamic>.from(
              json['attributes'] as Map? ?? {})
          .entries)
        entry.key: '${entry.value}',
    },
  );
}

StoreListing listingFromJson(Map<String, dynamic> json) {
  return StoreListing(
    id: asInt(json['id']),
    storeId: asInt(json['store_id']),
    productId: asInt(json['product_id']),
    price: (json['price'] as num?)?.toDouble() ?? 0.0,
    unit: json['unit'] as String? ?? 'piece',
    quantity: (json['quantity'] as num?)?.toInt() ?? 0,
    availability: _enum(
        Availability.values, json['availability'] as String? ?? 'in_stock', Availability.inStock),
    lastConfirmed:
        DateTime.tryParse(json['last_confirmed_at'] as String? ?? '') ??
            DateTime.now(),
    status: _enum(ListingStatus.values,
        json['status'] as String? ?? 'active', ListingStatus.active),
  );
}

Promotion promotionFromJson(Map<String, dynamic> json) {
  return Promotion(
    id: asInt(json['id']),
    storeId: asInt(json['store_id']),
    title: json['title'] as String,
    offer: json['offer'] as String,
    startsAt:
        DateTime.tryParse(json['starts_at'] as String? ?? '') ?? DateTime.now(),
    endsAt:
        DateTime.tryParse(json['ends_at'] as String? ?? '') ?? DateTime.now(),
    sponsored: json['sponsored'] == true,
    status: _enum(PromotionStatus.values, json['status'] as String,
        PromotionStatus.pending),
  );
}

StoreTour tourFromJson(Map<String, dynamic> json) {
  return StoreTour(
    id: asInt(json['id']),
    storeId: asInt(json['store_id']),
    title: json['title'] as String,
    status: _enum(TourStatus.values, json['status'] as String, TourStatus.draft),
    nodes: [
      for (final node in (json['nodes'] as List? ?? []))
        TourNode(
          id: asInt(node['id']),
          title: node['title'] as String,
          image: node['image'] as String? ?? '',
          connections: [...?(node['connections'] as List?)?.map(asInt)],
          privacyStatus: _enum(PrivacyStatus.values,
              node['privacy_status'] as String? ?? 'ready', PrivacyStatus.ready),
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
