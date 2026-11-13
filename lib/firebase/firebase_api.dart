import 'dart:convert';
import 'dart:math';

import 'package:cloud_functions/cloud_functions.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';

import '../api.dart';
import 'geo.dart';
import 'product_ai.dart';
import 'search_cursor.dart';

class LocalSpotFirebaseApi {
  LocalSpotFirebaseApi();

  final SearchCursorCache<Map<String, dynamic>> _searchCursorCache =
      SearchCursorCache<Map<String, dynamic>>();

  static bool get isReady => Firebase.apps.isNotEmpty;

  FirebaseAuth get _auth => FirebaseAuth.instance;
  FirebaseFirestore get _db => FirebaseFirestore.instance;
  FirebaseFunctions get _functions =>
      FirebaseFunctions.instanceFor(region: 'asia-southeast1');

  String _catalogImage(Object? value) {
    final image = value?.toString().trim() ?? '';
    final uri = Uri.tryParse(image);
    if (uri != null &&
        (uri.host == 'images.unsplash.com' ||
            uri.host == 'source.unsplash.com')) {
      return '';
    }
    return image;
  }

  Future<dynamic> _call(String name, Map<String, dynamic> data) async {
    final result = await _functions
        .httpsCallable(name)
        .call<Map<String, dynamic>>(data);
    return result.data;
  }

  Future<List<Map<String, dynamic>>> _activeVendorLocations() async {
    try {
      final result = await _call('listActiveVendorLocations', const {});
      if (result is! Map || result['sessions'] is! List) return const [];
      return [
        for (final row in result['sessions'] as List)
          if (row is Map) Map<String, dynamic>.from(row),
      ];
    } catch (_) {
      // Vendor locations are optional; keep the approved store catalog usable.
      return const [];
    }
  }

  String? get token => _auth.currentUser?.uid;

  int _toInt(dynamic v) {
    if (v is int) return v;
    if (v is num) return v.toInt();
    return int.tryParse('$v') ?? 0;
  }

  int _userNumericId(String uid) => uid.hashCode & 0x7fffffff;

  ApiException _mapAuth(FirebaseAuthException error) {
    return ApiException(switch (error.code) {
      'email-already-in-use' => 'That email is already registered.',
      'invalid-email' => 'Enter a valid email.',
      'weak-password' => 'Use a stronger password.',
      'user-not-found' ||
      'wrong-password' ||
      'invalid-credential' => 'Email or password is incorrect.',
      _ => error.message ?? 'Authentication failed.',
    });
  }

  Future<Map<String, dynamic>> _userPayload(User user) async {
    final snap = await _db.collection('users').doc(user.uid).get();
    final data = snap.data() ?? {};
    final members =
        await _db
            .collection('storeMembers')
            .where('userUid', isEqualTo: user.uid)
            .get();
    return {
      'id': (data['numericId'] as num?)?.toInt() ?? _userNumericId(user.uid),
      'name': data['name'] ?? user.displayName ?? '',
      'email': data['email'] ?? user.email ?? '',
      'role': data['role'] ?? 'customer',
      'owned_store_ids': [...?(data['ownedStoreIds'] as List?)],
      'member_store_ids': [
        for (final doc in members.docs) doc.data()['storeId'],
      ],
      'store_grants': [
        for (final doc in members.docs)
          {
            'store_id': doc.data()['storeId'],
            'inventory': doc.data()['inventory'] == true,
            'promotions': doc.data()['promotions'] == true,
            'location': doc.data()['location'] == true,
          },
      ],
    };
  }

  Future<List<Map<String, dynamic>>> _collectionMaps(String name) async {
    final snap = await _db.collection(name).get();
    return [
      for (final doc in snap.docs)
        {...doc.data(), 'id': doc.data()['numericId'] ?? doc.id},
    ];
  }

  Future<
    ({List<Map<String, dynamic>> documents, bool usedFallback, bool truncated})
  >
  _searchProductCandidates({
    required String normalizedQuery,
    required List<String> expandedCategories,
    required List<String> explicitCategories,
    required Map<String, String> attributeFilters,
  }) async {
    var indexReady = false;
    try {
      final indexState =
          await _db.collection('systemMetadata').doc('searchPrefixIndex').get();
      indexReady =
          indexState.data()?['ready'] == true &&
          indexState.data()?['version'] == 2;
    } on FirebaseException catch (error) {
      // Older deployed Rules may not expose the readiness switch yet. Product
      // documents are public, so use the bounded catalog scan in that case.
      if (error.code != 'permission-denied') rethrow;
    }
    if (!indexReady) {
      const candidateLimit = 2500;
      final snapshot =
          await _db
              .collection('products')
              .orderBy(FieldPath.documentId)
              .limit(candidateLimit + 1)
              .get();
      return (
        documents: [
          for (final doc in snapshot.docs.take(candidateLimit))
            {...doc.data(), 'id': doc.data()['numericId'] ?? doc.id},
        ],
        usedFallback: true,
        truncated: snapshot.docs.length > candidateLimit,
      );
    }

    final terms = <String>{};
    void addTerm(String value) {
      final term = _normalizeSearchText(value);
      if (term.length >= 2 && term.length <= 80) terms.add(term);
    }

    addTerm(normalizedQuery);
    for (final word in normalizedQuery.split(' ')) {
      addTerm(word);
    }
    for (final category in [...expandedCategories, ...explicitCategories]) {
      addTerm(category);
    }
    for (final value in attributeFilters.values) {
      addTerm(value);
    }
    if (terms.isEmpty || terms.length > 30) {
      const candidateLimit = 2500;
      final snapshot =
          await _db
              .collection('products')
              .orderBy(FieldPath.documentId)
              .limit(candidateLimit + 1)
              .get();
      return (
        documents: [
          for (final doc in snapshot.docs.take(candidateLimit))
            {...doc.data(), 'id': doc.data()['numericId'] ?? doc.id},
        ],
        usedFallback: true,
        truncated: snapshot.docs.length > candidateLimit,
      );
    }

    try {
      final baseQuery = _db
          .collection('products')
          .where(
            'searchPrefixes',
            arrayContainsAny: terms.toList(growable: false),
          )
          .orderBy(FieldPath.documentId);
      const candidateLimit = 2500;
      final snapshot = await baseQuery.limit(candidateLimit + 1).get();
      return (
        documents: [
          for (final doc in snapshot.docs.take(candidateLimit))
            {...doc.data(), 'id': doc.data()['numericId'] ?? doc.id},
        ],
        usedFallback: false,
        truncated: snapshot.docs.length > candidateLimit,
      );
    } on FirebaseException catch (error) {
      final missingIndex =
          error.code == 'failed-precondition' &&
          (error.message ?? '').toLowerCase().contains('index');
      if (!missingIndex && error.code != 'permission-denied') {
        rethrow;
      }
      const candidateLimit = 2500;
      final snapshot =
          await _db
              .collection('products')
              .orderBy(FieldPath.documentId)
              .limit(candidateLimit + 1)
              .get();
      return (
        documents: [
          for (final doc in snapshot.docs.take(candidateLimit))
            {...doc.data(), 'id': doc.data()['numericId'] ?? doc.id},
        ],
        usedFallback: true,
        truncated: snapshot.docs.length > candidateLimit,
      );
    }
  }

  Future<
    ({List<Map<String, dynamic>> documents, bool usedFallback, bool truncated})
  >
  _geohashCandidates(
    String collection,
    double latitude,
    double longitude, {
    String? status,
  }) async {
    try {
      final prefixes = nearbyGeohashPrefixes(latitude, longitude);
      final snapshots = await Future.wait(
        prefixes.map((prefix) {
          var query = _db
              .collection(collection)
              .where('geohash', isGreaterThanOrEqualTo: prefix)
              .where('geohash', isLessThan: '$prefix~');
          if (status != null) query = query.where('status', isEqualTo: status);
          // Fetch one extra document to tell the UI when this bounded page is incomplete.
          return query.limit(251).get();
        }),
      );
      final docs = <String, Map<String, dynamic>>{};
      var truncated = false;
      for (final snapshot in snapshots) {
        if (snapshot.docs.length > 250) truncated = true;
        for (final doc in snapshot.docs.take(250)) {
          docs[doc.id] = {'id': doc.id, ...doc.data()};
        }
      }
      // Legacy listings may not have geohashes yet. A successful Firestore
      // range query with zero matches is not an index error, so explicitly
      // retry against the bounded public catalog and apply distance locally.
      if (docs.isEmpty) {
        Query<Map<String, dynamic>> fallbackQuery = _db.collection(collection);
        if (status != null) {
          fallbackQuery = fallbackQuery.where('status', isEqualTo: status);
        }
        const fallbackLimit = 2500;
        final fallbackSnapshot =
            await fallbackQuery.limit(fallbackLimit + 1).get();
        return (
          documents: [
            for (final doc in fallbackSnapshot.docs.take(fallbackLimit))
              {'id': doc.id, ...doc.data()},
          ],
          usedFallback: true,
          truncated: fallbackSnapshot.docs.length > fallbackLimit,
        );
      }
      return (
        documents: docs.values.toList(growable: false),
        usedFallback: false,
        truncated: truncated,
      );
    } on FirebaseException catch (error) {
      final missingIndex =
          error.code == 'failed-precondition' &&
          (error.message ?? '').toLowerCase().contains('index');
      if (!missingIndex && error.code != 'permission-denied') {
        rethrow;
      }
      Query<Map<String, dynamic>> fallbackQuery = _db.collection(collection);
      if (status != null) {
        fallbackQuery = fallbackQuery.where('status', isEqualTo: status);
      }
      const fallbackLimit = 2500;
      final fallbackSnapshot =
          await fallbackQuery.limit(fallbackLimit + 1).get();
      final documents = [
        for (final doc in fallbackSnapshot.docs.take(fallbackLimit))
          {'id': doc.id, ...doc.data()},
      ];
      return (
        documents: documents,
        usedFallback: true,
        truncated: fallbackSnapshot.docs.length > fallbackLimit,
      );
    }
  }

  Map<String, dynamic> _storeJson(Map<String, dynamic> data) {
    return {
      'id': data['numericId'],
      'owner_id': data['ownerId'],
      'name': data['name'],
      'type': data['type'],
      'status': data['status'],
      'lat': data['lat'],
      'lng': data['lng'],
      'geohash': data['geohash'],
      'barangay': data['barangay'],
      'city': data['city'],
      'address': data['address'],
      'landmark': data['landmark'],
      'schedule': data['schedule'],
      'is_mobile': data['is_mobile'] == true,
      'image': _catalogImage(data['image']),
      'verification_note': data['verification_note'] ?? '',
      'location_mode': data['location_mode'] ?? 'fixed',
      'location_updated_at': data['location_updated_at'],
    };
  }

  Future<
    ({List<Map<String, dynamic>> documents, bool usedFallback, bool truncated})
  >
  _approvedStoresForIds(Set<int> storeIds) async {
    if (storeIds.isEmpty) {
      return (
        documents: const <Map<String, dynamic>>[],
        usedFallback: false,
        truncated: false,
      );
    }
    final ids = storeIds.toList(growable: false);
    final queries = <Future<QuerySnapshot<Map<String, dynamic>>>>[];
    for (var start = 0; start < ids.length; start += 30) {
      final chunk = ids.skip(start).take(30).toList(growable: false);
      queries.add(
        _db
            .collection('stores')
            .where('status', isEqualTo: 'approved')
            .where('numericId', whereIn: chunk)
            .get(),
      );
    }
    try {
      final snapshots = await Future.wait(queries);
      return (
        documents: [
          for (final snapshot in snapshots)
            for (final doc in snapshot.docs) _storeJson(doc.data()),
        ],
        usedFallback: false,
        truncated: false,
      );
    } on FirebaseException catch (error) {
      final missingIndex =
          error.code == 'failed-precondition' &&
          (error.message ?? '').toLowerCase().contains('index');
      if (!missingIndex && error.code != 'permission-denied') {
        rethrow;
      }
      const storeFallbackLimit = 2500;
      final approved =
          await _db
              .collection('stores')
              .where('status', isEqualTo: 'approved')
              .limit(storeFallbackLimit + 1)
              .get();
      return (
        documents: [
          for (final doc in approved.docs.take(storeFallbackLimit))
            if (storeIds.contains(_toInt(doc.data()['numericId'])))
              _storeJson(doc.data()),
        ],
        usedFallback: true,
        truncated: approved.docs.length > storeFallbackLimit,
      );
    }
  }

  Future<Map<String, dynamic>> catalog({
    bool includeListings = true,
    bool includeProducts = true,
  }) async {
    final user = _auth.currentUser;
    final approvedStoreDocs =
        await _db
            .collection('stores')
            .where('status', isEqualTo: 'approved')
            .get();
    final storeDocs = {for (final doc in approvedStoreDocs.docs) doc.id: doc};
    final approvedPromotionDocs =
        await _db
            .collection('promotions')
            .where('status', isEqualTo: 'approved')
            .get();
    final promotionDocs = {
      for (final doc in approvedPromotionDocs.docs) doc.id: doc,
    };
    if (user != null) {
      final profile = await _db.collection('users').doc(user.uid).get();
      if (profile.data()?['role'] == 'admin') {
        final allStores = await _db.collection('stores').get();
        final allPromotions = await _db.collection('promotions').get();
        for (final doc in allStores.docs) {
          storeDocs[doc.id] = doc;
        }
        for (final doc in allPromotions.docs) {
          promotionDocs[doc.id] = doc;
        }
      } else {
        final ownStores =
            await _db
                .collection('stores')
                .where('ownerUid', isEqualTo: user.uid)
                .get();
        final ownPromotions =
            await _db
                .collection('promotions')
                .where('ownerUid', isEqualTo: user.uid)
                .get();
        for (final doc in ownStores.docs) {
          storeDocs[doc.id] = doc;
        }
        for (final doc in ownPromotions.docs) {
          promotionDocs[doc.id] = doc;
        }
      }
    }
    final stores = [
      for (final doc in storeDocs.values) {'id': doc.id, ...doc.data()},
    ];
    final products =
        includeProducts
            ? await _collectionMaps('products')
            : <Map<String, dynamic>>[];
    final listings =
        includeListings
            ? await _collectionMaps('listings')
            : <Map<String, dynamic>>[];
    final promotions = [
      for (final doc in promotionDocs.values)
        {...doc.data(), 'id': doc.data()['numericId'] ?? doc.id},
    ];
    final publishedTours =
        await _db
            .collection('tours')
            .where('status', isEqualTo: 'published')
            .get();
    final ownDrafts =
        user == null
            ? null
            : await _db
                .collection('tours')
                .where('ownerUid', isEqualTo: user.uid)
                .get();
    final tourDocs =
        {
          for (final doc in publishedTours.docs) doc.id: doc,
          for (final doc in ownDrafts?.docs ?? const []) doc.id: doc,
        }.values;
    final tours = [
      for (final doc in tourDocs)
        {...doc.data(), 'id': doc.data()['numericId'] ?? doc.id},
    ];
    final activeVendorSessions = await _activeVendorLocations();
    final sessions = {
      for (final session in activeVendorSessions) (session['storeId']): session,
    };
    return {
      'stores': [
        for (final store in stores)
          {..._storeJson(store), 'live_session': sessions[store['numericId']]},
      ],
      'products': [
        for (final product in products)
          {
            'id': product['numericId'],
            'name': product['name'],
            'category': product['category'],
            'brand': product['brand'],
            'package_size': product['package_size'],
            'aliases': product['aliases'] ?? const [],
            'barcode': product['barcode'],
            'image': _catalogImage(product['image']),
            'attributes': product['attributes'] ?? const {},
          },
      ],
      'listings': [
        for (final listing in listings)
          {
            'id': listing['numericId'],
            'store_id': listing['storeId'],
            'product_id': listing['productId'],
            'price': listing['price'],
            'unit': listing['unit'],
            'quantity': listing['quantity'],
            'availability': listing['availability'],
            'last_confirmed_at': listing['last_confirmed_at'],
            'status': listing['status'],
          },
      ],
      'promotions': [
        for (final promo in promotions)
          {
            'id': promo['numericId'],
            'store_id': promo['storeId'],
            'title': promo['title'],
            'offer': promo['offer'],
            'starts_at': promo['starts_at'],
            'ends_at': promo['ends_at'],
            'sponsored': promo['sponsored'] == true,
            'status': promo['status'],
          },
      ],
      'tours': [
        for (final tour in tours)
          {
            'id': tour['numericId'],
            'store_id': tour['storeId'],
            'title': tour['title'],
            'status': tour['status'],
            'nodes': [
              for (final rawNode in (tour['nodes'] as List? ?? const []))
                if (rawNode is Map)
                  {
                    ...Map<String, dynamic>.from(rawNode),
                    'image': _catalogImage(rawNode['image']),
                  },
            ],
          },
      ],
    };
  }

  Future<void> _requireUser() async {
    if (_auth.currentUser == null) {
      throw ApiException('Sign in required.', status: 401);
    }
  }

  Future<bool> _canUseOwnerProductAi() async {
    final user = _auth.currentUser;
    if (user == null) return false;
    final profile = await _db.collection('users').doc(user.uid).get();
    final role = profile.data()?['role'];
    if (role == 'owner' || role == 'admin') return true;
    if (role != 'staff') return false;
    final memberships =
        await _db
            .collection('storeMembers')
            .where('userUid', isEqualTo: user.uid)
            .limit(20)
            .get();
    return memberships.docs.any((doc) => doc.data()['inventory'] == true);
  }

  Future<Map<String, dynamic>> _profile() async {
    await _requireUser();
    final user = _auth.currentUser!;
    return {
      'user': await _userPayload(user),
      'stores': [
        for (final row in (await catalog())['stores'] as List)
          if (row is Map && (row['owner_id'] == _userNumericId(user.uid))) row,
      ],
    };
  }

  Future<dynamic> get(String path, [Map<String, String>? query]) async {
    if (path == '/catalog') {
      // Catalog is publicly readable so we don't require auth here.
      // Authenticated users get more data (e.g. private tour drafts).
      return catalog();
    }
    await _requireUser();
    final staffList = RegExp(r'^/stores/(\d+)/staff$').firstMatch(path);
    if (staffList != null) {
      return _call('listStoreMemberships', {
        'storeId': int.parse(staffList.group(1)!),
      });
    }
    if (path == '/me') return _profile();
    if (path == '/favorites') {
      final snap =
          await _db
              .collection('favorites')
              .where('uid', isEqualTo: _auth.currentUser!.uid)
              .get();
      return [for (final doc in snap.docs) doc.data()];
    }
    if (path == '/admin/audit') {
      final snap = await _db.collection('auditLogs').limit(100).get();
      return [
        for (final doc in snap.docs)
          {
            'id': doc.data()['numericId'] ?? doc.id.hashCode,
            'action': doc.data()['action'],
            'user_id': doc.data()['userId'],
            'created_at': doc.data()['created_at'],
          },
      ];
    }
    if (path == '/admin/reports') {
      final snap = await _db.collection('reports').get();
      return [
        for (final doc in snap.docs)
          {
            'id': doc.data()['numericId'],
            'user_id': doc.data()['userId'],
            'target': doc.data()['target'],
            'reason': doc.data()['reason'],
            'resolved': doc.data()['resolved'] == true,
          },
      ];
    }
    if (path == '/admin/feedback') {
      final snap = await _db.collection('feedback').get();
      final docs =
          snap.docs
              .map(
                (doc) => <String, dynamic>{
                  'id': doc.data()['numericId'] ?? doc.id.hashCode,
                  'user_id': doc.data()['userId'],
                  'topic': doc.data()['topic'],
                  'body': doc.data()['body'],
                  'area': doc.data()['area'],
                },
              )
              .toList();
      docs.sort((a, b) => '${a['topic']}'.compareTo('${b['topic']}'));
      return docs;
    }
    if (path == '/stores/nearby') {
      final lat = double.tryParse(query?['lat'] ?? '') ?? 0;
      final lng = double.tryParse(query?['lng'] ?? '') ?? 0;
      final radiusKm = double.tryParse(query?['radius_km'] ?? '5') ?? 5;
      final nearbyStoreResult =
          lat == 0 && lng == 0
              ? null
              : await _geohashCandidates(
                'stores',
                lat,
                lng,
                status: 'approved',
              );
      final allStores =
          nearbyStoreResult?.documents ??
          ((await catalog())['stores'] as List? ?? []);
      if (lat == 0 && lng == 0) return allStores; // no coords, return all
      final activeSessions = await _activeVendorLocations();
      final sessionsByStore = <int, Map<String, dynamic>>{
        for (final session in activeSessions)
          if (DateTime.tryParse(
                '${session['expires_at']}',
              )?.isAfter(DateTime.now()) ==
              true)
            _toInt(session['storeId']): session,
      };
      return [
        for (final s in allStores)
          if (_geoDistKm(
                lat,
                lng,
                (s['lat'] as num?)?.toDouble() ?? 0,
                (s['lng'] as num?)?.toDouble() ?? 0,
              ) <=
              radiusKm)
            {
              ..._storeJson(s),
              'live_session': sessionsByStore[_toInt(s['numericId'])],
            },
      ];
    }

    // Recognition job status poll — return immediately as 'ready' since
    // Firebase recognition is synchronous in _recognitionSuggest.
    final recognitionJob = RegExp(
      r'^/product-recognition/jobs/(\d+)$',
    ).firstMatch(path);
    if (recognitionJob != null) {
      return {
        'id': int.parse(recognitionJob.group(1)!),
        'status': 'ready',
        'suggestions': const [],
      };
    }

    final movement = RegExp(
      r'^/store-products/(\d+)/movements$',
    ).firstMatch(path);
    if (movement != null) {
      final listingId = int.parse(movement.group(1)!);
      final response = await _call('listStoreListingMovements', {
        'listingId': listingId,
      });
      return List<Map<String, dynamic>>.from(
        (response['movements'] as List<dynamic>).map(
          (row) => Map<String, dynamic>.from(row as Map),
        ),
      );
    }
    throw ApiException('Unsupported Firebase GET $path');
  }

  String _searchFingerprint(Map<String, String> query) {
    final entries = query.entries
      .where((entry) => entry.key != 'page' && entry.key != 'cursor')
      .toList(growable: false)..sort((a, b) => a.key.compareTo(b.key));
    return jsonEncode({for (final entry in entries) entry.key: entry.value});
  }

  Map<String, dynamic> _searchPageEnvelope(
    SearchCursorPage<Map<String, dynamic>> page,
  ) => {
    'data': page.items,
    'meta': {
      ...page.metadata,
      'total': page.total,
      'last_page': page.lastPage,
      'current_page': page.currentPage,
      'next_cursor': page.nextCursor,
      'cursor_expired': page.expired,
    },
  };

  Future<Map<String, dynamic>> getEnvelope(
    String path, [
    Map<String, String>? query,
  ]) async {
    if (path == '/search') {
      final searchQuery = query ?? const <String, String>{};
      final perPage = (int.tryParse(searchQuery['per_page'] ?? '') ?? 20).clamp(
        1,
        50,
      );
      final fingerprint = _searchFingerprint(searchQuery);
      final cursor = searchQuery['cursor'];
      if (cursor != null) {
        return _searchPageEnvelope(
          _searchCursorCache.continueFrom(
            cursor: cursor,
            fingerprint: fingerprint,
            pageSize: perPage,
          ),
        );
      }
      final q = (query?['q'] ?? '').trim().toLowerCase();
      final categoryFilter = (query?['category'] ?? '').trim();
      final typeFilter = (query?['type'] ?? '').trim();
      final availabilityFilter = (query?['availability'] ?? '').trim();
      final minPrice = double.tryParse(query?['min_price'] ?? '');
      final maxPrice = double.tryParse(query?['max_price'] ?? '');
      final searchLat = double.tryParse(query?['lat'] ?? '') ?? 0;
      final searchLng = double.tryParse(query?['lng'] ?? '') ?? 0;
      final radiusKm = double.tryParse(query?['radius_km'] ?? '10') ?? 10;

      final hasSearchLocation = searchLat != 0 || searchLng != 0;
      final geohashResult =
          hasSearchLocation
              ? await _geohashCandidates(
                'listings',
                searchLat,
                searchLng,
                status: 'active',
              )
              : null;
      var candidateTruncated = geohashResult?.truncated == true;
      late final List<Map<String, dynamic>> allListings;
      if (geohashResult != null) {
        allListings = geohashResult.documents
            .map(
              (listing) => <String, dynamic>{
                'id': listing['numericId'],
                'store_id': listing['storeId'],
                'product_id': listing['productId'],
                'price': listing['price'],
                'unit': listing['unit'],
                'quantity': listing['quantity'],
                'availability': listing['availability'],
                'last_confirmed_at': listing['last_confirmed_at'],
                'status': listing['status'],
              },
            )
            .toList(growable: false);
      } else {
        const candidateLimit = 2500;
        final snapshot =
            await _db
                .collection('listings')
                .where('status', isEqualTo: 'active')
                .orderBy(FieldPath.documentId)
                .limit(candidateLimit + 1)
                .get();
        candidateTruncated = snapshot.docs.length > candidateLimit;
        allListings = [
          for (final doc in snapshot.docs.take(candidateLimit))
            {
              'id': doc.data()['numericId'],
              'store_id': doc.data()['storeId'],
              'product_id': doc.data()['productId'],
              'price': doc.data()['price'],
              'unit': doc.data()['unit'],
              'quantity': doc.data()['quantity'],
              'availability': doc.data()['availability'],
              'last_confirmed_at': doc.data()['last_confirmed_at'],
              'status': doc.data()['status'],
            },
        ];
      }
      final storeIds = {
        for (final listing in allListings)
          if (listing['store_id'] is num) _toInt(listing['store_id']),
      };
      final storeResult = await _approvedStoresForIds(storeIds);
      candidateTruncated = candidateTruncated || storeResult.truncated;

      final storeMap = <int, Map<String, dynamic>>{
        for (final s in storeResult.documents)
          _toInt((s as Map)['id']): Map<String, dynamic>.from(s),
      };

      // Expand category families (e.g. 'food' → [Produce, Groceries, Staples…]).
      final normalizedQuery =
          _normalizeSearchText(q)
              .replaceAll(RegExp(r'\b(near me|nearby|around here)\b'), ' ')
              .replaceAll(RegExp(r'\s+'), ' ')
              .trim();
      final attributeFilters = <String, String>{
        for (final entry
            in query?.entries ?? const <MapEntry<String, String>>[])
          if (entry.key.startsWith('attribute.') &&
              RegExp(r'^[a-z0-9_]{1,32}$').hasMatch(entry.key.substring(10)) &&
              _normalizeSearchText(entry.value).isNotEmpty)
            entry.key.substring(10): _normalizeSearchText(entry.value),
      };
      final expandedCategories = _expandCategories(normalizedQuery);
      final explicitCategories = _expandCategories(categoryFilter);
      final productCandidates = await _searchProductCandidates(
        normalizedQuery: normalizedQuery,
        expandedCategories: expandedCategories,
        explicitCategories: explicitCategories,
        attributeFilters: attributeFilters,
      );
      candidateTruncated = candidateTruncated || productCandidates.truncated;
      // Firestore product document IDs are opaque; listings reference numeric IDs.
      final productMap = <int, Map<String, dynamic>>{
        for (final product in productCandidates.documents)
          _toInt(
            (product as Map)['numericId'] ?? product['id'],
          ): Map<String, dynamic>.from(product),
      };

      final results = <Map<String, dynamic>>[];
      for (final listing in allListings) {
        final l = Map<String, dynamic>.from(listing as Map);
        if (l['status'] != null && l['status'] != 'active') continue;

        final product = productMap[_toInt(l['product_id'])];
        final store = storeMap[_toInt(l['store_id'])];
        if (product == null || store == null) continue;
        if (store['status'] != 'approved') continue;

        if (availabilityFilter.isNotEmpty &&
            '${l['availability']}' != availabilityFilter) {
          continue;
        }
        final price = (l['price'] as num?)?.toDouble() ?? 0;
        if (minPrice != null && price < minPrice) continue;
        if (maxPrice != null && price > maxPrice) continue;

        // Seller type filter.
        if (typeFilter.isNotEmpty &&
            '${store['type']}'.toLowerCase() != typeFilter.toLowerCase()) {
          continue;
        }

        // Explicit category filter from the filter UI.
        if (explicitCategories.isNotEmpty) {
          final productCat = _normalizeSearchText('${product['category']}');
          if (!explicitCategories.any(
            (c) => _normalizeSearchText(c) == productCat,
          )) {
            continue;
          }
        }

        // Keyword/category match.
        String matchType = 'exact';
        final productAttributes =
            product['attributes'] is Map
                ? Map<String, dynamic>.from(product['attributes'] as Map)
                : const <String, dynamic>{};
        if (attributeFilters.entries.any(
          (filter) =>
              filter.key == 'brand'
                  ? !_normalizeSearchText(
                    '${product['brand']}',
                  ).contains(filter.value)
                  : !productAttributes.entries.any(
                    (attribute) =>
                        _normalizeSearchText(
                              attribute.key,
                            ).replaceAll(' ', '') ==
                            filter.key.replaceAll('_', '') &&
                        _normalizeSearchText(
                          '${attribute.value}',
                        ).contains(filter.value),
                  ),
        )) {
          continue;
        }
        if (normalizedQuery.isNotEmpty) {
          final name = _normalizeSearchText('${product['name']}');
          final category = _normalizeSearchText('${product['category']}');
          final brand = _normalizeSearchText('${product['brand']}');
          final aliases =
              (product['aliases'] as List? ?? [])
                  .map((a) => _normalizeSearchText('$a'))
                  .toList();

          final exactMatch =
              name.contains(normalizedQuery) ||
              aliases.any((a) => a.contains(normalizedQuery));
          final brandMatch = brand.contains(normalizedQuery);
          final categoryExpand =
              expandedCategories.isNotEmpty &&
              expandedCategories.any(
                (c) => _normalizeSearchText(c) == category,
              );
          final categoryDirect = category.contains(normalizedQuery);
          final attributeMatch = productAttributes.values.any(
            (value) => _normalizeSearchText('$value').contains(normalizedQuery),
          );

          if (!exactMatch &&
              !brandMatch &&
              !categoryExpand &&
              !categoryDirect &&
              !attributeMatch) {
            continue;
          }

          if (attributeMatch &&
              !exactMatch &&
              !brandMatch &&
              !categoryExpand &&
              !categoryDirect) {
            matchType = 'attribute';
          } else if (categoryExpand && !exactMatch) {
            matchType = 'category';
          } else if (brandMatch && !exactMatch) {
            matchType = 'category';
          }
        }

        final distKm =
            hasSearchLocation
                ? _geoDistKm(
                  searchLat,
                  searchLng,
                  (store['lat'] as num?)?.toDouble() ?? 0,
                  (store['lng'] as num?)?.toDouble() ?? 0,
                )
                : 0.0;

        // Skip results outside the search radius.
        if (hasSearchLocation && distKm > radiusKm) continue;

        results.add({
          'listing': l,
          'product': product,
          'store': store,
          'distance_km': distKm,
          'match_type': matchType,
        });
      }

      final sort = query?['sort'] ?? 'relevance';
      results.sort((a, b) {
        final aExact = a['match_type'] == 'exact' ? 0 : 1;
        final bExact = b['match_type'] == 'exact' ? 0 : 1;
        final aDist = (a['distance_km'] as num?)?.toDouble() ?? 0;
        final bDist = (b['distance_km'] as num?)?.toDouble() ?? 0;
        final aListing = a['listing'] as Map;
        final bListing = b['listing'] as Map;
        if (sort == 'price') {
          final priceOrder = ((aListing['price'] as num?) ?? 0).compareTo(
            (bListing['price'] as num?) ?? 0,
          );
          if (priceOrder != 0) return priceOrder;
        } else if (sort == 'freshness') {
          final freshnessOrder = '${bListing['last_confirmed_at']}'.compareTo(
            '${aListing['last_confirmed_at']}',
          );
          if (freshnessOrder != 0) return freshnessOrder;
        } else if (sort == 'distance') {
          final distanceOrder = aDist.compareTo(bDist);
          if (distanceOrder != 0) return distanceOrder;
        } else if (aExact != bExact) {
          return aExact.compareTo(bExact);
        } else if ((aDist - bDist).abs() > 0.1) {
          return aDist.compareTo(bDist);
        }
        final aDate = '${aListing['last_confirmed_at']}';
        final bDate = '${bListing['last_confirmed_at']}';
        return bDate.compareTo(aDate);
      });

      final page = (int.tryParse(query?['page'] ?? '') ?? 1).clamp(1, 1000000);
      final offset = (page - 1) * perPage;
      return _searchPageEnvelope(
        _searchCursorCache.begin(
          fingerprint: fingerprint,
          items: results,
          pageSize: perPage,
          offset: offset,
          metadata: {
            'index_fallback':
                geohashResult?.usedFallback == true ||
                storeResult.usedFallback ||
                productCandidates.usedFallback,
            'candidate_truncated': candidateTruncated,
          },
        ),
      );
    }
    final data = await get(path, query);
    return {'data': data};
  }

  /// Expand a query term into category names using the same family/synonym
  /// map as the client-side [expandedCategories] function in models.dart.
  List<String> _expandCategories(String query) {
    final normalized = _normalizeSearchText(query);
    if (normalized.isEmpty) return const [];
    // Handle family: prefix (from category chip filter).
    if (normalized.startsWith('family ')) {
      final family = normalized.substring(7).trim();
      return _categoryFamilies[family] ?? const [];
    }
    // Synonym lookup.
    final cleaned =
        normalized
            .replaceAll(RegExp(r'\b(near me|nearby|around here)\b'), ' ')
            .replaceAll(RegExp(r'\s+'), ' ')
            .trim();
    for (final token in cleaned.split(' ')) {
      final family =
          _categorySynonyms[token] ??
          (_categoryFamilies.containsKey(token) ? token : null);
      if (family != null) return _categoryFamilies[family] ?? const [];
    }
    // Direct category name match.
    final directMatch =
        _allCategories
            .where(
              (c) =>
                  c.toLowerCase() == cleaned ||
                  c.toLowerCase().contains(cleaned),
            )
            .toList();
    return directMatch;
  }

  String _normalizeSearchText(String value) =>
      value
          .toLowerCase()
          .replaceAll(RegExp(r'[^a-z0-9]+'), ' ')
          .replaceAll(RegExp(r'\s+'), ' ')
          .trim();

  static const _categoryFamilies = <String, List<String>>{
    'food': [
      'Produce',
      'Groceries',
      'Staples',
      'Bakery',
      'Street food',
      'Drinks',
    ],
    'tech': ['Electronics', 'Computers', 'Phones', 'Appliances'],
    'hardware': ['Hardware', 'Tools', 'Plumbing', 'Electrical'],
    'clothing': ['Clothing'],
    'household': ['Household', 'Furniture', 'Appliances'],
  };

  static const _categorySynonyms = <String, String>{
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

  static const _allCategories = [
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

  Future<dynamic> post(String path, [Map<String, dynamic>? body]) async {
    final data = body ?? const <String, dynamic>{};
    if (path == '/auth/register') return _register(data);
    if (path == '/auth/login') return _login(data);
    await _requireUser();
    final uid = _auth.currentUser!.uid;

    if (path == '/stores') {
      return _call('submitStoreApplication', {
        ...data,
        'imageAssetId': data['image_asset_id'],
      });
    }

    final sessionStart = RegExp(
      r'^/stores/(\d+)/location-sessions$',
    ).firstMatch(path);
    if (sessionStart != null) {
      return _call('startVendorLocationSession', {
        'storeId': int.parse(sessionStart.group(1)!),
        'lat': data['lat'],
        'lng': data['lng'],
      });
    }

    if (path == '/favorites/toggle') {
      final type = data['favoritable_type'];
      final id = data['favoritable_id'];
      final existing =
          await _db
              .collection('favorites')
              .where('uid', isEqualTo: uid)
              .where('favoritable_type', isEqualTo: type)
              .where('favoritable_id', isEqualTo: id)
              .limit(1)
              .get();
      if (existing.docs.isNotEmpty) {
        await existing.docs.first.reference.delete();
      } else {
        await _db.collection('favorites').add({
          'uid': uid,
          'favoritable_type': type,
          'favoritable_id': id,
        });
      }
      return {'ok': true};
    }

    if (path == '/feedback') {
      return _call('submitUserFeedback', {
        'topic': data['topic'],
        'body': data['body'],
        'area': data['area'],
      });
    }

    if (path == '/reports') {
      return _call('submitUserReport', {
        'target': data['target'],
        'reason': data['reason'],
      });
    }

    final staff = RegExp(r'^/stores/(\d+)/staff$').firstMatch(path);
    if (staff != null) {
      final storeId = int.parse(staff.group(1)!);
      return _call('manageStoreMembership', {
        'storeId': storeId,
        'email': '${data['email']}'.trim().toLowerCase(),
        'action': 'set',
        'inventory': data['can_inventory'] == true,
        'promotions': data['can_promotions'] == true,
        'location': data['can_location'] == true,
      });
    }

    final listingCreate = RegExp(r'^/stores/(\d+)/products$').firstMatch(path);
    if (listingCreate != null) {
      final storeId = int.parse(listingCreate.group(1)!);
      return _call('createStoreListing', {
        'storeId': storeId,
        'productId': data['product_id'],
        'name': data['name'],
        'category': data['category'],
        'brand': data['brand'],
        'packageSize': data['package_size'],
        'barcode': data['barcode'],
        'attributes': data['attributes'],
        'imageAssetId': data['image_asset_id'],
        'price': data['price'],
        'unit': data['unit'],
        'quantity': data['quantity'] ?? 0,
        'availability': data['availability'] ?? 'in_stock',
      });
    }

    final promoCreate = RegExp(r'^/stores/(\d+)/promotions$').firstMatch(path);
    if (promoCreate != null) {
      return _call('createStorePromotion', {
        'storeId': int.parse(promoCreate.group(1)!),
        ...data,
      });
    }

    final tourCreate = RegExp(r'^/stores/(\d+)/tours$').firstMatch(path);
    if (tourCreate != null) {
      return _call('manageStoreTour', {
        'action': 'create',
        'storeId': int.parse(tourCreate.group(1)!),
        'title': data['title'],
      });
    }

    final nodeCreate = RegExp(r'^/tours/(\d+)/nodes$').firstMatch(path);
    if (nodeCreate != null) {
      return _call('manageStoreTour', {
        'action': 'addNode',
        'tourId': int.parse(nodeCreate.group(1)!),
        'title': data['title'],
        'originalPath': data['original_path'],
      });
    }

    final connect = RegExp(r'^/tours/(\d+)/connections$').firstMatch(path);
    if (connect != null) {
      return _call('manageStoreTour', {
        'action': 'connect',
        'tourId': int.parse(connect.group(1)!),
        'fromNodeId': data['from_node_id'],
        'toNodeId': data['to_node_id'],
      });
    }

    if (RegExp(
          r'^/tours/\d+/nodes/\d+/(process|review|manual-blurs)$',
        ).hasMatch(path) ||
        RegExp(r'^/tours/\d+/publish$').hasMatch(path)) {
      throw ApiException(
        'Trusted panorama privacy processing is not available yet.',
        status: 409,
      );
    }

    // ── Product recognition (catalog keyword/alias ranking) ───────────────
    if (path == '/product-recognition/suggest') {
      if (data['image'] is String &&
          (data['image'] as String).isNotEmpty &&
          !await _canUseOwnerProductAi()) {
        throw ApiException(
          'Photo suggestions are available to store owners and inventory staff.',
          status: 403,
        );
      }
      return _recognitionSuggest(data);
    }

    // ── Route preview (straight-line fallback) ────────────────────────────
    if (path == '/routes/preview') {
      return _routePreview(data);
    }

    // ── Visual / image search ─────────────────────────────────────────────
    if (path == '/search/by-image') {
      final suggestions = await _recognitionSuggest(data, allowAi: false);
      final catalogData = await _cachedCatalog();
      final allListings = catalogData['listings'] as List? ?? [];
      final allProducts = catalogData['products'] as List? ?? [];
      final allStores = catalogData['stores'] as List? ?? [];
      final productMap = <int, Map<String, dynamic>>{
        for (final p in allProducts)
          _toInt((p as Map)['id']): Map<String, dynamic>.from(p),
      };
      final storeMap = <int, Map<String, dynamic>>{
        for (final s in allStores)
          _toInt((s as Map)['id']): Map<String, dynamic>.from(s),
      };
      final suggestedIds = <int>{
        for (final s in (suggestions['suggestions'] as List? ?? []))
          if ((s as Map)['product'] != null) _toInt(s['product']['id']),
      };
      final hits = <Map<String, dynamic>>[];
      for (final listing in allListings) {
        final l = Map<String, dynamic>.from(listing as Map);
        final productId = _toInt(l['product_id']);
        if (!suggestedIds.contains(productId)) continue;
        final product = productMap[productId];
        final store = storeMap[_toInt(l['store_id'])];
        if (product == null || store == null) continue;
        if (store['status'] != 'approved') continue;
        hits.add({
          'listing': l,
          'product': product,
          'store': store,
          'distance_km': 0,
        });
      }
      return {
        'suggestions': suggestions['suggestions'],
        'hits': hits,
        'uncertain': suggestions['uncertain'] ?? true,
      };
    }

    throw ApiException('Unsupported Firebase POST $path');
  }

  // Catalog cache for recognition — refreshed at most once per minute.
  Map<String, dynamic>? _catalogCache;
  DateTime? _catalogCachedAt;

  Future<Map<String, dynamic>> _cachedCatalog() async {
    final now = DateTime.now();
    if (_catalogCache != null &&
        _catalogCachedAt != null &&
        now.difference(_catalogCachedAt!) < const Duration(minutes: 2)) {
      return _catalogCache!;
    }
    _catalogCache = await catalog();
    _catalogCachedAt = now;
    return _catalogCache!;
  }

  /// Rank the catalog by keyword/alias/category match against hint + barcode.
  /// This is the on-device recognition pipeline (no external vision API).
  Future<Map<String, dynamic>> _recognitionSuggest(
    Map<String, dynamic> data, {
    bool allowAi = true,
  }) async {
    final hint = (data['hint'] as String? ?? '').toLowerCase().trim();
    final barcode = (data['barcode'] as String? ?? '').trim();
    final catalogData = await _cachedCatalog();
    final allProducts = catalogData['products'] as List? ?? [];

    if (allowAi &&
        data['image'] is String &&
        (data['image'] as String).isNotEmpty) {
      try {
        final aiItems = await ProductAiSuggestionService.suggest(
          dataUrl: data['image'] as String,
          hint: hint,
          barcode: barcode,
        );
        final suggestions = <Map<String, dynamic>>[];
        for (final item in aiItems) {
          final candidateName = _normalizeSearchText(item['name'] as String);
          Map<String, dynamic>? matchedProduct;
          for (final rawProduct in allProducts) {
            final product = Map<String, dynamic>.from(rawProduct as Map);
            final names = <String>[
              '${product['name'] ?? ''}',
              ...((product['aliases'] as List? ?? []).map((alias) => '$alias')),
            ];
            if (names.any(
              (name) => _normalizeSearchText(name) == candidateName,
            )) {
              matchedProduct = product;
              break;
            }
          }
          suggestions.add({
            'product': matchedProduct,
            'label': '${item['name']} · ${item['category']}',
            'confidence': matchedProduct == null ? 0.5 : 0.7,
            'unknown_fields': [
              if (matchedProduct == null) 'catalog match',
              'price',
              'stock',
              'availability',
            ],
            'ocr': (item['ocr'] as String).isEmpty ? null : item['ocr'],
            'suggested_name': item['name'],
            'suggested_category': item['category'],
            'suggested_brand': item['brand'],
            'suggested_package_size': item['package_size'],
            'suggested_attributes': item['attributes'],
            'is_ai_generated': true,
          });
        }
        return {
          'suggestions': suggestions,
          'uncertain': true,
          'status': 'ready',
          'source': 'firebase_ai_logic',
        };
      } catch (_) {
        // AI is optional. Continue to the catalog matcher so manual entry stays available.
      }
    }

    // Score each product
    final scored = <(int score, Map<String, dynamic> product)>[];
    for (final p in allProducts) {
      final product = Map<String, dynamic>.from(p as Map);
      final score = _scoreProduct(product, hint: hint, barcode: barcode);
      if (score < 100) scored.add((score, product));
    }
    scored.sort((a, b) => a.$1.compareTo(b.$1));

    final suggestions = <Map<String, dynamic>>[];
    for (final item in scored.take(4)) {
      final product = item.$2;
      final confidence =
          item.$1 == 0
              ? 0.92
              : item.$1 <= 3
              ? 0.75
              : 0.45;
      suggestions.add({
        'product': product,
        'label': '${product['name']} · ${product['category']}',
        'confidence': confidence,
        'unknown_fields': ['price', 'stock'],
        'ocr': barcode.isNotEmpty ? 'barcode: $barcode' : null,
      });
    }

    if (suggestions.isEmpty) {
      suggestions.add({
        'product': null,
        'label': 'No catalog match · encode manually',
        'confidence': 0.0,
        'unknown_fields': ['identity', 'price', 'stock'],
        'ocr': null,
      });
    }

    return {
      'suggestions': suggestions,
      'uncertain': suggestions.every((s) => (s['confidence'] as double) < 0.5),
      'status': 'ready',
    };
  }

  /// Haversine distance in km between two lat/lng points.
  double _geoDistKm(double lat1, double lng1, double lat2, double lng2) {
    const r = 6371.0;
    final dLat = (lat2 - lat1) * pi / 180;
    final dLng = (lng2 - lng1) * pi / 180;
    final a =
        sin(dLat / 2) * sin(dLat / 2) +
        cos(lat1 * pi / 180) *
            cos(lat2 * pi / 180) *
            sin(dLng / 2) *
            sin(dLng / 2);
    return r * 2 * atan2(sqrt(a), sqrt(1 - a));
  }

  int _scoreProduct(
    Map<String, dynamic> product, {
    required String hint,
    required String barcode,
  }) {
    if (barcode.isNotEmpty) {
      final bc = '${product['barcode'] ?? ''}'.toLowerCase();
      if (bc == barcode.toLowerCase()) return 0;
    }
    if (hint.isEmpty) return 100;
    final name = '${product['name']}'.toLowerCase();
    final category = '${product['category']}'.toLowerCase();
    final brand = '${product['brand']}'.toLowerCase();
    final aliases =
        (product['aliases'] as List? ?? [])
            .map((a) => '$a'.toLowerCase())
            .toList();
    if (name == hint) return 0;
    if (name.startsWith(hint)) return 1;
    if (name.contains(hint)) return 2;
    if (aliases.any((a) => a == hint || a.contains(hint))) return 3;
    if (brand.contains(hint)) return 4;
    if (category.contains(hint)) return 5;
    // Token overlap for multi-word hints
    final hintTokens =
        hint.split(RegExp(r'\s+')).where((t) => t.length >= 2).toSet();
    final productTokens =
        '$name $category $brand ${aliases.join(' ')}'
            .split(RegExp(r'[^a-z0-9]+'))
            .where((t) => t.length >= 2)
            .toSet();
    final overlap = hintTokens.intersection(productTokens).length;
    if (overlap > 0) return 6 + (hintTokens.length - overlap);
    return 100;
  }

  Map<String, dynamic> _routePreview(Map<String, dynamic> data) {
    final originLat = (data['origin_lat'] as num?)?.toDouble() ?? 0.0;
    final originLng = (data['origin_lng'] as num?)?.toDouble() ?? 0.0;
    final destLat = (data['destination_lat'] as num?)?.toDouble() ?? 0.0;
    final destLng = (data['destination_lng'] as num?)?.toDouble() ?? 0.0;
    const steps = 16;
    final coordinates = <List<double>>[
      for (var i = 0; i <= steps; i++)
        [
          originLat + (destLat - originLat) * (i / steps),
          originLng + (destLng - originLng) * (i / steps),
        ],
    ];
    double radians(double degrees) => degrees * pi / 180;
    final dLat = radians(destLat - originLat);
    final dLng = radians(destLng - originLng);
    final a = (sin(dLat / 2) * sin(dLat / 2) +
            cos(radians(originLat)) *
                cos(radians(destLat)) *
                sin(dLng / 2) *
                sin(dLng / 2))
        .clamp(0.0, 1.0);
    final km = 6371.0 * 2 * atan2(sqrt(a), sqrt(1 - a));
    return {
      'coordinates': coordinates,
      'distance_km': km,
      'duration_minutes': null,
      'provider': 'localspot-firebase',
      'fallback': true,
    };
  }

  Future<dynamic> patch(String path, [Map<String, dynamic>? body]) async {
    await _requireUser();
    final data = body ?? const <String, dynamic>{};

    final storePatch = RegExp(r'^/stores/(\d+)$').firstMatch(path);
    if (storePatch != null) {
      return _call('updateStore', {
        'storeId': int.parse(storePatch.group(1)!),
        if (data['name'] != null) 'name': data['name'],
        if (data['type'] != null) 'type': data['type'],
        if (data['lat'] != null) 'lat': data['lat'],
        if (data['lng'] != null) 'lng': data['lng'],
        if (data['barangay'] != null) 'barangay': data['barangay'],
        if (data['city'] != null) 'city': data['city'],
        if (data['address'] != null) 'address': data['address'],
        if (data['landmark'] != null) 'landmark': data['landmark'],
        if (data['schedule'] != null) 'schedule': data['schedule'],
        if (data['is_mobile'] != null) 'isMobile': data['is_mobile'],
      });
    }

    final adminStore = RegExp(r'^/admin/stores/(\d+)$').firstMatch(path);
    if (adminStore != null) {
      return _call('reviewStoreApplication', {
        'storeId': int.parse(adminStore.group(1)!),
        'status': data['status'],
      });
    }

    final listingPatch = RegExp(r'^/store-products/(\d+)$').firstMatch(path);
    if (listingPatch != null) {
      final listingId = int.parse(listingPatch.group(1)!);
      if (data['status'] == 'archived') {
        return _call('archiveStoreListing', {'listingId': listingId});
      }
      return _call('updateStoreListing', {'listingId': listingId, ...data});
    }

    final promoAdmin = RegExp(r'^/admin/promotions/(\d+)$').firstMatch(path);
    if (promoAdmin != null) {
      return _call('reviewStorePromotion', {
        'promotionId': int.parse(promoAdmin.group(1)!),
        'status': data['status'],
      });
    }

    final reportAdmin = RegExp(r'^/admin/reports/(\d+)$').firstMatch(path);
    if (reportAdmin != null) {
      return _call('resolveReport', {
        'reportId': int.parse(reportAdmin.group(1)!),
      });
    }

    final sessionPatch = RegExp(
      r'^/stores/(\d+)/location-sessions/current$',
    ).firstMatch(path);
    if (sessionPatch != null) {
      return _call('updateVendorLocationSession', {
        'storeId': int.parse(sessionPatch.group(1)!),
        'lat': data['lat'],
        'lng': data['lng'],
      });
    }

    final staffPatch = RegExp(r'^/stores/(\d+)/staff/(\d+)$').firstMatch(path);
    if (staffPatch != null) {
      final storeId = int.parse(staffPatch.group(1)!);
      final memberNumericId = int.parse(staffPatch.group(2)!);
      return _call('manageStoreMembership', {
        'storeId': storeId,
        'userNumericId': memberNumericId,
        'action': 'set',
        if (data['can_inventory'] != null) 'inventory': data['can_inventory'],
        if (data['can_promotions'] != null)
          'promotions': data['can_promotions'],
        if (data['can_location'] != null) 'location': data['can_location'],
      });
    }

    throw ApiException('Unsupported Firebase PATCH $path');
  }

  Future<dynamic> delete(String path) async {
    if (path == '/auth/logout') {
      await _auth.signOut();
      return {'ok': true};
    }
    await _requireUser();
    if (path == '/auth/account') {
      return _call('deleteUserAccount', const {});
    }
    final session = RegExp(
      r'^/stores/(\d+)/location-sessions/current$',
    ).firstMatch(path);
    if (session != null) {
      return _call('stopVendorLocationSession', {
        'storeId': int.parse(session.group(1)!),
      });
    }
    final staff = RegExp(r'^/stores/(\d+)/staff/(\d+)$').firstMatch(path);
    if (staff != null) {
      return _call('manageStoreMembership', {
        'storeId': int.parse(staff.group(1)!),
        'userNumericId': int.parse(staff.group(2)!),
        'action': 'remove',
      });
    }
    throw ApiException('Unsupported Firebase DELETE $path');
  }

  Future<Map<String, dynamic>> _register(Map<String, dynamic> data) async {
    try {
      final credential = await _auth.createUserWithEmailAndPassword(
        email: '${data['email']}',
        password: '${data['password']}',
      );
      final user = credential.user!;
      await user.updateDisplayName('${data['name']}');
      // The Auth onUserCreated trigger owns profile creation. Once it has made
      // the customer-only profile, sync only the user-editable name field.
      try {
        final profile = _db.collection('users').doc(user.uid);
        for (var attempt = 0; attempt < 20; attempt++) {
          final snapshot = await profile.get();
          if (snapshot.exists) {
            await profile.update({'name': data['name']});
            break;
          }
          await Future<void>.delayed(const Duration(milliseconds: 300));
        }
      } catch (_) {}
      return {'token': user.uid, 'user': await _userPayload(user)};
    } on FirebaseAuthException catch (error) {
      throw _mapAuth(error);
    }
  }

  Future<Map<String, dynamic>> _login(Map<String, dynamic> data) async {
    try {
      final credential = await _auth.signInWithEmailAndPassword(
        email: '${data['email']}',
        password: '${data['password']}',
      );
      return {
        'token': credential.user!.uid,
        'user': await _userPayload(credential.user!),
      };
    } on FirebaseAuthException catch (error) {
      throw _mapAuth(error);
    }
  }
}
