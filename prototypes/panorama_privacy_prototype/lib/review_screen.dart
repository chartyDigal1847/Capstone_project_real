import 'dart:io';

import 'package:flutter/material.dart';
import 'package:panorama_viewer/panorama_viewer.dart';

import 'review_flow.dart';

typedef ReviewViewerBuilder = Widget Function(
  BuildContext context,
  PanoramaController controller,
  int selectedDirection,
  void Function(double longitude, double latitude, double tilt) onViewChanged,
);

class PanoramaReviewScreen extends StatefulWidget {
  const PanoramaReviewScreen({
    super.key,
    required this.derivativePath,
    required this.digest,
    required this.processingVersion,
    required this.initialInspected,
    required this.persistCoverage,
    required this.onApprove,
    this.viewerBuilder,
    this.closeAfterApproval = false,
  });
  final String derivativePath;
  final String digest;
  final String processingVersion;
  final Set<int> initialInspected;
  final Future<void> Function(String digest, Set<int> inspected)
  persistCoverage;
  final Future<bool> Function(String digest) onApprove;
  final ReviewViewerBuilder? viewerBuilder;
  final bool closeAfterApproval;

  @override
  State<PanoramaReviewScreen> createState() => _PanoramaReviewScreenState();
}

class _PanoramaReviewScreenState extends State<PanoramaReviewScreen> {
  late final PanoramaController _controller;
  late final ReviewCoverage _coverage;
  int _selected = 0;
  bool _directionPresented = false;
  bool _missRisk = false;
  bool _manualInspection = false;
  bool _saving = false;
  bool _approved = false;
  bool _invalidated = false;
  String? _message;

  @override
  void initState() {
    super.initState();
    _controller = PanoramaController();
    _coverage = ReviewCoverage(widget.initialInspected);
    if (!_coverage.isComplete) {
      _selected = _coverage.nextUninspected.index;
      WidgetsBinding.instance.addPostFrameCallback((_) => _goTo(_selected));
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _goTo(int index) {
    setState(() {
      _selected = index;
      _directionPresented = false;
      _message = null;
    });
    final direction = reviewDirections[index];
    _controller.setView(direction.latitude, direction.longitude);
  }

  bool _near(double a, double b) {
    final diff = (a - b).abs() % 360;
    return diff <= 12 || diff >= 348;
  }

  void _onViewChanged(double longitude, double latitude, double tilt) {
    final target = reviewDirections[_selected];
    final shown =
        _near(longitude, target.longitude) &&
        (latitude - target.latitude).abs() <= 12;
    if (shown != _directionPresented && mounted)
      setState(() => _directionPresented = shown);
  }

  Future<void> _markAndAdvance() async {
    if (!_directionPresented || _coverage.inspected.contains(_selected)) return;
    setState(() {
      _coverage.markInspected(_selected);
      _message = null;
    });
    await widget.persistCoverage(widget.digest, {..._coverage.inspected});
    if (!mounted) return;
    if (!_coverage.isComplete) {
      final next = _coverage.nextUninspected;
      _goTo(next.index);
    }
  }

  Future<void> _approve() async {
    final eligible = ReviewEligibility(
      allDirectionsInspected: _coverage.isComplete,
      derivativeExists: File(widget.derivativePath).existsSync(),
      digestMatches: true,
      processingIdle: !_saving,
      missRiskAcknowledged: _missRisk,
      manualInspectionConfirmed: _manualInspection,
    );
    if (!eligible.canApprove) return;
    setState(() {
      _saving = true;
      _message = null;
    });
    try {
      final saved = await widget.onApprove(widget.digest);
      if (mounted)
        setState(() {
          _approved = saved;
          _invalidated = !saved;
          _message = saved
              ? 'Local prototype review saved for this derivative.'
              : 'Derivative changed or review could not be saved. Start a new review.';
        });
      if (saved && widget.closeAfterApproval && mounted) {
        Navigator.of(context).pop('approved');
      }
    } catch (error) {
      if (mounted) setState(() => _message = 'Review save failed: $error');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Widget _viewer(BuildContext context) =>
      widget.viewerBuilder?.call(
        context,
        _controller,
        _selected,
        _onViewChanged,
      ) ??
      PanoramaViewer(
        key: ValueKey(widget.digest),
        panoramaController: _controller,
        latitude: reviewDirections[_selected].latitude,
        longitude: reviewDirections[_selected].longitude,
        minLatitude: -90,
        maxLatitude: 90,
        minLongitude: -180,
        maxLongitude: 180,
        onViewChanged: _onViewChanged,
        child: Image.file(File(widget.derivativePath), fit: BoxFit.cover),
      );

  @override
  Widget build(BuildContext context) {
    final marked = _coverage.inspected.contains(_selected);
    return Scaffold(
      appBar: AppBar(
        title: const Text('360° owner review'),
        actions: [
          IconButton(
            tooltip: 'Pause review and edit blur regions',
            onPressed: () => Navigator.pop(context, 'edit'),
            icon: const Icon(Icons.blur_on),
          ),
        ],
        leading: IconButton(
          tooltip: 'Close review',
          icon: const Icon(Icons.arrow_back),
          onPressed: () => Navigator.pop(context),
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Text(
            'Review the processed derivative. Drag to look around freely; use the direction grid to visit every checkpoint, including both poles and the left/right seam.',
          ),
          const SizedBox(height: 10),
          SizedBox(
            height: 360,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: _viewer(context),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'Coverage: ${_coverage.completed}/48 directions',
            key: const ValueKey('coverage-count'),
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const Text(
            'This tracker records explicit owner review actions. It cannot prove that every person was noticed.',
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 6,
            runSpacing: 2,
            children: [
              for (final direction in reviewDirections)
                SizedBox(
                  width: 42,
                  height: 42,
                  child: OutlinedButton(
                    key: ValueKey('direction-${direction.index}'),
                    style: OutlinedButton.styleFrom(
                      padding: EdgeInsets.zero,
                      backgroundColor:
                          _coverage.inspected.contains(direction.index)
                          ? Colors.green.shade100
                          : direction.index == _selected
                          ? Colors.amber.shade100
                          : null,
                    ),
                    onPressed: () => _goTo(direction.index),
                    child: Text('${direction.index + 1}'),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 6),
          if (!_coverage.isComplete)
            TextButton(
              onPressed: () => _goTo(_coverage.nextUninspected.index),
              child: const Text('Go to next uninspected direction'),
            ),
          if (_coverage.isComplete) ...[
            CheckboxListTile(
              value: _missRisk,
              onChanged: _saving
                  ? null
                  : (value) => setState(() => _missRisk = value ?? false),
              title: const Text(
                'I understand automatic detection can miss people.',
              ),
              controlAffinity: ListTileControlAffinity.leading,
            ),
            CheckboxListTile(
              value: _manualInspection,
              onChanged: _saving
                  ? null
                  : (value) =>
                        setState(() => _manualInspection = value ?? false),
              title: const Text(
                'I manually inspected the complete processed 360° panorama.',
              ),
              controlAffinity: ListTileControlAffinity.leading,
            ),
            FilledButton(
              key: const ValueKey('final-review-approval'),
              onPressed:
                  _saving ||
                      _approved ||
                      !_coverage.isComplete ||
                      !_missRisk ||
                      !_manualInspection ||
                      _invalidated
                  ? null
                  : _approve,
              child: Text(
                _saving
                    ? 'Saving review…'
                    : _approved
                    ? 'Review recorded'
                    : 'Complete owner review',
              ),
            ),
          ],
          if (_message != null)
            Text(_message!, key: const ValueKey('review-message')),
          Text(
            'Processing version ${widget.processingVersion} · derivative SHA-256 ${widget.digest}',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
      bottomNavigationBar: !_coverage.isComplete
          ? SafeArea(
              minimum: const EdgeInsets.all(12),
              child: FilledButton.icon(
                key: const ValueKey('mark-direction'),
                onPressed: _directionPresented && !marked
                    ? _markAndAdvance
                    : null,
                icon: Icon(marked ? Icons.check : Icons.visibility),
                label: Text(
                  marked
                      ? 'Direction inspected'
                      : _directionPresented
                      ? 'Mark this direction inspected & advance'
                      : 'Positioning review view…',
                ),
              ),
            )
          : null,
    );
  }
}
