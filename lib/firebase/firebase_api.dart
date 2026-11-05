// firebase_api.dart — DEPRECATED direct Firestore access.
//
// This class was the transitional direct-Firestore data layer. It is no
// longer used by LocalSpotGateway (which now routes ALL business reads and
// writes through the Laravel REST API). It is retained only so that any
// legacy code paths or tests that still reference it do not break during
// the transition.
//
// In the target architecture:
//   - Firebase Authentication remains directly integrated (allowed exception).
//   - Firebase Storage SDK remains directly integrated (allowed exception).
//   - cloud_firestore is NOT used for business data — Laravel owns Firestore.
//
// This file can be removed once all references are confirmed gone, and the
// `cloud_firestore` dependency removed from pubspec.yaml.

import 'dart:math';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';

import '../api.dart';

class LocalSpotFirebaseApi {
  LocalSpotFirebaseApi();

  static bool get isReady => Firebase.apps.isNotEmpty;

  FirebaseAuth get _auth => FirebaseAuth.instance;
  FirebaseFirestore get _db => FirebaseFirestore.instance;

  String? get token => _auth.currentUser?.uid;

  int _id() => DateTime.now().microsecondsSinceEpoch & 0x7fffffff;

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
      'user-not-found' || 'wrong-password' || 'invalid-credential' => 'Email or password is incorrect.',
      _ => error.message ?? 'Authentication failed.',
    });
  }

  Future<Map<String, dynamic>> _userPayload(User user) async {
    final snap = await _db.collection('users').doc(user.uid).get();
    final data = snap.data() ?? {};
    final members = await _db.collection('storeMembers').where('userUid', isEqualTo: user.uid).get();
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
    return [for (final doc in snap.docs) {'id': doc.id, ...doc.data()}];
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
      'barangay': data['barangay'],
      'city': data['city'],
      'address': data['address'],
      'landmark': data['landmark'],
      'schedule': data['schedule'],
      'is_mobile': data['is_mobile'] == true,
      'image': data['image'],
      'verification_note': data['verification_note'] ?? '',
      'location_mode': data['location_mode'] ?? 'fixed',
      'location_updated_at': data['location_updated_at'],
    };
  }

  Future<Map<String, dynamic>> catalog() async {
    // Fetch all collections in parallel instead of sequentially.
    // Previously 6 sequential round-trips; now a single parallel wait.
    final results = await Future.wait([
      _collectionMaps('stores'),
      _collectionMaps('products'),
      _collectionMaps('listings'),
      _collectionMaps('promotions'),
      _collectionMaps('tours'),
      _collectionMaps('vendorSessions'),
    ]);

    final stores = results[0];
    final products = results[1];
    final listings = results[2];
    final promotions = results[3];
    final tours = results[4];
    final sessions = {
      for (final row in results[5]) row['storeId']: row,
    };
    return {
      'stores': [
        for (final store in stores)
          {
            ..._storeJson(store),
            'live_session': sessions[store['numericId']],
          },
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
            'image': product['image'] ?? '',
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
            'nodes': tour['nodes'] ?? const [],
          },
      ],
    };
  }

  Future<DocumentSnapshot<Map<String, dynamic>>> _storeByNumeric(int id) async {
    final snap = await _db.collection('stores').where('numericId', isEqualTo: id).limit(1).get();
    if (snap.docs.isEmpty) throw ApiException('Store not found.');
    return snap.docs.first;
  }

  Future<DocumentSnapshot<Map<String, dynamic>>> _docByNumeric(String collection, int id) async {
    final snap = await _db.collection(collection).where('numericId', isEqualTo: id).limit(1).get();
    if (snap.docs.isEmpty) throw ApiException('Not found.');
    return snap.docs.first;
  }

  Future<void> _requireUser() async {
    if (_auth.currentUser == null) throw ApiException('Sign in required.', status: 401);
  }

  Future<Map<String, dynamic>> _profile() async {
    await _requireUser();
    final user = _auth.currentUser!;
    return {
      'user': await _userPayload(user),
      'stores': [
        for (final row in (await _cachedCatalog())['stores'] as List)
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
    if (path == '/me') return _profile();
    if (path == '/favorites') {
      final snap = await _db.collection('favorites').where('uid', isEqualTo: _auth.currentUser!.uid).get();
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
      final docs = snap.docs.map((doc) => <String, dynamic>{
        'id': doc.data()['numericId'] ?? doc.id.hashCode,
        'user_id': doc.data()['userId'],
        'topic': doc.data()['topic'],
        'body': doc.data()['body'],
        'area': doc.data()['area'],
      }).toList();
      docs.sort((a, b) => '${a['topic']}'.compareTo('${b['topic']}'));
      return docs;
    }
    if (path == '/stores/nearby') {
      final lat = double.tryParse(query?['lat'] ?? '') ?? 0;
      final lng = double.tryParse(query?['lng'] ?? '') ?? 0;
      final radiusKm = double.tryParse(query?['radius_km'] ?? '5') ?? 5;
      final allStores = (await _cachedCatalog())['stores'] as List? ?? [];
      if (lat == 0 && lng == 0) return allStores; // no coords, return all
      return [
        for (final s in allStores)
          if (s is Map && _geoDistKm(lat, lng, (s['lat'] as num?)?.toDouble() ?? 0, (s['lng'] as num?)?.toDouble() ?? 0) <= radiusKm)
            s,
      ];
    }

    // Recognition job status poll — return immediately as 'ready' since
    // Firebase recognition is synchronous in _recognitionSuggest.
    final recognitionJob = RegExp(r'^/product-recognition/jobs/(\d+)$').firstMatch(path);
    if (recognitionJob != null) {
      return {'id': int.parse(recognitionJob.group(1)!), 'status': 'ready', 'suggestions': const []};
    }

    final movement = RegExp(r'^/store-products/(\d+)/movements$').firstMatch(path);
    if (movement != null) {
      final listingId = int.parse(movement.group(1)!);
      final snap = await _db.collection('stockMovements').where('listingId', isEqualTo: listingId).get();
      final rows = [
        for (final doc in snap.docs)
          {
            'kind': doc.data()['kind'],
            'quantity_delta': doc.data()['quantity_delta'],
            'note': doc.data()['note'],
            'created_at': doc.data()['created_at'],
          },
      ];
      rows.sort((a, b) => '${b['created_at']}'.compareTo('${a['created_at']}'));
      return rows;
    }
    throw ApiException('Unsupported Firebase GET $path');
  }

  Future<Map<String, dynamic>> getEnvelope(String path, [Map<String, String>? query]) async {
    if (path == '/search') {
      final q = (query?['q'] ?? '').trim().toLowerCase();
      final categoryFilter = (query?['category'] ?? '').trim();
      final typeFilter = (query?['type'] ?? '').trim();
      final searchLat = double.tryParse(query?['lat'] ?? '') ?? 0;
      final searchLng = double.tryParse(query?['lng'] ?? '') ?? 0;
      final radiusKm = double.tryParse(query?['radius_km'] ?? '10') ?? 10;

      final catalogData = await _cachedCatalog();
      final allProducts = catalogData['products'] as List? ?? [];
      final allListings = catalogData['listings'] as List? ?? [];
      final allStores = catalogData['stores'] as List? ?? [];

      // Build lookup maps with int key guard.
      final productMap = <int, Map<String, dynamic>>{
        for (final p in allProducts) _toInt((p as Map)['id']): Map<String, dynamic>.from(p),
      };
      final storeMap = <int, Map<String, dynamic>>{
        for (final s in allStores) _toInt((s as Map)['id']): Map<String, dynamic>.from(s),
      };

      // Expand category families (e.g. 'food' → [Produce, Groceries, Staples…]).
      final expandedCategories = _expandCategories(q);
      final explicitCategories = _expandCategories(categoryFilter);

      final results = <Map<String, dynamic>>[];
      for (final listing in allListings) {
        final l = Map<String, dynamic>.from(listing as Map);
        if (l['status'] != null && l['status'] != 'active') continue;

        final product = productMap[_toInt(l['product_id'])];
        final store = storeMap[_toInt(l['store_id'])];
        if (product == null || store == null) continue;
        if (store['status'] != 'approved') continue;

        // Seller type filter.
        if (typeFilter.isNotEmpty && '${store['type']}'.toLowerCase() != typeFilter.toLowerCase()) continue;

        // Explicit category filter from the filter UI.
        if (explicitCategories.isNotEmpty) {
          final productCat = '${product['category']}'.toLowerCase();
          if (!explicitCategories.any((c) => c.toLowerCase() == productCat)) continue;
        }

        // Keyword/category match.
        String matchType = 'exact';
        if (q.isNotEmpty) {
          final name = '${product['name']}'.toLowerCase();
          final category = '${product['category']}'.toLowerCase();
          final brand = '${product['brand']}'.toLowerCase();
          final aliases = (product['aliases'] as List? ?? [])
              .map((a) => '$a'.toLowerCase())
              .toList();

          final exactMatch = name.contains(q) || aliases.any((a) => a.contains(q));
          final brandMatch = brand.contains(q);
          final categoryExpand = expandedCategories.isNotEmpty &&
              expandedCategories.any((c) => c.toLowerCase() == category);
          final categoryDirect = category.contains(q);

          if (!exactMatch && !brandMatch && !categoryExpand && !categoryDirect) continue;

          if (categoryExpand && !exactMatch) {
            matchType = 'category';
          } else if (brandMatch && !exactMatch) {
            matchType = 'category';
          }
        }

        final distKm = searchLat != 0
            ? _geoDistKm(searchLat, searchLng,
                (store['lat'] as num?)?.toDouble() ?? 0,
                (store['lng'] as num?)?.toDouble() ?? 0)
            : 0.0;

        // Skip results outside the search radius.
        if (searchLat != 0 && distKm > radiusKm) continue;

        results.add({
          'listing': l,
          'product': product,
          'store': store,
          'distance_km': distKm,
          'match_type': matchType,
        });
      }

      // Sort: exact matches first, then by distance, then by freshness.
      results.sort((a, b) {
        final aExact = a['match_type'] == 'exact' ? 0 : 1;
        final bExact = b['match_type'] == 'exact' ? 0 : 1;
        if (aExact != bExact) return aExact.compareTo(bExact);
        final aDist = (a['distance_km'] as num?)?.toDouble() ?? 0;
        final bDist = (b['distance_km'] as num?)?.toDouble() ?? 0;
        if ((aDist - bDist).abs() > 0.1) return aDist.compareTo(bDist);
        final aDate = '${(a['listing'] as Map)['last_confirmed_at']}';
        final bDate = '${(b['listing'] as Map)['last_confirmed_at']}';
        return bDate.compareTo(aDate);
      });

      return {
        'data': results,
        'meta': {
          'total': results.length,
          'last_page': 1,
          'current_page': 1,
        },
      };
    }
    final data = await get(path, query);
    return {'data': data};
  }

  /// Expand a query term into category names using the same family/synonym
  /// map as the client-side [expandedCategories] function in models.dart.
  List<String> _expandCategories(String query) {
    if (query.isEmpty) return const [];
    // Handle family: prefix (from category chip filter).
    if (query.startsWith('family:')) {
      final family = query.substring(7);
      return _categoryFamilies[family] ?? const [];
    }
    // Synonym lookup.
    final cleaned = query
        .toLowerCase()
        .replaceAll(RegExp(r'\b(near me|nearby|around here)\b'), ' ')
        .trim();
    for (final token in cleaned.split(' ')) {
      final family = _categorySynonyms[token] ??
          (_categoryFamilies.containsKey(token) ? token : null);
      if (family != null) return _categoryFamilies[family] ?? const [];
    }
    // Direct category name match.
    final directMatch = _allCategories
        .where((c) => c.toLowerCase() == cleaned || c.toLowerCase().contains(cleaned))
        .toList();
    return directMatch;
  }

  static const _categoryFamilies = <String, List<String>>{
    'food': ['Produce', 'Groceries', 'Staples', 'Bakery', 'Street food', 'Drinks'],
    'tech': ['Electronics', 'Computers', 'Phones', 'Appliances'],
    'hardware': ['Hardware', 'Tools', 'Plumbing', 'Electrical'],
    'clothing': ['Clothing'],
    'household': ['Household', 'Furniture', 'Appliances'],
  };

  static const _categorySynonyms = <String, String>{
    'food': 'food', 'pagkain': 'food', 'grocery': 'food', 'groceries': 'food',
    'produce': 'food', 'tech': 'tech', 'gadget': 'tech', 'electronics': 'tech',
    'computer': 'tech', 'phone': 'tech', 'hardware': 'hardware', 'tools': 'hardware',
    'tool': 'hardware', 'clothing': 'clothing', 'clothes': 'clothing',
    'household': 'household',
  };

  static const _allCategories = [
    'Produce', 'Groceries', 'Staples', 'Bakery', 'Street food', 'Drinks',
    'Hardware', 'Tools', 'Plumbing', 'Electrical', 'Electronics', 'Computers',
    'Phones', 'Appliances', 'Household', 'Furniture', 'Clothing', 'Books', 'Automotive',
  ];

  Future<dynamic> post(String path, [Map<String, dynamic>? body]) async {
    final data = body ?? const <String, dynamic>{};
    if (path == '/auth/register') return _register(data);
    if (path == '/auth/login') return _login(data);
    await _requireUser();
    final uid = _auth.currentUser!.uid;
    final numericUser = _userNumericId(uid);

    if (path == '/stores') {
      final id = _id();
      await _db.collection('stores').add({
        'numericId': id,
        'ownerId': numericUser,
        'ownerUid': uid,
        'name': data['name'],
        'type': data['type'],
        'status': 'pending',
        'lat': data['lat'],
        'lng': data['lng'],
        'barangay': data['barangay'] ?? '',
        'city': data['city'] ?? '',
        'address': data['address'] ?? '',
        'landmark': data['landmark'] ?? '',
        'schedule': data['schedule'] ?? '',
        'is_mobile': data['is_mobile'] == true,
        'image': data['image'],
        'verification_note': data['verification_note'] ?? '',
        'location_mode': data['is_mobile'] == true ? 'regular' : 'fixed',
        'location_updated_at': DateTime.now().toIso8601String(),
      });
      final userRef = _db.collection('users').doc(uid);
      await _db.runTransaction((tx) async {
        final snap = await tx.get(userRef);
        final owned = [...?(snap.data()?['ownedStoreIds'] as List?), id];
        tx.update(userRef, {'ownedStoreIds': owned, 'role': 'owner'});
      });
      return {'id': id};
    }

    if (path == '/favorites/toggle') {
      final type = data['favoritable_type'];
      final id = data['favoritable_id'];
      final existing = await _db
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
      await _db.collection('feedback').add({
        'numericId': _id(),
        'userId': numericUser,
        'uid': uid,
        'topic': data['topic'],
        'body': data['body'],
        'area': data['area'],
      });
      return {'ok': true};
    }

    if (path == '/reports') {
      await _db.collection('reports').add({
        'numericId': _id(),
        'userId': numericUser,
        'uid': uid,
        'target': data['target'],
        'reason': data['reason'],
        'resolved': false,
      });
      return {'ok': true};
    }

    final staff = RegExp(r'^/stores/(\d+)/staff$').firstMatch(path);
    if (staff != null) {
      final storeId = int.parse(staff.group(1)!);
      final email = '${data['email']}'.trim().toLowerCase();
      // Look up the invitee's Firestore user doc by email
      String userUid = '';
      int userNumericId = 0;
      try {
        final snap = await _db.collection('users').where('email', isEqualTo: email).limit(1).get();
        if (snap.docs.isEmpty) {
          throw ApiException('No LocalSpot account uses that email.');
        }
        userUid = snap.docs.first.id;
        userNumericId = _toInt(snap.docs.first.data()['numericId']);
        // Add storeId to their memberStoreIds
        await _db.runTransaction((tx) async {
          final ref = snap.docs.first.reference;
          final current = await tx.get(ref);
          final existing = (current.data()?['memberStoreIds'] as List? ?? []);
          if (!existing.contains(storeId)) {
            tx.update(ref, {'memberStoreIds': [...existing, storeId], 'role': 'staff'});
          }
        });
      } catch (e) {
        if (e is ApiException) rethrow;
        // If lookup fails, proceed with empty uid (offline-ish fallback)
      }
      // Upsert storeMember record
      final existing = await _db.collection('storeMembers')
          .where('storeId', isEqualTo: storeId)
          .where('email', isEqualTo: email)
          .limit(1)
          .get();
      final memberData = {
        'storeId': storeId,
        'email': email,
        'userUid': userUid,
        'userNumericId': userNumericId,
        'inventory': data['can_inventory'] == true,
        'promotions': data['can_promotions'] == true,
        'location': data['can_location'] == true,
      };
      if (existing.docs.isNotEmpty) {
        await existing.docs.first.reference.update(memberData);
      } else {
        await _db.collection('storeMembers').add(memberData);
      }
      return {'ok': true};
    }

    final listingCreate = RegExp(r'^/stores/(\d+)/products$').firstMatch(path);
    if (listingCreate != null) {
      final storeId = int.parse(listingCreate.group(1)!);
      var productId = data['product_id'] as int?;
      if (productId == null) {
        productId = _id();
        await _db.collection('products').add({
          'numericId': productId,
          'name': data['name'],
          'category': data['category'] ?? 'Groceries',
          'brand': data['brand'] ?? '',
          'package_size': data['package_size'] ?? '',
          'aliases': [data['name']],
          'barcode': data['barcode'],
          'image': '',
          'attributes': data['attributes'] ?? {},
          'createdByUid': uid,
        });
      }
      final listingId = _id();
      await _db.collection('listings').add({
        'numericId': listingId,
        'storeId': storeId,
        'productId': productId,
        'price': data['price'],
        'unit': data['unit'],
        'quantity': data['quantity'] ?? 0,
        'availability': data['availability'] ?? 'in_stock',
        'last_confirmed_at': DateTime.now().toIso8601String(),
        'status': 'active',
        'ownerUid': uid,
      });
      await _db.collection('stockMovements').add({
        'listingId': listingId,
        'kind': 'add',
        'quantity_delta': data['quantity'] ?? 0,
        'note': 'Owner confirmed listing',
        'created_at': DateTime.now().toIso8601String(),
        'ownerUid': uid,
      });
      return {'id': listingId};
    }

    final promoCreate = RegExp(r'^/stores/(\d+)/promotions$').firstMatch(path);
    if (promoCreate != null) {
      final id = _id();
      await _db.collection('promotions').add({
        'numericId': id,
        'storeId': int.parse(promoCreate.group(1)!),
        'title': data['title'],
        'offer': data['offer'],
        'starts_at': data['starts_at'],
        'ends_at': data['ends_at'],
        'sponsored': data['sponsored'] == true,
        'status': 'pending',
        'ownerUid': uid,
      });
      return {'id': id};
    }

    final tourCreate = RegExp(r'^/stores/(\d+)/tours$').firstMatch(path);
    if (tourCreate != null) {
      final id = _id();
      await _db.collection('tours').add({
        'numericId': id,
        'storeId': int.parse(tourCreate.group(1)!),
        'title': data['title'],
        'status': 'draft',
        'nodes': const [],
        'ownerUid': uid,
      });
      return {
        'id': id,
        'store_id': int.parse(tourCreate.group(1)!),
        'title': data['title'],
        'status': 'draft',
        'nodes': const [],
      };
    }

    final sessionStart = RegExp(r'^/stores/(\d+)/location-sessions$').firstMatch(path);
    if (sessionStart != null) {
      final storeId = int.parse(sessionStart.group(1)!);
      final now = DateTime.now();
      final payload = {
        'numericId': _id(),
        'storeId': storeId,
        'lat': data['lat'],
        'lng': data['lng'],
        'started_at': now.toIso8601String(),
        'last_update_at': now.toIso8601String(),
        'expires_at': now.add(const Duration(hours: 2)).toIso8601String(),
        'ended_at': null,
        'ownerUid': uid,
      };
      await _db.collection('vendorSessions').doc('$storeId').set(payload);
      return payload;
    }

    final nodeCreate = RegExp(r'^/tours/(\d+)/nodes$').firstMatch(path);
    if (nodeCreate != null) {
      return _mutateTour(int.parse(nodeCreate.group(1)!), (tour) {
        final nodes = [...?(tour['nodes'] as List?)];
        final nodeId = nodes.length + 1;
        nodes.add({
          'id': nodeId,
          'title': data['title'],
          'image': '',
          'connections': nodes.isEmpty ? const [] : [nodes.length],
          'privacy_status': 'processing',
          'owner_reviewed': false,
          'manual_blur': false,
          'original_retained': true,
          'blur_regions': const [],
        });
        if (nodes.length >= 2) {
          final prev = Map<String, dynamic>.from(nodes[nodes.length - 2] as Map);
          prev['connections'] = [...?(prev['connections'] as List?), nodeId];
          nodes[nodes.length - 2] = prev;
        }
        tour['nodes'] = nodes;
      });
    }

    final connect = RegExp(r'^/tours/(\d+)/connections$').firstMatch(path);
    if (connect != null) {
      return _mutateTour(int.parse(connect.group(1)!), (tour) {
        final nodes = [
          for (final node in (tour['nodes'] as List? ?? [])) Map<String, dynamic>.from(node as Map),
        ];
        void link(int from, int to) {
          for (final node in nodes) {
            if (node['id'] == from) {
              final connections = [...?(node['connections'] as List?)];
              if (!connections.contains(to)) connections.add(to);
              node['connections'] = connections;
            }
          }
        }
        link(data['from_node_id'] as int, data['to_node_id'] as int);
        link(data['to_node_id'] as int, data['from_node_id'] as int);
        tour['nodes'] = nodes;
      });
    }

    final process = RegExp(r'^/tours/(\d+)/nodes/(\d+)/process$').firstMatch(path);
    if (process != null) {
      return _mutateTour(int.parse(process.group(1)!), (tour) {
        final fail = data['fail'] == true;
        tour['nodes'] = [
          for (final node in (tour['nodes'] as List? ?? []))
            if ((node as Map)['id'] == int.parse(process.group(2)!))
              {
                ...node,
                'privacy_status': fail ? 'failed' : 'ready',
                'image': fail ? '' : '/tours/public/${tour['storeId']}/${node['id']}.jpg',
                'owner_reviewed': false,
              }
            else
              node,
        ];
      });
    }

    final review = RegExp(r'^/tours/(\d+)/nodes/(\d+)/review$').firstMatch(path);
    if (review != null) {
      return _mutateTour(int.parse(review.group(1)!), (tour) {
        tour['nodes'] = [
          for (final node in (tour['nodes'] as List? ?? []))
            if ((node as Map)['id'] == int.parse(review.group(2)!)) {...node, 'owner_reviewed': true} else node,
        ];
      });
    }

    final blurs = RegExp(r'^/tours/(\d+)/nodes/(\d+)/manual-blurs$').firstMatch(path);
    if (blurs != null) {
      return _mutateTour(int.parse(blurs.group(1)!), (tour) {
        tour['nodes'] = [
          for (final node in (tour['nodes'] as List? ?? []))
            if ((node as Map)['id'] == int.parse(blurs.group(2)!))
              {
                ...node,
                'manual_blur': true,
                'privacy_status': 'ready',
                'blur_regions': [...?(node['blur_regions'] as List?), ...?(data['regions'] as List?)],
              }
            else
              node,
        ];
      });
    }

    final publish = RegExp(r'^/tours/(\d+)/publish$').firstMatch(path);
    if (publish != null) {
      return _mutateTour(int.parse(publish.group(1)!), (tour) {
        tour['status'] = 'published';
      });
    }

    // ── Product recognition (catalog keyword/alias ranking) ───────────────
    if (path == '/product-recognition/suggest') {
      return _recognitionSuggest(data);
    }

    // ── Route preview (straight-line fallback) ────────────────────────────
    if (path == '/routes/preview') {
      return _routePreview(data);
    }

    // ── Visual / image search ─────────────────────────────────────────────
    if (path == '/search/by-image') {
      final suggestions = await _recognitionSuggest(data);
      final catalogData = await _cachedCatalog();
      final allListings = catalogData['listings'] as List? ?? [];
      final allProducts = catalogData['products'] as List? ?? [];
      final allStores = catalogData['stores'] as List? ?? [];
      final productMap = <int, Map<String, dynamic>>{
        for (final p in allProducts) _toInt((p as Map)['id']): Map<String, dynamic>.from(p),
      };
      final storeMap = <int, Map<String, dynamic>>{
        for (final s in allStores) _toInt((s as Map)['id']): Map<String, dynamic>.from(s),
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
        hits.add({'listing': l, 'product': product, 'store': store, 'distance_km': 0});
      }
      return {
        'suggestions': suggestions['suggestions'],
        'hits': hits,
        'uncertain': suggestions['uncertain'] ?? true,
      };
    }

    throw ApiException('Unsupported Firebase POST $path');
  }

  // Catalog cache — refreshed at most once every 5 minutes.
  // This means repeated searches and recognition calls reuse the same
  // in-memory snapshot instead of going back to Firestore each time.
  Map<String, dynamic>? _catalogCache;
  DateTime? _catalogCachedAt;

  Future<Map<String, dynamic>> _cachedCatalog() async {
    final now = DateTime.now();
    if (_catalogCache != null &&
        _catalogCachedAt != null &&
        now.difference(_catalogCachedAt!) < const Duration(minutes: 5)) {
      return _catalogCache!;
    }
    _catalogCache = await catalog();
    _catalogCachedAt = now;
    return _catalogCache!;
  }

  /// Rank the catalog by keyword/alias/category match against hint + barcode.
  /// This is the on-device recognition pipeline (no external vision API).
  Future<Map<String, dynamic>> _recognitionSuggest(Map<String, dynamic> data) async {
    final hint = (data['hint'] as String? ?? '').toLowerCase().trim();
    final barcode = (data['barcode'] as String? ?? '').trim();
    final catalogData = await _cachedCatalog();
    final allProducts = catalogData['products'] as List? ?? [];

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
      final confidence = item.$1 == 0 ? 0.92 : item.$1 <= 3 ? 0.75 : 0.45;
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
    final a = sin(dLat / 2) * sin(dLat / 2) +
        cos(lat1 * pi / 180) * cos(lat2 * pi / 180) * sin(dLng / 2) * sin(dLng / 2);
    return r * 2 * atan2(sqrt(a), sqrt(1 - a));
  }

  int _scoreProduct(Map<String, dynamic> product, {required String hint, required String barcode}) {
    if (barcode.isNotEmpty) {
      final bc = '${product['barcode'] ?? ''}'.toLowerCase();
      if (bc == barcode.toLowerCase()) return 0;
    }
    if (hint.isEmpty) return 100;
    final name = '${product['name']}'.toLowerCase();
    final category = '${product['category']}'.toLowerCase();
    final brand = '${product['brand']}'.toLowerCase();
    final aliases = (product['aliases'] as List? ?? []).map((a) => '$a'.toLowerCase()).toList();
    if (name == hint) return 0;
    if (name.startsWith(hint)) return 1;
    if (name.contains(hint)) return 2;
    if (aliases.any((a) => a == hint || a.contains(hint))) return 3;
    if (brand.contains(hint)) return 4;
    if (category.contains(hint)) return 5;
    // Token overlap for multi-word hints
    final hintTokens = hint.split(RegExp(r'\s+')).where((t) => t.length >= 2).toSet();
    final productTokens = '$name $category $brand ${aliases.join(' ')}'
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
    final dLat = destLat - originLat;
    final dLng = destLng - originLng;
    final distKm = 6371.0 * 2 * (0.5 - (dLat * dLat + dLng * dLng) / 4);
    final km = distKm.abs().clamp(0.01, 9999.0);
    return {
      'coordinates': coordinates,
      'distance_km': km,
      'duration_minutes': (km / 20 * 60).ceil().clamp(1, 9999),
      'provider': 'localspot-firebase',
      'fallback': true,
    };
  }

  Future<Map<String, dynamic>> _mutateTour(int tourId, void Function(Map<String, dynamic> tour) mutate) async {
    final doc = await _docByNumeric('tours', tourId);
    final tour = {...doc.data()!};
    mutate(tour);
    await doc.reference.update({'nodes': tour['nodes'], 'status': tour['status']});
    return {
      'id': tour['numericId'],
      'store_id': tour['storeId'],
      'title': tour['title'],
      'status': tour['status'],
      'nodes': tour['nodes'] ?? const [],
    };
  }

  Future<dynamic> patch(String path, [Map<String, dynamic>? body]) async {
    await _requireUser();
    final data = body ?? const <String, dynamic>{};
    final uid = _auth.currentUser!.uid;

    final storePatch = RegExp(r'^/stores/(\d+)$').firstMatch(path);
    if (storePatch != null) {
      final doc = await _storeByNumeric(int.parse(storePatch.group(1)!));
      await doc.reference.update({
        if (data['name'] != null) 'name': data['name'],
        if (data['type'] != null) 'type': data['type'],
        if (data['lat'] != null) 'lat': data['lat'],
        if (data['lng'] != null) 'lng': data['lng'],
        if (data['barangay'] != null) 'barangay': data['barangay'],
        if (data['city'] != null) 'city': data['city'],
        if (data['address'] != null) 'address': data['address'],
        if (data['landmark'] != null) 'landmark': data['landmark'],
        if (data['schedule'] != null) 'schedule': data['schedule'],
        if (data['is_mobile'] != null) 'is_mobile': data['is_mobile'],
        if (data['image'] != null) 'image': data['image'],
        'location_updated_at': DateTime.now().toIso8601String(),
      });
      return {'ok': true};
    }

    final adminStore = RegExp(r'^/admin/stores/(\d+)$').firstMatch(path);
    if (adminStore != null) {
      final doc = await _storeByNumeric(int.parse(adminStore.group(1)!));
      await doc.reference.update({'status': data['status']});
      await _db.collection('auditLogs').add({
        'numericId': _id(),
        'action': 'store.status=${data['status']}',
        'userId': _userNumericId(uid),
        'created_at': DateTime.now().toIso8601String(),
      });
      return {'ok': true};
    }

    final listingPatch = RegExp(r'^/store-products/(\d+)$').firstMatch(path);
    if (listingPatch != null) {
      final doc = await _docByNumeric('listings', int.parse(listingPatch.group(1)!));
      final prevData = doc.data();
      await doc.reference.update({
        if (data['price'] != null) 'price': data['price'],
        if (data['unit'] != null) 'unit': data['unit'],
        if (data['quantity'] != null) 'quantity': data['quantity'],
        if (data['availability'] != null) 'availability': data['availability'],
        if (data['status'] != null) 'status': data['status'],
        'last_confirmed_at': DateTime.now().toIso8601String(),
      });
      // Write a stock movement entry so history is visible.
      final prevQty = (prevData?['quantity'] as num?)?.toInt() ?? 0;
      final newQty = (data['quantity'] as num?)?.toInt() ?? prevQty;
      final delta = newQty - prevQty;
      final kind = data['status'] == 'archived' ? 'archive' : 'adjust';
      await _db.collection('stockMovements').add({
        'listingId': _toInt(prevData?['numericId']),
        'kind': kind,
        'quantity_delta': delta,
        'note': data['status'] == 'unavailable' ? 'Marked unavailable' : 'Stock update',
        'created_at': DateTime.now().toIso8601String(),
        'ownerUid': uid,
      });
      return {'ok': true};
    }

    final promoAdmin = RegExp(r'^/admin/promotions/(\d+)$').firstMatch(path);
    if (promoAdmin != null) {
      final doc = await _docByNumeric('promotions', int.parse(promoAdmin.group(1)!));
      await doc.reference.update({'status': data['status']});
      return {'ok': true};
    }

    final reportAdmin = RegExp(r'^/admin/reports/(\d+)$').firstMatch(path);
    if (reportAdmin != null) {
      final doc = await _docByNumeric('reports', int.parse(reportAdmin.group(1)!));
      await doc.reference.update({'resolved': true});
      return {'ok': true};
    }

    final sessionPatch = RegExp(r'^/stores/(\d+)/location-sessions/current$').firstMatch(path);
    if (sessionPatch != null) {
      await _db.collection('vendorSessions').doc(sessionPatch.group(1)!).set({
        'lat': data['lat'],
        'lng': data['lng'],
        'last_update_at': DateTime.now().toIso8601String(),
        'ownerUid': uid,
      }, SetOptions(merge: true));
      return {'ok': true};
    }

    final staffPatch = RegExp(r'^/stores/(\d+)/staff/(\d+)$').firstMatch(path);
    if (staffPatch != null) {
      final storeId = int.parse(staffPatch.group(1)!);
      final memberNumericId = int.parse(staffPatch.group(2)!);
      // Find the specific staff member by their numeric ID, not just the first one.
      final snap = await _db
          .collection('storeMembers')
          .where('storeId', isEqualTo: storeId)
          .where('userNumericId', isEqualTo: memberNumericId)
          .limit(1)
          .get();
      if (snap.docs.isNotEmpty) {
        await snap.docs.first.reference.update({
          if (data['can_inventory'] != null) 'inventory': data['can_inventory'],
          if (data['can_promotions'] != null) 'promotions': data['can_promotions'],
          if (data['can_location'] != null) 'location': data['can_location'],
        });
      }
      return {'ok': true};
    }

    throw ApiException('Unsupported Firebase PATCH $path');
  }

  Future<dynamic> delete(String path) async {
    if (path == '/auth/logout') {
      await _auth.signOut();
      return {'ok': true};
    }
    await _requireUser();
    final session = RegExp(r'^/stores/(\d+)/location-sessions/current$').firstMatch(path);
    if (session != null) {
      await _db.collection('vendorSessions').doc(session.group(1)!).set({
        'ended_at': DateTime.now().toIso8601String(),
        'ownerUid': _auth.currentUser!.uid,
      }, SetOptions(merge: true));
      return {'ok': true};
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
      final role = '${data['role']}';
      await _db.collection('users').doc(user.uid).set({
        'numericId': _userNumericId(user.uid),
        'name': data['name'],
        'email': data['email'],
        'role': role == 'admin' ? 'admin' : (role == 'owner' ? 'owner' : 'customer'),
        'ownedStoreIds': const [],
        'memberStoreIds': const [],
        'storeGrants': const [],
      });
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
      return {'token': credential.user!.uid, 'user': await _userPayload(credential.user!)};
    } on FirebaseAuthException catch (error) {
      throw _mapAuth(error);
    }
  }
}
