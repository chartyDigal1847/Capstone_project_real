import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localspot/api.dart';
import 'package:localspot/main.dart';
import 'package:localspot/models.dart';
import 'package:localspot/screens/customer_screens.dart';
import 'package:localspot/screens/detail_screens.dart';
import 'package:localspot/state.dart';
import 'package:localspot/widgets.dart';

void main() {
  testWidgets(
    'sign-in offers demo credentials without bundling user profiles',
    (tester) async {
      await tester.pumpWidget(const LocalSpotRoot());
      expect(find.textContaining('Find it nearby'), findsOneWidget);

      await tester.tap(find.text('Sign in'));
      await tester.pumpAndSettle();

      final demoEmailLabels = find.byWidgetPredicate(
        (widget) =>
            widget is Text &&
            const {
              'maria@localspot.ph',
              'nena@localspot.ph',
              'tonyo@localspot.ph',
              'ana@localspot.ph',
              'admin@localspot.ph',
              'lito@localspot.ph',
              'bea@localspot.ph',
            }.contains(widget.data),
      );
      expect(demoEmailLabels, findsNWidgets(7));
      expect(
        find.textContaining('profile and role load from the database'),
        findsNWidgets(7),
      );
    },
  );

  testWidgets('360 tour pans a viewpoint and walks connected nodes', (
    tester,
  ) async {
    final app = _testState();
    await tester.pumpWidget(
      AppScope(
        notifier: app,
        child: MaterialApp(
          home: Scaffold(
            body: TourViewerPage(tour: app.tours.first, onBack: () {}),
          ),
        ),
      ),
    );
    expect(
      find.textContaining('Drag to look around this viewpoint'),
      findsOneWidget,
    );
    await tester.tap(find.text('Grocery shelf'));
    await tester.pump();
    expect(find.text('Grocery shelf'), findsWidgets);
    expect(find.text('Counter'), findsOneWidget);
  });

  test(
    'recognition does not substitute local sample results when offline',
    () async {
      final app = AppState();
      final result = await app.visualSearch(hint: 'mango');
      expect(result.suggestions, isEmpty);
      expect(result.hits, isEmpty);
      expect(result.uncertain, isTrue);
      expect(await app.suggestFromCapture(hint: 'mango'), isEmpty);
    },
  );

  test('owner listings can be created without a barcode and archived', () {
    final app = _testState(role: AppRole.owner);
    final store = app.ownedStore()!;
    final listing = app.addListing(
      storeId: store.id,
      name: 'White sugar',
      category: 'Staples',
      price: 68,
      unit: 'kilo',
      quantity: 9,
      availability: Availability.inStock,
    );
    expect(app.productById(listing.productId)!.name, 'White sugar');
    expect(app.productById(listing.productId)!.barcode, isNull);
    expect(app.stockChanges[listing.id], isNotEmpty);
    app.archiveListing(listing);
    expect(
      app.listingsForStore(store.id).where((row) => row.id == listing.id),
      isEmpty,
    );
  });

  test('API validation errors map onto named fields', () {
    final error = ApiException.fromResponse(422, {
      'message': 'The email has already been taken.',
      'errors': {
        'email': ['The email has already been taken.'],
        'name': ['The name field is required.'],
      },
    });
    expect(error.field('email'), contains('taken'));
    expect(error.field('name'), contains('required'));
    expect(error.field('password'), isNull);
  });

  test('business catalog starts empty until live data is loaded', () {
    final app = AppState();
    expect(app.usingSeededCatalog, isFalse);
    expect(app.stores, isEmpty);
    expect(app.products, isEmpty);
    expect(app.listings, isEmpty);
  });

  test('sponsored cards ignore expired promotions', () {
    final app = _testState();
    for (final promo in app.promotions) {
      promo.endsAt = DateTime.now().subtract(const Duration(days: 1));
    }
    expect(app.liveSponsored(), isEmpty);
  });

  test('mobile vendor can update a public pin', () {
    final app = _testState(role: AppRole.owner);
    final store = app.stores.firstWhere((item) => item.isMobile);
    app.currentUser = app.users.firstWhere((user) => user.id == store.ownerId);
    app.updateStorePin(store, 14.6181, 121.0544);
    expect(store.lat, 14.6181);
  });

  test('only the owner can invite staff', () {
    final app = _testState();
    app.currentUser = app.users.firstWhere(
      (user) => user.email == 'ana@localspot.ph',
    );
    expect(app.inviteStaff(storeId: 1, email: 'maria@localspot.ph'), isNotNull);

    app.currentUser = app.users.firstWhere(
      (user) => user.email == 'nena@localspot.ph',
    );
    expect(app.inviteStaff(storeId: 1, email: 'maria@localspot.ph'), isNull);
    expect(
      app.staffForStore(1).map((user) => user.email),
      contains('maria@localspot.ph'),
    );
  });

  testWidgets('map stays in-app without third-party Street View', (
    tester,
  ) async {
    final app = _testState();
    await _pumpSignedInApp(tester, app);
    await tester.tap(find.text('Map'));
    await tester.pumpAndSettle();

    expect(find.textContaining('in-app map'), findsWidgets);
    expect(find.text('Follow me'), findsNothing);
    expect(find.text('Street View'), findsNothing);
    expect(find.textContaining('Mapillary'), findsNothing);
    expect(find.text('3D Explore'), findsNothing);
    expect(find.text('All types'), findsOneWidget);
    expect(find.byTooltip('Recenter'), findsOneWidget);
  });

  test(
    'catalog includes hardware, electronics and other lawful product types',
    () {
      final app = _testState();
      expect(
        app.stores.any((store) => store.type == StoreType.hardware),
        isTrue,
      );
      expect(
        app.stores.any((store) => store.type == StoreType.electronics),
        isTrue,
      );
      expect(
        productCategories,
        containsAll(['Hardware', 'Electronics', 'Clothing', 'Automotive']),
      );
    },
  );

  testWidgets(
    'search keeps filters compact and still shows listings after a category pick',
    (tester) async {
      final state = _testState();
      await _pumpSignedInApp(tester, state);
      await tester.tap(find.text('Search'));
      await tester.pumpAndSettle();

      expect(find.text('BROWSE CATEGORIES'), findsNothing);
      expect(find.text('CATEGORY'), findsOneWidget);
      expect(find.text('All products'), findsOneWidget);

      final app = AppScope.of(tester.element(find.byType(SearchPage)));
      app.apiOnline = false;
      app.remoteSearchHits = null;
      app.setCategoryFilter(familyFilterValue('food'));
      await tester.pumpAndSettle();

      expect(find.text('All Food'), findsOneWidget);
      expect(find.textContaining('participating listings'), findsOneWidget);
      expect(
        find.textContaining('No participating seller listed this yet.'),
        findsOneWidget,
      );
    },
  );

  test('family category filters include descendant products', () {
    final app = _testState();
    app.setCategoryFilter(familyFilterValue('food'));
    final food = app.searchListings('');
    expect(food, isNotEmpty);
    expect(
      food.every(
        (hit) => categoriesMatchingFilter(
          familyFilterValue('food'),
        ).contains(hit.product.category),
      ),
      isTrue,
    );

    app.setCategoryFilter('Hardware');
    final hardware = app.searchListings('');
    expect(hardware.every((hit) => hit.product.category == 'Hardware'), isTrue);
    expect(
      hardware.any((hit) => hit.product.name.toLowerCase().contains('hammer')),
      isTrue,
    );
  });

  test(
    'search matches aliases and small typos, ranked by relevance then distance',
    () {
      final app = _testState();
      expect(app.searchListings('mangga'), isNotEmpty);
      expect(
        app.searchListings('mngo').first.product.name.toLowerCase(),
        contains('mango'),
      );
      expect(
        app.searchListings('martilyo').first.product.name.toLowerCase(),
        contains('hammer'),
      );
      expect(app.searchListings('usb c').first.product.category, 'Electronics');
      expect(
        app
            .searchListings('food near me')
            .any((hit) => hit.product.category == 'Produce'),
        isTrue,
      );
      expect(app.searchListings('tech').first.product.category, 'Electronics');
      expect(
        app
            .searchListings('hardware')
            .any((hit) => hit.product.name.toLowerCase().contains('hammer')),
        isTrue,
      );
      expect(
        app.searchListings('USB-C charger for Samsung').first.product.name,
        'USB-C cable',
      );
      expect(
        app.searchListings('USB-C charger for Samsung').first.matchType,
        SearchMatchType.semantic,
      );
      expect(
        app.searchListings('4809990123456').first.matchType,
        SearchMatchType.identifier,
      );
      app.setSearchSort(SearchSort.price);
      final priced = app.searchListings('');
      expect(
        priced.first.listing.price,
        lessThanOrEqualTo(priced.last.listing.price),
      );
      expect(app.canLoadMoreSearch, isFalse);
    },
  );

  test(
    'tour nodes stay unpublished until server privacy processing completes',
    () async {
      final app = _testState();
      app.currentUser = UserAccount(
        id: 2,
        name: 'Store owner',
        email: 'owner@test.local',
        password: '',
        role: AppRole.owner,
        ownedStoreIds: const [1],
      );
      final tour = app.addTour(1, 'Privacy tour');
      app.addTourNode(tour, 'Door', 1001);
      app.addTourNode(tour, 'Aisle', 1002);
      expect(tour.nodes.first.image, isEmpty);
      expect(tour.nodes.first.originalRetained, isTrue);
      expect(tour.nodes.first.privacyStatus, PrivacyStatus.processing);
      expect(await app.publishTour(tour), isNotNull);
      expect(tour.status, TourStatus.draft);
    },
  );

  test(
    'foreground location is held only while a map or navigation screen retains it',
    () {
      final app = _testState();
      expect(app.isWatchingLocation, isFalse);
      app.locationAllowed = true;
      app.retainForegroundLocation();
      expect(app.isWatchingLocation, isTrue);
      app.releaseForegroundLocation();
      expect(app.isWatchingLocation, isFalse);
    },
  );

  test(
    'route preview fallback is available while vendor locations require a live API',
    () async {
      final app = _testState();
      final store = app.stores.firstWhere((item) => item.isMobile);
      app.currentUser = app.users.firstWhere(
        (user) => user.id == store.ownerId,
      );
      final route = await app.previewRoute(
        destLat: store.lat,
        destLng: store.lng,
      );
      expect(route.coordinates, isNotEmpty);
      expect(route.fallback, isTrue);

      expect(app.sessionFor(store), isNull);
    },
  );

  test('only the owner can start a live vendor location session', () async {
    final app = _testState();
    final store = app.stores.firstWhere((item) => item.isMobile);
    app.currentUser = app.users.firstWhere(
      (user) => user.email == 'maria@localspot.ph',
    );
    await app.startVendorSession(store, lat: 14.6201, lng: 121.0572);
    expect(app.sessionFor(store)?.isActive, isNot(true));

    app.currentUser = app.users.firstWhere((user) => user.id == store.ownerId);
    await app.startVendorSession(store, lat: 14.6201, lng: 121.0572);
    expect(app.sessionFor(store)?.isActive, isTrue);
  });

  test('staff grants gate inventory promotions and live location', () async {
    final app = _testState();
    final store = app.stores.firstWhere((item) => item.id == 1);
    final mobile = app.stores.firstWhere((item) => item.isMobile);
    final nena = app.users.firstWhere(
      (user) => user.email == 'nena@localspot.ph',
    );
    final ana = app.users.firstWhere(
      (user) => user.email == 'ana@localspot.ph',
    );
    final maria = app.users.firstWhere(
      (user) => user.email == 'maria@localspot.ph',
    );

    app.currentUser = ana;
    expect(app.canEditInventory(store), isTrue);
    expect(app.canManagePromotions(store), isFalse);
    expect(app.canShareLiveLocation(mobile), isFalse);

    app.currentUser = nena;
    expect(
      app.inviteStaff(
        storeId: 1,
        email: 'maria@localspot.ph',
        inventory: false,
        promotions: true,
        location: false,
      ),
      isNull,
    );
    app.currentUser = app.users.firstWhere((user) => user.id == mobile.ownerId);
    expect(
      app.inviteStaff(
        storeId: mobile.id,
        email: 'maria@localspot.ph',
        inventory: false,
        location: true,
      ),
      isNull,
    );

    app.currentUser = maria;
    expect(app.canEditInventory(store), isFalse);
    expect(app.canManagePromotions(store), isTrue);
    expect(app.canShareLiveLocation(mobile), isTrue);
    await app.startVendorSession(mobile, lat: 14.6201, lng: 121.0572);
    expect(app.sessionFor(mobile)?.isActive, isTrue);
  });
}

// These fixtures model API responses only in tests. Production AppState starts
// empty and loads its business records from Laravel/Firestore.
AppState _testState({AppRole role = AppRole.customer}) {
  final app = AppState();
  final users = <UserAccount>[
    UserAccount(
      id: 1,
      name: 'Maria Santos',
      email: 'maria@localspot.ph',
      password: '',
      role: AppRole.customer,
    ),
    UserAccount(
      id: 2,
      name: 'Aling Nena',
      email: 'nena@localspot.ph',
      password: '',
      role: AppRole.owner,
      ownedStoreIds: const [1],
    ),
    UserAccount(
      id: 3,
      name: 'Mang Tonyo',
      email: 'tonyo@localspot.ph',
      password: '',
      role: AppRole.owner,
      ownedStoreIds: const [4],
    ),
    UserAccount(
      id: 4,
      name: 'Ana Cruz',
      email: 'ana@localspot.ph',
      password: '',
      role: AppRole.staff,
      memberStoreIds: const [1],
      storeGrants: {1: StoreGrant(inventory: true)},
    ),
    UserAccount(
      id: 5,
      name: 'Admin Reyes',
      email: 'admin@localspot.ph',
      password: '',
      role: AppRole.admin,
    ),
    UserAccount(
      id: 6,
      name: 'Lito Mercado',
      email: 'lito@localspot.ph',
      password: '',
      role: AppRole.owner,
      ownedStoreIds: const [6],
    ),
    UserAccount(
      id: 7,
      name: 'Bea Tan',
      email: 'bea@localspot.ph',
      password: '',
      role: AppRole.owner,
      ownedStoreIds: const [7],
    ),
  ];
  app.users.addAll(users);
  app.currentUser = users.firstWhere((user) => user.role == role);

  app.stores.addAll([
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
      landmark: 'Beside the waiting shed',
      schedule: 'Daily 6:00 AM – 10:00 PM',
      isMobile: false,
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
      landmark: 'Near the barangay hall',
      schedule: 'Mon–Sat mornings',
      isMobile: true,
      locationMode: LocationMode.regular,
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
      landmark: 'Beside the pawnshop',
      schedule: 'Mon–Sat 7:30 AM – 7:00 PM',
      isMobile: false,
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
      address: 'Farmermarket annex',
      landmark: 'Phone repair alley',
      schedule: 'Daily 10:00 AM – 8:00 PM',
      isMobile: false,
    ),
  ]);

  final products = <CatalogProduct>[
    CatalogProduct(
      id: 1,
      name: 'Carabao mango',
      category: 'Produce',
      brand: '',
      packageSize: 'per kilo',
      aliases: ['mangga', 'indian mango', 'mango'],
      image: '',
    ),
    CatalogProduct(
      id: 2,
      name: 'Cooking oil',
      category: 'Groceries',
      brand: 'Minola',
      packageSize: '1 L bottle',
      aliases: ['mantika', 'vegetable oil'],
      barcode: '4807770123456',
      image: '',
    ),
    CatalogProduct(
      id: 3,
      name: 'Well-milled rice',
      category: 'Staples',
      brand: '',
      packageSize: 'per kilo',
      aliases: ['bigas', 'rice'],
      image: '',
    ),
    CatalogProduct(
      id: 4,
      name: 'Pan de sal',
      category: 'Bakery',
      brand: '',
      packageSize: 'per piece',
      aliases: ['pandesal', 'bread'],
      image: '',
    ),
    CatalogProduct(
      id: 5,
      name: 'Lakatan banana',
      category: 'Produce',
      brand: '',
      packageSize: 'per kilo',
      aliases: ['saging', 'banana'],
      image: '',
    ),
    CatalogProduct(
      id: 6,
      name: 'Canned sardines',
      category: 'Groceries',
      brand: "Young's Town",
      packageSize: '155 g can',
      aliases: ['sardinas', 'sardines'],
      image: '',
    ),
    CatalogProduct(
      id: 7,
      name: 'Taho',
      category: 'Street food',
      brand: '',
      packageSize: 'per cup',
      aliases: ['soy pudding'],
      image: '',
    ),
    CatalogProduct(
      id: 8,
      name: 'Instant noodles',
      category: 'Groceries',
      brand: 'Lucky Me',
      packageSize: '55 g pack',
      aliases: ['pancit canton', 'noodles'],
      image: '',
    ),
    CatalogProduct(
      id: 9,
      name: 'Claw hammer',
      category: 'Hardware',
      brand: 'Stanley',
      packageSize: '16 oz',
      aliases: ['martilyo', 'hammer'],
      image: '',
    ),
    CatalogProduct(
      id: 10,
      name: 'USB-C cable',
      category: 'Electronics',
      brand: 'Anker',
      packageSize: '1 m',
      aliases: ['type c cable', 'charger cable', 'usb c'],
      barcode: '4809990123456',
      image: '',
      attributes: const {'compatibility': 'USB-C Samsung Type-C phones'},
    ),
    CatalogProduct(
      id: 11,
      name: 'Rubber slippers',
      category: 'Clothing',
      brand: 'Havaianas',
      packageSize: 'pair',
      aliases: ['tsinelas', 'slippers'],
      image: '',
    ),
  ];
  app.products.addAll(products);
  final now = DateTime.now();
  const storeForProduct = <int, int>{
    1: 1,
    2: 1,
    3: 1,
    4: 1,
    5: 1,
    6: 1,
    7: 4,
    8: 1,
    9: 6,
    10: 7,
    11: 1,
  };
  app.listings.addAll([
    for (var i = 0; i < products.length; i++)
      StoreListing(
        id: i + 1,
        storeId: storeForProduct[products[i].id]!,
        productId: products[i].id,
        price: 20 + i.toDouble(),
        unit: 'piece',
        quantity: 10 + i,
        availability: Availability.inStock,
        lastConfirmed: now.subtract(Duration(minutes: i * 5)),
      ),
  ]);
  app.promotions.addAll([
    Promotion(
      id: 1,
      storeId: 1,
      title: 'Mango weekend',
      offer: 'Fresh produce',
      startsAt: now.subtract(const Duration(days: 1)),
      endsAt: now.add(const Duration(days: 1)),
      sponsored: true,
      status: PromotionStatus.approved,
    ),
    Promotion(
      id: 2,
      storeId: 1,
      title: 'Expired offer',
      offer: 'Old',
      startsAt: now.subtract(const Duration(days: 5)),
      endsAt: now.subtract(const Duration(days: 1)),
      sponsored: true,
      status: PromotionStatus.approved,
    ),
  ]);
  app.tours.add(
    StoreTour(
      id: 1,
      storeId: 1,
      title: 'Market tour',
      status: TourStatus.published,
      nodes: [
        TourNode(
          id: 1,
          title: 'Grocery shelf',
          image: '',
          connections: [2],
          ownerReviewed: true,
        ),
        TourNode(
          id: 2,
          title: 'Counter',
          image: '',
          connections: [1],
          ownerReviewed: true,
        ),
      ],
    ),
  );
  return app;
}

Future<void> _pumpSignedInApp(WidgetTester tester, AppState app) async {
  await tester.pumpWidget(
    AppScope(notifier: app, child: const MaterialApp(home: LocalSpotShell())),
  );
  await tester.pumpAndSettle();
}
