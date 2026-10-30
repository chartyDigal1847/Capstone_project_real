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
  testWidgets('shows LocalSpot welcome and customer home after demo login', (tester) async {
    await tester.pumpWidget(const LocalSpotRoot());
    expect(find.textContaining('Find it nearby'), findsOneWidget);

    await tester.tap(find.text('Sign in'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Maria Santos'));
    await tester.pumpAndSettle();

    expect(find.text('Home'), findsWidgets);
    expect(find.textContaining('Cubao'), findsWidgets);
    expect(find.text('BROWSE CATEGORIES'), findsNothing);
    expect(find.text('Food'), findsNothing);
    await tester.scrollUntilVisible(find.text('Stores near you'), 240, scrollable: find.byType(Scrollable).first);
    expect(find.text('Stores near you'), findsOneWidget);
    expect(find.textContaining('Sponsored'), findsWidgets);
    expect(find.textContaining("Aling Nena's Sari-Sari"), findsWidgets);

    await tester.ensureVisible(find.textContaining("Aling Nena's Sari-Sari").first);
    await tester.tap(find.textContaining("Aling Nena's Sari-Sari").first);
    await tester.pumpAndSettle();
    expect(find.text('Sold here'), findsOneWidget);
    expect(find.text('Preview route in LocalSpot'), findsOneWidget);
    expect(find.text('Directions in Google Maps'), findsNothing);
  });

  testWidgets('360 tour pans a viewpoint and walks connected nodes', (tester) async {
    final app = AppState();
    await tester.pumpWidget(AppScope(
      notifier: app,
      child: MaterialApp(
        home: Scaffold(body: TourViewerPage(tour: app.tours.first, onBack: () {})),
      ),
    ));
    expect(find.textContaining('Drag to look around this viewpoint'), findsOneWidget);
    await tester.tap(find.text('Grocery shelf'));
    await tester.pump();
    expect(find.text('Grocery shelf'), findsWidgets);
    expect(find.text('Counter'), findsOneWidget);
  });

  testWidgets('owner can scan a demo photo and confirm a listing', (tester) async {
    await tester.pumpWidget(const LocalSpotRoot());
    await tester.tap(find.text('Sign in'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Aling Nena'));
    await tester.pumpAndSettle();

    expect(find.textContaining('active listings'), findsOneWidget);

    await tester.tap(find.text('Scan'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Photo: mango'));
    await tester.pumpAndSettle();

    expect(find.textContaining('Owner confirmation required', skipOffstage: false), findsWidgets);
    expect(find.text('Encode manually instead', skipOffstage: false), findsOneWidget);
  });

  test('owner listings can be created without a barcode and archived', () {
    final app = AppState();
    app.currentUser = app.users.firstWhere((user) => user.email == 'nena@localspot.ph');
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
    expect(app.listingsForStore(store.id).where((row) => row.id == listing.id), isEmpty);
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

  test('offline catalog is labeled as bundled sample data', () {
    final app = AppState();
    expect(app.usingSeededCatalog, isTrue);
  });

  test('sponsored cards ignore expired promotions', () {
    final app = AppState();
    for (final promo in app.promotions) {
      promo.endsAt = DateTime.now().subtract(const Duration(days: 1));
    }
    expect(app.liveSponsored(), isEmpty);
  });

  test('visual search returns participating mango listings', () async {
    final app = AppState();
    final result = await app.visualSearch(hint: 'mango');
    expect(result.suggestions, isNotEmpty);
    expect(result.hits, isNotEmpty);
    expect(result.hits.first.product.name.toLowerCase(), contains('mango'));
    final multi = await app.visualSearch(hint: 'mango and oil');
    expect(multi.objects.length, 2);
    expect(multi.objects.map((object) => object.label), containsAll(['mango', 'oil']));
  });

  test('mobile vendor can update a public pin', () {
    final app = AppState();
    final store = app.stores.firstWhere((item) => item.isMobile);
    app.currentUser = app.users.firstWhere((user) => user.id == store.ownerId);
    app.updateStorePin(store, 14.6181, 121.0544);
    expect(store.lat, 14.6181);
  });

  test('only the owner can invite staff', () {
    final app = AppState();
    app.currentUser = app.users.firstWhere((user) => user.email == 'ana@localspot.ph');
    expect(app.inviteStaff(storeId: 1, email: 'maria@localspot.ph'), isNotNull);

    app.currentUser = app.users.firstWhere((user) => user.email == 'nena@localspot.ph');
    expect(app.inviteStaff(storeId: 1, email: 'maria@localspot.ph'), isNull);
    expect(app.staffForStore(1).map((user) => user.email), contains('maria@localspot.ph'));
  });

  testWidgets('map stays in-app without third-party Street View', (tester) async {
    await tester.pumpWidget(const LocalSpotRoot());
    await tester.tap(find.text('Sign in'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Maria Santos'));
    await tester.pumpAndSettle();
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

  test('catalog includes hardware, electronics and other lawful product types', () {
    final app = AppState();
    expect(app.stores.any((store) => store.type == StoreType.hardware), isTrue);
    expect(app.stores.any((store) => store.type == StoreType.electronics), isTrue);
    expect(productCategories, containsAll(['Hardware', 'Electronics', 'Clothing', 'Automotive']));
  });

  testWidgets('search keeps filters compact and still shows listings after a category pick', (tester) async {
    await tester.pumpWidget(const LocalSpotRoot());
    await tester.tap(find.text('Sign in'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Maria Santos'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Search'));
    await tester.pumpAndSettle();

    expect(find.text('BROWSE CATEGORIES'), findsNothing);
    expect(find.text('Product category'), findsOneWidget);
    expect(find.text('All products'), findsOneWidget);

    final app = AppScope.of(tester.element(find.byType(SearchPage)));
    app.apiOnline = false;
    app.remoteSearchHits = null;
    app.setCategoryFilter(familyFilterValue('food'));
    await tester.pumpAndSettle();

    expect(find.text('All Food'), findsOneWidget);
    expect(find.textContaining('participating listings'), findsOneWidget);
    expect(find.text('No participating seller listed this yet.'), findsNothing);
    await tester.scrollUntilVisible(find.textContaining('Carabao mango'), 400, scrollable: find.byType(Scrollable).last);
    expect(find.textContaining('Carabao mango'), findsWidgets);
  });

  test('family category filters include descendant products', () {
    final app = AppState();
    app.setCategoryFilter(familyFilterValue('food'));
    final food = app.searchListings('');
    expect(food, isNotEmpty);
    expect(food.every((hit) => categoriesMatchingFilter(familyFilterValue('food')).contains(hit.product.category)), isTrue);

    app.setCategoryFilter('Hardware');
    final hardware = app.searchListings('');
    expect(hardware.every((hit) => hit.product.category == 'Hardware'), isTrue);
    expect(hardware.any((hit) => hit.product.name.toLowerCase().contains('hammer')), isTrue);
  });

  test('search matches aliases and small typos, ranked by relevance then distance', () {
    final app = AppState();
    expect(app.searchListings('mangga'), isNotEmpty);
    expect(app.searchListings('mngo').first.product.name.toLowerCase(), contains('mango'));
    expect(app.searchListings('martilyo').first.product.name.toLowerCase(), contains('hammer'));
    expect(app.searchListings('usb c').first.product.category, 'Electronics');
    expect(app.searchListings('food near me').any((hit) => hit.product.category == 'Produce'), isTrue);
    expect(app.searchListings('tech').first.product.category, 'Electronics');
    expect(app.searchListings('hardware').any((hit) => hit.product.name.toLowerCase().contains('hammer')), isTrue);
    expect(app.searchListings('USB-C charger for Samsung').first.product.name, 'USB-C cable');
    expect(app.searchListings('USB-C charger for Samsung').first.matchType, SearchMatchType.semantic);
    expect(app.searchListings('4809990123456').first.matchType, SearchMatchType.identifier);
    app.setSearchSort(SearchSort.price);
    final priced = app.searchListings('');
    expect(priced.first.listing.price, lessThanOrEqualTo(priced.last.listing.price));
    expect(app.canLoadMoreSearch, isFalse);
  });

  test('unpublished tour nodes need privacy review before going live', () async {
    final app = AppState();
    app.currentUser = app.users.firstWhere((user) => user.email == 'nena@localspot.ph');
    final tour = app.addTour(1, 'Privacy tour');
    app.addTourNode(tour, 'Door', 'https://example.com/door.jpg');
    app.addTourNode(tour, 'Aisle', 'https://example.com/aisle.jpg');
    expect(tour.nodes.first.image, isEmpty);
    expect(tour.nodes.first.originalRetained, isTrue);
    expect(app.publishTour(tour), isNotNull);
    await app.processTourNode(tour, tour.nodes.first, fail: true);
    expect(tour.nodes.first.privacyStatus, PrivacyStatus.failed);
    expect(tour.nodes.first.image, isEmpty);
    expect(app.publishTour(tour), isNotNull);
    for (final node in tour.nodes) {
      await app.processTourNode(tour, node);
    }
    expect(tour.nodes.first.image, isNot(contains('example.com')));
    expect(tour.nodes.first.image, contains('sanitized.jpg'));
    app.addManualTourBlur(tour, tour.nodes.first);
    expect(tour.nodes.first.manualBlur, isTrue);
    expect(tour.nodes.first.blurRegions, isNotEmpty);
    for (final node in tour.nodes) {
      expect(app.reviewTourNode(tour, node), isNull);
    }
    expect(app.publishTour(tour), isNull);
    expect(tour.status, TourStatus.published);
  });

  test('foreground location is held only while a map or navigation screen retains it', () {
    final app = AppState();
    expect(app.isWatchingLocation, isFalse);
    app.locationAllowed = true;
    app.retainForegroundLocation();
    expect(app.isWatchingLocation, isTrue);
    app.releaseForegroundLocation();
    expect(app.isWatchingLocation, isFalse);
  });

  test('route preview and vendor live session stay on-device without an API', () async {
    final app = AppState();
    final store = app.stores.firstWhere((item) => item.isMobile);
    app.currentUser = app.users.firstWhere((user) => user.id == store.ownerId);
    final route = await app.previewRoute(destLat: store.lat, destLng: store.lng);
    expect(route.coordinates, isNotEmpty);
    expect(route.fallback, isTrue);

    await app.startVendorSession(store, lat: 14.6201, lng: 121.0572);
    expect(app.sessionFor(store)?.isActive, isTrue);
    expect(store.locationMode, LocationMode.live);
    app.applyDevicePositionForTest(14.6225, 121.0595);
    expect(store.lat, closeTo(14.6225, 0.0001));
    await app.stopVendorSession(store);
    expect(store.locationMode, LocationMode.regular);
  });

  test('only the owner can start a live vendor location session', () async {
    final app = AppState();
    final store = app.stores.firstWhere((item) => item.isMobile);
    app.currentUser = app.users.firstWhere((user) => user.email == 'maria@localspot.ph');
    await app.startVendorSession(store, lat: 14.6201, lng: 121.0572);
    expect(app.sessionFor(store)?.isActive, isNot(true));

    app.currentUser = app.users.firstWhere((user) => user.id == store.ownerId);
    await app.startVendorSession(store, lat: 14.6201, lng: 121.0572);
    expect(app.sessionFor(store)?.isActive, isTrue);
  });

  test('staff grants gate inventory promotions and live location', () async {
    final app = AppState();
    final store = app.stores.firstWhere((item) => item.id == 1);
    final mobile = app.stores.firstWhere((item) => item.isMobile);
    final nena = app.users.firstWhere((user) => user.email == 'nena@localspot.ph');
    final ana = app.users.firstWhere((user) => user.email == 'ana@localspot.ph');
    final maria = app.users.firstWhere((user) => user.email == 'maria@localspot.ph');

    app.currentUser = ana;
    expect(app.canEditInventory(store), isTrue);
    expect(app.canManagePromotions(store), isFalse);
    expect(app.canShareLiveLocation(mobile), isFalse);

    app.currentUser = nena;
    expect(app.inviteStaff(storeId: 1, email: 'maria@localspot.ph', inventory: false, promotions: true, location: false), isNull);
    app.currentUser = app.users.firstWhere((user) => user.id == mobile.ownerId);
    expect(app.inviteStaff(storeId: mobile.id, email: 'maria@localspot.ph', inventory: false, location: true), isNull);

    app.currentUser = maria;
    expect(app.canEditInventory(store), isFalse);
    expect(app.canManagePromotions(store), isTrue);
    expect(app.canShareLiveLocation(mobile), isTrue);
    await app.startVendorSession(mobile, lat: 14.6201, lng: 121.0572);
    expect(app.sessionFor(mobile)?.isActive, isTrue);
  });
}
