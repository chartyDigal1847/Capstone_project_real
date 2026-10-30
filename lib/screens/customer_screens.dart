import 'dart:async';

import 'package:flutter/material.dart';

import '../map_view.dart';
import '../models.dart';
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
              decoration: BoxDecoration(color: paper, borderRadius: BorderRadius.circular(28), border: Border.all(color: line)),
              child: Row(
                children: [
                  const Icon(Icons.search, color: taupe),
                  const SizedBox(width: 10),
                  const Expanded(child: Text('Search products, brands, aliases…', style: TextStyle(color: Color(0xFF99938A), fontSize: 13))),
                  IconButton(onPressed: onCameraSearch, icon: const Icon(Icons.photo_camera_outlined, color: leafDark)),
                ],
              ),
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
                          distanceKm: app.distanceKm(app.searchLat, app.searchLng, store.lat, store.lng),
                          badge: 'Sponsored',
                          width: 220,
                          height: 168,
                          onTap: () => onStore(store),
                        ),
                        Positioned(
                          left: 12,
                          right: 12,
                          top: 40,
                          child: Text(promo.offer, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(color: paper, fontSize: 12, fontWeight: FontWeight.w600)),
                        ),
                      ],
                    ),
                  );
                }
                final store = hot[index];
                return StoreImageCard(
                  store: store,
                  distanceKm: app.distanceKm(app.searchLat, app.searchLng, store.lat, store.lng),
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
            child: EmptyNote('No participating stores in this area yet. Widen the radius in Search.'),
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
                  distanceKm: app.distanceKm(app.searchLat, app.searchLng, store.lat, store.lng),
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
                        NetworkPhoto(store.image, width: 40, height: 40, radius: 10),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(store.name, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 14)),
                              Text('${store.type.label} · ${app.distanceKm(app.searchLat, app.searchLng, store.lat, store.lng).toStringAsFixed(1)} km', style: const TextStyle(color: taupe, fontSize: 11)),
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
                            NetworkPhoto(product.image, width: 52, height: 52, radius: 10),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(product.name, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
                                  Text('${peso(listing.price)} / ${listing.unit} · ${availabilityLabel(listing.availability)}', style: const TextStyle(color: taupe, fontSize: 11)),
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
  const SearchPage({super.key, required this.onProduct, required this.onStore, this.initialQuery = ''});
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
      unawaited(AppScope.of(context).fetchSearch(activeQuery.isEmpty ? controller.text : activeQuery));
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
    return Column(
      children: [
        const PageHeader('Search products'),
        if (app.searchBusy) const LinearProgressIndicator(minHeight: 2, color: leaf),
        if (app.searchNote.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
            child: Text(app.searchNote, style: const TextStyle(color: taupe, fontSize: 12)),
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
            textInputAction: TextInputAction.search,
            onSubmitted: (value) {
              setState(() => activeQuery = value);
              app.fetchSearch(value);
            },
            decoration: InputDecoration(
              hintText: 'Name, brand, category, or local term',
              prefixIcon: const Icon(Icons.search, color: taupe),
              suffixIcon: controller.text.isEmpty
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
        const CatalogFilters(),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
          child: Text(
            app.searchTotal > 0
                ? '${hits.length} of ${app.searchTotal} participating listings within ${app.radiusKm.toStringAsFixed(0)} km'
                : '${hits.length} participating listings within ${app.radiusKm.toStringAsFixed(0)} km',
            style: const TextStyle(color: taupe, fontSize: 12, fontWeight: FontWeight.w600),
          ),
        ),
        Expanded(
          child: hits.isEmpty
              ? Padding(
                  padding: const EdgeInsets.all(20),
                  child: Column(
                    children: [
                      const EmptyNote('No participating seller listed this yet. Try another name, a parent category, or a wider radius.', icon: Icons.search_off),
                      const SizedBox(height: 12),
                      OutlinedButton(onPressed: () => app.setRadius(10), child: const Text('Widen to 10 km')),
                      TextButton(
                        onPressed: () {
                          app.setTypeFilter(null);
                          app.setCategoryFilter(null);
                          app.setSearchSort(SearchSort.relevance);
                          controller.clear();
                          setState(() => activeQuery = '');
                          app.fetchSearch('');
                        },
                        child: const Text('Clear filters'),
                      ),
                    ],
                  ),
                )
              : ListView.builder(
                  padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
                  itemCount: hits.length + (app.canLoadMoreSearch ? 1 : 0),
                  itemBuilder: (_, i) {
                    if (i >= hits.length) {
                      return Padding(
                        padding: const EdgeInsets.only(top: 4, bottom: 12),
                        child: OutlinedButton(
                          onPressed: app.searchBusy ? null : () => app.fetchSearch(query, nextPage: true),
                          child: const Text('Load more'),
                        ),
                      );
                    }
                    final hit = hits[i];
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
                                  Text(hit.product.name, style: const TextStyle(fontWeight: FontWeight.w700)),
                                  const SizedBox(height: 4),
                                  StatusChip(matchTypeLabel(hit.matchType), color: hit.matchType == SearchMatchType.exact ? leaf : champagne),
                                  Text(hit.store.name, style: const TextStyle(color: taupe, fontSize: 11)),
                                  Text('${peso(hit.listing.price)} / ${hit.listing.unit} · ${hit.distanceKm.toStringAsFixed(1)} km', style: const TextStyle(fontSize: 12)),
                                  Text('${availabilityLabel(hit.listing.availability)} · ${freshness(hit.listing.lastConfirmed)}', style: const TextStyle(fontSize: 10, color: taupe)),
                                ],
                              ),
                            ),
                            IconButton(onPressed: () => widget.onStore(hit.store), icon: const Icon(Icons.storefront_outlined)),
                          ],
                        ),
                      ),
                    );
                  },
                ),
        ),
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
  Store? selected;
  AppState? _app;
  var _asked = false;
  var _holdingLocation = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _app = AppScope.of(context);
    if (_asked) return;
    _asked = true;
    _holdLocation();
  }

  Future<void> _holdLocation() async {
    await _app?.requestForegroundLocation(startUpdates: true);
    if (!mounted) return;
    _app?.retainForegroundLocation();
    _holdingLocation = true;
  }

  @override
  void dispose() {
    if (_holdingLocation) _app?.releaseForegroundLocation();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final stores = app.nearbyStores();
    final focusLat = app.followMyLocation ? (app.deviceLat ?? app.searchLat) : app.searchLat;
    final focusLng = app.followMyLocation ? (app.deviceLng ?? app.searchLng) : app.searchLng;
    return Column(
      children: [
        const PageHeader('Map'),
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
                onSelect: (store) => setState(() => selected = store),
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
                    tooltip: 'Recenter',
                    onPressed: () async {
                      if (!app.locationAllowed) {
                        await app.requestForegroundLocation(startUpdates: true);
                      }
                      if (!context.mounted) return;
                      app.setFollowMyLocation(true);
                    },
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
                      Text(selected!.name, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
                      Text('${selected!.type.label} · ${selected!.landmark}', style: const TextStyle(color: taupe, fontSize: 12)),
                      if (selected!.isMobile)
                        Text(
                          selected!.locationMode == LocationMode.live ? 'Live public location' : 'Regular selling area',
                          style: const TextStyle(fontSize: 11, color: taupe),
                        ),
                      const SizedBox(height: 8),
                      const Text('Tap for catalog, tour and in-app route preview'),
                      if (widget.onRoute != null)
                        TextButton(
                          onPressed: () => widget.onRoute!(selected!),
                          child: const Text('Preview route in LocalSpot'),
                        ),
                    ],
                  ),
                ),
              const SizedBox(height: 10),
              ...stores.map((store) => Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: SoftCard(
                      onTap: () => setState(() => selected = store),
                      child: Row(
                        children: [
                          IconWell(Icons.place_outlined, color: store.id == selected?.id ? clay : leafDark),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(store.name, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700)),
                                Text('${store.type.label} · ${app.distanceKm(app.searchLat, app.searchLng, store.lat, store.lng).toStringAsFixed(1)} km', style: const TextStyle(color: taupe, fontSize: 11)),
                              ],
                            ),
                          ),
                          const Icon(Icons.chevron_right, color: taupe),
                        ],
                      ),
                    ),
                  )),
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
    final stores = app.stores.where((s) => app.favoriteStoreIds.contains(s.id)).toList();
    final products = app.products.where((p) => app.favoriteProductIds.contains(p.id)).toList();
    return ListView(
      padding: const EdgeInsets.only(bottom: 28),
      children: [
        const PageHeader('Saved'),
        const SectionHeading('Stores'),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: stores.isEmpty
              ? const EmptyNote('Saved stores will appear here.', icon: Icons.bookmark_border)
              : SoftCard(
                  padding: EdgeInsets.zero,
                  child: Column(
                    children: [
                      for (var i = 0; i < stores.length; i++) ...[
                        if (i > 0) const Divider(height: 1),
                        MenuRow(icon: Icons.storefront_outlined, title: stores[i].name, subtitle: stores[i].type.label, onTap: () => onStore(stores[i])),
                      ],
                    ],
                  ),
                ),
        ),
        const SizedBox(height: 18),
        const SectionHeading('Products'),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: products.isEmpty
              ? const EmptyNote('Saved products will appear here.', icon: Icons.favorite_border)
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
                              Expanded(child: Text(p.name, style: const TextStyle(fontWeight: FontWeight.w700))),
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
    required this.onLocation,
    required this.onLogout,
    required this.onAdmin,
    required this.onFeedback,
  });
  final VoidCallback onLocation;
  final VoidCallback onLogout;
  final VoidCallback onAdmin;
  final VoidCallback onFeedback;

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final user = app.currentUser!;
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
                  child: Text(user.name.substring(0, 1), style: const TextStyle(color: paper, fontFamily: 'Georgia', fontSize: 22)),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(user.name, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 17)),
                      Text('${user.email} · ${roleLabel(user.role)}', style: const TextStyle(color: taupe, fontSize: 12)),
                      const SizedBox(height: 6),
                      Text(app.connectionNote, style: const TextStyle(color: taupe, fontSize: 11)),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 16),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: SoftCard(
            padding: EdgeInsets.zero,
            child: Column(
              children: [
                MenuRow(
                  icon: Icons.cloud_outlined,
                  title: app.apiOnline ? 'API connected' : 'Retry API connection',
                  subtitle: app.connectionNote,
                  onTap: () => app.bootstrap(),
                ),
                const Divider(height: 1),
                MenuRow(icon: Icons.place_outlined, title: 'Search area', subtitle: app.searchAreaLabel, onTap: onLocation),
                const Divider(height: 1),
                SwitchListTile(
                  contentPadding: const EdgeInsets.fromLTRB(12, 4, 8, 4),
                  secondary: const IconWell(Icons.my_location_outlined),
                  title: const Text('Follow my location', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 14)),
                  subtitle: const Text('Centers the map only while this is on', style: TextStyle(fontSize: 11, color: taupe)),
                  value: app.followMyLocation,
                  onChanged: (value) {
                    if (value) {
                      app.requestForegroundLocation(startUpdates: true).then((_) => app.setFollowMyLocation(true));
                    } else {
                      app.setFollowMyLocation(false);
                    }
                  },
                ),
                const Divider(height: 1),
                MenuRow(icon: Icons.privacy_tip_outlined, title: 'Location permission', subtitle: app.locationNote, onTap: onLocation),
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
                MenuRow(icon: Icons.flag_outlined, title: 'Reports you filed', subtitle: '${app.reports.where((r) => r.userId == user.id).length} reports'),
                const Divider(height: 1),
                MenuRow(icon: Icons.forum_outlined, title: 'Pilot feedback', subtitle: 'Failed search, wrong pin, or stale stock', onTap: onFeedback),
                if (user.role == AppRole.admin) ...[
                  const Divider(height: 1),
                  MenuRow(icon: Icons.admin_panel_settings_outlined, title: 'Admin review', onTap: onAdmin),
                ],
                const Divider(height: 1),
                MenuRow(icon: Icons.logout, title: 'Sign out', iconColor: clay, onTap: onLogout),
              ],
            ),
          ),
        ),
        const Padding(
          padding: EdgeInsets.fromLTRB(20, 16, 20, 0),
          child: InfoBanner(
            'Photos used for product recognition are suggestions only. Store owners confirm identity, price and stock. LocalSpot lists participating sellers, not every vendor in the Philippines. Lawful product categories such as groceries, hardware and electronics are supported. The 2D map, route preview and owner-created 360° store tour stay inside the app. Customer location is used in the foreground only and is not stored as a movement history.',
          ),
        ),
      ],
    );
  }
}
