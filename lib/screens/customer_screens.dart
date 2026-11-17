import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:geolocator/geolocator.dart';

import '../map_view.dart';
import '../models.dart';
import '../services/mapbox_location_search.dart';
import '../state.dart';
import '../theme.dart';
import '../widgets.dart';

class HomePage extends StatelessWidget {
  const HomePage({
    super.key,
    required this.onSearch,
    required this.onMap,
    required this.onStore,
    required this.onLocation,
    required this.onCameraSearch,
    required this.onSaved,
  });

  final VoidCallback onSearch;
  final VoidCallback onMap;
  final ValueChanged<Store> onStore;
  final VoidCallback onLocation;
  final VoidCallback onCameraSearch;
  final VoidCallback onSaved;

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final sponsored = app.liveSponsored();
    final stores = app.nearbyStores();
    final hot = app.hotStores().take(8).toList();

    return ListView(
      padding: const EdgeInsets.only(bottom: 28),
      children: [
        PageHeader(
          'Home',
          subtitle: app.searchAreaLabel,
          onSubtitleTap: onLocation,
          trailing: IconButton(
            onPressed: onSaved,
            tooltip: 'Saved',
            icon: const Icon(Icons.favorite_border, color: charcoal),
          ),
        ),
        const SeededDataBanner(),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 6),
          child: InkWell(
            onTap: onSearch,
            borderRadius: BorderRadius.circular(28),
            child: Container(
              height: 48,
              padding: const EdgeInsets.only(left: 16, right: 6),
              decoration: BoxDecoration(
                color: paper,
                borderRadius: BorderRadius.circular(28),
                border: Border.all(color: line),
              ),
              child: Row(
                children: [
                  const Icon(Icons.search, color: taupe),
                  const SizedBox(width: 10),
                  const Expanded(
                    child: Text(
                      'Search products, brands, aliases…',
                      style: TextStyle(color: Color(0xFF99938A), fontSize: 13),
                    ),
                  ),
                  IconButton(
                    onPressed: onCameraSearch,
                    icon: const Icon(
                      Icons.photo_camera_outlined,
                      color: leafDark,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
        // ── Category browse chips ─────────────────────────────────
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 6, 0, 0),
          child: SizedBox(
            height: 36,
            child: ListView(
              scrollDirection: Axis.horizontal,
              children: [
                for (final family in browseFamilies)
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: ActionChip(
                      label: Text(family.$1),
                      onPressed: () {
                        AppScope.of(context)
                          ..setCategoryFilter(familyFilterValue(family.$2))
                          ..applySearchDraft(family.$1);
                        onSearch();
                      },
                      backgroundColor: paper,
                      side: const BorderSide(color: line),
                      labelStyle: const TextStyle(
                        fontSize: 12,
                        color: charcoal,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
        if (sponsored.isNotEmpty || hot.isNotEmpty) ...[
          const SizedBox(height: 8),
          SectionHeading('Hot & sponsored', onTap: onMap, action: 'Open map'),
          SizedBox(
            height: 168,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 20),
              itemCount: (sponsored.isNotEmpty ? sponsored.length : hot.length),
              separatorBuilder: (_, __) => const SizedBox(width: 12),
              itemBuilder: (_, index) {
                if (sponsored.isNotEmpty) {
                  final promo = sponsored[index];
                  final store = app.storeById(promo.storeId);
                  if (store == null) return const SizedBox.shrink();
                  return SizedBox(
                    width: 220,
                    child: Stack(
                      children: [
                        StoreImageCard(
                          store: store,
                          distanceKm: app.distanceKm(
                            app.searchLat,
                            app.searchLng,
                            store.lat,
                            store.lng,
                          ),
                          badge: 'Sponsored',
                          width: 220,
                          height: 168,
                          onTap: () => onStore(store),
                        ),
                        Positioned(
                          left: 12,
                          right: 12,
                          top: 40,
                          child: Text(
                            promo.offer,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: paper,
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ],
                    ),
                  );
                }
                final store = hot[index];
                return StoreImageCard(
                  store: store,
                  distanceKm: app.distanceKm(
                    app.searchLat,
                    app.searchLng,
                    store.lat,
                    store.lng,
                  ),
                  badge: 'Popular',
                  onTap: () => onStore(store),
                );
              },
            ),
          ),
        ],
        const SizedBox(height: 10),
        SectionHeading('Stores near you', onTap: onMap, action: 'Open map'),
        if (stores.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 20),
            child: EmptyNote(
              'No participating stores in this area yet. Widen the radius in Search.',
            ),
          )
        else
          SizedBox(
            height: 188,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 20),
              itemCount: stores.length,
              separatorBuilder: (_, __) => const SizedBox(width: 12),
              itemBuilder: (_, index) {
                final store = stores[index];
                return StoreImageCard(
                  store: store,
                  distanceKm: app.distanceKm(
                    app.searchLat,
                    app.searchLng,
                    store.lat,
                    store.lng,
                  ),
                  onTap: () => onStore(store),
                );
              },
            ),
          ),
        const SizedBox(height: 18),
        const SectionHeading('Suggested from nearby stores'),
        ...stores.map((store) {
          final picks = app.listingsForStore(store.id).take(2).toList();
          if (picks.isEmpty) return const SizedBox.shrink();
          return Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 14),
            child: SoftCard(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  InkWell(
                    onTap: () => onStore(store),
                    child: Row(
                      children: [
                        NetworkPhoto(
                          store.image,
                          width: 40,
                          height: 40,
                          radius: 10,
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                store.name,
                                style: const TextStyle(
                                  fontWeight: FontWeight.w700,
                                  fontSize: 14,
                                ),
                              ),
                              Text(
                                '${store.type.label} · ${app.distanceKm(app.searchLat, app.searchLng, store.lat, store.lng).toStringAsFixed(1)} km',
                                style: const TextStyle(
                                  color: taupe,
                                  fontSize: 11,
                                ),
                              ),
                            ],
                          ),
                        ),
                        const Icon(Icons.chevron_right, color: taupe),
                      ],
                    ),
                  ),
                  const SizedBox(height: 10),
                  ...picks.map((listing) {
                    final product = app.productById(listing.productId);
                    if (product == null) return const SizedBox.shrink();
                    return Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: InkWell(
                        onTap: () => onStore(store),
                        child: Row(
                          children: [
                            NetworkPhoto(
                              product.image,
                              width: 52,
                              height: 52,
                              radius: 10,
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    product.name,
                                    style: const TextStyle(
                                      fontWeight: FontWeight.w600,
                                      fontSize: 13,
                                    ),
                                  ),
                                  Text(
                                    '${peso(listing.price)} / ${listing.unit} · ${availabilityLabel(listing.availability)}',
                                    style: const TextStyle(
                                      color: taupe,
                                      fontSize: 11,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                    );
                  }),
                ],
              ),
            ),
          );
        }),
      ],
    );
  }
}

class SearchPage extends StatefulWidget {
  const SearchPage({
    super.key,
    required this.onProduct,
    required this.onStore,
    this.initialQuery = '',
  });
  final ValueChanged<CatalogProduct> onProduct;
  final ValueChanged<Store> onStore;
  final String initialQuery;

  @override
  State<SearchPage> createState() => _SearchPageState();
}

class _SearchPageState extends State<SearchPage> {
  late final controller = TextEditingController(text: widget.initialQuery);
  Timer? _debounce;
  String activeQuery = '';
  var _started = false;
  AppState? _app;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final app = AppScope.of(context);
    _app = app;
    if (app.searchDraft.isNotEmpty) {
      controller.text = app.searchDraft;
      activeQuery = app.searchDraft;
      app.searchDraft = '';
    }
    if (_started) return;
    _started = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      unawaited(
        AppScope.of(
          context,
        ).fetchSearch(activeQuery.isEmpty ? controller.text : activeQuery),
      );
    });
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _app?.cancelSearch();
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final query = activeQuery.isEmpty ? controller.text : activeQuery;
    final hits = app.remoteSearchHits ?? app.searchListings(query);
    final distanceLabel =
        app.searchLat != 0 || app.searchLng != 0
            ? ' within ${app.radiusKm.toStringAsFixed(0)} km'
            : '';
    final countLabel =
        app.searchResultsTruncated
            ? 'At least ${app.searchTotal} matching listings$distanceLabel'
            : app.searchTotal > 0
            ? '${hits.length} of ${app.searchTotal} participating listings$distanceLabel'
            : '${hits.length} participating listings$distanceLabel';

    final controls = <Widget>[
      const PageHeader('Search products'),
      if (app.searchBusy)
        const LinearProgressIndicator(minHeight: 2, color: leaf),
      if (app.searchNote.isNotEmpty)
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 4),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  app.searchNote,
                  style: const TextStyle(color: taupe, fontSize: 12),
                ),
              ),
              TextButton(
                onPressed: () => app.fetchSearch(query),
                child: const Text('Retry'),
              ),
            ],
          ),
        ),
      Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
        child: TextField(
          controller: controller,
          onChanged: (value) {
            setState(() {});
            _debounce?.cancel();
            _debounce = Timer(const Duration(milliseconds: 280), () {
              if (!mounted) return;
              setState(() => activeQuery = value);
              AppScope.of(context).fetchSearch(value);
            });
          },
          onSubmitted: (value) {
            setState(() => activeQuery = value);
            app.fetchSearch(value);
          },
          textInputAction: TextInputAction.search,
          decoration: InputDecoration(
            hintText: 'Name, brand, category, or local term',
            prefixIcon: const Icon(Icons.search, color: taupe),
            suffixIcon:
                controller.text.isEmpty
                    ? null
                    : IconButton(
                      tooltip: 'Clear',
                      onPressed: () {
                        controller.clear();
                        setState(() => activeQuery = '');
                        app.fetchSearch('');
                      },
                      icon: const Icon(Icons.close, size: 18),
                    ),
          ),
        ),
      ),
      if (query.trim().isNotEmpty || app.aiSearchNote.isNotEmpty)
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
          child: Row(
            children: [
              if (app.aiSearchInterpreting)
                const SizedBox.square(
                  dimension: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              else if (app.aiSearchNote.isNotEmpty)
                Expanded(
                  child: Text(
                    app.aiSearchNote,
                    style: const TextStyle(color: taupe, fontSize: 11),
                  ),
                )
              else
                const Spacer(),
              TextButton.icon(
                onPressed:
                    app.aiSearchInterpreting
                        ? null
                        : app.hasSearchIntent
                        ? app.clearSearchIntent
                        : () {
                          setState(() => activeQuery = query);
                          unawaited(app.interpretSearchIntent(query));
                        },
                icon: Icon(
                  app.hasSearchIntent
                      ? Icons.filter_alt_off
                      : Icons.auto_awesome,
                  size: 17,
                ),
                label: Text(
                  app.hasSearchIntent
                      ? 'Clear AI filters'
                      : 'Interpret with AI',
                ),
              ),
            ],
          ),
        ),
      const CatalogFilters(),
      Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
        child: Text(
          countLabel,
          style: const TextStyle(
            color: taupe,
            fontSize: 12,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    ];

    if (hits.isEmpty) {
      return CustomScrollView(
        slivers: [
          SliverToBoxAdapter(child: Column(children: controls)),
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 40),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const EmptyNote(
                    'No participating seller listed this yet.\nTry another name, a parent category, or a wider radius.',
                    icon: Icons.search_off,
                  ),
                  const SizedBox(height: 12),
                  OutlinedButton(
                    onPressed: () => app.setRadius(10),
                    child: const Text('Widen to 10 km'),
                  ),
                  const SizedBox(height: 8),
                  OutlinedButton(
                    onPressed: app.clearSearchFilters,
                    child: const Text('Clear filters'),
                  ),
                  const SizedBox(height: 8),
                  TextButton(
                    onPressed: () {
                      app.clearSearchFilters();
                      controller.clear();
                      setState(() => activeQuery = '');
                      app.fetchSearch('');
                    },
                    child: const Text('Clear search and filters'),
                  ),
                ],
              ),
            ),
          ),
        ],
      );
    }

    return CustomScrollView(
      slivers: [
        SliverToBoxAdapter(child: Column(children: controls)),
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 0),
          sliver: SliverList(
            delegate: SliverChildBuilderDelegate((context, index) {
              final hit = hits[index];
              return Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: SoftCard(
                  onTap: () => widget.onProduct(hit.product),
                  child: Row(
                    children: [
                      NetworkPhoto(hit.product.image, width: 70, height: 70),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              hit.product.name,
                              style: const TextStyle(
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            const SizedBox(height: 4),
                            StatusChip(
                              matchTypeLabel(hit.matchType),
                              color:
                                  hit.matchType == SearchMatchType.exact
                                      ? leaf
                                      : champagne,
                            ),
                            Text(
                              hit.store.name,
                              style: const TextStyle(
                                color: taupe,
                                fontSize: 11,
                              ),
                            ),
                            Text(
                              '${peso(hit.listing.price)} / ${hit.listing.unit} · ${hit.distanceKm.toStringAsFixed(1)} km',
                              style: const TextStyle(fontSize: 12),
                            ),
                            Text(
                              '${availabilityLabel(hit.listing.availability)} · ${freshness(hit.listing.lastConfirmed)}',
                              style: const TextStyle(
                                fontSize: 10,
                                color: taupe,
                              ),
                            ),
                          ],
                        ),
                      ),
                      IconButton(
                        onPressed: () => widget.onStore(hit.store),
                        icon: const Icon(Icons.storefront_outlined),
                      ),
                    ],
                  ),
                ),
              );
            }, childCount: hits.length),
          ),
        ),
        if (app.canLoadMoreSearch)
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 4, 20, 12),
              child: OutlinedButton(
                onPressed:
                    app.searchBusy
                        ? null
                        : () => app.fetchSearch(query, nextPage: true),
                child: const Text('Load more'),
              ),
            ),
          ),
        const SliverToBoxAdapter(child: SizedBox(height: 20)),
      ],
    );
  }
}

class MapPage extends StatefulWidget {
  const MapPage({super.key, required this.onStore, this.onRoute});
  final ValueChanged<Store> onStore;
  final ValueChanged<Store>? onRoute;

  @override
  State<MapPage> createState() => _MapPageState();
}

class _MapPageState extends State<MapPage> {
  final _areaSearchController = TextEditingController();
  List<MapboxLocationResult> _areaSuggestions = const [];
  String? _areaSearchError;
  bool _searchingArea = false;
  Store? selected;
  AppState? _app;
  var _permissionGranted = false;
  var _checkingPermission = false;
  var _asked = false;
  String _permissionMessage = 'Location access is required to use the map.';
  var _holdingLocation = false;

  @override
  void dispose() {
    _areaSearchController.dispose();
    if (_holdingLocation) _app?.releaseForegroundLocation();
    super.dispose();
  }

  Future<void> _searchArea(AppState app) async {
    final query = _areaSearchController.text.trim();
    if (query.length < 2) {
      setState(() {
        _areaSuggestions = const [];
        _areaSearchError = 'Enter at least 2 characters to search.';
      });
      return;
    }
    setState(() {
      _searchingArea = true;
      _areaSearchError = null;
      _areaSuggestions = const [];
    });
    try {
      final results = await searchMapboxLocations(
        query,
        latitude: app.searchLat,
        longitude: app.searchLng,
      );
      if (!mounted) return;
      setState(() {
        _areaSuggestions = results;
        if (results.isEmpty) _areaSearchError = 'No matching places found.';
      });
    } catch (error) {
      if (!mounted) return;
      setState(() => _areaSearchError = error.toString());
    } finally {
      if (mounted) setState(() => _searchingArea = false);
    }
  }

  Future<void> _goToMyLocation(AppState app) async {
    await app.requestForegroundLocation(startUpdates: true);
    if (!mounted) return;
    if (app.locationAllowed && app.deviceLat != null && app.deviceLng != null) {
      app.setFollowMyLocation(true);
      return;
    }
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(app.locationNote)));
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _app = AppScope.of(context);
    if (_asked) return;
    _asked = true;
    _ensureLocationPermission(requestIfNeeded: true);
  }

  Future<void> _ensureLocationPermission({
    required bool requestIfNeeded,
  }) async {
    if (_checkingPermission) return;
    setState(() => _checkingPermission = true);
    try {
      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied && requestIfNeeded) {
        permission = await Geolocator.requestPermission();
      }
      if (!mounted) return;
      if (permission == LocationPermission.whileInUse ||
          permission == LocationPermission.always) {
        setState(() {
          _permissionGranted = true;
          _permissionMessage = '';
        });
        await _app?.requestForegroundLocation(startUpdates: true);
        if (!mounted) return;
        if (_app?.locationAllowed == true && !_holdingLocation) {
          _app?.retainForegroundLocation();
          _holdingLocation = true;
        }
      } else {
        setState(() {
          _permissionGranted = false;
          _permissionMessage =
              permission == LocationPermission.deniedForever
                  ? 'Location access is blocked. Enable it in app settings to use the map.'
                  : 'Allow foreground location access to use the map.';
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _permissionGranted = false;
          _permissionMessage = 'Could not check location access. Try again.';
        });
      }
    } finally {
      if (mounted) setState(() => _checkingPermission = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final stores = app.nearbyStores();
    final focusLat =
        app.followMyLocation ? (app.deviceLat ?? app.searchLat) : app.searchLat;
    final focusLng =
        app.followMyLocation ? (app.deviceLng ?? app.searchLng) : app.searchLng;
    if (!_permissionGranted) {
      return Column(
        children: [
          const PageHeader('Map'),
          Expanded(
            child: Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: SoftCard(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const IconWell(Icons.location_on_outlined),
                      const SizedBox(height: 16),
                      const Text(
                        'Location access required',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(_permissionMessage, textAlign: TextAlign.center),
                      const SizedBox(height: 16),
                      PrimaryButton(
                        _checkingPermission
                            ? 'Checking…'
                            : 'Allow location access',
                        onPressed:
                            _checkingPermission
                                ? null
                                : () async {
                                  final permission =
                                      await Geolocator.checkPermission();
                                  if (permission ==
                                      LocationPermission.deniedForever) {
                                    await Geolocator.openAppSettings();
                                  } else {
                                    await _ensureLocationPermission(
                                      requestIfNeeded: true,
                                    );
                                  }
                                },
                      ),
                      if (_permissionMessage.contains('app settings')) ...[
                        const SizedBox(height: 8),
                        TextButton(
                          onPressed:
                              () => _ensureLocationPermission(
                                requestIfNeeded: false,
                              ),
                          child: const Text('Check permission again'),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      );
    }
    return Column(
      children: [
        const PageHeader('Map'),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 10),
          child: Column(
            children: [
              TextField(
                controller: _areaSearchController,
                textInputAction: TextInputAction.search,
                onSubmitted: (_) => _searchArea(app),
                decoration: InputDecoration(
                  hintText: 'Search an area or address',
                  prefixIcon: const Icon(Icons.search),
                  suffixIcon:
                      _searchingArea
                          ? const Padding(
                            padding: EdgeInsets.all(14),
                            child: SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            ),
                          )
                          : IconButton(
                            tooltip: 'Search places',
                            onPressed: () => _searchArea(app),
                            icon: const Icon(Icons.arrow_forward),
                          ),
                  filled: true,
                  fillColor: paper,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(16),
                    borderSide: BorderSide(color: line),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(16),
                    borderSide: BorderSide(color: line),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(16),
                    borderSide: const BorderSide(color: leafDark, width: 1.5),
                  ),
                ),
              ),
              if (_areaSearchError != null)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      _areaSearchError!,
                      style: const TextStyle(color: clay, fontSize: 12),
                    ),
                  ),
                ),
              if (_areaSuggestions.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: SoftCard(
                    padding: EdgeInsets.zero,
                    child: Column(
                      children: [
                        for (var i = 0; i < _areaSuggestions.length; i++) ...[
                          if (i > 0) const Divider(height: 1),
                          ListTile(
                            dense: true,
                            leading: const Icon(Icons.place_outlined),
                            title: Text(_areaSuggestions[i].name),
                            subtitle: Text(_areaSuggestions[i].placeName),
                            onTap: () {
                              final place = _areaSuggestions[i];
                              FocusScope.of(context).unfocus();
                              app.setManualCenter(
                                place.latitude,
                                place.longitude,
                                place.placeName,
                              );
                              setState(() {
                                _areaSearchController.text = place.name;
                                _areaSuggestions = const [];
                                _areaSearchError = null;
                              });
                            },
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
            ],
          ),
        ),
        const CatalogFilters(showCategory: false),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
          child: Stack(
            children: [
              LocalMapView(
                stores: stores,
                centerLat: focusLat,
                centerLng: focusLng,
                userLat: app.deviceLat ?? app.searchLat,
                userLng: app.deviceLng ?? app.searchLng,
                selectedId: selected?.id,
                onSelect: widget.onStore,
                followUser: app.followMyLocation,
                onUserPan: () {
                  if (app.followMyLocation) app.setFollowMyLocation(false);
                },
                height: 240,
              ),
              Positioned(
                right: 10,
                bottom: 28,
                child: Material(
                  color: paper,
                  shape: const CircleBorder(),
                  elevation: 2,
                  child: IconButton(
                    tooltip: 'My location',
                    onPressed: () => _goToMyLocation(app),
                    icon: const Icon(Icons.my_location, color: leafDark),
                  ),
                ),
              ),
            ],
          ),
        ),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.all(20),
            children: [
              InfoBanner(app.locationNote, icon: Icons.my_location_outlined),
              const SizedBox(height: 12),
              if (selected != null)
                SoftCard(
                  onTap: () => widget.onStore(selected!),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        selected!.name,
                        style: const TextStyle(
                          fontWeight: FontWeight.w700,
                          fontSize: 16,
                        ),
                      ),
                      Text(
                        '${selected!.type.label} · ${selected!.landmark}',
                        style: const TextStyle(color: taupe, fontSize: 12),
                      ),
                      if (selected!.isMobile)
                        Text(
                          selected!.locationMode == LocationMode.live
                              ? 'Live public location'
                              : 'Regular selling area',
                          style: const TextStyle(fontSize: 11, color: taupe),
                        ),
                      const SizedBox(height: 8),
                      const Text(
                        'Tap for catalog, tour and in-app route preview',
                      ),
                      if (widget.onRoute != null)
                        TextButton(
                          onPressed: () => widget.onRoute!(selected!),
                          child: const Text('Preview route in Locentra'),
                        ),
                    ],
                  ),
                ),
              const SizedBox(height: 10),
              ...stores.map(
                (store) => Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: SoftCard(
                    onTap: () => setState(() => selected = store),
                    child: Row(
                      children: [
                        IconWell(
                          Icons.place_outlined,
                          color: store.id == selected?.id ? clay : leafDark,
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                store.name,
                                style: const TextStyle(
                                  fontSize: 13,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                              Text(
                                '${store.type.label} · ${app.distanceKm(app.searchLat, app.searchLng, store.lat, store.lng).toStringAsFixed(1)} km',
                                style: const TextStyle(
                                  color: taupe,
                                  fontSize: 11,
                                ),
                              ),
                            ],
                          ),
                        ),
                        const Icon(Icons.chevron_right, color: taupe),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class SavedPage extends StatelessWidget {
  const SavedPage({super.key, required this.onProduct, required this.onStore});
  final ValueChanged<CatalogProduct> onProduct;
  final ValueChanged<Store> onStore;

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final stores =
        app.stores.where((s) => app.favoriteStoreIds.contains(s.id)).toList();
    final products =
        app.products
            .where((p) => app.favoriteProductIds.contains(p.id))
            .toList();
    return ListView(
      padding: const EdgeInsets.only(bottom: 28),
      children: [
        const PageHeader('Saved'),
        const SectionHeading('Stores'),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child:
              stores.isEmpty
                  ? const EmptyNote(
                    'Saved stores will appear here.',
                    icon: Icons.bookmark_border,
                  )
                  : SoftCard(
                    padding: EdgeInsets.zero,
                    child: Column(
                      children: [
                        for (var i = 0; i < stores.length; i++) ...[
                          if (i > 0) const Divider(height: 1),
                          MenuRow(
                            icon: Icons.storefront_outlined,
                            title: stores[i].name,
                            subtitle: stores[i].type.label,
                            onTap: () => onStore(stores[i]),
                          ),
                        ],
                      ],
                    ),
                  ),
        ),
        const SizedBox(height: 18),
        const SectionHeading('Products'),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child:
              products.isEmpty
                  ? const EmptyNote(
                    'Saved products will appear here.',
                    icon: Icons.favorite_border,
                  )
                  : Column(
                    children: [
                      for (final p in products)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 10),
                          child: SoftCard(
                            onTap: () => onProduct(p),
                            child: Row(
                              children: [
                                NetworkPhoto(p.image, width: 52, height: 52),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: Text(
                                    p.name,
                                    style: const TextStyle(
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                ),
                                const Icon(Icons.chevron_right, color: taupe),
                              ],
                            ),
                          ),
                        ),
                    ],
                  ),
        ),
      ],
    );
  }
}

class ProfilePage extends StatelessWidget {
  const ProfilePage({
    super.key,
    required this.onLogout,
    required this.onAdmin,
    required this.onFeedback,
  });
  final VoidCallback onLogout;
  final VoidCallback onAdmin;
  final VoidCallback onFeedback;

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final user = app.currentUser!;
    final profileName = user.name.trim();
    final profileInitial =
        profileName.isEmpty ? '?' : profileName.substring(0, 1).toUpperCase();
    return ListView(
      padding: const EdgeInsets.only(bottom: 28),
      children: [
        const PageHeader('Profile'),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: SoftCard(
            child: Row(
              children: [
                CircleAvatar(
                  radius: 26,
                  backgroundColor: leafDark,
                  child: Text(
                    profileInitial,
                    style: const TextStyle(
                      color: paper,
                      fontFamily: 'Georgia',
                      fontSize: 22,
                    ),
                  ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        profileName.isEmpty ? 'Locentra user' : profileName,
                        style: const TextStyle(
                          fontWeight: FontWeight.w700,
                          fontSize: 17,
                        ),
                      ),
                      Text(
                        '${user.email} · ${roleLabel(user.role)}',
                        style: const TextStyle(color: taupe, fontSize: 12),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: SoftCard(
            padding: EdgeInsets.zero,
            child: Column(
              children: [
                MenuRow(
                  icon: Icons.flag_outlined,
                  title: 'Reports you filed',
                  subtitle:
                      '${app.reports.where((r) => r.userId == user.id).length} reports',
                  onTap: () {
                    final mine =
                        app.reports.where((r) => r.userId == user.id).toList();
                    showDialog<void>(
                      context: context,
                      builder:
                          (ctx) => AlertDialog(
                            title: const Text('Your reports'),
                            content:
                                mine.isEmpty
                                    ? const Text(
                                      'You have not filed any reports yet.',
                                    )
                                    : SizedBox(
                                      width: 340,
                                      child: ListView(
                                        shrinkWrap: true,
                                        children: [
                                          for (final r in mine)
                                            ListTile(
                                              dense: true,
                                              title: Text(
                                                r.target,
                                                style: const TextStyle(
                                                  fontWeight: FontWeight.w600,
                                                  fontSize: 13,
                                                ),
                                              ),
                                              subtitle: Text(
                                                r.reason,
                                                style: const TextStyle(
                                                  fontSize: 12,
                                                ),
                                              ),
                                              trailing:
                                                  r.resolved
                                                      ? const StatusChip(
                                                        'Resolved',
                                                        color: leaf,
                                                      )
                                                      : const StatusChip(
                                                        'Pending',
                                                        color: champagne,
                                                      ),
                                            ),
                                        ],
                                      ),
                                    ),
                            actions: [
                              TextButton(
                                onPressed: () => Navigator.pop(ctx),
                                child: const Text('Close'),
                              ),
                            ],
                          ),
                    );
                  },
                ),
                const Divider(height: 1),
                MenuRow(
                  icon: Icons.forum_outlined,
                  title: 'Pilot feedback',
                  subtitle: 'Failed search, wrong pin, or stale stock',
                  onTap: onFeedback,
                ),
                if (user.role == AppRole.admin) ...[
                  const Divider(height: 1),
                  MenuRow(
                    icon: Icons.admin_panel_settings_outlined,
                    title: 'Admin review',
                    onTap: onAdmin,
                  ),
                ],
                const Divider(height: 1),
                MenuRow(
                  icon: Icons.logout,
                  title: 'Sign out',
                  iconColor: clay,
                  onTap: onLogout,
                ),
                const Divider(height: 1),
                MenuRow(
                  icon: Icons.delete_forever_outlined,
                  title: 'Delete account',
                  subtitle: 'Permanently remove your Locentra account',
                  iconColor: clay,
                  onTap: () async {
                    final confirmed = await showDialog<bool>(
                      context: context,
                      builder:
                          (dialogContext) => AlertDialog(
                            title: const Text('Delete your account?'),
                            content: const Text(
                              'Your profile, saved favorites, reports, feedback and staff access will be removed. This cannot be undone.',
                            ),
                            actions: [
                              TextButton(
                                onPressed:
                                    () => Navigator.pop(dialogContext, false),
                                child: const Text('Cancel'),
                              ),
                              FilledButton(
                                onPressed:
                                    () => Navigator.pop(dialogContext, true),
                                child: const Text('Delete account'),
                              ),
                            ],
                          ),
                    );
                    if (confirmed != true || !context.mounted) return;
                    final error = await app.deleteAccount();
                    if (!context.mounted) return;
                    if (error == null) {
                      onLogout();
                    } else {
                      ScaffoldMessenger.of(
                        context,
                      ).showSnackBar(SnackBar(content: Text(error)));
                    }
                  },
                ),
              ],
            ),
          ),
        ),
        const Padding(
          padding: EdgeInsets.fromLTRB(20, 16, 20, 0),
          child: InfoBanner(
            'Photos used for product recognition are suggestions only. Store owners confirm identity, price and stock. Locentra lists participating sellers, not every vendor in the Philippines. Lawful product categories such as groceries, hardware and electronics are supported. The 2D map, route preview and owner-created 360° store tour stay inside the app. Customer location is used in the foreground only and is not stored as a movement history.',
          ),
        ),
      ],
    );
  }
}
