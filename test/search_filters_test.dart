import 'package:flutter_test/flutter_test.dart';
import 'package:localspot/models.dart';
import 'package:localspot/state.dart';

void main() {
  test('availability and price filters constrain offline search results', () {
    final app = AppState();
    app.setAvailabilityFilter(Availability.inStock);
    app.updatePriceFilterDraft(min: '50', max: '100');
    app.applyPriceFilter();

    final results = app.searchListings('');
    expect(results, isNotEmpty);
    expect(
      results.every(
        (hit) =>
            hit.listing.availability == Availability.inStock &&
            hit.listing.price >= 50 &&
            hit.listing.price <= 100,
      ),
      isTrue,
    );
  });

  test('invalid price ranges preserve the last applied filters', () {
    final app = AppState();
    app.setAvailabilityFilter(Availability.inStock);
    app.updatePriceFilterDraft(min: '50', max: '100');
    app.applyPriceFilter();
    final before = app.searchListings('').map((hit) => hit.listing.id).toSet();

    app.updatePriceFilterDraft(min: '101', max: '20');
    app.applyPriceFilter();

    expect(app.priceFilterError, isNotEmpty);
    expect(app.searchListings('').map((hit) => hit.listing.id).toSet(), before);
  });

  test('clear search filters resets every filter and draft value', () {
    final app = AppState();
    app.setRadius(10);
    app.setTypeFilter(StoreType.hardware);
    app.setAvailabilityFilter(Availability.low);
    app.setCategoryFilter('Hardware');
    app.setSearchSort(SearchSort.price);
    app.updateSearchAttributeDraft(key: 'material', value: 'steel');
    app.updatePriceFilterDraft(min: '10', max: '50');
    app.applyPriceFilter();

    app.clearSearchFilters();

    expect(app.radiusKm, 3);
    expect(app.typeFilter, isNull);
    expect(app.availabilityFilter, isNull);
    expect(app.categoryFilter, isNull);
    expect(app.searchSort, SearchSort.relevance);
    expect(app.minPriceFilter, isNull);
    expect(app.maxPriceFilter, isNull);
    expect(app.minPriceDraft, isEmpty);
    expect(app.maxPriceDraft, isEmpty);
    expect(app.searchAttributeKey, isEmpty);
    expect(app.searchAttributeValue, isEmpty);
  });
}
