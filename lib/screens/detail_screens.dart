import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:url_launcher/url_launcher.dart';

import '../map_view.dart';
import '../models.dart';
import '../state.dart';
import '../theme.dart';
import '../widgets.dart';

class ProductDetailPage extends StatelessWidget {
  const ProductDetailPage({
    super.key,
    required this.product,
    required this.onBack,
    required this.onStore,
  });
  final CatalogProduct product;
  final VoidCallback onBack;
  final ValueChanged<Store> onStore;

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final hits = app.listingsForProduct(product.id);
    final saved = app.favoriteProductIds.contains(product.id);
    return ListView(
      children: [
        Stack(
          children: [
            NetworkPhoto(product.image, height: 240, width: double.infinity, radius: 0),
            Positioned(top: 12, left: 8, child: IconButton.filledTonal(onPressed: onBack, icon: const Icon(Icons.arrow_back))),
            Positioned(
              top: 12,
              right: 8,
              child: IconButton.filledTonal(
                onPressed: () => app.toggleFavoriteProduct(product.id),
                icon: Icon(saved ? Icons.favorite : Icons.favorite_border),
              ),
            ),
          ],
        ),
        Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SoftCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Eyebrow(product.category.toUpperCase()),
                    const SizedBox(height: 6),
                    Text(product.name, style: const TextStyle(fontFamily: 'Georgia', fontSize: 28, height: 1.1)),
                    if (product.brand.isNotEmpty) Text(product.brand, style: const TextStyle(color: taupe)),
                    Text(product.packageSize, style: const TextStyle(fontSize: 13)),
                    if (product.attributes.isNotEmpty) ...[
                      const SizedBox(height: 8),
                      for (final entry in product.attributes.entries)
                        Text('${entry.key}: ${entry.value}', style: const TextStyle(fontSize: 12, color: taupe)),
                    ],
                    const SizedBox(height: 10),
                    Text('Also searched as: ${product.aliases.join(', ')}', style: const TextStyle(color: taupe, fontSize: 11, height: 1.4)),
                  ],
                ),
              ),
              const SizedBox(height: 18),
              const Text('Participating sellers', style: TextStyle(fontFamily: 'Georgia', fontSize: 22)),
              const SizedBox(height: 8),
              if (hits.isEmpty)
                const EmptyNote('No approved nearby store has listed this product yet.', icon: Icons.storefront_outlined)
              else
                ...hits.map((hit) => Padding(
                      padding: const EdgeInsets.only(bottom: 10),
                      child: SoftCard(
                        onTap: () => onStore(hit.store),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(hit.store.name, style: const TextStyle(fontWeight: FontWeight.w700)),
                            Text('${hit.store.type.label} · ${hit.distanceKm.toStringAsFixed(1)} km'),
                            Text('${peso(hit.listing.price)} / ${hit.listing.unit} · ${availabilityLabel(hit.listing.availability)}'),
                            Text(freshness(hit.listing.lastConfirmed), style: const TextStyle(color: taupe, fontSize: 11)),
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

class StoreDetailPage extends StatelessWidget {
  const StoreDetailPage({
    super.key,
    required this.store,
    required this.onBack,
    required this.onProduct,
    required this.onTour,
    required this.onReport,
    required this.onRoute,
  });
  final Store store;
  final VoidCallback onBack;
  final ValueChanged<CatalogProduct> onProduct;
  final VoidCallback onTour;
  final VoidCallback onReport;
  final VoidCallback onRoute;

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final catalog = app.listingsForStore(store.id);
    final tour = app.tourForStore(store.id);
    final saved = app.favoriteStoreIds.contains(store.id);
    return ListView(
      children: [
        Stack(
          children: [
            NetworkPhoto(store.image, height: 210, width: double.infinity, radius: 0),
            Positioned(top: 12, left: 8, child: IconButton.filledTonal(onPressed: onBack, icon: const Icon(Icons.arrow_back))),
            Positioned(
              top: 12,
              right: 8,
              child: IconButton.filledTonal(
                onPressed: () => app.toggleFavoriteStore(store.id),
                icon: Icon(saved ? Icons.favorite : Icons.favorite_border),
              ),
            ),
          ],
        ),
        Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SoftCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    StatusChip(storeStatusLabel(store.status)),
                    const SizedBox(height: 8),
                    Text(store.name, style: const TextStyle(fontFamily: 'Georgia', fontSize: 28, height: 1.1)),
                    Text(store.type.label, style: const TextStyle(color: taupe)),
                    const SizedBox(height: 10),
                    Text('${store.address}, ${store.barangay}, ${store.city}'),
                    Text('Landmark: ${store.landmark}', style: const TextStyle(fontSize: 12, color: taupe)),
                    Text(store.schedule, style: const TextStyle(fontSize: 12)),
                    if (store.isMobile) ...[
                      const SizedBox(height: 8),
                      Text(_vendorLocationCopy(store), style: const TextStyle(fontSize: 11, color: taupe)),
                    ],
                  ],
                ),
              ),
              const SizedBox(height: 14),
              LocalMapView(
                stores: [store],
                centerLat: store.lat,
                centerLng: store.lng,
                userLat: app.deviceLat ?? app.searchLat,
                userLng: app.deviceLng ?? app.searchLng,
                selectedId: store.id,
                height: 160,
              ),
              const SizedBox(height: 12),
              PrimaryButton('Preview route in LocalSpot', onPressed: onRoute),
              const Padding(
                padding: EdgeInsets.only(top: 10, bottom: 10),
                child: InfoBanner(
                  'The route stays on the LocalSpot map. An external map app is optional. Owner-created 360° tours are the immersive store view in this release.',
                  icon: Icons.map_outlined,
                ),
              ),
              if (tour != null)
                OutlinedButton(onPressed: onTour, child: const Text('Open 360° store tour'))
              else
                const EmptyNote('No published store tour yet.', icon: Icons.threesixty_outlined),
              TextButton(onPressed: onReport, child: const Text('Report a problem with this listing')),
              const SizedBox(height: 10),
              const Text('Sold here', style: TextStyle(fontFamily: 'Georgia', fontSize: 22)),
              const SizedBox(height: 8),
              const InfoBanner('These are this store’s listings only.', icon: Icons.inventory_2_outlined),
              const SizedBox(height: 12),
              if (catalog.isEmpty)
                const EmptyNote('This store has not published products yet.', icon: Icons.inventory_2_outlined)
              else
                ...catalog.map((listing) {
                  final product = app.productById(listing.productId);
                  if (product == null) return const SizedBox.shrink();
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: SoftCard(
                      onTap: () => onProduct(product),
                      child: Row(
                        children: [
                          NetworkPhoto(product.image, width: 72, height: 72, radius: 12),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(product.name, style: const TextStyle(fontWeight: FontWeight.w700)),
                                Text('${peso(listing.price)} / ${listing.unit}', style: const TextStyle(fontSize: 13)),
                                Text('${availabilityLabel(listing.availability)} · ${freshness(listing.lastConfirmed)}', style: const TextStyle(fontSize: 11, color: taupe)),
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
      ],
    );
  }
}

class TourViewerPage extends StatefulWidget {
  const TourViewerPage({super.key, required this.tour, required this.onBack});
  final StoreTour tour;
  final VoidCallback onBack;

  @override
  State<TourViewerPage> createState() => _TourViewerPageState();
}

class _TourViewerPageState extends State<TourViewerPage> {
  late int nodeId = widget.tour.nodes.first.id;
  double pan = 0;

  @override
  Widget build(BuildContext context) {
    final node = widget.tour.nodes.firstWhere((n) => n.id == nodeId);
    return Column(
      children: [
        PageHeader(widget.tour.title, onBack: widget.onBack),
        Expanded(
          child: Stack(
            fit: StackFit.expand,
            children: [
              LayoutBuilder(
                builder: (context, constraints) {
                  return GestureDetector(
                    onHorizontalDragUpdate: (details) {
                      setState(() => pan = (pan + details.delta.dx).clamp(-220.0, 220.0));
                    },
                    onHorizontalDragEnd: (details) {
                      if (details.primaryVelocity == null || node.connections.isEmpty) return;
                      if (details.primaryVelocity!.abs() < 900) return;
                      setState(() {
                        pan = 0;
                        nodeId = details.primaryVelocity! < 0 ? node.connections.first : node.connections.last;
                      });
                    },
                    child: ClipRect(
                      child: Transform.translate(
                        offset: Offset(pan, 0),
                        child: OverflowBox(
                          minWidth: constraints.maxWidth * 1.7,
                          maxWidth: constraints.maxWidth * 1.7,
                          minHeight: constraints.maxHeight,
                          maxHeight: constraints.maxHeight,
                          alignment: Alignment.center,
                          child: NetworkPhoto(
                            node.image,
                            radius: 0,
                            height: constraints.maxHeight,
                            width: constraints.maxWidth * 1.7,
                          ),
                        ),
                      ),
                    ),
                  );
                },
              ),
              if (node.image.trim().isEmpty)
                const Center(
                  child: Padding(
                    padding: EdgeInsets.all(24),
                    child: EmptyNote('This viewpoint has no public privacy-processed image. The original stays private.', icon: Icons.hide_image_outlined),
                  ),
                ),
              Positioned(
                left: 16,
                right: 16,
                bottom: 24,
                child: SoftCard(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(node.title, style: const TextStyle(fontWeight: FontWeight.w700)),
                      const Text('Drag to look around this viewpoint · use arrows to walk the connected tour', style: TextStyle(fontSize: 11, color: taupe)),
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          for (final id in node.connections)
                            OutlinedButton(
                              onPressed: () => setState(() {
                                pan = 0;
                                nodeId = id;
                              }),
                              child: Text(widget.tour.nodes.firstWhere((n) => n.id == id).title),
                            ),
                        ],
                      ),
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

String _vendorLocationCopy(Store store) {
  return switch (store.locationMode) {
    LocationMode.live => 'Mobile vendor · live public location is on${store.locationUpdatedAt == null ? '' : ' · updated ${freshness(store.locationUpdatedAt!)}'}.',
    LocationMode.stale => 'Mobile vendor · live session expired. Showing the regular selling area.',
    LocationMode.regular => 'Mobile vendor · regular selling area. Live sharing is off.',
    LocationMode.fixed => 'Mobile vendor · registered pin.',
  };
}

class RoutePreviewPage extends StatefulWidget {
  const RoutePreviewPage({super.key, required this.store, required this.onBack});
  final Store store;
  final VoidCallback onBack;

  @override
  State<RoutePreviewPage> createState() => _RoutePreviewPageState();
}

class _RoutePreviewPageState extends State<RoutePreviewPage> {
  RoutePreview? preview;
  String? error;
  var loading = true;
  var navigating = false;
  var _holdingLocation = false;
  AppState? _app;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _app = AppScope.of(context);
    if (_holdingLocation) return;
    _holdingLocation = true;
    _app!.retainForegroundLocation();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _load();
    });
  }

  @override
  void dispose() {
    if (_holdingLocation) _app?.releaseForegroundLocation();
    super.dispose();
  }

  Future<void> _load() async {
    final app = AppScope.of(context);
    try {
      final result = await app.previewRoute(destLat: widget.store.lat, destLng: widget.store.lng);
      if (!mounted) return;
      setState(() {
        preview = result;
        loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        error = 'Could not build a route preview.';
        loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final route = preview?.coordinates ?? const <GeoPoint>[];
    return ListView(
      padding: const EdgeInsets.only(bottom: 24),
      children: [
        PageHeader('Route preview', onBack: widget.onBack),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: LocalMapView(
            stores: [widget.store],
            centerLat: navigating ? (app.deviceLat ?? app.searchLat) : widget.store.lat,
            centerLng: navigating ? (app.deviceLng ?? app.searchLng) : widget.store.lng,
            userLat: app.deviceLat ?? app.searchLat,
            userLng: app.deviceLng ?? app.searchLng,
            selectedId: widget.store.id,
            route: route,
            followUser: navigating,
            height: 280,
          ),
        ),
        const SizedBox(height: 12),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: SoftCard(
            child: loading
                ? const Text('Drawing the route on the LocalSpot map…')
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(widget.store.name, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
                      if (preview != null) ...[
                        Text('${preview!.distanceKm.toStringAsFixed(1)} km · ${preview!.durationMinutes ?? '—'} min'),
                        Text(
                          preview!.fallback
                              ? 'Straight-line preview · a licensed road router can replace this in production.'
                              : 'Route from the configured provider · ${preview!.provider}',
                          style: const TextStyle(color: taupe, fontSize: 11),
                        ),
                      ],
                      if (error != null) Text(error!, style: const TextStyle(color: clay)),
                      const SizedBox(height: 8),
                      Text(
                        navigating
                            ? 'Following your position on the LocalSpot map. Turn-by-turn voice guidance is a later enhancement.'
                            : 'Stay inside LocalSpot to preview this route.',
                        style: const TextStyle(color: taupe, fontSize: 11),
                      ),
                    ],
                  ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
          child: PrimaryButton(
            navigating ? 'Stop following' : 'Start in-app navigation',
            onPressed: () async {
              if (navigating) {
                app.setFollowMyLocation(false);
                setState(() => navigating = false);
                return;
              }
              await app.requestForegroundLocation(startUpdates: true);
              app.setFollowMyLocation(true);
              if (!mounted) return;
              setState(() => navigating = true);
            },
          ),
        ),
        TextButton(
          onPressed: () {
            final uri = Uri.parse('https://www.openstreetmap.org/directions?from=${app.searchLat},${app.searchLng}&to=${widget.store.lat},${widget.store.lng}');
            launchUrl(uri, mode: LaunchMode.externalApplication);
          },
          child: const Text('Optional: open in an external map app'),
        ),
      ],
    );
  }
}

class LocationPage extends StatelessWidget {
  const LocationPage({super.key, required this.onBack});
  final VoidCallback onBack;

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    return ListView(
      padding: const EdgeInsets.only(bottom: 24),
      children: [
        PageHeader('Search area', onBack: onBack),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: InfoBanner(app.locationNote, icon: Icons.privacy_tip_outlined),
        ),
        const SizedBox(height: 12),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: LocalMapView(
            stores: app.stores.where((s) => s.status == StoreStatus.approved).toList(),
            centerLat: app.searchLat,
            centerLng: app.searchLng,
            userLat: app.deviceLat,
            userLng: app.deviceLng,
            onPick: (lat, lng) => app.setManualCenter(lat, lng, 'Pinned area · Quezon City'),
            height: 280,
          ),
        ),
        const SizedBox(height: 12),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: PrimaryButton('Use my current location', onPressed: () => app.requestForegroundLocation()),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
          child: OutlinedButton(
            onPressed: app.useApproximateLocation,
            child: const Text('Use approximate Cubao area'),
          ),
        ),
        TextButton(onPressed: app.denyLocation, child: const Text('Keep using a manual area')),
      ],
    );
  }
}

class ReportPage extends StatefulWidget {
  const ReportPage({super.key, required this.target, required this.onBack});
  final String target;
  final VoidCallback onBack;

  @override
  State<ReportPage> createState() => _ReportPageState();
}

class _ReportPageState extends State<ReportPage> {
  final reason = TextEditingController();

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
      children: [
        PageHeader('Report listing', onBack: widget.onBack),
        SoftCard(child: Text(widget.target, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 16))),
        const SizedBox(height: 12),
        SoftCard(child: LabeledField('What is wrong?', reason, maxLines: 4)),
        const SizedBox(height: 16),
        PrimaryButton('Submit report', onPressed: () {
          if (reason.text.trim().isEmpty) return;
          app.addReport(widget.target, reason.text.trim());
          widget.onBack();
        }),
      ],
    );
  }
}

class CameraSearchPage extends StatefulWidget {
  const CameraSearchPage({super.key, required this.onBack, required this.onProduct, required this.onStore});
  final VoidCallback onBack;
  final ValueChanged<CatalogProduct> onProduct;
  final ValueChanged<Store> onStore;

  @override
  State<CameraSearchPage> createState() => _CameraSearchPageState();
}

class _CameraSearchPageState extends State<CameraSearchPage> {
  bool loading = false;
  VisualSearchResult? result;
  String? selectedObject;
  AppState? _app;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _app = AppScope.of(context);
  }

  @override
  void dispose() {
    _app?.cancelRecognition();
    super.dispose();
  }

  List<RecognitionSuggestion> get _visibleSuggestions {
    final current = result;
    if (current == null) return const [];
    if (selectedObject == null || current.objects.length <= 1) return current.suggestions;
    return [
      for (final object in current.objects)
        if (object.label == selectedObject) ...object.suggestions,
    ];
  }

  List<SearchHit> get _visibleHits {
    final current = result;
    if (current == null) return const [];
    final ids = {
      for (final suggestion in _visibleSuggestions)
        if (suggestion.product != null) suggestion.product!.id,
    };
    if (ids.isEmpty) return current.hits;
    return [for (final hit in current.hits) if (ids.contains(hit.product.id)) hit];
  }

  Future<void> _lookup(String hint, {String? image}) async {
    setState(() => loading = true);
    final next = await AppScope.of(context).visualSearch(hint: hint, image: image);
    if (!mounted) return;
    setState(() {
      loading = false;
      result = next;
      selectedObject = next.objects.length > 1 ? next.objects.first.label : null;
    });
  }

  Future<void> _pick(ImageSource source) async {
    try {
      final file = await ImagePicker().pickImage(source: source, imageQuality: 70);
      if (file == null) return;
      String? image;
      try {
        final bytes = await file.readAsBytes();
        if (bytes.isNotEmpty && bytes.length <= 1500000) {
          image = 'data:image/jpeg;base64,${base64Encode(bytes)}';
        }
      } catch (_) {}
      await _lookup(file.name.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), ' '), image: image);
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Camera unavailable. Try a sample photo.')));
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListView(
      children: [
        PageHeader('Photo search', onBack: widget.onBack),
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: 20),
          child: InfoBanner(
            'A photo suggests likely products, then LocalSpot searches participating listings nearby. It does not invent stock a store has not reported.',
            icon: Icons.photo_camera_outlined,
          ),
        ),
        const SizedBox(height: 12),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: SoftCard(
            child: CaptureActions(
              onCamera: () => _pick(ImageSource.camera),
              onGallery: () => _pick(ImageSource.gallery),
            ),
          ),
        ),
        if (loading) const Padding(padding: EdgeInsets.all(16), child: Center(child: CircularProgressIndicator())),
        const SizedBox(height: 12),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: SoftCard(
            padding: EdgeInsets.zero,
            child: Column(
              children: [
                for (final key in const ['mango', 'oil', 'sardines', 'hammer', 'mango and oil', 'unknown']) ...[
                  if (key != 'mango') const Divider(height: 1),
                  MenuRow(
                    icon: Icons.image_outlined,
                    title: 'Photo: $key',
                    onTap: () => _lookup(key),
                  ),
                ],
              ],
            ),
          ),
        ),
        if (result != null) ...[
          const SectionHeading('Suggested identity'),
          if (result!.objects.length > 1)
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
              child: Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final object in result!.objects)
                    ChoiceChip(
                      label: Text(object.label),
                      selected: selectedObject == object.label,
                      onSelected: (_) => setState(() => selectedObject = object.label),
                    ),
                ],
              ),
            ),
          if (result!.uncertain)
            const Padding(
              padding: EdgeInsets.fromLTRB(20, 0, 20, 8),
              child: InfoBanner('Match is uncertain. Showing similar participating listings when possible.', icon: Icons.help_outline),
            ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: SoftCard(
              padding: EdgeInsets.zero,
              child: Column(
                children: [
                  for (var i = 0; i < _visibleSuggestions.length; i++) ...[
                    if (i > 0) const Divider(height: 1),
                    MenuRow(
                      icon: Icons.auto_awesome_outlined,
                      title: _visibleSuggestions[i].label,
                      subtitle: 'Confidence ${(_visibleSuggestions[i].confidence * 100).round()}%',
                      onTap: _visibleSuggestions[i].product == null ? null : () => widget.onProduct(_visibleSuggestions[i].product!),
                    ),
                  ],
                ],
              ),
            ),
          ),
          const SectionHeading('Nearby participating listings'),
          if (_visibleHits.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 20),
              child: EmptyNote('No participating seller listed a match in this search area.', icon: Icons.search_off),
            )
          else
            ..._visibleHits.map((hit) => Padding(
                  padding: const EdgeInsets.fromLTRB(20, 0, 20, 10),
                  child: SoftCard(
                    onTap: () => widget.onStore(hit.store),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(hit.product.name, style: const TextStyle(fontWeight: FontWeight.w700)),
                        Text('${hit.store.name} · ${peso(hit.listing.price)} / ${hit.listing.unit} · ${hit.distanceKm.toStringAsFixed(1)} km', style: const TextStyle(color: taupe, fontSize: 12)),
                      ],
                    ),
                  ),
                )),
        ],
      ],
    );
  }
}
