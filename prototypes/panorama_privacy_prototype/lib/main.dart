import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:panorama_viewer/panorama_viewer.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'review_model.dart';
import 'review_flow.dart';
import 'review_screen.dart';
import 'spherical_mask.dart';

void main() => runApp(const PanoramaPrototypeApp());

class PanoramaPrototypeApp extends StatelessWidget {
  const PanoramaPrototypeApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'LocalSpot Panorama Privacy Prototype',
    theme: ThemeData(
      colorSchemeSeed: const Color(0xff167857),
      useMaterial3: true,
    ),
    home: const PrototypeScreen(),
  );
}

class PrototypeScreen extends StatefulWidget {
  const PrototypeScreen({
    super.key,
    this.ownerContext,
    this.initialPath,
    this.initialName,
    this.integratedMode = false,
    this.onReviewCompleted,
  });
  final AuthenticatedOwnerContext? ownerContext;
  final String? initialPath;
  final String? initialName;
  final bool integratedMode;
  final ValueChanged<PanoramaPrivacyReceipt>? onReviewCompleted;
  @override
  State<PrototypeScreen> createState() => _PrototypeScreenState();
}

class _PrototypeScreenState extends State<PrototypeScreen> {
  static const _channel = MethodChannel('localspot/panorama_privacy_prototype');
  static const _progressChannel = EventChannel(
    'localspot/panorama_privacy_prototype/progress',
  );
  static const _processingVersion = 'localspot-panorama-local-v2';
  final _picker = ImagePicker();
  String? _source;
  String? _sourceName;
  String? _sourceSha256;
  String? _derivative; // bounded-size viewer preview
  String? _derivativePath; // full-resolution JPEG used for hashing and review
  String? _derivativeSha256;
  List<Map<String, double>> _automaticRegions = [];
  List<Map<String, double>> _manualRegions = [];
  List<List<Map<String, double>>> _undo = [];
  List<List<Map<String, double>>> _redo = [];
  int _faceCount = 0;
  int _personCount = 0;
  int? _elapsedMs;
  int? _outputWidth;
  int? _outputHeight;
  int? _outputBytes;
  String? _error;
  bool _working = false;
  bool _derivativeOutdated = false;
  int _progressCurrent = 0;
  int _progressTotal = 0;
  String _progressStage = 'Preparing';
  String? _reviewedDigest;
  String? _reviewTimestamp;
  final _manualEditorKey = GlobalKey();
  bool _resumeReviewAfterEdit = false;
  final _reviewStore = LocalOwnerReviewStore();
  bool _initialPathLoaded = false;

  List<Map<String, double>> get _allRegions => [
    ..._automaticRegions,
    ..._manualRegions,
  ];

  @override
  void initState() {
    super.initState();
    _progressChannel.receiveBroadcastStream().listen(
      (event) {
        if (!mounted || event is! Map) return;
        setState(() {
          _progressCurrent = event['current'] as int? ?? 0;
          _progressTotal = event['total'] as int? ?? 0;
          _progressStage = event['stage'] as String? ?? 'Processing';
        });
      },
      onError: (Object error) {
        if (mounted) {
          setState(() => _error = 'Progress reporting failed: $error');
        }
      },
    );
    if (widget.initialPath != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || _initialPathLoaded) return;
        _initialPathLoaded = true;
        _setSource(widget.initialPath!, name: widget.initialName);
      });
    }
  }

  Future<String> _hashFile(String path) async {
    final accumulator = _DigestSink();
    final converter = sha256.startChunkedConversion(accumulator);
    await for (final chunk in File(path).openRead()) {
      converter.add(chunk);
    }
    converter.close();
    return accumulator.digest?.toString() ??
        (throw StateError('Could not hash the file.'));
  }

  Future<void> _setSource(String path, {String? name}) async {
    try {
      final oldDigest = _derivativeSha256;
      final file = File(path);
      if (!await file.exists()) {
        throw StateError('Selected panorama is no longer available.');
      }
      final digest = await _hashFile(path);
      final prefs = await SharedPreferences.getInstance();
      final saved = prefs.getString('pano.manual.$digest');
      final restored = <Map<String, double>>[];
      if (saved != null) {
        for (final item in (jsonDecode(saved) as List)) {
          if (item is Map) restored.add(_readRegion(item));
        }
      }
      if (!mounted) return;
      if (oldDigest != null) await _reviewStore.invalidate(oldDigest);
      setState(() {
        _source = path;
        _sourceName = name ?? file.uri.pathSegments.last;
        _sourceSha256 = digest;
        _derivative = null;
        _derivativePath = null;
        _derivativeOutdated = false;
        _derivativeSha256 = null;
        _outputWidth = null;
        _outputHeight = null;
        _outputBytes = null;
        _automaticRegions = [];
        _manualRegions = restored;
        _undo = [];
        _redo = [];
        _reviewedDigest = null;
        _reviewTimestamp = null;
        _error = null;
      });
    } catch (error) {
      if (mounted) setState(() => _error = 'Could not load panorama: $error');
    }
  }

  Map<String, double> _readRegion(Map<dynamic, dynamic> value) => {
    'x': (value['x'] as num).toDouble(),
    'y': (value['y'] as num).toDouble(),
    'w': (value['w'] as num).toDouble(),
    'h': (value['h'] as num).toDouble(),
  };

  Future<void> _choose() async {
    try {
      final picked = await _picker.pickImage(
        source: ImageSource.gallery,
        requestFullMetadata: false,
      );
      if (picked != null) await _setSource(picked.path);
    } catch (error) {
      if (mounted) {
        setState(() => _error = 'Could not open the selected panorama: $error');
      }
    }
  }

  Future<void> _chooseDebugFixture() async {
    if (!kDebugMode) return;
    try {
      final fixtures =
          await _channel.invokeListMethod<Map<Object?, Object?>>(
            'listDebugFixtures',
          ) ??
          [];
      if (!mounted) return;
      if (fixtures.isEmpty) {
        setState(
          () => _error = 'No debug fixtures found in this debuggable app\'s app-private files/test-fixtures directory.',
        );
        return;
      }
      final selected = await showDialog<Map<Object?, Object?>>(
        context: context,
        builder: (context) => SimpleDialog(
          title: const Text('Local debug fixtures'),
          children: [
            for (final fixture in fixtures)
              SimpleDialogOption(
                onPressed: () => Navigator.pop(context, fixture),
                child: Text(
                  '${fixture['name']}\n${fixture['width']} × ${fixture['height']} · ${fixture['bytes']} bytes\nSHA-256 ${fixture['sha256']}',
                ),
              ),
          ],
        ),
      );
      if (selected == null) return;
      final path = selected['path'] as String;
      final sourceBytes = await File(path).readAsBytes();
      final hash = sha256.convert(sourceBytes).toString();
      if (hash != selected['sha256']) {
        throw StateError('Fixture digest changed while loading.');
      }
      await _setSource(path, name: selected['name'] as String);
    } catch (error) {
      if (mounted) setState(() => _error = 'Debug fixture load failed: $error');
    }
  }

  Future<void> _persistManualRegions() async {
    final digest = _sourceSha256;
    if (digest == null) return;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('pano.manual.$digest', jsonEncode(_manualRegions));
  }

  void _snapshotForUndo() {
    _undo = [
      ..._undo,
      _manualRegions.map((region) => Map<String, double>.from(region)).toList(),
    ];
    if (_undo.length > 50) _undo = _undo.sublist(_undo.length - 50);
    _redo = [];
  }

  void _changedMasks(List<Map<String, double>> next) {
    final oldDigest = _derivativeSha256;
    if (oldDigest != null) _reviewStore.invalidate(oldDigest);
    setState(() {
      _manualRegions = next;
      _derivativeOutdated = _derivative != null;
      _reviewedDigest = null;
      _reviewTimestamp = null;
      _derivativeSha256 = null;
    });
    _persistManualRegions();
  }

  void _addManualMask(TapUpDetails details, BoxConstraints size) {
    _snapshotForUndo();
    final x = (details.localPosition.dx / size.maxWidth).clamp(0.0, 1.0);
    final y = (details.localPosition.dy / (size.maxWidth / 2)).clamp(0.0, 1.0);
    _changedMasks([
      ..._manualRegions,
      {'x': x, 'y': (y - .05).clamp(0.0, .88), 'w': .06, 'h': .12},
    ]);
  }

  void _moveManual(int index, double dx, double dy, double mapWidth) {
    final current = _manualRegions[index];
    final next = _manualRegions
        .map((region) => Map<String, double>.from(region))
        .toList();
    next[index] = SphericalMaskGeometry.move(
      current,
      dx / mapWidth,
      dy / (mapWidth / 2),
    );
    setState(() {
      _manualRegions = next;
      _derivativeOutdated = _derivative != null;
      _reviewedDigest = null;
      _reviewTimestamp = null;
    });
  }

  void _resizeManual(int index, double dx, double dy, double mapWidth) {
    final current = _manualRegions[index];
    final next = _manualRegions
        .map((region) => Map<String, double>.from(region))
        .toList();
    next[index] = SphericalMaskGeometry.resize(
      current,
      dx / mapWidth,
      dy / (mapWidth / 2),
    );
    setState(() {
      _manualRegions = next;
      _derivativeOutdated = _derivative != null;
      _reviewedDigest = null;
      _reviewTimestamp = null;
    });
  }

  void _removeManual(int index) {
    _snapshotForUndo();
    final next =
        _manualRegions
            .map((region) => Map<String, double>.from(region))
            .toList()
          ..removeAt(index);
    _changedMasks(next);
  }

  Future<void> _undoMasks() async {
    if (_undo.isEmpty) return;
    final oldDigest = _derivativeSha256;
    if (oldDigest != null) await _reviewStore.invalidate(oldDigest);
    setState(() {
      _redo = [
        ..._redo,
        _manualRegions
            .map((region) => Map<String, double>.from(region))
            .toList(),
      ];
      _manualRegions = _undo.last;
      _undo = _undo.sublist(0, _undo.length - 1);
      _reviewedDigest = null;
      _reviewTimestamp = null;
      _derivativeSha256 = null;
      _derivativeOutdated = _derivative != null;
    });
    await _persistManualRegions();
  }

  Future<void> _redoMasks() async {
    if (_redo.isEmpty) return;
    final oldDigest = _derivativeSha256;
    if (oldDigest != null) await _reviewStore.invalidate(oldDigest);
    setState(() {
      _undo = [
        ..._undo,
        _manualRegions
            .map((region) => Map<String, double>.from(region))
            .toList(),
      ];
      _manualRegions = _redo.last;
      _redo = _redo.sublist(0, _redo.length - 1);
      _reviewedDigest = null;
      _reviewTimestamp = null;
      _derivativeSha256 = null;
      _derivativeOutdated = _derivative != null;
    });
    await _persistManualRegions();
  }

  Future<void> _process() async {
    final source = _source;
    if (source == null) return;
    setState(() {
      _working = true;
      _progressCurrent = 0;
      _progressTotal = 14;
      _progressStage = 'Preparing';
      _error = null;
    });
    try {
      final response = await _channel.invokeMapMethod<String, dynamic>(
        'process',
        {'path': source},
      );
      if (response == null) {
        throw StateError('The native processor returned no result.');
      }
      final output = response['path'] as String?;
      final preview = response['previewPath'] as String?;
      if (output == null ||
          preview == null ||
          !await File(output).exists() ||
          !await File(preview).exists() ||
          await File(output).length() == 0 ||
          await File(preview).length() == 0) {
        throw StateError(
          'No processed derivative was written. Processing is not complete.',
        );
      }
      final automatic = [
        for (final value in (response['regions'] as List? ?? const []))
          if (value is Map) _readRegion(value),
      ];
      final digest = await _hashFile(output);
      final outputBytes = await File(output).length();
      final previousDigest = _derivativeSha256;
      if (previousDigest != null) await _reviewStore.invalidate(previousDigest);
      await _reviewStore.invalidate(digest);
      setState(() {
        _derivative = preview;
        _derivativePath = output;
        _derivativeOutdated = false;
        _derivativeSha256 = digest;
        _outputWidth = response['width'] as int?;
        _outputHeight = response['height'] as int?;
        _outputBytes = outputBytes;
        _faceCount = response['faceDetections'] as int? ?? 0;
        _personCount = response['personDetections'] as int? ?? 0;
        _elapsedMs = response['elapsedMs'] as int?;
        _automaticRegions = automatic;
        _reviewedDigest = null;
        _reviewTimestamp = null;
      });
      if (_manualRegions.isNotEmpty) await _applyManualMasks();
    } catch (error) {
      setState(() {
        _derivative = null;
        _derivativePath = null;
        _derivativeSha256 = null;
        _error = error.toString();
      });
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  Future<void> _cancelProcessing() async {
    try {
      await _channel.invokeMethod<void>('cancel');
    } on PlatformException catch (error) {
      if (mounted) {
        setState(
          () => _error = 'Cancellation request failed: ${error.message}',
        );
      }
    }
  }

  Future<void> _applyManualMasks() async {
    final source = _source;
    if (source == null || _allRegions.isEmpty) return;
    final previousDigest = _derivativeSha256;
    setState(() {
      _working = true;
      _error = null;
      _derivativeSha256 = null;
      _reviewedDigest = null;
      _reviewTimestamp = null;
    });
    try {
      final response = await _channel.invokeMapMethod<String, dynamic>(
        'applyMasks',
        {'path': source, 'masks': _allRegions},
      );
      final output = response?['path'] as String?;
      final preview = response?['previewPath'] as String?;
      if (output == null ||
          preview == null ||
          !await File(output).exists() ||
          !await File(preview).exists() ||
          await File(output).length() == 0) {
        throw StateError('The corrected derivative was not written.');
      }
      final digest = await _hashFile(output);
      final outputBytes = await File(output).length();
      if (previousDigest != null) await _reviewStore.invalidate(previousDigest);
      await _reviewStore.invalidate(digest);
      setState(() {
        _derivative = preview;
        _derivativePath = output;
        _derivativeSha256 = digest;
        _outputWidth = response?['width'] as int?;
        _outputHeight = response?['height'] as int?;
        _outputBytes = outputBytes;
        _derivativeOutdated = false;
      });
    } catch (error) {
      setState(() {
        _derivative = null;
        _derivativePath = null;
        _error = error.toString();
      });
    } finally {
      if (mounted) {
        setState(() => _working = false);
        if (_resumeReviewAfterEdit &&
            _derivativePath != null &&
            !_derivativeOutdated) {
          _resumeReviewAfterEdit = false;
          await _openOwnerReview();
        }
      }
    }
  }

  Future<void> _openOwnerReview() async {
    final path = _derivativePath;
    final digest = _derivativeSha256;
    if (!mounted ||
        path == null ||
        digest == null ||
        _working ||
        _derivativeOutdated) {
      return;
    }
    final navigator = Navigator.of(context);
    if (!await File(path).exists()) return;
    final coverage = await _reviewStore.loadCoverage(digest);
    if (!mounted) return;
    final result = await navigator.push<String>(
      MaterialPageRoute(
        builder: (_) => PanoramaReviewScreen(
          derivativePath: path,
          digest: digest,
          processingVersion: _processingVersion,
          initialInspected: coverage,
          persistCoverage: (reviewDigest, inspected) async {
            if (reviewDigest == _derivativeSha256) {
              await _reviewStore.saveCoverage(
                derivativeSha256: reviewDigest,
                inspected: inspected,
              );
            }
          },
          onApprove: (reviewDigest) async {
            final latestPath = _derivativePath;
            if (!mounted ||
                _working ||
                _derivativeOutdated ||
                latestPath == null ||
                !await File(latestPath).exists()) {
              return false;
            }
            final actualDigest = await _hashFile(latestPath);
            if (actualDigest != reviewDigest ||
                actualDigest != _derivativeSha256) {
              await _reviewStore.invalidate(reviewDigest);
              if (mounted) {
                setState(() {
                  _derivativeSha256 = actualDigest;
                  _reviewedDigest = null;
                  _reviewTimestamp = null;
                });
              }
              return false;
            }
            final owner = widget.ownerContext;
            if (owner != null) {
              await _reviewStore.save(
                owner: owner,
                derivativeSha256: actualDigest,
                processingVersion: _processingVersion,
                approved: true,
              );
            } else {
              await _reviewStore.saveLocalPrototype(
                derivativeSha256: actualDigest,
                processingVersion: _processingVersion,
                approved: true,
              );
            }
            if (mounted) {
              setState(() {
                _reviewedDigest = actualDigest;
                _reviewTimestamp = DateTime.now().toUtc().toIso8601String();
              });
            }
            return true;
          },
          closeAfterApproval: widget.integratedMode,
        ),
      ),
    );
    if (result == 'approved' && mounted && widget.integratedMode) {
      final inspected = await _reviewStore.loadCoverage(digest);
      if (!mounted) return;
      final receipt = PanoramaPrivacyReceipt(
        sourcePath: _source!,
        sourceName: _sourceName ?? File(_source!).uri.pathSegments.last,
        sourceSha256: _sourceSha256!,
        derivativePath: path,
        derivativeSha256: digest,
        processingVersion: _processingVersion,
        reviewedAt: DateTime.now().toUtc(),
        inspectedDirections: inspected,
        acknowledgedMissRisk: true,
        acknowledgedManualInspection: true,
      );
      widget.onReviewCompleted?.call(receipt);
      Navigator.of(context).pop(receipt);
      return;
    }
    if (!mounted || result != 'edit') return;
    _resumeReviewAfterEdit = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final editorContext = _manualEditorKey.currentContext;
      if (editorContext != null) {
        Scrollable.ensureVisible(
          editorContext,
          duration: const Duration(milliseconds: 350),
          alignment: .15,
        );
      }
    });
  }

  List<(double, double)> _horizontalSegments(double x, double w) {
    return SphericalMaskGeometry.horizontalSegments(x, w);
  }

  Widget _regionOverlay(
    Map<String, double> region,
    int index,
    double mapWidth,
    double mapHeight,
  ) {
    final segments = _horizontalSegments(region['x']!, region['w']!);
    return Stack(
      children: [
        for (var part = 0; part < segments.length; part++)
          Positioned(
            left: segments[part].$1 * mapWidth,
            top: region['y']! * mapHeight,
            width: segments[part].$2 * mapWidth,
            height: region['h']! * mapHeight,
            child: Builder(
              builder: (context) {
                var resizing = false;
                return GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onPanStart: (details) {
                    final box = context.findRenderObject()! as RenderBox;
                    final size = box.size;
                    // Treat the bottom-right 40% as the resize handle; this is much
                    // easier to hit on a phone than the small painted corner icon.
                    resizing =
                        details.localPosition.dx >= size.width * .6 &&
                        details.localPosition.dy >= size.height * .6;
                    _snapshotForUndo();
                  },
                  onPanUpdate: (details) {
                    if (resizing) {
                      _resizeManual(
                        index,
                        details.delta.dx,
                        details.delta.dy,
                        mapWidth,
                      );
                    } else {
                      _moveManual(
                        index,
                        details.delta.dx,
                        details.delta.dy,
                        mapWidth,
                      );
                    }
                  },
                  onPanEnd: (_) {
                    _changedMasks(
                      _manualRegions
                          .map((region) => Map<String, double>.from(region))
                          .toList(),
                    );
                  },
                  child: Container(
                    decoration: BoxDecoration(
                      color: Colors.orange.withValues(alpha: .18),
                      border: Border.all(color: Colors.orange, width: 2),
                    ),
                    child: part == segments.length - 1
                        ? const Align(
                            alignment: Alignment.bottomRight,
                            child: IgnorePointer(
                              child: DecoratedBox(
                                decoration: BoxDecoration(
                                  color: Colors.orange,
                                  shape: BoxShape.circle,
                                ),
                                child: SizedBox(
                                  width: 20,
                                  height: 20,
                                  child: Icon(
                                    Icons.open_in_full,
                                    size: 12,
                                    color: Colors.white,
                                  ),
                                ),
                              ),
                            ),
                          )
                        : null,
                  ),
                );
              },
            ),
          ),
      ],
    );
  }

  Widget _manualEditor(double mapWidth) {
    final mapHeight = mapWidth / 2;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Manual blur corrections',
          style: Theme.of(context).textTheme.titleMedium,
        ),
        const Text(
          'Tap to add a spherical region. Drag a region to move it; drag its corner handle to resize. Seam-crossing regions wrap onto both image edges.',
        ),
        Row(
          children: [
            TextButton.icon(
              onPressed: _undo.isEmpty ? null : _undoMasks,
              icon: const Icon(Icons.undo),
              label: const Text('Undo'),
            ),
            TextButton.icon(
              onPressed: _redo.isEmpty ? null : _redoMasks,
              icon: const Icon(Icons.redo),
              label: const Text('Redo'),
            ),
          ],
        ),
        GestureDetector(
          onTapUp: (details) =>
              _addManualMask(details, BoxConstraints(maxWidth: mapWidth)),
          child: SizedBox(
            width: mapWidth,
            height: mapHeight,
            child: Stack(
              children: [
                Positioned.fill(
                  child: Image.file(
                    File(_source!),
                    fit: BoxFit.fill,
                    cacheWidth: 2048,
                  ),
                ),
                for (final region in _automaticRegions)
                  for (final segment in _horizontalSegments(
                    region['x']!,
                    region['w']!,
                  ))
                    Positioned(
                      left: segment.$1 * mapWidth,
                      top: region['y']! * mapHeight,
                      width: segment.$2 * mapWidth,
                      height: region['h']! * mapHeight,
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          color: Colors.red.withValues(alpha: .18),
                          border: Border.all(color: Colors.red, width: 1),
                        ),
                      ),
                    ),
                for (var i = 0; i < _manualRegions.length; i++)
                  _regionOverlay(_manualRegions[i], i, mapWidth, mapHeight),
              ],
            ),
          ),
        ),
        for (var i = 0; i < _manualRegions.length; i++)
          ListTile(
            dense: true,
            leading: const Icon(Icons.blur_on, color: Colors.orange),
            title: Text(
              'Manual mask ${i + 1} · lon ${(_manualRegions[i]['x']! * 360 - 180).toStringAsFixed(1)}° · lat ${(90 - _manualRegions[i]['y']! * 180).toStringAsFixed(1)}° · span ${(_manualRegions[i]['w']! * 360).toStringAsFixed(1)}° × ${(_manualRegions[i]['h']! * 180).toStringAsFixed(1)}°',
            ),
            trailing: IconButton(
              tooltip: 'Remove blur region',
              onPressed: () => _removeManual(i),
              icon: const Icon(Icons.delete_outline),
            ),
          ),
        OutlinedButton.icon(
          onPressed: _working || _allRegions.isEmpty ? null : _applyManualMasks,
          icon: const Icon(Icons.blur_on),
          label: const Text('Regenerate derivative with all corrections'),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final derivative = _derivative;
    return Scaffold(
      appBar: AppBar(
        title: Text(
          widget.integratedMode
              ? 'Panorama privacy review'
              : 'Panorama privacy lab',
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            child: Padding(
              padding: EdgeInsets.all(14),
              child: Text(
                widget.integratedMode
                    ? 'On-device processing and owner review are local attestations. Firebase must verify the uploaded derivative before it can be published.'
                    : 'Local prototype only. Detection and blurring run on this Android device. Local review is not authenticated or sent to Firebase and never enables publishing.',
              ),
            ),
          ),
          const SizedBox(height: 12),
          if (!widget.integratedMode)
            FilledButton.icon(
              onPressed: _working ? null : _choose,
              icon: const Icon(Icons.photo_library_outlined),
              label: const Text('Choose a 2:1 panorama'),
            ),
          if (kDebugMode)
            OutlinedButton.icon(
              onPressed: _working ? null : _chooseDebugFixture,
              icon: const Icon(Icons.science_outlined),
              label: const Text('Load local debug fixture (debug build only)'),
            ),
          if (_source != null) ...[
            Text(
              'Source: $_sourceName · SHA-256 ${_sourceSha256 ?? 'calculating'}',
            ),
            OutlinedButton.icon(
              onPressed: _working ? null : _process,
              icon: const Icon(Icons.shield_outlined),
              label: const Text('Detect and blur on device'),
            ),
          ],
          if (_working) ...[
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 10),
              child: LinearProgressIndicator(
                value: _progressTotal == 0
                    ? null
                    : _progressCurrent / _progressTotal,
              ),
            ),
            Text('$_progressStage: $_progressCurrent / $_progressTotal'),
            TextButton.icon(
              onPressed: _cancelProcessing,
              icon: const Icon(Icons.cancel_outlined),
              label: const Text('Cancel processing'),
            ),
          ],
          if (_error != null)
            Card(
              color: Theme.of(context).colorScheme.errorContainer,
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Text('Processing failed: $_error'),
              ),
            ),
          if (derivative != null) ...[
            const SizedBox(height: 10),
            Text(
              'Inspect the full sphere — drag to rotate and tilt to the poles.',
              style: Theme.of(context).textTheme.titleSmall,
            ),
            const SizedBox(height: 6),
            SizedBox(
              height: 240,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: PanoramaViewer(
                  key: ValueKey(_derivativeSha256),
                  child: Image.file(File(derivative), fit: BoxFit.cover),
                ),
              ),
            ),
            const SizedBox(height: 10),
            Text(
              'Detections: $_faceCount faces, $_personCount people · ${_elapsedMs ?? 0} ms · ${_allRegions.length} total blur regions',
            ),
            if (_derivativeOutdated)
              const Text(
                'Corrections changed. This preview is stale and cannot be reviewed until you regenerate the derivative.',
              ),
            if (_derivativeSha256 != null)
              SelectableText('Derivative SHA-256: $_derivativeSha256'),
            if (_outputWidth != null)
              Text(
                'Derivative dimensions: $_outputWidth × $_outputHeight · ${_outputBytes ?? 0} bytes',
              ),
            const SizedBox(height: 14),
            KeyedSubtree(
              key: _manualEditorKey,
              child: LayoutBuilder(
                builder: (context, constraints) =>
                    _manualEditor(constraints.maxWidth),
              ),
            ),
            const SizedBox(height: 12),
            const Text(
              'Automatic detection can miss people, including small, distant, or occluded people. Inspect the entire sphere and add corrections. Owner review is an acknowledgement, not a guarantee.',
            ),
            OutlinedButton.icon(
              key: const ValueKey('open-owner-review'),
              onPressed:
                  _working || _derivativeOutdated || _derivativeSha256 == null
                  ? null
                  : _openOwnerReview,
              icon: const Icon(Icons.public),
              label: Text(
                _reviewTimestamp == null
                    ? 'Start complete 360° owner review'
                    : 'Review this processed derivative again',
              ),
            ),
            if (_reviewTimestamp != null)
              Text(
                'Local prototype review ${widget.ownerContext == null ? '(no authenticated UID)' : 'for authenticated owner'} at $_reviewTimestamp · digest ${_reviewedDigest ?? ''} · version $_processingVersion',
              ),
          ],
          const SizedBox(height: 16),
        ],
      ),
    );
  }
}

class _DigestSink implements Sink<Digest> {
  Digest? digest;
  @override
  void add(Digest value) => digest = value;
  @override
  void close() {}
}
