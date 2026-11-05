import 'dart:async';
import 'dart:math';

import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';

import 'api.dart';
import 'firebase/gateway.dart';
import 'firebase/media_upload_service.dart';
import 'models.dart';
import 'repositories.dart';

const defaultCenterLat = 14.6195;
const defaultCenterLng = 121.0568;
const radiiKm = [1.0, 3.0, 5.0, 10.0];

class AppState extends ChangeNotifier {
  AppState();

  final api = LocalSpotGateway();
  late final authRepo = AuthRepository(api);
  late final catalogRepo = CatalogRepository(api);
  // Media upload service for the Cloud Storage quarantine flow (plan Wave 1).
  late final mediaUpload = MediaUploadService();

  // [apiOnline] means Firebase is initialized so authenticated API requests
  // can be attempted. [backendReachable] tracks a successful API read.
  bool apiOnline = false;
  bool backendReachable = false;
  bool usingSeededCatalog = false;
  bool writeBusy = false;
  ApiException? lastApiError;
  String connectionNote = 'Connecting to the LocalSpot API…';

  // Temporary client identifiers are replaced with server records after writes.
  int _nextFeedback = -1;
  int _nextProduct = -1;
  int _nextListing = -1;
  int _nextPromo = -1;
  int _nextTour = -1;
  int _nextReport = -1;

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
  final _pendingFavoriteWrites = <String>{};
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
    return null;
  }

  Future<void> bootstrap() async {
    // Firebase is already initialized in main() before runApp().
    // AppState.bootstrap() only needs to load catalog data and restore session.
    final firebaseReady = Firebase.apps.isNotEmpty;

    // Show a connecting message immediately so the UI isn't blank.
    connectionNote = 'Connecting to the LocalSpot API…';
    notifyListeners();

    if (firebaseReady) {
      apiOnline = true;
      try {
        final data = await catalogRepo.catalog();
        _applyCatalog(data);
        usingSeededCatalog = false;
        backendReachable = true;
        connectionNote = 'Connected to the LocalSpot API';
        // Restore session from Firebase Auth persisted state if available.
        if (api.token != null) {
          try {
            await _hydrateSession();
          } catch (e) {
            if (e is BackendUnreachableException) {
              backendReachable = false;
              connectionNote = '⚠ LocalSpot API unreachable — live data could not be loaded';
            } else {
              // Auth token may have expired; clear and fall through to guest mode.
              currentUser = null;
            }
          }
        }
      } on BackendUnreachableException {
        backendReachable = false;
        connectionNote = '⚠ LocalSpot API unreachable — live data could not be loaded';
      } catch (e) {
        // Firebase is initialized, but the API request failed.
        backendReachable = false;
        connectionNote = 'Error loading catalog: ${e.toString().length > 60 ? e.toString().substring(0, 60) : e}';
      }
    } else {
      // No local demo data: business records must come from Laravel/Firestore.
      apiOnline = false;
      backendReachable = false;
      usingSeededCatalog = false;
      connectionNote = 'Firebase Auth is not configured · connect to LocalSpot API to load live data';
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
      // Also refresh reports and feedback from Firestore for admin view.
      try {
        final reportRows = await api.get('/admin/reports') as List;
        reports
          ..clear()
          ..addAll(reportRows.map((e) => ReportItem(
                id: (e as Map)['id'] as int? ?? 0,
                userId: e['user_id'] as int? ?? 0,
                target: e['target'] as String? ?? '',
                reason: e['reason'] as String? ?? '',
                resolved: e['resolved'] == true,
              )));
      } catch (_) {}
      try {
        final feedbackRows = await api.get('/admin/feedback') as List;
        feedback
          ..clear()
          ..addAll(feedbackRows.map((e) => PilotFeedback(
                id: (e as Map)['id'] as int? ?? 0,
                userId: e['user_id'] as int? ?? 0,
                topic: e['topic'] as String? ?? '',
                body: e['body'] as String? ?? '',
                area: e['area'] as String?,
              )));
      } catch (_) {}
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
    try {
      final data = await catalogRepo.catalog();
      _applyCatalog(data);
      usingSeededCatalog = false;
      backendReachable = true;
      connectionNote = 'Connected to the LocalSpot API';
      notifyListeners();
    } on BackendUnreachableException {
      backendReachable = false;
      connectionNote = '⚠ LocalSpot API unreachable — live data could not be loaded';
      notifyListeners();
    } catch (error) {
      backendReachable = false;
      connectionNote = 'Catalog refresh failed: ${error.toString().length > 80 ? error.toString().substring(0, 80) : error}';
      notifyListeners();
    }
  }

  Future<void> refreshNearby() async {
    if (!apiOnline) return;
    // Load the complete server catalog before requesting location-specific data.
    if (usingSeededCatalog) {
      await refreshCatalog();
      if (usingSeededCatalog) return;
    }
    // Laravel's catalog is the source of truth — use the full catalog
    // path which already returns location-aware store data.
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
        final session =
            vendorSessionFromJson(live is Map ? Map<String, dynamic>.from(live) : null);
        if (session != null) {
          vendorSessions[session.storeId] = session;
        } else {
          vendorSessions.remove(incoming.id);
        }
      }
      backendReachable = true;
      connectionNote = 'Connected to the LocalSpot API';
      notifyListeners();
    } on BackendUnreachableException {
      backendReachable = false;
      connectionNote = '⚠ LocalSpot API unreachable — showing cached data';
      notifyListeners();
    } catch (error) {
      backendReachable = false;
      connectionNote = 'Nearby stores refresh failed: ${error.toString().length > 80 ? error.toString().substring(0, 80) : error}';
      notifyListeners();
    }
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
        final data = await authRepo.register(
            name: name, email: email, password: password, role: role);
        // Firebase Auth manages the session — token is the UID.
        currentUser =
            userFromJson(Map<String, dynamic>.from(data['user'] as Map));
        // Hydrate catalog/favorites in the background; don't block the UI.
        unawaited(_hydrateSession().catchError((_) {}));
        notifyListeners();
        return null;
      } on ApiException catch (error) {
        lastApiError = error;
        notifyListeners();
        return error;
      }
    }
    return ApiException('Firebase Auth and the LocalSpot API are required to create an account.');
  }

  Future<String?> login(String email, String password) async {
    if (apiOnline) {
      try {
        final data =
            await authRepo.login(email: email, password: password);
        currentUser =
            userFromJson(Map<String, dynamic>.from(data['user'] as Map));
        // Hydrate in background so the UI navigates immediately.
        unawaited(() async {
          try {
            await _hydrateSession();
            if (currentUser?.role == AppRole.admin) {
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
              notifyListeners();
            }
          } on BackendUnreachableException {
            connectionNote = '⚠ Signed in but server was unreachable — some features require connectivity';
            notifyListeners();
          } catch (_) {}
        }());
        notifyListeners();
        return null;
      } on ApiException catch (error) {
        return error.message;
      }
    }
    return 'Firebase Auth and the LocalSpot API are required to sign in.';
  }

  void logout() {
    // Firebase sign-out is handled inside the gateway's delete('/auth/logout').
    if (apiOnline) {
      unawaited(api.delete('/auth/logout'));
    }
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
        searchNote = 'Search API returned no live results.';
      } else {
        final pageHits = <SearchHit>[];
        for (final row in rows) {
          try {
            final r = Map<String, dynamic>.from(row as Map);
            pageHits.add(SearchHit(
              listing: listingFromJson(Map<String, dynamic>.from(r['listing'] as Map)),
              store: storeFromJson(Map<String, dynamic>.from(r['store'] as Map)),
              product: productFromJson(Map<String, dynamic>.from(r['product'] as Map)),
              distanceKm: (r['distance_km'] as num?)?.toDouble() ?? 0,
              matchType: _parseMatchType(r['match_type'] as String?),
            ));
          } catch (_) {
            // Skip malformed rows rather than dropping the whole result.
          }
        }
        if (nextPage && remoteSearchHits != null) {
          remoteSearchHits = [...remoteSearchHits!, ...pageHits];
        } else {
          remoteSearchHits = pageHits;
        }
        searchNote = pageHits.isEmpty && rows.isNotEmpty
            ? 'Some results could not be parsed · showing what loaded'
            : '';
      }
    } catch (e) {
      if (generation != _searchGeneration) return;
      if (!nextPage) remoteSearchHits = null;
      // Show the actual error message so it's visible in the UI during development.
      searchNote = 'Search unavailable · ${e.toString().length > 80 ? e.toString().substring(0, 80) : e}';
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

  Future<String?> toggleFavoriteStore(int id) => _toggleFavorite('store', id, favoriteStoreIds);

  Future<String?> toggleFavoriteProduct(int id) => _toggleFavorite('product', id, favoriteProductIds);

  Future<String?> _toggleFavorite(String type, int id, Set<int> favorites) async {
    final key = '$type:$id';
    if (!_pendingFavoriteWrites.add(key)) return 'Please wait for the current favorite update to finish.';

    final wasSaved = favorites.contains(id);
    if (wasSaved) {
      favorites.remove(id);
    } else {
      favorites.add(id);
    }
    notifyListeners();

    try {
      if (!apiOnline || api.token == null) return null;

      final result = await api.post('/favorites/toggle', {
        'favoritable_type': type,
        'favoritable_id': id,
      }) as Map;
      final saved = result['saved'] == true;
      if (saved) {
        favorites.add(id);
      } else {
        favorites.remove(id);
      }
      return null;
    } on ApiException catch (error) {
      lastApiError = error;
      if (wasSaved) {
        favorites.add(id);
      } else {
        favorites.remove(id);
      }
      return error.message;
    } catch (_) {
      if (wasSaved) {
        favorites.add(id);
      } else {
        favorites.remove(id);
      }
      return 'Could not update this favorite. Please try again.';
    } finally {
      _pendingFavoriteWrites.remove(key);
      notifyListeners();
    }
  }

  Future<Store> registerStore({
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
  }) async {
    _beginWrite();
    if (apiOnline && api.token != null) {
      try {
        final data = await api.post('/stores', {
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
        }) as Map;
        final store = storeFromJson(Map<String, dynamic>.from(data));
        stores.add(store);
        notifyListeners();
        await refreshCatalog();
        _endWrite();
        return store;
      } on ApiException catch (e) {
        _endWrite();
        lastApiError = e;
        notifyListeners();
        // Re-throw so the UI can show the error to the user.
        rethrow;
      }
    }
    _endWrite();
    throw ApiException(
      'Cannot register store — server is not reachable. Check your connection.',
      status: 0,
    );
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
    String? image,
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
            if (image != null) 'image': image,
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

  void addTourNode(StoreTour tour, String title, int mediaAssetId) {
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
          final data = await api.post('/tours/${tour.id}/nodes', {
            'title': title,
            'media_asset_id': mediaAssetId,
          }) as Map;
          _replaceTour(tour.id, tourFromJson(Map<String, dynamic>.from(data)));
        } on ApiException catch (error) {
          lastApiError = error;
          tour.nodes.removeWhere((candidate) => candidate.id == node.id);
          if (tour.nodes.isNotEmpty) {
            tour.nodes.last.connections.remove(node.id);
          }
          notifyListeners();
        } catch (_) {
          tour.nodes.removeWhere((candidate) => candidate.id == node.id);
          if (tour.nodes.isNotEmpty) {
            tour.nodes.last.connections.remove(node.id);
          }
          notifyListeners();
        } finally {
          _endWrite();
        }
      }());
    } else {
      _endWrite();
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

  Future<String?> publishTour(StoreTour tour) async {
    if (tour.nodes.length < 2) return 'Connect at least two viewpoints before publishing.';
    if (tour.nodes.any((node) => !node.canPublish || node.image.contains('#') || node.image.contains('tours/originals'))) {
      return 'Every viewpoint needs privacy processing and owner review before publishing.';
    }
    if (!apiOnline || api.token == null) {
      return 'Connect to the server before publishing this tour.';
    }

    _beginWrite();
    try {
      await api.post('/tours/${tour.id}/publish');
      tour.status = TourStatus.published;
      notifyListeners();
      await refreshCatalog();
      return null;
    } on ApiException catch (error) {
      lastApiError = error;
      return error.message;
    } catch (_) {
      return 'The tour could not be published. Please try again.';
    } finally {
      _endWrite();
    }
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
    return const [];
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
    return VisualSearchResult(suggestions: const [], hits: const [], uncertain: true);
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
