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
    final stores = await _collectionMaps('stores');
    final products = await _collectionMaps('products');
    final listings = await _collectionMaps('listings');
    final promotions = await _collectionMaps('promotions');
    final tours = await _collectionMaps('tours');
    final sessions = {
      for (final row in await _collectionMaps('vendorSessions')) row['storeId']: row,
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
    if (path == '/stores/nearby') return (await catalog())['stores'];
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
      // Perform a simple in-memory search over the catalog when a query is provided.
      // Full-text / semantic search can be added via a Cloud Function later.
      final q = (query?['q'] ?? '').trim().toLowerCase();
      final catalogData = await catalog();
      final allProducts = catalogData['products'] as List? ?? [];
      final allListings = catalogData['listings'] as List? ?? [];
      final allStores = catalogData['stores'] as List? ?? [];

      // Build lookup maps — use asInt to guard against Firestore returning
      // numeric IDs as doubles instead of ints.
      final productMap = <int, Map<String, dynamic>>{
        for (final p in allProducts) _toInt((p as Map)['id']): Map<String, dynamic>.from(p),
      };
      final storeMap = <int, Map<String, dynamic>>{
        for (final s in allStores) _toInt((s as Map)['id']): Map<String, dynamic>.from(s),
      };

      final results = <Map<String, dynamic>>[];
      for (final listing in allListings) {
        final l = Map<String, dynamic>.from(listing as Map);
        final product = productMap[_toInt(l['product_id'])];
        final store = storeMap[_toInt(l['store_id'])];
        if (product == null || store == null) continue;
        if (store['status'] != 'approved') continue;

        // Simple keyword match when a query is provided.
        if (q.isNotEmpty) {
          final name = '${product['name']}'.toLowerCase();
          final category = '${product['category']}'.toLowerCase();
          final brand = '${product['brand']}'.toLowerCase();
          final aliases = (product['aliases'] as List? ?? [])
              .map((a) => '$a'.toLowerCase())
              .toList();
          final matches = name.contains(q) ||
              category.contains(q) ||
              brand.contains(q) ||
              aliases.any((a) => a.contains(q));
          if (!matches) continue;
        }

        results.add({
          'listing': l,
          'product': product,
          'store': store,
          'distance_km': 0,
          'match_type': 'exact',
        });
      }

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
      await _db.collection('storeMembers').add({
        'storeId': int.parse(staff.group(1)!),
        'email': data['email'],
        'userUid': '',
        'userNumericId': 0,
        'inventory': data['can_inventory'] == true,
        'promotions': data['can_promotions'] == true,
        'location': data['can_location'] == true,
      });
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

    throw ApiException('Unsupported Firebase POST $path');
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
        if (data['lat'] != null) 'lat': data['lat'],
        if (data['lng'] != null) 'lng': data['lng'],
        if (data['landmark'] != null) 'landmark': data['landmark'],
        if (data['schedule'] != null) 'schedule': data['schedule'],
        if (data['is_mobile'] != null) 'is_mobile': data['is_mobile'],
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
      await doc.reference.update({
        if (data['price'] != null) 'price': data['price'],
        if (data['unit'] != null) 'unit': data['unit'],
        if (data['quantity'] != null) 'quantity': data['quantity'],
        if (data['availability'] != null) 'availability': data['availability'],
        if (data['status'] != null) 'status': data['status'],
        'last_confirmed_at': DateTime.now().toIso8601String(),
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
      final snap = await _db.collection('storeMembers').where('storeId', isEqualTo: storeId).get();
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
