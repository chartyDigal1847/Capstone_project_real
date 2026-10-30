import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';

import 'api.dart';
import 'models.dart';
import 'repositories.dart';

const defaultCenterLat = 14.6195;
const defaultCenterLng = 121.0568;
const radiiKm = [1.0, 3.0, 5.0, 10.0];

class AppState extends ChangeNotifier {
  AppState() {
    _seed();
  }

  final api = LocalSpotApi();
  late final authRepo = AuthRepository(api);
  late final catalogRepo = CatalogRepository(api);
  bool apiOnline = false;
  bool usingSeededCatalog = true;
  bool writeBusy = false;
  ApiException? lastApiError;
  String connectionNote = 'Trying LocalSpot API…';

  final users = <UserAccount>[];
  final stores = <Store>[];
  final products = <CatalogProduct>[];
  final listings = <StoreListing>[];
  final promotions = <Promotion>[];
  final tours = <StoreTour>[];
  final reports = <ReportItem>[];
  final feedback = <PilotFeedback>[];
  final favoriteStoreIds = <int>{};
  final favoriteProductIds = <int>{};
  final stockChanges = <int, List<StockChange>>{};
  final auditLogs = <AuditEntry>[];

  UserAccount? currentUser;
  bool locationAllowed = false;
  bool followMyLocation = false;
  double searchLat = defaultCenterLat;
  double searchLng = defaultCenterLng;
  double? deviceLat;
  double? deviceLng;
  String searchAreaLabel = 'Cubao, Quezon City';
  String locationNote = 'Foreground location is off. Pick an area on the map or allow location when you open Map.';
  double radiusKm = 3;
  DateTime? _lastCatalogRefreshAt;
  DateTime? _lastVendorPingAt;
  double? _lastCatalogLat;
  double? _lastCatalogLng;
  StreamSubscription<Position>? _positionSub;
  int _locationHolders = 0;
  final vendorSessions = <int, VendorSession>{};
  RoutePreview? lastRoute;
  StoreType? typeFilter;
  String? categoryFilter;
  String searchDraft = '';
  SearchSort searchSort = SearchSort.relevance;
  List<SearchHit>? remoteSearchHits;
  bool searchBusy = false;
  String searchNote = '';
  String lastSearchQuery = '';
  int searchPage = 1;
  int searchLastPage = 1;
  int searchTotal = 0;
  int _searchGeneration = 0;
  int _recognitionGeneration = 0;

  void cancelSearch() => _searchGeneration++;

  void cancelRecognition() => _recognitionGeneration++;

  void _beginWrite() {
    writeBusy = true;
    notifyListeners();
  }

  void _endWrite() {
    writeBusy = false;
    notifyListeners();
  }

  int _nextUser = 10;
  int _nextStore = 10;
  int _nextProduct = 30;
  int _nextListing = 40;
  int _nextPromo = 10;
  int _nextTour = 10;
  int _nextReport = 10;
  int _nextFeedback = 10;

  bool get signedIn => currentUser != null;
  AppRole get role => currentUser?.role ?? AppRole.customer;

  List<Store> managedStores() {
    final user = currentUser;
    if (user == null) return [];
    return stores.where((store) {
      if (store.ownerId == user.id) return true;
      if (user.ownedStoreIds.contains(store.id) || user.memberStoreIds.contains(store.id)) return true;
      return false;
    }).toList();
  }

  Store? ownedStore() {
    final user = currentUser;
    if (user == null) return null;
    final managed = managedStores();
    if (managed.isNotEmpty) return managed.first;
    if (user.role == AppRole.staff) {
      return stores.where((s) => s.id == 1).firstOrNull;
    }
    return null;
  }

  Future<void> bootstrap() async {
    await api.restoreToken();
    try {
      final data = await catalogRepo.catalog();
      _applyCatalog(data);
      apiOnline = true;
      usingSeededCatalog = false;
      connectionNote = 'Connected to Laravel API · Cubao pilot';
      if (api.token != null) {
        try {
          await _hydrateSession();
        } catch (_) {
          await api.persistToken(null);
          currentUser = null;
        }
      }
    } catch (_) {
      apiOnline = false;
      usingSeededCatalog = true;
      connectionNote = 'API offline · using on-device demo data';
    }
    notifyListeners();
  }

  Future<void> _hydrateSession() async {
    final me = await authRepo.me();
    currentUser = userFromJson(Map<String, dynamic>.from(me['user'] as Map));
    for (final row in (me['stores'] as List? ?? [])) {
      final store = storeFromJson(Map<String, dynamic>.from(row as Map));
      stores.removeWhere((item) => item.id == store.id);
      stores.add(store);
    }
    try {
      final favs = await api.get('/favorites');
      if (favs is List) {
        favoriteStoreIds.clear();
        favoriteProductIds.clear();
        for (final row in favs) {
          final map = Map<String, dynamic>.from(row as Map);
          final id = map['favoritable_id'] as int? ?? map['favoritableId'] as int?;
          final type = map['favoritable_type'] as String? ?? '';
          if (id == null) continue;
          if (type == 'store') favoriteStoreIds.add(id);
          if (type == 'product') favoriteProductIds.add(id);
        }
      }
    } catch (_) {}
    if (role == AppRole.admin) {
      unawaited(loadAudit());
    }
  }

  Future<void> loadAudit() async {
    if (!apiOnline || role != AppRole.admin) return;
    try {
      final rows = await api.get('/admin/audit');
      if (rows is! List) return;
      auditLogs
        ..clear()
        ..addAll([
          for (final row in rows)
            AuditEntry(
              id: (row as Map)['id'] as int,
              action: row['action'] as String? ?? '',
              userId: row['user_id'] as int?,
              createdAt: DateTime.tryParse(row['created_at'] as String? ?? ''),
            ),
        ]);
      notifyListeners();
    } catch (_) {}
  }

  Future<List<StockChange>> loadMovements(StoreListing listing) async {
    if (apiOnline && api.token != null) {
      try {
        final rows = await api.get('/store-products/${listing.id}/movements');
        if (rows is List) {
          final parsed = [
            for (final row in rows)
              StockChange(
                kind: (row as Map)['kind'] as String? ?? 'adjust',
                quantityDelta: (row['quantity_delta'] as num?)?.toInt() ?? 0,
                note: row['note'] as String? ?? '',
                at: DateTime.tryParse(row['created_at'] as String? ?? '') ?? DateTime.now(),
              ),
          ];
          stockChanges[listing.id] = parsed;
          notifyListeners();
          return parsed;
        }
      } catch (_) {}
    }
    return stockChanges[listing.id] ?? const [];
  }

  void _recordMovement(StoreListing listing, {required String kind, required int delta, String note = ''}) {
    stockChanges.putIfAbsent(listing.id, () => []);
    stockChanges[listing.id]!.insert(
      0,
      StockChange(kind: kind, quantityDelta: delta, note: note, at: DateTime.now()),
    );
  }

  Future<void> refreshCatalog() async {
    if (!apiOnline) return;
    final data = await catalogRepo.catalog();
    _applyCatalog(data);
    notifyListeners();
  }

  Future<void> refreshNearby() async {
    if (!apiOnline) return;
    try {
      final query = {
        'lat': searchLat.toString(),
        'lng': searchLng.toString(),
        'radius_km': radiusKm.toString(),
      };
      final rows = await api.get('/stores/nearby', query);
      if (rows is! List) return;
      for (final row in rows) {
        final map = Map<String, dynamic>.from(row as Map);
        final incoming = storeFromJson(map);
        final existing = storeById(incoming.id);
        if (existing == null) {
          stores.add(incoming);
        } else {
          existing.lat = incoming.lat;
          existing.lng = incoming.lng;
          existing.locationMode = incoming.locationMode;
          existing.locationUpdatedAt = incoming.locationUpdatedAt;
        }
        final live = map['live_session'];
        final session = vendorSessionFromJson(live is Map ? Map<String, dynamic>.from(live) : null);
        if (session != null) {
          vendorSessions[session.storeId] = session;
        } else {
          vendorSessions.remove(incoming.id);
        }
      }
      notifyListeners();
    } catch (_) {}
  }

  void _applyCatalog(Map data) {
    stores
      ..clear()
      ..addAll([...((data['stores'] as List?) ?? []).map((e) => storeFromJson(Map<String, dynamic>.from(e)))]);
    vendorSessions.clear();
    for (final row in (data['stores'] as List? ?? [])) {
      final map = Map<String, dynamic>.from(row as Map);
      final session = vendorSessionFromJson(map['live_session'] is Map ? Map<String, dynamic>.from(map['live_session'] as Map) : null);
      if (session != null) vendorSessions[session.storeId] = session;
    }
    products
      ..clear()
      ..addAll([...((data['products'] as List?) ?? []).map((e) => productFromJson(Map<String, dynamic>.from(e)))]);
    listings
      ..clear()
      ..addAll([...((data['listings'] as List?) ?? []).map((e) => listingFromJson(Map<String, dynamic>.from(e)))]);
    promotions
      ..clear()
      ..addAll([...((data['promotions'] as List?) ?? []).map((e) => promotionFromJson(Map<String, dynamic>.from(e)))]);
    tours
      ..clear()
      ..addAll([...((data['tours'] as List?) ?? []).map((e) => tourFromJson(Map<String, dynamic>.from(e)))]);
  }

  Future<ApiException?> register({
    required String name,
    required String email,
    required String password,
    required AppRole role,
  }) async {
    lastApiError = null;
    if (apiOnline) {
      try {
        final data = await authRepo.register(name: name, email: email, password: password, role: role);
        await api.persistToken(data['token'] as String);
        currentUser = userFromJson(Map<String, dynamic>.from(data['user'] as Map));
        await _hydrateSession();
        notifyListeners();
        return null;
      } on ApiException catch (error) {
        lastApiError = error;
        notifyListeners();
        return error;
      }
    }
    final user = UserAccount(
      id: _nextUser++,
      name: name,
      email: email,
      password: password,
      role: role,
    );
    users.add(user);
    currentUser = user;
    notifyListeners();
    return null;
  }

  Future<String?> login(String email, String password) async {
    if (apiOnline) {
      try {
        final data = await authRepo.login(email: email, password: password);
        await api.persistToken(data['token'] as String);
        currentUser = userFromJson(Map<String, dynamic>.from(data['user'] as Map));
        await _hydrateSession();
        if (currentUser!.role == AppRole.admin) {
          final reportData = await api.get('/admin/reports') as List;
          reports
            ..clear()
            ..addAll(reportData.map((e) => ReportItem(
                  id: e['id'] as int,
                  userId: e['user_id'] as int,
                  target: e['target'] as String,
                  reason: e['reason'] as String,
                  resolved: e['resolved'] == true,
                )));
        }
        notifyListeners();
        return null;
      } on ApiException catch (error) {
        return error.message;
      }
    }
    final match = users.where((u) => u.email == email && u.password == password);
    if (match.isEmpty) return 'Email or password is incorrect.';
    currentUser = match.first;
    notifyListeners();
    return null;
  }

  void logout() {
    if (apiOnline && api.token != null) {
      unawaited(api.delete('/auth/logout'));
    }
    unawaited(api.persistToken(null));
    currentUser = null;
    followMyLocation = false;
    unawaited(stopLocationUpdates());
    notifyListeners();
  }

  void useApproximateLocation() {
    locationAllowed = true;
    followMyLocation = false;
    searchLat = defaultCenterLat;
    searchLng = defaultCenterLng;
    deviceLat = defaultCenterLat;
    deviceLng = defaultCenterLng;
    searchAreaLabel = 'Approximate area · Cubao, Quezon City';
    locationNote = 'Using an approximate Cubao fix. Allow precise location on a device to follow your position.';
    notifyListeners();
  }

  void denyLocation() {
    locationAllowed = false;
    followMyLocation = false;
    unawaited(stopLocationUpdates());
    locationNote = 'Location permission is off. Choose a search area on the map.';
    notifyListeners();
  }

  void setManualCenter(double lat, double lng, String label) {
    followMyLocation = false;
    searchLat = lat;
    searchLng = lng;
    searchAreaLabel = label;
    locationNote = 'Using a manually selected search area.';
    notifyListeners();
    unawaited(refreshNearby());
  }

  void setFollowMyLocation(bool value) {
    followMyLocation = value;
    if (value && deviceLat != null && deviceLng != null) {
      searchLat = deviceLat!;
      searchLng = deviceLng!;
      searchAreaLabel = 'Following your location';
    }
    notifyListeners();
  }

  Future<void> requestForegroundLocation({bool startUpdates = false}) async {
    try {
      final service = await Geolocator.isLocationServiceEnabled();
      if (!service) {
        locationAllowed = false;
        locationNote = 'Device location is off. Turn it on, or pick an area manually.';
        notifyListeners();
        return;
      }
      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }
      if (permission == LocationPermission.denied || permission == LocationPermission.deniedForever) {
        denyLocation();
        locationNote = permission == LocationPermission.deniedForever
            ? 'Location is blocked for this app. Use a manual search area.'
            : 'Location permission denied. Use a manual search area.';
        notifyListeners();
        return;
      }
      final position = await Geolocator.getCurrentPosition(locationSettings: const LocationSettings(accuracy: LocationAccuracy.high));
      _applyDevicePosition(position.latitude, position.longitude, recenterSearch: true);
      locationAllowed = true;
      locationNote = 'Foreground location is on. LocalSpot does not request background tracking.';
      if (startUpdates) await startLocationUpdates();
      notifyListeners();
    } catch (_) {
      locationNote = 'Could not read GPS on this device. Pick an area or use the Cubao approximate fix.';
      notifyListeners();
    }
  }

  Future<void> startLocationUpdates() async {
    await _positionSub?.cancel();
    if (!locationAllowed) return;
    _positionSub = Geolocator.getPositionStream(
      locationSettings: const LocationSettings(accuracy: LocationAccuracy.high, distanceFilter: 8),
    ).listen((position) {
      _applyDevicePosition(position.latitude, position.longitude, recenterSearch: followMyLocation);
    }, onError: (_) {});
  }

  Future<void> stopLocationUpdates() async {
    await _positionSub?.cancel();
    _positionSub = null;
  }

  bool get isWatchingLocation => _locationHolders > 0;

  void retainForegroundLocation() {
    _locationHolders++;
    if (_locationHolders == 1 && locationAllowed) {
      unawaited(startLocationUpdates());
    }
  }

  void releaseForegroundLocation() {
    if (_locationHolders == 0) return;
    _locationHolders--;
    if (_locationHolders == 0) {
      unawaited(stopLocationUpdates());
    }
  }

  @visibleForTesting
  void applyDevicePositionForTest(double lat, double lng) {
    locationAllowed = true;
    _applyDevicePosition(lat, lng, recenterSearch: false);
  }

  void _applyDevicePosition(double lat, double lng, {required bool recenterSearch}) {
    deviceLat = lat;
    deviceLng = lng;
    if (recenterSearch) {
      searchLat = lat;
      searchLng = lng;
      searchAreaLabel = 'Current location';
    }
    final movedFar = _lastCatalogLat == null ||
        distanceKm(_lastCatalogLat!, _lastCatalogLng ?? lng, lat, lng) >= 0.15;
    final stale = _lastCatalogRefreshAt == null || DateTime.now().difference(_lastCatalogRefreshAt!) > const Duration(seconds: 45);
    if (movedFar && stale) {
      _lastCatalogLat = lat;
      _lastCatalogLng = lng;
      _lastCatalogRefreshAt = DateTime.now();
      unawaited(refreshNearby());
    }
    _maybePingVendorSessions(lat, lng);
    notifyListeners();
  }

  void _maybePingVendorSessions(double lat, double lng) {
    if (currentUser == null) return;
    if (role != AppRole.owner && role != AppRole.staff) return;
    if (_lastVendorPingAt != null && DateTime.now().difference(_lastVendorPingAt!) < const Duration(seconds: 15)) {
      return;
    }
    for (final store in managedStores()) {
      final session = vendorSessions[store.id];
      if (session == null || !session.isActive) continue;
      if (distanceKm(session.lat, session.lng, lat, lng) < 0.03) continue;
      _lastVendorPingAt = DateTime.now();
      unawaited(pingVendorSession(store, lat, lng));
    }
  }

  Future<RoutePreview> previewRoute({required double destLat, required double destLng}) async {
    final originLat = deviceLat ?? searchLat;
    final originLng = deviceLng ?? searchLng;
    if (apiOnline) {
      try {
        final data = await api.post('/routes/preview', {
          'origin_lat': originLat,
          'origin_lng': originLng,
          'destination_lat': destLat,
          'destination_lng': destLng,
        }) as Map;
        lastRoute = routePreviewFromJson(Map<String, dynamic>.from(data));
        notifyListeners();
        return lastRoute!;
      } catch (_) {}
    }
    lastRoute = _localRoute(originLat, originLng, destLat, destLng);
    notifyListeners();
    return lastRoute!;
  }

  RoutePreview _localRoute(double originLat, double originLng, double destLat, double destLng) {
    const steps = 16;
    final points = <GeoPoint>[
      for (var i = 0; i <= steps; i++)
        GeoPoint(
          originLat + (destLat - originLat) * (i / steps),
          originLng + (destLng - originLng) * (i / steps),
        ),
    ];
    final km = distanceKm(originLat, originLng, destLat, destLng);
    return RoutePreview(
      coordinates: points,
      distanceKm: km,
      durationMinutes: km > 0 ? max(1, (km / 20 * 60).round()) : 1,
      provider: 'localspot',
      fallback: true,
    );
  }

  VendorSession? sessionFor(Store store) {
    final session = vendorSessions[store.id];
    if (session == null) return null;
    if (!session.isActive) {
      if (store.isMobile) store.locationMode = LocationMode.stale;
      return session.endedAt == null ? session : null;
    }
    return session;
  }

  bool canShareLiveLocation(Store store) {
    final user = currentUser;
    if (user == null) return false;
    if (user.role == AppRole.admin || store.ownerId == user.id) return true;
    return user.storeGrants[store.id]?.location == true;
  }

  bool canEditInventory(Store store) {
    final user = currentUser;
    if (user == null) return false;
    if (user.role == AppRole.admin || store.ownerId == user.id) return true;
    return user.storeGrants[store.id]?.inventory ?? user.memberStoreIds.contains(store.id);
  }

  bool canManagePromotions(Store store) {
    final user = currentUser;
    if (user == null) return false;
    if (user.role == AppRole.admin || store.ownerId == user.id) return true;
    return user.storeGrants[store.id]?.promotions == true;
  }

  Future<void> startVendorSession(Store store, {double? lat, double? lng}) async {
    if (!canShareLiveLocation(store)) return;
    final nextLat = lat ?? deviceLat ?? store.lat;
    final nextLng = lng ?? deviceLng ?? store.lng;
    final session = VendorSession(
      storeId: store.id,
      lat: nextLat,
      lng: nextLng,
      startedAt: DateTime.now(),
      lastUpdateAt: DateTime.now(),
      expiresAt: DateTime.now().add(const Duration(hours: 2)),
    );
    vendorSessions[store.id] = session;
    store.lat = nextLat;
    store.lng = nextLng;
    store.locationMode = LocationMode.live;
    store.locationUpdatedAt = session.lastUpdateAt;
    notifyListeners();
    if (apiOnline && api.token != null) {
      try {
        final data = await api.post('/stores/${store.id}/location-sessions', {
          'lat': nextLat,
          'lng': nextLng,
        }) as Map;
        final remote = vendorSessionFromJson(Map<String, dynamic>.from(data));
        if (remote != null) vendorSessions[store.id] = remote;
      } catch (_) {}
    }
    notifyListeners();
  }

  Future<void> pingVendorSession(Store store, double lat, double lng) async {
    final session = vendorSessions[store.id];
    if (session == null || !session.isActive) return;
    session.lat = lat;
    session.lng = lng;
    session.lastUpdateAt = DateTime.now();
    store.lat = lat;
    store.lng = lng;
    store.locationUpdatedAt = session.lastUpdateAt;
    notifyListeners();
    if (apiOnline && api.token != null) {
      unawaited(api.patch('/stores/${store.id}/location-sessions/current', {'lat': lat, 'lng': lng}));
    }
  }

  Future<void> stopVendorSession(Store store) async {
    if (!canShareLiveLocation(store)) return;
    final session = vendorSessions[store.id];
    session?.endedAt = DateTime.now();
    store.locationMode = store.isMobile ? LocationMode.regular : LocationMode.fixed;
    notifyListeners();
    if (apiOnline && api.token != null) {
      try {
        await api.delete('/stores/${store.id}/location-sessions/current');
      } catch (_) {}
    }
  }

  void setRadius(double km) {
    radiusKm = km;
    notifyListeners();
    unawaited(refreshNearby());
    unawaited(fetchSearch(lastSearchQuery));
  }

  void setTypeFilter(StoreType? type) {
    typeFilter = type;
    notifyListeners();
    unawaited(refreshNearby());
    unawaited(fetchSearch(lastSearchQuery));
  }

  void setCategoryFilter(String? category) {
    categoryFilter = category;
    notifyListeners();
    unawaited(fetchSearch(lastSearchQuery));
  }

  void setSearchSort(SearchSort sort) {
    searchSort = sort;
    notifyListeners();
    unawaited(fetchSearch(lastSearchQuery));
  }

  bool get canLoadMoreSearch => apiOnline && searchPage < searchLastPage && !searchBusy;

  Future<void> fetchSearch(String query, {bool nextPage = false}) async {
    lastSearchQuery = query;
    if (!apiOnline) {
      remoteSearchHits = null;
      searchBusy = false;
      searchNote = '';
      searchPage = 1;
      searchLastPage = 1;
      searchTotal = 0;
      notifyListeners();
      return;
    }
    if (nextPage) {
      if (searchPage >= searchLastPage) return;
      searchPage += 1;
    } else {
      searchPage = 1;
    }
    final generation = ++_searchGeneration;
    searchBusy = true;
    notifyListeners();
    try {
      final envelope = await catalogRepo.searchListings({
        'q': query,
        'lat': searchLat.toString(),
        'lng': searchLng.toString(),
        'radius_km': radiusKm.toString(),
        'sort': searchSort.name,
        'page': searchPage.toString(),
        'per_page': '20',
        if (typeFilter != null) 'type': typeFilter!.name,
        if (categoryFilter != null) 'category': categoryFilter!,
      });
      if (generation != _searchGeneration) return;
      final rows = envelope['data'];
      final meta = envelope['meta'] is Map ? Map<String, dynamic>.from(envelope['meta'] as Map) : const <String, dynamic>{};
      searchTotal = (meta['total'] as num?)?.toInt() ?? (rows is List ? rows.length : 0);
      searchLastPage = (meta['last_page'] as num?)?.toInt() ?? 1;
      if (rows is! List) {
        if (!nextPage) remoteSearchHits = null;
        searchNote = 'Search API unavailable · showing on-device results';
      } else {
        final pageHits = [
          for (final row in rows)
            SearchHit(
              listing: listingFromJson(Map<String, dynamic>.from((row as Map)['listing'] as Map)),
              store: storeFromJson(Map<String, dynamic>.from(row['store'] as Map)),
              product: productFromJson(Map<String, dynamic>.from(row['product'] as Map)),
              distanceKm: (row['distance_km'] as num?)?.toDouble() ?? 0,
              matchType: _parseMatchType(row['match_type'] as String?),
            ),
        ];
        if (nextPage && remoteSearchHits != null) {
          remoteSearchHits = [...remoteSearchHits!, ...pageHits];
        } else {
          remoteSearchHits = pageHits;
        }
        searchNote = '';
      }
    } catch (_) {
      if (generation != _searchGeneration) return;
      if (!nextPage) remoteSearchHits = null;
      searchNote = 'Search API unavailable · showing on-device results';
    }
    if (generation != _searchGeneration) return;
    searchBusy = false;
    notifyListeners();
  }

  SearchMatchType _parseMatchType(String? raw) {
    return switch (raw) {
      'category' => SearchMatchType.category,
      'similar' => SearchMatchType.similar,
      'identifier' => SearchMatchType.identifier,
      'semantic' => SearchMatchType.semantic,
      _ => SearchMatchType.exact,
    };
  }

  void toggleFavoriteStore(int id) {
    if (!favoriteStoreIds.add(id)) favoriteStoreIds.remove(id);
    if (apiOnline && api.token != null) {
      unawaited(api.post('/favorites/toggle', {'favoritable_type': 'store', 'favoritable_id': id}));
    }
    notifyListeners();
  }

  void toggleFavoriteProduct(int id) {
    if (!favoriteProductIds.add(id)) favoriteProductIds.remove(id);
    if (apiOnline && api.token != null) {
      unawaited(api.post('/favorites/toggle', {'favoritable_type': 'product', 'favoritable_id': id}));
    }
    notifyListeners();
  }

  Store registerStore({
    required String name,
    required StoreType type,
    required double lat,
    required double lng,
    required String barangay,
    required String city,
    required String address,
    required String landmark,
    required String schedule,
    required bool isMobile,
    required String verificationNote,
  }) {
    _beginWrite();
    final store = Store(
      id: _nextStore++,
      ownerId: currentUser!.id,
      name: name,
      type: type,
      status: StoreStatus.pending,
      lat: lat,
      lng: lng,
      barangay: barangay,
      city: city,
      address: address,
      landmark: landmark,
      schedule: schedule,
      isMobile: isMobile,
      verificationNote: verificationNote,
    );
    stores.add(store);
    notifyListeners();
    if (apiOnline && api.token != null) {
      unawaited(() async {
        try {
          await api.post('/stores', {
            'name': name,
            'type': type.name,
            'lat': lat,
            'lng': lng,
            'barangay': barangay,
            'city': city,
            'address': address,
            'landmark': landmark,
            'schedule': schedule,
            'is_mobile': isMobile,
            'verification_note': verificationNote,
          });
          await refreshCatalog();
        } finally {
          _endWrite();
        }
      }());
    } else {
      _endWrite();
    }
    return store;
  }

  String? inviteStaff({
    required int storeId,
    required String email,
    bool inventory = true,
    bool promotions = false,
    bool location = false,
  }) {
    final owner = currentUser;
    final store = storeById(storeId);
    if (owner == null || store == null) return 'Sign in as the store owner first.';
    if (owner.role != AppRole.owner && owner.role != AppRole.admin) {
      return 'Only the store owner can invite staff.';
    }
    if (owner.role == AppRole.owner && store.ownerId != owner.id) {
      return 'You can only invite staff to your own store.';
    }
    final normalized = email.trim().toLowerCase();
    final match = users.where((user) => user.email.toLowerCase() == normalized);
    if (match.isEmpty) return 'No LocalSpot account uses that email.';
    final member = match.first;
    if (member.role == AppRole.admin) return 'Administrators cannot be added as store staff.';
    if (member.id == store.ownerId) return 'The owner already manages this store.';
    if (!member.memberStoreIds.contains(storeId)) {
      member.memberStoreIds = [...member.memberStoreIds, storeId];
    }
    if (member.role == AppRole.customer) member.role = AppRole.staff;
    member.storeGrants[storeId] = StoreGrant(inventory: inventory, promotions: promotions, location: location);
    notifyListeners();
    if (apiOnline && api.token != null) {
      unawaited(api.post('/stores/$storeId/staff', {
        'email': member.email,
        'can_inventory': inventory,
        'can_promotions': promotions,
        'can_location': location,
      }));
    }
    return null;
  }

  void setStaffGrant(int storeId, UserAccount member, {bool? inventory, bool? promotions, bool? location}) {
    final grant = member.storeGrants.putIfAbsent(storeId, () => StoreGrant());
    if (inventory != null) grant.inventory = inventory;
    if (promotions != null) grant.promotions = promotions;
    if (location != null) grant.location = location;
    notifyListeners();
    if (apiOnline && api.token != null) {
      unawaited(api.patch('/stores/$storeId/staff/${member.id}', {
        if (inventory != null) 'can_inventory': inventory,
        if (promotions != null) 'can_promotions': promotions,
        if (location != null) 'can_location': location,
      }));
    }
  }

  List<UserAccount> staffForStore(int storeId) =>
      users.where((user) => user.memberStoreIds.contains(storeId)).toList();

  void updateStore(Store store) {
    notifyListeners();
    if (apiOnline && api.token != null) {
      unawaited(api.patch('/stores/${store.id}', {
        'lat': store.lat,
        'lng': store.lng,
        'landmark': store.landmark,
        'schedule': store.schedule,
        'is_mobile': store.isMobile,
      }));
    }
  }

  void updateStorePin(Store store, double lat, double lng) {
    store.lat = lat;
    store.lng = lng;
    updateStore(store);
  }

  void addFeedback({required String topic, required String body, String? area}) {
    feedback.add(PilotFeedback(
      id: _nextFeedback++,
      userId: currentUser?.id ?? 0,
      topic: topic,
      body: body,
      area: area,
    ));
    notifyListeners();
    if (apiOnline && api.token != null) {
      unawaited(api.post('/feedback', {
        'topic': topic,
        'body': body,
        'area': area,
      }));
    }
  }

  void setStoreStatus(Store store, StoreStatus status) {
    store.status = status;
    notifyListeners();
    if (apiOnline && api.token != null) {
      unawaited(api.patch('/admin/stores/${store.id}', {'status': status.name}));
    }
  }

  CatalogProduct createProduct({
    required String name,
    required String category,
    required String brand,
    required String packageSize,
    required List<String> aliases,
    String? barcode,
    required String image,
    Map<String, String> attributes = const {},
  }) {
    final product = CatalogProduct(
      id: _nextProduct++,
      name: name,
      category: category,
      brand: brand,
      packageSize: packageSize,
      aliases: aliases,
      barcode: barcode,
      image: image,
      attributes: attributes,
    );
    products.add(product);
    notifyListeners();
    return product;
  }

  StoreListing addListing({
    required int storeId,
    int? productId,
    required String name,
    String category = 'Groceries',
    String brand = '',
    String packageSize = '',
    String? barcode,
    required double price,
    required String unit,
    required int quantity,
    required Availability availability,
    Map<String, String> attributes = const {},
  }) {
    _beginWrite();
    final resolvedId = productId ??
        createProduct(
          name: name,
          category: category,
          brand: brand,
          packageSize: packageSize,
          aliases: [name.toLowerCase()],
          barcode: barcode,
          image: 'https://images.unsplash.com/photo-1542838132-92c53300491e?auto=format&fit=crop&w=800&q=80',
          attributes: attributes,
        ).id;
    final listing = StoreListing(
      id: _nextListing++,
      storeId: storeId,
      productId: resolvedId,
      price: price,
      unit: unit,
      quantity: quantity,
      availability: availability,
      lastConfirmed: DateTime.now(),
    );
    listings.add(listing);
    _recordMovement(listing, kind: 'add', delta: quantity, note: 'Owner confirmed listing');
    notifyListeners();
    if (apiOnline && api.token != null) {
      unawaited(() async {
        try {
          await api.post('/stores/$storeId/products', {
            if (productId != null) 'product_id': productId,
            'name': name,
            'category': category,
            'brand': brand,
            'package_size': packageSize,
            'barcode': barcode,
            'price': price,
            'unit': unit,
            'quantity': quantity,
            'availability': availabilityApi(availability),
            'attributes': attributes,
          });
          await refreshCatalog();
        } finally {
          _endWrite();
        }
      }());
    } else {
      _endWrite();
    }
    return listing;
  }

  void updateListing(StoreListing listing, {int? quantityDelta, String note = 'Stock update'}) {
    _beginWrite();
    listing.lastConfirmed = DateTime.now();
    _recordMovement(listing, kind: listing.status == ListingStatus.archived ? 'archive' : 'adjust', delta: quantityDelta ?? 0, note: note);
    notifyListeners();
    if (apiOnline && api.token != null) {
      unawaited(() async {
        try {
          await api.patch('/store-products/${listing.id}', {
            'price': listing.price,
            'unit': listing.unit,
            'quantity': listing.quantity,
            'availability': availabilityApi(listing.availability),
            'status': listing.status.name,
          });
        } finally {
          _endWrite();
        }
      }());
    } else {
      _endWrite();
    }
  }

  void archiveListing(StoreListing listing) {
    listing.status = ListingStatus.archived;
    listing.availability = Availability.unavailable;
    updateListing(listing);
  }

  Promotion addPromotion({
    required int storeId,
    required String title,
    required String offer,
    required bool sponsored,
    int days = 14,
  }) {
    _beginWrite();
    final starts = DateTime.now();
    final ends = starts.add(Duration(days: days < 1 ? 14 : days));
    final promo = Promotion(
      id: _nextPromo++,
      storeId: storeId,
      title: title,
      offer: offer,
      startsAt: starts,
      endsAt: ends,
      sponsored: sponsored,
      status: PromotionStatus.pending,
    );
    promotions.add(promo);
    notifyListeners();
    if (apiOnline && api.token != null) {
      unawaited(() async {
        try {
          await api.post('/stores/$storeId/promotions', {
            'title': title,
            'offer': offer,
            'sponsored': sponsored,
            'starts_at': starts.toIso8601String(),
            'ends_at': ends.toIso8601String(),
          });
          await refreshCatalog();
        } finally {
          _endWrite();
        }
      }());
    } else {
      _endWrite();
    }
    return promo;
  }

  void setPromotionStatus(Promotion promo, PromotionStatus status) {
    promo.status = status;
    notifyListeners();
    if (apiOnline && api.token != null) {
      unawaited(api.patch('/admin/promotions/${promo.id}', {'status': status.name}));
    }
  }

  StoreTour addTour(int storeId, String title) {
    final tour = StoreTour(
      id: _nextTour++,
      storeId: storeId,
      title: title,
      status: TourStatus.draft,
      nodes: [],
    );
    tours.add(tour);
    notifyListeners();
    if (apiOnline && api.token != null) {
      unawaited(() async {
        final data = await api.post('/stores/$storeId/tours', {'title': title}) as Map;
        _replaceTour(tour.id, tourFromJson(Map<String, dynamic>.from(data)));
      }());
    }
    return tour;
  }

  void _replaceTour(int localId, StoreTour incoming) {
    tours.removeWhere((item) => item.id == localId || item.id == incoming.id);
    tours.add(incoming);
    notifyListeners();
  }

  void connectTourNodes(StoreTour tour, TourNode from, TourNode to) {
    if (!from.connections.contains(to.id)) from.connections.add(to.id);
    if (!to.connections.contains(from.id)) to.connections.add(from.id);
    notifyListeners();
    if (apiOnline && api.token != null) {
      unawaited(api.post('/tours/${tour.id}/connections', {
        'from_node_id': from.id,
        'to_node_id': to.id,
      }));
    }
  }

  void addTourNode(StoreTour tour, String title, String image) {
    _beginWrite();
    final node = TourNode(
      id: tour.nodes.length + 1,
      title: title,
      image: '',
      connections: [],
      privacyStatus: PrivacyStatus.processing,
      ownerReviewed: false,
      originalRetained: true,
    );
    if (tour.nodes.isNotEmpty) {
      tour.nodes.last.connections.add(node.id);
      node.connections.add(tour.nodes.last.id);
    }
    tour.nodes.add(node);
    notifyListeners();
    if (apiOnline && api.token != null) {
      unawaited(() async {
        try {
          final data = await api.post('/tours/${tour.id}/nodes', {'title': title, 'image': image}) as Map;
          _replaceTour(tour.id, tourFromJson(Map<String, dynamic>.from(data)));
        } finally {
          _endWrite();
        }
      }());
    } else {
      _endWrite();
    }
  }

  Future<void> processTourNode(StoreTour tour, TourNode node, {bool fail = false}) async {
    if (fail) {
      node.privacyStatus = PrivacyStatus.failed;
      node.image = '';
      node.ownerReviewed = false;
    } else {
      node.privacyStatus = PrivacyStatus.ready;
      node.image = '/storage/tours/${node.id}/sanitized.jpg';
    }
    notifyListeners();
    if (apiOnline && api.token != null) {
      try {
        final data = await api.post('/tours/${tour.id}/nodes/${node.id}/process', {'fail': fail}) as Map;
        _replaceTour(tour.id, tourFromJson(Map<String, dynamic>.from(data)));
      } catch (_) {}
    }
  }

  String? reviewTourNode(StoreTour tour, TourNode node) {
    if (node.privacyStatus != PrivacyStatus.ready) {
      return 'Privacy processing must finish before review.';
    }
    node.ownerReviewed = true;
    notifyListeners();
    if (apiOnline && api.token != null) {
      unawaited(api.post('/tours/${tour.id}/nodes/${node.id}/review'));
    }
    return null;
  }

  void addManualTourBlur(StoreTour tour, TourNode node, {BlurRegion? region}) {
    final mask = region ?? const BlurRegion(x: 0.35, y: 0.35, w: 0.3, h: 0.3);
    node.manualBlur = true;
    node.privacyStatus = PrivacyStatus.ready;
    if (node.image.trim().isEmpty) {
      node.image = '/storage/tours/${node.id}/sanitized.jpg';
    }
    node.blurRegions = [...node.blurRegions, mask];
    notifyListeners();
    if (apiOnline && api.token != null) {
      unawaited(api.post('/tours/${tour.id}/nodes/${node.id}/manual-blurs', {
        'regions': [
          {'x': mask.x, 'y': mask.y, 'w': mask.w, 'h': mask.h},
        ],
      }));
    }
  }

  String? publishTour(StoreTour tour) {
    if (tour.nodes.length < 2) return 'Connect at least two viewpoints before publishing.';
    if (tour.nodes.any((node) => !node.canPublish || node.image.contains('#') || node.image.contains('tours/originals'))) {
      return 'Every viewpoint needs privacy processing and owner review before publishing.';
    }
    _beginWrite();
    tour.status = TourStatus.published;
    notifyListeners();
    if (apiOnline && api.token != null) {
      unawaited(() async {
        try {
          await api.post('/tours/${tour.id}/publish');
          await refreshCatalog();
        } finally {
          _endWrite();
        }
      }());
    } else {
      _endWrite();
    }
    return null;
  }

  void addReport(String target, String reason) {
    reports.add(ReportItem(
      id: _nextReport++,
      userId: currentUser?.id ?? 0,
      target: target,
      reason: reason,
    ));
    notifyListeners();
    if (apiOnline && api.token != null) {
      unawaited(api.post('/reports', {'target': target, 'reason': reason}));
    }
  }

  void resolveReport(ReportItem report) {
    report.resolved = true;
    notifyListeners();
    if (apiOnline && api.token != null) {
      unawaited(api.patch('/admin/reports/${report.id}'));
    }
  }

  List<CatalogProduct> searchCatalog(String query) {
    final q = query.trim().toLowerCase();
    if (q.isEmpty) return products;
    return products.where((p) => _matchesProduct(p, q)).toList();
  }

  void applySearchDraft(String query) {
    searchDraft = query;
    notifyListeners();
  }

  List<SearchHit> searchListings(String query) {
    final q = query.trim().toLowerCase();
    final familyCats = expandedCategories(q);
    final hits = <SearchHit>[];
    for (final listing in listings) {
      if (listing.status != ListingStatus.active) continue;
      final store = storeById(listing.storeId);
      final product = productById(listing.productId);
      if (store == null || product == null) continue;
      if (store.status != StoreStatus.approved) continue;
      if (typeFilter != null && store.type != typeFilter) continue;
      if (!productMatchesCategoryFilter(product.category, categoryFilter)) continue;
      final distance = distanceKm(searchLat, searchLng, store.lat, store.lng);
      if (distance > radiusKm) continue;
      final keyword = q.isEmpty || _matchesProduct(product, q);
      final categoryHit = familyCats.any((cat) => cat.toLowerCase() == product.category.toLowerCase());
      if (q.isNotEmpty && !keyword && !categoryHit && !_semanticMatch(product, q)) continue;
      hits.add(SearchHit(
        listing: listing,
        store: store,
        product: product,
        distanceKm: distance,
        matchType: q.isEmpty
            ? SearchMatchType.exact
            : _matchKind(product, q, familyCats),
      ));
    }
    hits.sort((a, b) {
      switch (searchSort) {
        case SearchSort.price:
          return a.listing.price.compareTo(b.listing.price);
        case SearchSort.freshness:
          return b.listing.lastConfirmed.compareTo(a.listing.lastConfirmed);
        case SearchSort.distance:
          return a.distanceKm.compareTo(b.distanceKm);
        case SearchSort.relevance:
          if (q.isNotEmpty) {
            final byRelevance = _relevance(a.product, q, familyCats).compareTo(_relevance(b.product, q, familyCats));
            if (byRelevance != 0) return byRelevance;
          }
          final byDistance = a.distanceKm.compareTo(b.distanceKm);
          if (byDistance != 0) return byDistance;
          return a.product.name.compareTo(b.product.name);
      }
    });
    return hits;
  }

  List<Store> hotStores() {
    final sponsoredIds = liveSponsored().map((promo) => promo.storeId).toSet();
    final stores = nearbyStores();
    stores.sort((a, b) {
      final hotA = sponsoredIds.contains(a.id) ? 0 : 1;
      final hotB = sponsoredIds.contains(b.id) ? 0 : 1;
      if (hotA != hotB) return hotA.compareTo(hotB);
      return listingsForStore(b.id).length.compareTo(listingsForStore(a.id).length);
    });
    return stores;
  }

  List<Store> nearbyStores() {
    final result = stores.where((s) {
      if (s.status != StoreStatus.approved) return false;
      if (typeFilter != null && s.type != typeFilter) return false;
      return distanceKm(searchLat, searchLng, s.lat, s.lng) <= radiusKm;
    }).toList()
      ..sort((a, b) => distanceKm(searchLat, searchLng, a.lat, a.lng)
          .compareTo(distanceKm(searchLat, searchLng, b.lat, b.lng)));
    return result;
  }

  List<SearchHit> nearbyProducts() => searchListings('');

  List<Promotion> liveSponsored() {
    final now = DateTime.now();
    return promotions
        .where((p) =>
            p.status == PromotionStatus.approved &&
            p.sponsored &&
            !now.isBefore(p.startsAt) &&
            !now.isAfter(p.endsAt))
        .toList();
  }

  Store? storeById(int id) => stores.where((s) => s.id == id).firstOrNull;
  CatalogProduct? productById(int id) => products.where((p) => p.id == id).firstOrNull;
  List<StoreListing> listingsForStore(int storeId) =>
      listings.where((l) => l.storeId == storeId && l.status == ListingStatus.active).toList();
  List<SearchHit> listingsForProduct(int productId) =>
      searchListings('').where((h) => h.product.id == productId).toList();
  StoreTour? tourForStore(int storeId) => tours
      .where((t) => t.storeId == storeId && t.status == TourStatus.published)
      .firstOrNull;
  StoreTour? draftOrPublishedTour(int storeId) =>
      tours.where((t) => t.storeId == storeId).firstOrNull;

  CatalogProduct? _named(String needle) =>
      products.where((p) => p.name.toLowerCase().contains(needle) || p.aliases.any((a) => a.toLowerCase().contains(needle))).firstOrNull;

  Future<dynamic> _awaitRecognitionJob(dynamic data, int generation) async {
    if (data is! Map) return data;
    final id = data['id'];
    var status = data['status'] as String?;
    Map current = data;
    for (var i = 0; i < 8 && status == 'pending' && id != null; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 200));
      if (generation != _recognitionGeneration) return current;
      current = Map<String, dynamic>.from(await api.get('/product-recognition/jobs/$id') as Map);
      status = current['status'] as String?;
    }
    return current;
  }

  List<RecognitionSuggestion> _suggestionsFrom(dynamic data) {
    final rows = data is List
        ? data
        : data is Map && data['suggestions'] is List
            ? data['suggestions'] as List
            : const [];
    return [
      for (final row in rows)
        RecognitionSuggestion(
          row['product'] == null ? null : productFromJson(Map<String, dynamic>.from(row['product'] as Map)),
          row['label'] as String? ?? 'Suggestion',
          (row['confidence'] as num?)?.toDouble() ?? 0.4,
          unknownFields: row['unknown_fields'] is List
              ? [...(row['unknown_fields'] as List).map((e) => e.toString())]
              : const ['price', 'stock'],
          ocrText: row['ocr'] as String?,
        ),
    ];
  }

  List<RecognizedObject> _objectsFrom(dynamic data, List<RecognitionSuggestion> fallback) {
    if (data is Map && data['objects'] is List && (data['objects'] as List).isNotEmpty) {
      return [
        for (final row in data['objects'] as List)
          RecognizedObject(
            label: (row as Map)['label'] as String? ?? 'item',
            suggestions: _suggestionsFrom(row),
          ),
      ];
    }
    return fallback.isEmpty ? const [] : [RecognizedObject(label: 'item', suggestions: fallback)];
  }

  List<String> _objectHints(String hint) {
    final parts = hint
        .split(RegExp(r'\s*(?:,|&|\band\b)\s+', caseSensitive: false))
        .map((part) => part.trim())
        .where((part) => part.isNotEmpty)
        .toList();
    return parts.isEmpty ? [hint] : parts;
  }

  Future<List<RecognitionSuggestion>> suggestFromCapture({String? hint, String? barcode, String? image}) async {
    final generation = ++_recognitionGeneration;
    if (apiOnline) {
      try {
        var data = await api.post('/product-recognition/suggest', {
          if (hint != null && hint.trim().isNotEmpty) 'hint': hint.trim(),
          if (barcode != null && barcode.trim().isNotEmpty) 'barcode': barcode.trim(),
          if (image != null && image.isNotEmpty) 'image': image,
        });
        if (generation != _recognitionGeneration) return const [];
        data = await _awaitRecognitionJob(data, generation);
        if (generation != _recognitionGeneration) return const [];
        return _suggestionsFrom(data);
      } catch (_) {}
    }
    if (generation != _recognitionGeneration) return const [];
    final parts = _objectHints(hint ?? barcode ?? 'unknown');
    if (parts.length == 1) return suggestFromPhoto(parts.first);
    return [for (final part in parts) ...suggestFromPhoto(part)];
  }

  Future<VisualSearchResult> visualSearch({String? hint, String? barcode, String? image}) async {
    final generation = ++_recognitionGeneration;
    if (apiOnline) {
      try {
        final data = await api.post('/search/by-image', {
          if (hint != null && hint.trim().isNotEmpty) 'hint': hint.trim(),
          if (barcode != null && barcode.trim().isNotEmpty) 'barcode': barcode.trim(),
          if (image != null && image.isNotEmpty) 'image': image,
          'lat': searchLat.toString(),
          'lng': searchLng.toString(),
          'radius_km': radiusKm.toString(),
        }) as Map;
        if (generation != _recognitionGeneration) {
          return VisualSearchResult(suggestions: const [], hits: const [], uncertain: true);
        }
        final suggestions = _suggestionsFrom(data);
        final hits = [
          for (final row in (data['hits'] as List? ?? []))
            SearchHit(
              listing: listingFromJson(Map<String, dynamic>.from((row as Map)['listing'] as Map)),
              store: storeFromJson(Map<String, dynamic>.from(row['store'] as Map)),
              product: productFromJson(Map<String, dynamic>.from(row['product'] as Map)),
              distanceKm: (row['distance_km'] as num?)?.toDouble() ?? 0,
              matchType: SearchMatchType.similar,
            ),
        ];
        return VisualSearchResult(
          suggestions: suggestions,
          hits: hits,
          uncertain: data['uncertain'] == true || suggestions.every((s) => s.product == null || s.confidence < 0.5),
          objects: _objectsFrom(data, suggestions),
        );
      } catch (_) {}
    }
    final suggestions = await suggestFromCapture(hint: hint, barcode: barcode, image: image);
    final hits = <SearchHit>[];
    final seen = <int>{};
    for (final suggestion in suggestions) {
      final product = suggestion.product;
      if (product == null) continue;
      for (final hit in listingsForProduct(product.id)) {
        if (seen.add(hit.listing.id)) {
          hits.add(SearchHit(
            listing: hit.listing,
            store: hit.store,
            product: hit.product,
            distanceKm: hit.distanceKm,
            matchType: SearchMatchType.similar,
          ));
        }
      }
    }
    final query = hint ?? barcode ?? '';
    if (hits.isEmpty && query.trim().isNotEmpty) {
      for (final hit in searchListings(query)) {
        if (seen.add(hit.listing.id)) hits.add(hit);
      }
    }
    final uncertain = suggestions.isEmpty || suggestions.every((s) => s.product == null || s.confidence < 0.5);
    final objects = [
      for (final part in _objectHints(hint ?? barcode ?? 'item'))
        RecognizedObject(label: part, suggestions: suggestFromPhoto(part)),
    ];
    return VisualSearchResult(suggestions: suggestions, hits: hits, uncertain: uncertain, objects: objects);
  }

  List<RecognitionSuggestion> suggestFromPhoto(String imageKey) {
    return switch (imageKey) {
      'mango' => [
          RecognitionSuggestion(_named('mango'), 'Likely mango · produce', 0.86, unknownFields: const ['price', 'stock', 'variety']),
          RecognitionSuggestion(_named('banana'), 'Similar fruit · banana', 0.41, unknownFields: const ['price', 'stock', 'variety']),
        ],
      'oil' => [
          RecognitionSuggestion(_named('oil'), 'Cooking oil bottle detected', 0.78, ocrText: 'Minola 1L', unknownFields: const ['price', 'stock']),
        ],
      'sardines' => [
          RecognitionSuggestion(_named('sardine'), 'Canned sardines · OCR: YOUNG\'S', 0.81, ocrText: "YOUNG'S TOWN", unknownFields: const ['price', 'stock']),
        ],
      'hammer' => [
          RecognitionSuggestion(_named('hammer'), 'Likely claw hammer · hardware', 0.84, unknownFields: const ['price', 'stock', 'dimensions']),
        ],
      _ => [
          RecognitionSuggestion(null, 'Uncertain match · encode manually', 0.22, unknownFields: const ['identity', 'price', 'stock']),
        ],
    };
  }

  bool _matchesProduct(CatalogProduct product, String q) {
    if (_identifierMatch(product, q) || _semanticMatch(product, q)) return true;
    for (final field in _productFields(product)) {
      if (field.contains(q) || (field.length >= 3 && q.contains(field)) || _lev(field, q) <= 2) return true;
      for (final token in field.split(RegExp(r'[^a-z0-9]+'))) {
        if (token.length < 3) continue;
        if (token.contains(q) || q.contains(token) || _lev(token, q) <= 2) return true;
      }
    }
    return false;
  }

  SearchMatchType _matchKind(CatalogProduct product, String q, List<String> familyCats) {
    if (_identifierMatch(product, q)) return SearchMatchType.identifier;
    final rank = _relevance(product, q, familyCats);
    if (rank <= 3) return SearchMatchType.exact;
    if (_semanticMatch(product, q)) return SearchMatchType.semantic;
    if (familyCats.any((cat) => cat.toLowerCase() == product.category.toLowerCase())) return SearchMatchType.category;
    return SearchMatchType.exact;
  }

  bool _identifierMatch(CatalogProduct product, String q) {
    final isBarcode = RegExp(r'^\d{8,14}$').hasMatch(q);
    final isModel = RegExp(r'[a-z]+\d|\d+[a-z]').hasMatch(q);
    if (product.barcode != null && product.barcode!.toLowerCase() == q) return true;
    for (final field in _productFields(product)) {
      if (field == q) return true;
      if (isBarcode && field.replaceAll(RegExp(r'\D+'), '') == q) return true;
      if (isModel && field.contains(q)) return true;
    }
    return false;
  }

  bool _semanticMatch(CatalogProduct product, String q) {
    const stop = {'for', 'the', 'a', 'an', 'of', 'and', 'or', 'to', 'in', 'on', 'near', 'me', 'nearby', 'with', 'from'};
    final qTokens = q.split(RegExp(r'[^a-z0-9]+')).where((t) => t.length >= 2 && !stop.contains(t)).toList();
    if (qTokens.length < 2) return false;
    final hay = _productFields(product).join(' ').split(RegExp(r'[^a-z0-9]+')).where((t) => t.length >= 2).toSet();
    final overlap = qTokens.where(hay.contains).length;
    return overlap / qTokens.length >= 0.4;
  }

  int _relevance(CatalogProduct product, String q, [List<String> familyCats = const []]) {
    final name = product.name.toLowerCase();
    if (_identifierMatch(product, q)) return 0;
    if (name == q) return 0;
    if (name.startsWith(q)) return 1;
    if (name.contains(q)) return 2;
    if (product.aliases.any((alias) => alias.toLowerCase() == q || alias.toLowerCase().contains(q))) return 3;
    if (_semanticMatch(product, q)) return 4;
    if (familyCats.any((cat) => cat.toLowerCase() == product.category.toLowerCase())) return 5;
    return 8;
  }

  Iterable<String> _productFields(CatalogProduct product) => [
        product.name,
        product.brand,
        product.category,
        product.packageSize,
        ...product.aliases,
        ...product.attributes.values,
      ].map((e) => e.toLowerCase());

  int _lev(String a, String b) {
    if (a == b) return 0;
    if (a.isEmpty) return b.length;
    if (b.isEmpty) return a.length;
    if ((a.length - b.length).abs() > 2) return 99;
    final prev = List<int>.generate(b.length + 1, (i) => i);
    for (var i = 0; i < a.length; i++) {
      var diag = i;
      prev[0] = i + 1;
      for (var j = 0; j < b.length; j++) {
        final tmp = prev[j + 1];
        prev[j + 1] = a[i] == b[j] ? diag : 1 + min(min(diag, prev[j]), prev[j + 1]);
        diag = tmp;
      }
    }
    return prev[b.length];
  }

  double distanceKm(double lat1, double lng1, double lat2, double lng2) {
    const r = 6371.0;
    final dLat = _rad(lat2 - lat1);
    final dLng = _rad(lng2 - lng1);
    final a = sin(dLat / 2) * sin(dLat / 2) +
        cos(_rad(lat1)) * cos(_rad(lat2)) * sin(dLng / 2) * sin(dLng / 2);
    return r * 2 * atan2(sqrt(a), sqrt(1 - a));
  }

  double _rad(double d) => d * pi / 180;

  void _seed() {
    users.addAll([
      UserAccount(id: 1, name: 'Maria Santos', email: 'maria@localspot.ph', password: 'demo', role: AppRole.customer),
      UserAccount(id: 2, name: 'Aling Nena', email: 'nena@localspot.ph', password: 'demo', role: AppRole.owner, ownedStoreIds: [1]),
      UserAccount(id: 3, name: 'Mang Tonyo', email: 'tonyo@localspot.ph', password: 'demo', role: AppRole.owner, ownedStoreIds: [2]),
      UserAccount(id: 4, name: 'Ana Cruz', email: 'ana@localspot.ph', password: 'demo', role: AppRole.staff, memberStoreIds: [1], storeGrants: {1: StoreGrant(inventory: true)}),
      UserAccount(id: 5, name: 'Admin Reyes', email: 'admin@localspot.ph', password: 'demo', role: AppRole.admin),
      UserAccount(id: 6, name: 'Lito Mercado', email: 'lito@localspot.ph', password: 'demo', role: AppRole.owner, ownedStoreIds: [6]),
      UserAccount(id: 7, name: 'Bea Tan', email: 'bea@localspot.ph', password: 'demo', role: AppRole.owner, ownedStoreIds: [7]),
    ]);

    stores.addAll([
      Store(
        id: 1,
        ownerId: 2,
        name: "Aling Nena's Sari-Sari",
        type: StoreType.sariSari,
        status: StoreStatus.approved,
        lat: 14.6198,
        lng: 121.0562,
        barangay: 'Socorro',
        city: 'Quezon City',
        address: '12 P. Tuazon Blvd',
        landmark: 'Beside the waiting shed near Aurora Blvd',
        schedule: 'Daily 6:00 AM – 10:00 PM',
        isMobile: false,
        image: 'https://images.unsplash.com/photo-1604719312566-8912e9227c6a?auto=format&fit=crop&w=900&q=80',
      ),
      Store(
        id: 2,
        ownerId: 3,
        name: "Mang Tonyo's Fruit Stall",
        type: StoreType.fruitVegetable,
        status: StoreStatus.approved,
        lat: 14.6184,
        lng: 121.0539,
        barangay: 'South Triangle',
        city: 'Quezon City',
        address: 'Farmer’s Market inner aisle 4',
        landmark: 'Near the mango row, green tarpaulin',
        schedule: 'Tue–Sun 5:00 AM – 6:00 PM',
        isMobile: false,
        image: 'https://images.unsplash.com/photo-1488459716781-31db52582fe9?auto=format&fit=crop&w=900&q=80',
      ),
      Store(
        id: 3,
        ownerId: 2,
        name: 'QuickGo Mini Mart',
        type: StoreType.convenience,
        status: StoreStatus.approved,
        lat: 14.6216,
        lng: 121.0589,
        barangay: 'E. Rodriguez',
        city: 'Quezon City',
        address: 'G/F Gateway-adjacent strip',
        landmark: 'Across the jeepney stop',
        schedule: 'Open 24 hours',
        isMobile: false,
        image: 'https://images.unsplash.com/photo-1604719311684-14b4bd8fda7c?auto=format&fit=crop&w=900&q=80',
      ),
      Store(
        id: 4,
        ownerId: 3,
        name: 'Kuya Ben Mobile Taho',
        type: StoreType.streetVendor,
        status: StoreStatus.approved,
        lat: 14.6171,
        lng: 121.0551,
        barangay: 'Kamuning',
        city: 'Quezon City',
        address: 'Selling along Scout area',
        landmark: 'Usually near the barangay hall mornings',
        schedule: 'Mon–Sat 6:00 AM – 11:00 AM',
        isMobile: true,
        locationMode: LocationMode.regular,
        image: 'https://images.unsplash.com/photo-1540189549336-e6e99c3679fe?auto=format&fit=crop&w=900&q=80',
      ),
      Store(
        id: 6,
        ownerId: 6,
        name: 'Cubao Hardware & Tools',
        type: StoreType.hardware,
        status: StoreStatus.approved,
        lat: 14.6209,
        lng: 121.0548,
        barangay: 'Socorro',
        city: 'Quezon City',
        address: '18 Gen. Romulo Ave',
        landmark: 'Orange facade beside the pawnshop',
        schedule: 'Mon–Sat 7:30 AM – 7:00 PM',
        isMobile: false,
        image: 'https://images.unsplash.com/photo-1504148455328-c376907d081c?auto=format&fit=crop&w=900&q=80',
      ),
      Store(
        id: 7,
        ownerId: 7,
        name: 'QC Gadget Hub',
        type: StoreType.electronics,
        status: StoreStatus.approved,
        lat: 14.6189,
        lng: 121.0574,
        barangay: 'Cubao',
        city: 'Quezon City',
        address: '2/F Farmermarket annex',
        landmark: 'Next to the phone repair alley',
        schedule: 'Daily 10:00 AM – 8:00 PM',
        isMobile: false,
        image: 'https://images.unsplash.com/photo-1519389950473-47ba0277781c?auto=format&fit=crop&w=900&q=80',
      ),
      Store(
        id: 5,
        ownerId: 2,
        name: 'Bagong Palengke Dry Goods',
        type: StoreType.marketStall,
        status: StoreStatus.pending,
        lat: 14.6228,
        lng: 121.0524,
        barangay: 'Pinyahan',
        city: 'Quezon City',
        address: 'Stall 18, wet & dry section',
        landmark: 'Blue umbrella, next to rice sacks',
        schedule: 'Daily 5:30 AM – 5:00 PM',
        isMobile: false,
      ),
    ]);

    products.addAll([
      CatalogProduct(
        id: 1,
        name: 'Carabao mango',
        category: 'Produce',
        brand: '',
        packageSize: 'per kilo',
        aliases: ['mangga', 'indian mango', 'mango'],
        image: 'https://images.unsplash.com/photo-1553279768-865429fa0078?auto=format&fit=crop&w=800&q=80',
        attributes: const {'variety': 'Carabao'},
      ),
      CatalogProduct(
        id: 2,
        name: 'Cooking oil',
        category: 'Groceries',
        brand: 'Minola',
        packageSize: '1 L bottle',
        aliases: ['mantika', 'vegetable oil'],
        barcode: '4807770123456',
        image: 'https://images.unsplash.com/photo-1474979266404-7eaacbcd87c5?auto=format&fit=crop&w=800&q=80',
      ),
      CatalogProduct(
        id: 3,
        name: 'Well-milled rice',
        category: 'Staples',
        brand: '',
        packageSize: 'per kilo',
        aliases: ['bigas', 'sinandomeng', 'rice'],
        image: 'https://images.unsplash.com/photo-1586201375761-83865001e31c?auto=format&fit=crop&w=800&q=80',
      ),
      CatalogProduct(
        id: 4,
        name: 'Pan de sal',
        category: 'Bakery',
        brand: '',
        packageSize: 'per piece',
        aliases: ['pandesal', 'bread'],
        image: 'https://images.unsplash.com/photo-1509440159596-0249088772ff?auto=format&fit=crop&w=800&q=80',
      ),
      CatalogProduct(
        id: 5,
        name: 'Lakatan banana',
        category: 'Produce',
        brand: '',
        packageSize: 'per kilo',
        aliases: ['saging', 'banana', 'lakatan'],
        image: 'https://images.unsplash.com/photo-1571771894821-ce9b6c11b08e?auto=format&fit=crop&w=800&q=80',
      ),
      CatalogProduct(
        id: 6,
        name: 'Canned sardines',
        category: 'Groceries',
        brand: "Young's Town",
        packageSize: '155 g can',
        aliases: ['sardinas', 'sardines'],
        barcode: '4800015123456',
        image: 'https://images.unsplash.com/photo-1598515214211-89d3c73ae83b?auto=format&fit=crop&w=800&q=80',
      ),
      CatalogProduct(
        id: 7,
        name: 'Taho',
        category: 'Street food',
        brand: '',
        packageSize: 'per cup',
        aliases: ['taho', 'soy pudding'],
        image: 'https://images.unsplash.com/photo-1569718212165-3a8278d5f624?auto=format&fit=crop&w=800&q=80',
      ),
      CatalogProduct(
        id: 8,
        name: 'Instant noodles',
        category: 'Groceries',
        brand: 'Lucky Me',
        packageSize: '55 g pack',
        aliases: ['pancit canton', 'noodles', 'lucky me'],
        image: 'https://images.unsplash.com/photo-1612929635977-2bddc1c0c0b0?auto=format&fit=crop&w=800&q=80',
      ),
      CatalogProduct(
        id: 9,
        name: 'Claw hammer',
        category: 'Hardware',
        brand: 'Stanley',
        packageSize: '16 oz',
        aliases: ['martilyo', 'hammer'],
        barcode: '4808880123456',
        image: 'https://images.unsplash.com/photo-1586864387963-0a911f4c0c1d?auto=format&fit=crop&w=800&q=80',
        attributes: const {'material': 'steel'},
      ),
      CatalogProduct(
        id: 10,
        name: 'USB-C cable',
        category: 'Electronics',
        brand: 'Anker',
        packageSize: '1 m',
        aliases: ['type c cable', 'charger cable', 'usb c'],
        barcode: '4809990123456',
        image: 'https://images.unsplash.com/photo-1583863788434-e58a36330cf0?auto=format&fit=crop&w=800&q=80',
        attributes: const {'model': 'USB-C', 'capacity': '1 m', 'compatibility': 'USB-C Samsung Type-C phones'},
      ),
      CatalogProduct(
        id: 11,
        name: 'Rubber slippers',
        category: 'Clothing',
        brand: 'Havaianas',
        packageSize: 'pair',
        aliases: ['tsinelas', 'slippers', 'flip flops'],
        image: 'https://images.unsplash.com/photo-1603487742131-4160ec999275?auto=format&fit=crop&w=800&q=80',
      ),
      CatalogProduct(
        id: 12,
        name: 'Motorcycle engine oil',
        category: 'Automotive',
        brand: 'Motul',
        packageSize: '1 L bottle',
        aliases: ['motor oil', 'engine oil'],
        barcode: '4811110123456',
        image: 'https://images.unsplash.com/photo-1486262715619-67b85e0b08d3?auto=format&fit=crop&w=800&q=80',
      ),
    ]);

    final now = DateTime.now();
    listings.addAll([
      StoreListing(id: 1, storeId: 1, productId: 2, price: 98, unit: 'bottle', quantity: 8, availability: Availability.inStock, lastConfirmed: now.subtract(const Duration(hours: 3))),
      StoreListing(id: 2, storeId: 1, productId: 3, price: 56, unit: 'kilo', quantity: 20, availability: Availability.inStock, lastConfirmed: now.subtract(const Duration(hours: 5))),
      StoreListing(id: 3, storeId: 1, productId: 4, price: 4, unit: 'piece', quantity: 40, availability: Availability.low, lastConfirmed: now.subtract(const Duration(hours: 1))),
      StoreListing(id: 4, storeId: 1, productId: 6, price: 28, unit: 'can', quantity: 15, availability: Availability.inStock, lastConfirmed: now.subtract(const Duration(hours: 8))),
      StoreListing(id: 5, storeId: 1, productId: 8, price: 16, unit: 'pack', quantity: 24, availability: Availability.inStock, lastConfirmed: now.subtract(const Duration(minutes: 40))),
      StoreListing(id: 6, storeId: 2, productId: 1, price: 180, unit: 'kilo', quantity: 12, availability: Availability.inStock, lastConfirmed: now.subtract(const Duration(hours: 2))),
      StoreListing(id: 7, storeId: 2, productId: 5, price: 70, unit: 'kilo', quantity: 18, availability: Availability.inStock, lastConfirmed: now.subtract(const Duration(hours: 2))),
      StoreListing(id: 8, storeId: 3, productId: 2, price: 112, unit: 'bottle', quantity: 30, availability: Availability.inStock, lastConfirmed: now.subtract(const Duration(hours: 12))),
      StoreListing(id: 9, storeId: 3, productId: 6, price: 32, unit: 'can', quantity: 40, availability: Availability.inStock, lastConfirmed: now.subtract(const Duration(hours: 12))),
      StoreListing(id: 10, storeId: 3, productId: 8, price: 18, unit: 'pack', quantity: 50, availability: Availability.inStock, lastConfirmed: now.subtract(const Duration(hours: 6))),
      StoreListing(id: 11, storeId: 4, productId: 7, price: 25, unit: 'cup', quantity: 20, availability: Availability.inStock, lastConfirmed: now.subtract(const Duration(hours: 1))),
      StoreListing(id: 12, storeId: 6, productId: 9, price: 285, unit: 'piece', quantity: 14, availability: Availability.inStock, lastConfirmed: now.subtract(const Duration(hours: 4))),
      StoreListing(id: 13, storeId: 7, productId: 10, price: 249, unit: 'piece', quantity: 22, availability: Availability.inStock, lastConfirmed: now.subtract(const Duration(hours: 6))),
      StoreListing(id: 14, storeId: 6, productId: 11, price: 120, unit: 'pair', quantity: 18, availability: Availability.inStock, lastConfirmed: now.subtract(const Duration(hours: 9))),
      StoreListing(id: 15, storeId: 6, productId: 12, price: 390, unit: 'bottle', quantity: 7, availability: Availability.low, lastConfirmed: now.subtract(const Duration(hours: 2))),
    ]);

    promotions.addAll([
      Promotion(
        id: 1,
        storeId: 2,
        title: 'Mangga of the week',
        offer: 'Ripe carabao mango ₱165/kilo until Sunday',
        startsAt: now.subtract(const Duration(days: 1)),
        endsAt: now.add(const Duration(days: 5)),
        sponsored: true,
        status: PromotionStatus.approved,
      ),
      Promotion(
        id: 2,
        storeId: 1,
        title: 'Pandesal morning bundle',
        offer: '10 pieces for ₱35 before 8 AM',
        startsAt: now,
        endsAt: now.add(const Duration(days: 10)),
        sponsored: true,
        status: PromotionStatus.approved,
      ),
    ]);

    tours.add(StoreTour(
      id: 1,
      storeId: 1,
      title: 'Walk through Aling Nena’s',
      status: TourStatus.published,
      nodes: [
        TourNode(
          id: 1,
          title: 'Storefront',
          image: 'https://images.unsplash.com/photo-1604719312566-8912e9227c6a?auto=format&fit=crop&w=1200&q=80',
          connections: [2],
          ownerReviewed: true,
        ),
        TourNode(
          id: 2,
          title: 'Grocery shelf',
          image: 'https://images.unsplash.com/photo-1578916171728-46686eac8d58?auto=format&fit=crop&w=1200&q=80',
          connections: [1, 3],
          ownerReviewed: true,
        ),
        TourNode(
          id: 3,
          title: 'Counter',
          image: 'https://images.unsplash.com/photo-1534723452862-4c874018d66d?auto=format&fit=crop&w=1200&q=80',
          connections: [2],
          ownerReviewed: true,
        ),
      ],
    ));

    reports.add(ReportItem(
      id: 1,
      userId: 1,
      target: 'QuickGo Mini Mart · cooking oil price',
      reason: 'Listed ₱112 but the shelf tag yesterday was ₱108.',
    ));

    favoriteStoreIds.add(1);
    favoriteProductIds.add(1);
  }
}

class RecognitionSuggestion {
  RecognitionSuggestion(
    this.product,
    this.label,
    this.confidence, {
    this.unknownFields = const ['price', 'stock'],
    this.ocrText,
  });
  final CatalogProduct? product;
  final String label;
  final double confidence;
  final List<String> unknownFields;
  final String? ocrText;
}

class RecognizedObject {
  RecognizedObject({required this.label, required this.suggestions});
  final String label;
  final List<RecognitionSuggestion> suggestions;
}

class VisualSearchResult {
  VisualSearchResult({required this.suggestions, required this.hits, required this.uncertain, this.objects = const []});
  final List<RecognitionSuggestion> suggestions;
  final List<SearchHit> hits;
  final bool uncertain;
  final List<RecognizedObject> objects;
}
