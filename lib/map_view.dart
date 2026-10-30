import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:maplibre_gl/maplibre_gl.dart';

import 'models.dart';
import 'theme.dart';

const mapStyleUrl = String.fromEnvironment(
  'MAP_STYLE_URL',
  defaultValue: 'https://tiles.openfreemap.org/styles/liberty',
);

bool inWidgetTest() => WidgetsBinding.instance.runtimeType.toString().contains('Test');

bool useNativeMapLibre() {
  if (inWidgetTest()) return false;
  if (kIsWeb) return true;
  return defaultTargetPlatform == TargetPlatform.android || defaultTargetPlatform == TargetPlatform.iOS;
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
  final List<GeoPoint> route;
  final bool followUser;
  final double tilt;
  final double height;

  @override
  Widget build(BuildContext context) {
    final child = useNativeMapLibre()
        ? _MapLibreCanvas(
            stores: stores,
            centerLat: centerLat,
            centerLng: centerLng,
            userLat: userLat,
            userLng: userLng,
            selectedId: selectedId,
            onSelect: onSelect,
            onPick: onPick,
            onUserPan: onUserPan,
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
          );
    return SizedBox(height: height, child: ClipRRect(borderRadius: BorderRadius.circular(18), child: child));
  }
}

class _MapLibreCanvas extends StatefulWidget {
  const _MapLibreCanvas({
    required this.stores,
    required this.centerLat,
    required this.centerLng,
    required this.userLat,
    required this.userLng,
    required this.selectedId,
    required this.onSelect,
    required this.onPick,
    required this.onUserPan,
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
  final List<GeoPoint> route;
  final bool followUser;
  final double tilt;

  @override
  State<_MapLibreCanvas> createState() => _MapLibreCanvasState();
}

class _MapLibreCanvasState extends State<_MapLibreCanvas> {
  MapLibreMapController? _controller;
  var _styleReady = false;
  var _programmaticMove = false;
  var _syncGen = 0;
  final _circles = <String, int>{};

  double get _targetLat => widget.followUser ? (widget.userLat ?? widget.centerLat) : widget.centerLat;
  double get _targetLng => widget.followUser ? (widget.userLng ?? widget.centerLng) : widget.centerLng;

  @override
  void didUpdateWidget(covariant _MapLibreCanvas oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!_styleReady) return;
    _syncAnnotations();
    final followEnabled = widget.followUser && !oldWidget.followUser;
    final centerChanged = widget.centerLat != oldWidget.centerLat || widget.centerLng != oldWidget.centerLng;
    final userChanged = widget.followUser && (widget.userLat != oldWidget.userLat || widget.userLng != oldWidget.userLng);
    final tiltChanged = widget.tilt != oldWidget.tilt;
    if (followEnabled || centerChanged || userChanged || tiltChanged) {
      _moveTo(_targetLat, _targetLng);
    }
  }

  Future<void> _moveTo(double lat, double lng) async {
    final controller = _controller;
    if (controller == null || !_styleReady) return;
    _programmaticMove = true;
    try {
      await controller.animateCamera(CameraUpdate.newCameraPosition(CameraPosition(
        target: LatLng(lat, lng),
        zoom: widget.tilt > 0 ? 16.2 : 14.6,
        tilt: widget.tilt,
      )));
    } catch (_) {}
    if (mounted) _programmaticMove = false;
  }

  Future<void> _syncAnnotations() async {
    final controller = _controller;
    if (controller == null || !_styleReady) return;
    final gen = ++_syncGen;
    try {
      await controller.clearCircles();
      await controller.clearLines();
    } catch (_) {}
    if (!mounted || gen != _syncGen) return;
    _circles.clear();
    if (widget.route.length >= 2) {
      await controller.addLine(LineOptions(
        geometry: [for (final point in widget.route) LatLng(point.lat, point.lng)],
        lineColor: '#9E514B',
        lineWidth: 4.5,
        lineOpacity: 0.92,
      ));
    }
    if (!mounted || gen != _syncGen) return;
    for (final store in widget.stores) {
      if (!mounted || gen != _syncGen) return;
      final selected = store.id == widget.selectedId;
      final circle = await controller.addCircle(
        CircleOptions(
          geometry: LatLng(store.lat, store.lng),
          circleRadius: selected ? 11 : 8,
          circleColor: selected ? '#9E514B' : '#1E4A36',
          circleStrokeColor: '#FFFFFF',
          circleStrokeWidth: 2,
        ),
        {'storeId': store.id},
      );
      _circles[circle.id] = store.id;
    }
    final userLat = widget.userLat;
    final userLng = widget.userLng;
    if (userLat != null && userLng != null) {
      await controller.addCircle(CircleOptions(
        geometry: LatLng(userLat, userLng),
        circleRadius: 7,
        circleColor: '#C4A56B',
        circleStrokeColor: '#FFFFFF',
        circleStrokeWidth: 2,
      ));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        MapLibreMap(
          styleString: mapStyleUrl,
          initialCameraPosition: CameraPosition(
            target: LatLng(widget.centerLat, widget.centerLng),
            zoom: widget.tilt > 0 ? 16.2 : 14.6,
            tilt: widget.tilt,
          ),
          compassEnabled: true,
          myLocationEnabled: false,
          trackCameraPosition: true,
          onMapCreated: (controller) {
            _controller = controller;
            controller.onCircleTapped.add((circle) {
              final id = _circles[circle.id] ?? circle.data?['storeId'] as int?;
              if (id == null) return;
              final store = widget.stores.where((item) => item.id == id).firstOrNull;
              if (store != null) widget.onSelect?.call(store);
            });
          },
          onStyleLoadedCallback: () {
            _styleReady = true;
            _syncAnnotations();
            _moveTo(_targetLat, _targetLng);
          },
          onMapClick: (point, latLng) => widget.onPick?.call(latLng.latitude, latLng.longitude),
          onCameraIdle: () {
            if (_programmaticMove || widget.followUser) return;
            widget.onUserPan?.call();
          },
        ),
        const Positioned(
          left: 8,
          right: 8,
          bottom: 8,
          child: Text(
            '© OpenStreetMap © OpenFreeMap · MapLibre in LocalSpot',
            style: TextStyle(fontSize: 10, color: Color(0xFF3A3A3A)),
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

  static const _span = 0.012;

  Offset _toOffset(double lat, double lng, Size size) {
    final minLat = centerLat - _span;
    final maxLat = centerLat + _span;
    final minLng = centerLng - _span;
    final maxLng = centerLng + _span;
    final x = ((lng - minLng) / (maxLng - minLng)).clamp(0.04, 0.96) * size.width;
    final y = (1 - ((lat - minLat) / (maxLat - minLat)).clamp(0.04, 0.96)) * size.height;
    return Offset(x, y);
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final size = Size(constraints.maxWidth, constraints.maxHeight);
        return GestureDetector(
          onTapDown: onPick == null
              ? null
              : (details) {
                  final minLat = centerLat - _span;
                  final maxLat = centerLat + _span;
                  final minLng = centerLng - _span;
                  final maxLng = centerLng + _span;
                  final lng = minLng + (details.localPosition.dx / size.width) * (maxLng - minLng);
                  final lat = maxLat - (details.localPosition.dy / size.height) * (maxLat - minLat);
                  onPick!(lat, lng);
                },
          child: Stack(
            children: [
              CustomPaint(
                size: size,
                painter: _MapPainter(
                  route: [for (final point in route) _toOffset(point.lat, point.lng, size)],
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
                    child: Icon(Icons.location_on, color: selected ? clay : leafDark, size: selected ? 34 : 28),
                  ),
                );
              }),
              Builder(builder: (_) {
                final lat = userLat ?? centerLat;
                final lng = userLng ?? centerLng;
                final you = _toOffset(lat, lng, size);
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
              }),
              const Positioned(
                left: 10,
                right: 10,
                bottom: 10,
                child: Text(
                  '© OpenStreetMap · in-app map fallback (MapLibre on Android/iOS)',
                  style: TextStyle(color: Colors.white, fontSize: 10),
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
    canvas.drawRect(Offset.zero & size, Paint()..color = const Color(0xFFCAD9C4));
    final road = Paint()
      ..color = const Color(0xFFEEE6D8)
      ..strokeWidth = 10
      ..style = PaintingStyle.stroke;
    canvas.drawLine(Offset(0, size.height * .42), Offset(size.width, size.height * .38), road);
    canvas.drawLine(Offset(size.width * .32, 0), Offset(size.width * .4, size.height), road);
    canvas.drawLine(Offset(0, size.height * .72), Offset(size.width, size.height * .62), road..strokeWidth = 7);
    canvas.drawRRect(
      RRect.fromRectAndRadius(Rect.fromLTWH(size.width * .48, size.height * .18, 70, 48), const Radius.circular(8)),
      Paint()..color = const Color(0xFF9BB48F),
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(Rect.fromLTWH(size.width * .12, size.height * .52, 90, 36), const Radius.circular(8)),
      Paint()..color = const Color(0xFF8FAF86),
    );
    if (route.length >= 2) {
      final line = Paint()
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
  bool shouldRepaint(covariant _MapPainter oldDelegate) => oldDelegate.route != route;
}
