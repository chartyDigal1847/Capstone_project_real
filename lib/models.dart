enum AppRole { customer, owner, staff, admin }

enum StoreType {
  sariSari,
  fruitVegetable,
  marketStall,
  streetVendor,
  convenience,
  supermarket,
  generalMerchandise,
  hardware,
  electronics,
  appliance,
  clothing,
  bookstore,
  autoParts,
  other,
}

const productCategories = [
  'Produce',
  'Groceries',
  'Staples',
  'Bakery',
  'Street food',
  'Drinks',
  'Hardware',
  'Tools',
  'Plumbing',
  'Electrical',
  'Electronics',
  'Computers',
  'Phones',
  'Appliances',
  'Household',
  'Furniture',
  'Clothing',
  'Books',
  'Automotive',
];

const browseFamilies = [
  ('Food', 'food'),
  ('Tech', 'tech'),
  ('Hardware', 'hardware'),
  ('Clothing', 'clothing'),
  ('Household', 'household'),
];

const familyFilterPrefix = 'family:';

String familyFilterValue(String familyKey) => '$familyFilterPrefix$familyKey';

String? familyKeyFromFilter(String? filter) {
  if (filter == null || !filter.startsWith(familyFilterPrefix)) return null;
  return filter.substring(familyFilterPrefix.length);
}

List<String> categoriesMatchingFilter(String? filter) {
  if (filter == null || filter.isEmpty) return const [];
  final family = familyKeyFromFilter(filter);
  if (family != null) return categoryFamilies[family] ?? const [];
  return [filter];
}

bool productMatchesCategoryFilter(String productCategory, String? filter) {
  if (filter == null || filter.isEmpty) return true;
  return categoriesMatchingFilter(filter).any((category) => category.toLowerCase() == productCategory.toLowerCase());
}

String categoryFilterLabel(String? filter) {
  if (filter == null || filter.isEmpty) return 'All products';
  final family = familyKeyFromFilter(filter);
  if (family != null) {
    for (final item in browseFamilies) {
      if (item.$2 == family) return 'All ${item.$1}';
    }
    return 'All $family';
  }
  return filter;
}

const categoryFamilies = <String, List<String>>{
  'food': ['Produce', 'Groceries', 'Staples', 'Bakery', 'Street food', 'Drinks'],
  'tech': ['Electronics', 'Computers', 'Phones', 'Appliances'],
  'hardware': ['Hardware', 'Tools', 'Plumbing', 'Electrical'],
  'clothing': ['Clothing'],
  'household': ['Household', 'Furniture', 'Appliances'],
};

const categorySynonyms = <String, String>{
  'food': 'food',
  'pagkain': 'food',
  'grocery': 'food',
  'groceries': 'food',
  'produce': 'food',
  'tech': 'tech',
  'gadget': 'tech',
  'electronics': 'tech',
  'computer': 'tech',
  'phone': 'tech',
  'hardware': 'hardware',
  'tools': 'hardware',
  'tool': 'hardware',
  'clothing': 'clothing',
  'clothes': 'clothing',
  'household': 'household',
};

List<String> expandedCategories(String query) {
  final cleaned = query
      .toLowerCase()
      .replaceAll(RegExp(r'\b(near me|nearby|around here)\b'), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  if (cleaned.isEmpty) return const [];
  for (final token in cleaned.split(' ')) {
    final family = categorySynonyms[token] ?? (categoryFamilies.containsKey(token) ? token : null);
    if (family != null) return categoryFamilies[family] ?? const [];
  }
  return const [];
}

enum SearchMatchType { exact, category, similar, identifier, semantic }

enum SearchSort { relevance, distance, price, freshness }

String searchSortLabel(SearchSort sort) => switch (sort) {
      SearchSort.relevance => 'Relevance',
      SearchSort.distance => 'Distance',
      SearchSort.price => 'Price',
      SearchSort.freshness => 'Freshness',
    };

List<(String key, String label)> categoryAttributeFields(String category) {
  final value = category.toLowerCase();
  if (value.contains('cloth')) {
    return const [('size', 'Size'), ('material', 'Material')];
  }
  if (value.contains('electron') || value == 'phones' || value == 'computers') {
    return const [('model', 'Model'), ('capacity', 'Capacity / storage'), ('compatibility', 'Compatibility (if known)')];
  }
  if (value.contains('hardware') || value == 'tools' || value == 'plumbing' || value == 'electrical') {
    return const [('dimensions', 'Dimensions'), ('material', 'Material'), ('voltage', 'Voltage (if any)')];
  }
  if (value.contains('auto')) {
    return const [('fitment', 'Make / model / year')];
  }
  if (value.contains('produce') || value.contains('food') || value.contains('bakery') || value.contains('drink')) {
    return const [('variety', 'Variety'), ('unit_hint', 'Typical selling unit')];
  }
  return const [('details', 'Extra details (optional)')];
}

String matchTypeLabel(SearchMatchType type) => switch (type) {
      SearchMatchType.exact => 'Exact',
      SearchMatchType.category => 'Category',
      SearchMatchType.similar => 'Visually similar',
      SearchMatchType.identifier => 'Identifier',
      SearchMatchType.semantic => 'Similar need',
    };

enum PrivacyStatus { pending, processing, needsReview, ready, failed }

enum StoreStatus { pending, approved, suspended }

enum ListingStatus { active, archived, unavailable }

enum Availability { inStock, low, unavailable }

enum PromotionStatus { draft, pending, approved, rejected }

enum TourStatus { draft, published }

enum LocationMode { fixed, regular, live, stale }

class GeoPoint {
  const GeoPoint(this.lat, this.lng);
  final double lat;
  final double lng;
}

class RoutePreview {
  RoutePreview({
    required this.coordinates,
    required this.distanceKm,
    required this.durationMinutes,
    required this.provider,
    required this.fallback,
  });

  final List<GeoPoint> coordinates;
  final double distanceKm;
  final int? durationMinutes;
  final String provider;
  final bool fallback;
}

class VendorSession {
  VendorSession({
    required this.storeId,
    required this.lat,
    required this.lng,
    required this.startedAt,
    required this.lastUpdateAt,
    required this.expiresAt,
    this.endedAt,
    this.id,
  });

  final int? id;
  final int storeId;
  double lat;
  double lng;
  DateTime startedAt;
  DateTime lastUpdateAt;
  DateTime expiresAt;
  DateTime? endedAt;

  bool get isActive => endedAt == null && expiresAt.isAfter(DateTime.now());
}

class StoreGrant {
  StoreGrant({this.inventory = true, this.promotions = false, this.location = false});

  bool inventory;
  bool promotions;
  bool location;
}

class UserAccount {
  UserAccount({
    required this.id,
    required this.name,
    required this.email,
    required this.password,
    required this.role,
    this.ownedStoreIds = const [],
    this.memberStoreIds = const [],
    Map<int, StoreGrant>? storeGrants,
  }) : storeGrants = storeGrants ?? {};

  final int id;
  String name;
  final String email;
  final String password;
  AppRole role;
  List<int> ownedStoreIds;
  List<int> memberStoreIds;
  Map<int, StoreGrant> storeGrants;
}

class Store {
  Store({
    required this.id,
    required this.ownerId,
    required this.name,
    required this.type,
    required this.status,
    required this.lat,
    required this.lng,
    required this.barangay,
    required this.city,
    required this.address,
    required this.landmark,
    required this.schedule,
    required this.isMobile,
    this.image,
    this.verificationNote = '',
    this.locationMode = LocationMode.fixed,
    this.locationUpdatedAt,
  });

  final int id;
  int ownerId;
  String name;
  StoreType type;
  StoreStatus status;
  double lat;
  double lng;
  String barangay;
  String city;
  String address;
  String landmark;
  String schedule;
  bool isMobile;
  String? image;
  String verificationNote;
  LocationMode locationMode;
  DateTime? locationUpdatedAt;
}

class CatalogProduct {
  CatalogProduct({
    required this.id,
    required this.name,
    required this.category,
    required this.brand,
    required this.packageSize,
    required this.aliases,
    this.barcode,
    required this.image,
    this.attributes = const {},
  });

  final int id;
  String name;
  String category;
  String brand;
  String packageSize;
  List<String> aliases;
  String? barcode;
  String image;
  Map<String, String> attributes;
}

class StoreListing {
  StoreListing({
    required this.id,
    required this.storeId,
    required this.productId,
    required this.price,
    required this.unit,
    required this.quantity,
    required this.availability,
    required this.lastConfirmed,
    this.status = ListingStatus.active,
  });

  final int id;
  final int storeId;
  int productId;
  double price;
  String unit;
  int quantity;
  Availability availability;
  DateTime lastConfirmed;
  ListingStatus status;
}

class Promotion {
  Promotion({
    required this.id,
    required this.storeId,
    required this.title,
    required this.offer,
    required this.startsAt,
    required this.endsAt,
    required this.sponsored,
    required this.status,
  });

  final int id;
  final int storeId;
  String title;
  String offer;
  DateTime startsAt;
  DateTime endsAt;
  bool sponsored;
  PromotionStatus status;
}

class BlurRegion {
  const BlurRegion({required this.x, required this.y, required this.w, required this.h});
  final double x;
  final double y;
  final double w;
  final double h;
}

class TourNode {
  TourNode({
    required this.id,
    required this.title,
    required this.image,
    required this.connections,
    this.privacyStatus = PrivacyStatus.ready,
    this.ownerReviewed = false,
    this.manualBlur = false,
    this.originalRetained = false,
    this.blurRegions = const [],
  });

  final int id;
  String title;
  String image;
  List<int> connections;
  PrivacyStatus privacyStatus;
  bool ownerReviewed;
  bool manualBlur;
  bool originalRetained;
  List<BlurRegion> blurRegions;

  bool get canPublish => privacyStatus == PrivacyStatus.ready && ownerReviewed && image.trim().isNotEmpty;
}

class StoreTour {
  StoreTour({
    required this.id,
    required this.storeId,
    required this.title,
    required this.status,
    required this.nodes,
  });

  final int id;
  final int storeId;
  String title;
  TourStatus status;
  List<TourNode> nodes;
}

class StockChange {
  StockChange({
    required this.kind,
    required this.quantityDelta,
    required this.note,
    required this.at,
  });

  final String kind;
  final int quantityDelta;
  final String note;
  final DateTime at;
}

class AuditEntry {
  AuditEntry({
    required this.id,
    required this.action,
    this.userId,
    this.createdAt,
  });

  final int id;
  final String action;
  final int? userId;
  final DateTime? createdAt;
}

class ReportItem {
  ReportItem({
    required this.id,
    required this.userId,
    required this.target,
    required this.reason,
    this.resolved = false,
  });

  final int id;
  final int userId;
  final String target;
  final String reason;
  bool resolved;
}

class PilotFeedback {
  PilotFeedback({
    required this.id,
    required this.userId,
    required this.topic,
    required this.body,
    this.area,
  });

  final int id;
  final int userId;
  final String topic;
  final String body;
  final String? area;
}

class SearchHit {
  SearchHit({
    required this.listing,
    required this.store,
    required this.product,
    required this.distanceKm,
    this.matchType = SearchMatchType.exact,
  });

  final StoreListing listing;
  final Store store;
  final CatalogProduct product;
  final double distanceKm;
  final SearchMatchType matchType;
}

extension FirstOrNullX<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}

extension StoreTypeLabel on StoreType {
  String get label => switch (this) {
        StoreType.sariSari => 'Sari-sari store',
        StoreType.fruitVegetable => 'Fruit & vegetable vendor',
        StoreType.marketStall => 'Public-market stall',
        StoreType.streetVendor => 'Street / mobile vendor',
        StoreType.convenience => 'Convenience store',
        StoreType.supermarket => 'Supermarket',
        StoreType.generalMerchandise => 'General merchandise',
        StoreType.hardware => 'Hardware / construction',
        StoreType.electronics => 'Electronics / technology',
        StoreType.appliance => 'Appliances',
        StoreType.clothing => 'Clothing & footwear',
        StoreType.bookstore => 'Bookstore',
        StoreType.autoParts => 'Auto / motorcycle parts',
        StoreType.other => 'Other local seller',
      };
}
