import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:mapbox_maps_flutter/mapbox_maps_flutter.dart' hide Size;

import 'mapbox_config.dart';
import 'models.dart';
import 'theme.dart';

bool inWidgetTest() =>
    WidgetsBinding.instance.runtimeType.toString().contains('Test');

bool useNativeMapbox() {
  if (inWidgetTest()) return false;
  if (kIsWeb) return true;
  return defaultTargetPlatform == TargetPlatform.android ||
      defaultTargetPlatform == TargetPlatform.iOS;
}

class LocalMapView extends StatelessWidget {
  const LocalMapView({
    super.key,
    required this.stores,
    required this.centerLat,
    required this.centerLng,
    this.userLat,
    this.userLng,
    this.selectedId,
    this.onSelect,
    this.onPick,
    this.onUserPan,
    this.onLocateUser,
    this.route = const [],
    this.followUser = false,
    this.tilt = 0,
    this.height = 280,
  });

  final List<Store> stores;
  final double centerLat;
  final double centerLng;
  final double? userLat;
  final double? userLng;
  final int? selectedId;
  final ValueChanged<Store>? onSelect;
  final void Function(double lat, double lng)? onPick;
  final VoidCallback? onUserPan;
  final VoidCallback? onLocateUser;
  final List<GeoPoint> route;
  final bool followUser;
  final double tilt;
  final double height;

  @override
  Widget build(BuildContext context) {
    final mapboxUnavailable = useNativeMapbox() && !hasMapboxPublicToken;
    final child =
        useNativeMapbox() && hasMapboxPublicToken
            ? _MapboxCanvas(
              stores: stores,
              centerLat: centerLat,
              centerLng: centerLng,
              userLat: userLat,
              userLng: userLng,
              selectedId: selectedId,
              onSelect: onSelect,
              onPick: onPick,
              onUserPan: onUserPan,
              onLocateUser: onLocateUser,
              route: route,
              followUser: followUser,
              tilt: tilt,
            )
            : _SchematicMapView(
              stores: stores,
              centerLat: centerLat,
              centerLng: centerLng,
              userLat: userLat,
              userLng: userLng,
              selectedId: selectedId,
              onSelect: onSelect,
              onPick: onPick,
              route: route,
              onLocateUser: onLocateUser,
              mapboxUnavailable: mapboxUnavailable,
            );
    return SizedBox(
      height: height,
      child: ClipRRect(borderRadius: BorderRadius.circular(18), child: child),
    );
  }
}

class _MapboxCanvas extends StatefulWidget {
  const _MapboxCanvas({
    required this.stores,
    required this.centerLat,
    required this.centerLng,
    required this.userLat,
    required this.userLng,
    required this.selectedId,
    required this.onSelect,
    required this.onPick,
    required this.onUserPan,
    required this.onLocateUser,
    required this.route,
    required this.followUser,
    required this.tilt,
  });

  final List<Store> stores;
  final double centerLat;
  final double centerLng;
  final double? userLat;
  final double? userLng;
  final int? selectedId;
  final ValueChanged<Store>? onSelect;
  final void Function(double lat, double lng)? onPick;
  final VoidCallback? onUserPan;
  final VoidCallback? onLocateUser;
  final List<GeoPoint> route;
  final bool followUser;
  final double tilt;

  @override
  State<_MapboxCanvas> createState() => _MapboxCanvasState();
}

class _MapboxCanvasState extends State<_MapboxCanvas> {
  static const _emptyCollection = '{"type":"FeatureCollection","features":[]}';
  static const _routeSourceId = 'localspot-route-source';
  static const _storesSourceId = 'localspot-stores-source';
  static const _selectedSourceId = 'localspot-selected-source';
  static const _customerSourceId = 'localspot-customer-source';

  MapboxMap? _map;
  GeoJsonSource? _routeSource;
  GeoJsonSource? _storesSource;
  GeoJsonSource? _selectedSource;
  GeoJsonSource? _customerSource;
  var _styleReady = false;
  var _panChanged = false;
  String? _styleError;
  StreamSubscription<MapContentGestureContext>? _panSubscription;

  double get _targetLat =>
      widget.followUser
          ? (widget.userLat ?? widget.centerLat)
          : widget.centerLat;
  double get _targetLng =>
      widget.followUser
          ? (widget.userLng ?? widget.centerLng)
          : widget.centerLng;

  @override
  void didUpdateWidget(covariant _MapboxCanvas oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!_styleReady) return;
    final markersChanged =
        oldWidget.stores != widget.stores ||
        oldWidget.selectedId != widget.selectedId ||
        oldWidget.userLat != widget.userLat ||
        oldWidget.userLng != widget.userLng ||
        oldWidget.route != widget.route;
    final routeChanged = oldWidget.route != widget.route;
    if (markersChanged) _syncFeatures();
    final followEnabled = widget.followUser && !oldWidget.followUser;
    final centerChanged =
        widget.centerLat != oldWidget.centerLat ||
        widget.centerLng != oldWidget.centerLng;
    final userChanged =
        widget.followUser &&
        (widget.userLat != oldWidget.userLat ||
            widget.userLng != oldWidget.userLng);
    final tiltChanged = widget.tilt != oldWidget.tilt;
    if (routeChanged && widget.route.length >= 2) {
      _fitRoute();
    } else if (followEnabled || centerChanged || userChanged || tiltChanged) {
      _moveTo(_targetLat, _targetLng);
    }
  }

  Future<void> _moveTo(double lat, double lng) async {
    final map = _map;
    if (map == null || !_styleReady) return;
    await map.flyTo(
      CameraOptions(
        center: Point(coordinates: Position(lng, lat)),
        zoom: widget.tilt > 0 ? 16.2 : 14.6,
        pitch: widget.tilt,
      ),
      MapAnimationOptions(duration: 700),
    );
  }

  Future<void> _fitRoute() async {
    final map = _map;
    if (map == null || !_styleReady || widget.route.length < 2) return;
    final camera = await map.cameraForCoordinates(
      [
        for (final point in widget.route)
          Point(coordinates: Position(point.lng, point.lat)),
      ],
      MbxEdgeInsets(top: 36, left: 36, bottom: 36, right: 36),
      null,
      null,
    );
    await map.flyTo(camera, MapAnimationOptions(duration: 700));
  }

  Future<void> _onMapCreated(MapboxMap map) async {
    _map = map;
    _panSubscription = map.gestures.pan.gestureEvents.listen((event) {
      if (event.gestureState == GestureState.started) _panChanged = false;
      if (event.gestureState == GestureState.changed) _panChanged = true;
      if (event.gestureState == GestureState.ended) {
        if (_panChanged && widget.followUser) widget.onUserPan?.call();
        _panChanged = false;
      }
    });
    map.addInteraction(
      TapInteraction.onMap((context) {
        final position = context.point.coordinates;
        final latitude = position.lat.toDouble();
        final longitude = position.lng.toDouble();
        Store? closest;
        var closestDistanceKm = double.infinity;
        for (final store in widget.stores) {
          final x =
              (longitude - store.lng) * math.cos(latitude * math.pi / 180);
          final y = latitude - store.lat;
          final distanceKm = math.sqrt(x * x + y * y) * 111;
          if (distanceKm < closestDistanceKm) {
            closest = store;
            closestDistanceKm = distanceKm;
          }
        }
        if (closest != null && closestDistanceKm < 0.05) {
          widget.onSelect?.call(closest);
        } else {
          widget.onPick?.call(latitude, longitude);
        }
      }),
    );
  }

  Future<void> _onStyleLoaded(StyleLoadedEventData _) async {
    final map = _map;
    if (map == null) return;
    try {
      _routeSource = GeoJsonSource(id: _routeSourceId, data: _emptyCollection);
      _storesSource = GeoJsonSource(
        id: _storesSourceId,
        data: _emptyCollection,
      );
      _selectedSource = GeoJsonSource(
        id: _selectedSourceId,
        data: _emptyCollection,
      );
      _customerSource = GeoJsonSource(
        id: _customerSourceId,
        data: _emptyCollection,
      );

      await map.addSource(_routeSource!);
      await map.addSource(_storesSource!);
      await map.addSource(_selectedSource!);
      await map.addSource(_customerSource!);
      await map.addLayer(
        LineLayer(
          id: 'localspot-route-layer',
          sourceId: _routeSourceId,
          lineColor: clay.toARGB32(),
          lineWidth: 5,
          lineCap: LineCap.ROUND,
          lineJoin: LineJoin.ROUND,
        ),
      );
      await map.addLayer(
        CircleLayer(
          id: 'localspot-stores-layer',
          sourceId: _storesSourceId,
          circleRadius: 8,
          circleColor: leafDark.toARGB32(),
          circleStrokeColor: Colors.white.toARGB32(),
          circleStrokeWidth: 2,
        ),
      );
      await map.addLayer(
        CircleLayer(
          id: 'localspot-selected-layer',
          sourceId: _selectedSourceId,
          circleRadius: 11,
          circleColor: clay.toARGB32(),
          circleStrokeColor: Colors.white.toARGB32(),
          circleStrokeWidth: 2,
        ),
      );
      await map.addLayer(
        CircleLayer(
          id: 'localspot-customer-layer',
          sourceId: _customerSourceId,
          circleRadius: 8,
          circleColor: champagne.toARGB32(),
          circleStrokeColor: Colors.white.toARGB32(),
          circleStrokeWidth: 2,
        ),
      );
      await map.logo.updateSettings(LogoSettings(enabled: true));
      await map.attribution.updateSettings(
        AttributionSettings(enabled: true, clickable: true),
      );
      _styleReady = true;
      await _syncFeatures();
      if (widget.route.length >= 2) {
        await _fitRoute();
      } else {
        await _moveTo(_targetLat, _targetLng);
      }
    } catch (error) {
      if (!mounted) return;
      setState(() => _styleError = 'Could not load map features: $error');
    }
  }

  Future<void> _syncFeatures() async {
    if (!_styleReady) return;
    final route = _routeSource;
    final stores = _storesSource;
    final selected = _selectedSource;
    final customer = _customerSource;
    if (route == null || stores == null || selected == null || customer == null) {
      return;
    }

    route.updateGeoJSON(
      widget.route.length >= 2 ? _lineString(widget.route) : _emptyCollection,
    );
    stores.updateGeoJSON(
      _featureCollection([
        for (final store in widget.stores)
          if (store.id != widget.selectedId)
            _pointFeature(store.lng, store.lat, store.id),
      ]),
    );
    final selectedStore =
        widget.stores
            .where((store) => store.id == widget.selectedId)
            .firstOrNull;
    selected.updateGeoJSON(
      _featureCollection([
        if (selectedStore != null)
          _pointFeature(selectedStore.lng, selectedStore.lat, selectedStore.id),
      ]),
    );
    final userLat = widget.userLat;
    final userLng = widget.userLng;
    customer.updateGeoJSON(
      _featureCollection([
        if (userLat != null && userLng != null)
          _pointFeature(userLng, userLat, 'customer'),
      ]),
    );
  }

  String _featureCollection(List<Map<String, Object>> features) =>
      jsonEncode({'type': 'FeatureCollection', 'features': features});

  Map<String, Object> _pointFeature(
    double longitude,
    double latitude,
    Object id,
  ) => {
    'type': 'Feature',
    'properties': {'id': id},
    'geometry': {
      'type': 'Point',
      'coordinates': [longitude, latitude],
    },
  };

  String _lineString(List<GeoPoint> points) => jsonEncode({
    'type': 'Feature',
    'properties': const {},
    'geometry': {
      'type': 'LineString',
      'coordinates': [
        for (final point in points) [point.lng, point.lat],
      ],
    },
  });

  @override
  void dispose() {
    unawaited(_panSubscription?.cancel());
    _map = null;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        MapWidget(
          styleUri: MapboxStyles.MAPBOX_STREETS,
          viewport: CameraViewportState(
            center: Point(
              coordinates: Position(widget.centerLng, widget.centerLat),
            ),
            zoom: widget.tilt > 0 ? 16.2 : 14.6,
            pitch: widget.tilt,
          ),
          onMapCreated: (map) => _onMapCreated(map),
          onStyleLoadedListener: _onStyleLoaded,
        ),
        if (_styleError != null)
          Positioned(
            left: 12,
            right: 12,
            top: 12,
            child: Material(
              color: Colors.white.withValues(alpha: .95),
              borderRadius: BorderRadius.circular(12),
              child: Padding(
                padding: const EdgeInsets.all(10),
                child: Text(
                  _styleError!,
                  style: const TextStyle(color: clay, fontSize: 12),
                ),
              ),
            ),
          ),
        if (widget.onLocateUser != null)
          Positioned(
            right: 12,
            bottom: 38,
            child: FloatingActionButton.small(
              heroTag: null,
              tooltip: 'Center on my location',
              onPressed: widget.onLocateUser,
              child: const Icon(Icons.my_location),
            ),
          ),
      ],
    );
  }
}

class _SchematicMapView extends StatelessWidget {
  const _SchematicMapView({
    required this.stores,
    required this.centerLat,
    required this.centerLng,
    required this.userLat,
    required this.userLng,
    required this.selectedId,
    required this.onSelect,
    required this.onPick,
    required this.route,
    required this.onLocateUser,
    required this.mapboxUnavailable,
  });

  final List<Store> stores;
  final double centerLat;
  final double centerLng;
  final double? userLat;
  final double? userLng;
  final int? selectedId;
  final ValueChanged<Store>? onSelect;
  final void Function(double lat, double lng)? onPick;
  final List<GeoPoint> route;
  final VoidCallback? onLocateUser;
  final bool mapboxUnavailable;

  static const _span = 0.012;

  Offset _toOffset(double lat, double lng, Size size) {
    final minLat = centerLat - _span;
    final maxLat = centerLat + _span;
    final minLng = centerLng - _span;
    final maxLng = centerLng + _span;
    final x =
        ((lng - minLng) / (maxLng - minLng)).clamp(0.04, 0.96) * size.width;
    final y =
        (1 - ((lat - minLat) / (maxLat - minLat)).clamp(0.04, 0.96)) *
        size.height;
    return Offset(x, y);
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final size = Size(constraints.maxWidth, constraints.maxHeight);
        return GestureDetector(
          onTapDown:
              onPick == null
                  ? null
                  : (details) {
                    final minLat = centerLat - _span;
                    final maxLat = centerLat + _span;
                    final minLng = centerLng - _span;
                    final maxLng = centerLng + _span;
                    final lng =
                        minLng +
                        (details.localPosition.dx / size.width) *
                            (maxLng - minLng);
                    final lat =
                        maxLat -
                        (details.localPosition.dy / size.height) *
                            (maxLat - minLat);
                    onPick!(lat, lng);
                  },
          child: Stack(
            children: [
              CustomPaint(
                size: size,
                painter: _MapPainter(
                  route: [
                    for (final point in route)
                      _toOffset(point.lat, point.lng, size),
                  ],
                ),
              ),
              ...stores.map((store) {
                final pos = _toOffset(store.lat, store.lng, size);
                final selected = store.id == selectedId;
                return Positioned(
                  left: pos.dx - 16,
                  top: pos.dy - 32,
                  child: GestureDetector(
                    onTap: () => onSelect?.call(store),
                    child: Icon(
                      Icons.location_on,
                      color: selected ? clay : leafDark,
                      size: selected ? 34 : 28,
                    ),
                  ),
                );
              }),
              if (userLat != null && userLng != null)
                Builder(
                  builder: (_) {
                    final you = _toOffset(userLat!, userLng!, size);
                    return Positioned(
                      left: you.dx - 7,
                      top: you.dy - 7,
                      child: Container(
                        width: 14,
                        height: 14,
                        decoration: BoxDecoration(
                          color: champagne,
                          shape: BoxShape.circle,
                          border: Border.all(color: Colors.white, width: 2),
                        ),
                      ),
                    );
                  },
                ),
              const Positioned(
                left: 10,
                right: 10,
                bottom: 10,
                child: Text(
                  'in-app map preview · schematic fallback, not street directions',
                  style: TextStyle(color: Colors.white, fontSize: 10),
                ),
              ),
              if (onLocateUser != null)
                Positioned(
                  right: 10,
                  top: 10,
                  child: FloatingActionButton.small(
                    heroTag: null,
                    tooltip: 'Center on my location',
                    onPressed: onLocateUser,
                    child: const Icon(Icons.my_location),
                  ),
                ),
              if (mapboxUnavailable)
                const Positioned(
                  left: 10,
                  right: 10,
                  top: 10,
                  child: Material(
                    color: Color(0xF5FFFDF8),
                    borderRadius: BorderRadius.all(Radius.circular(12)),
                    child: Padding(
                      padding: EdgeInsets.all(10),
                      child: Text(
                        'Mapbox is not configured. Run with a public token using --dart-define=ACCESS_TOKEN=pk.…',
                        style: TextStyle(color: clay, fontSize: 12),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}

class _MapPainter extends CustomPainter {
  _MapPainter({required this.route});
  final List<Offset> route;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(
      Offset.zero & size,
      Paint()..color = const Color(0xFFCAD9C4),
    );
    final road =
        Paint()
          ..color = const Color(0xFFEEE6D8)
          ..strokeWidth = 10
          ..style = PaintingStyle.stroke;
    canvas.drawLine(
      Offset(0, size.height * .42),
      Offset(size.width, size.height * .38),
      road,
    );
    canvas.drawLine(
      Offset(size.width * .32, 0),
      Offset(size.width * .4, size.height),
      road,
    );
    canvas.drawLine(
      Offset(0, size.height * .72),
      Offset(size.width, size.height * .62),
      road..strokeWidth = 7,
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(size.width * .48, size.height * .18, 70, 48),
        const Radius.circular(8),
      ),
      Paint()..color = const Color(0xFF9BB48F),
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(size.width * .12, size.height * .52, 90, 36),
        const Radius.circular(8),
      ),
      Paint()..color = const Color(0xFF8FAF86),
    );
    if (route.length >= 2) {
      final line =
          Paint()
            ..color = clay
            ..strokeWidth = 4
            ..style = PaintingStyle.stroke
            ..strokeCap = StrokeCap.round;
      final path = Path()..moveTo(route.first.dx, route.first.dy);
      for (final point in route.skip(1)) {
        path.lineTo(point.dx, point.dy);
      }
      canvas.drawPath(path, line);
    }
  }

  @override
  bool shouldRepaint(covariant _MapPainter oldDelegate) =>
      oldDelegate.route != route;
}
