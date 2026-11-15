import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:panorama_privacy_prototype/review_flow.dart';
import 'package:panorama_privacy_prototype/review_screen.dart';
import 'package:panorama_viewer/panorama_viewer.dart';

const _digest =
    '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';

Widget _testViewer(
  BuildContext context,
  PanoramaController controller,
  int selected,
  void Function(double, double, double) onViewChanged,
) {
  final direction = reviewDirections[selected];
  return Center(
    child: TextButton(
      key: const ValueKey('present-direction'),
      onPressed: () =>
          onViewChanged(direction.longitude, direction.latitude, 0),
      child: Text('Present ${selected + 1}'),
    ),
  );
}

void main() {
  testWidgets('restores saved progress and presentation alone does not count', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final saved = <int>{0, 1};
    await tester.pumpWidget(
      MaterialApp(
        home: PanoramaReviewScreen(
          derivativePath: 'test/review_screen_test.dart',
          digest: _digest,
          processingVersion: 'review-test-v1',
          initialInspected: saved,
          persistCoverage: (_, values) async {
            saved
              ..clear()
              ..addAll(values);
          },
          onApprove: (_) async => true,
          viewerBuilder: _testViewer,
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Coverage: 2/48 directions'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('present-direction')));
    await tester.pump();
    expect(find.text('Coverage: 2/48 directions'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('mark-direction')));
    await tester.pumpAndSettle();
    expect(saved, {0, 1, 2});
    expect(find.text('Coverage: 3/48 directions'), findsOneWidget);
  });

  testWidgets(
    'explicitly presents and marks all directions; approval needs both acknowledgements',
    (tester) async {
      tester.view.physicalSize = const Size(1200, 2400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final saved = <int>{};
      var approvals = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: PanoramaReviewScreen(
            derivativePath: 'test/review_screen_test.dart',
            digest: _digest,
            processingVersion: 'review-test-v1',
            initialInspected: const {},
            persistCoverage: (_, values) async {
              saved
                ..clear()
                ..addAll(values);
            },
            onApprove: (_) async {
              approvals++;
              return true;
            },
            viewerBuilder: _testViewer,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Coverage: 0/48 directions'), findsOneWidget);
      expect(
        tester
            .widget<FilledButton>(find.byKey(const ValueKey('mark-direction')))
            .onPressed,
        isNull,
      );

      for (var i = 0; i < 48; i++) {
        await tester.ensureVisible(
          find.byKey(const ValueKey('present-direction')),
        );
        await tester.tap(find.byKey(const ValueKey('present-direction')));
        await tester.pump();
        await tester.ensureVisible(
          find.byKey(const ValueKey('mark-direction')),
        );
        await tester.tap(find.byKey(const ValueKey('mark-direction')));
        await tester.pumpAndSettle();
      }
      expect(saved, hasLength(48));
      expect(find.text('Coverage: 48/48 directions'), findsOneWidget);
      expect(approvals, 0);
      expect(
        tester
            .widget<FilledButton>(
              find.byKey(const ValueKey('final-review-approval')),
            )
            .onPressed,
        isNull,
      );

      final missRisk = find.text(
        'I understand automatic detection can miss people.',
      );
      final manual = find.text(
        'I manually inspected the complete processed 360° panorama.',
      );
      await _scrollUntilFound(tester, missRisk);
      await tester.tap(missRisk);
      await tester.pump();
      await _scrollUntilFound(tester, manual);
      expect(
        tester
            .widget<FilledButton>(
              find.byKey(const ValueKey('final-review-approval')),
            )
            .onPressed,
        isNull,
      );
      await tester.tap(manual);
      await tester.pump();
      await _scrollUntilFound(tester, find.text('Complete owner review'));
      await tester.tap(find.text('Complete owner review'));
      await tester.pumpAndSettle();
      expect(approvals, 1);
      expect(find.text('Review recorded'), findsOneWidget);
    },
  );

  testWidgets('manual editor action exits review with edit result', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    String? result;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () async {
                result = await Navigator.push<String>(
                  context,
                  MaterialPageRoute(
                    builder: (_) => PanoramaReviewScreen(
                      derivativePath: 'unused.jpg',
                      digest: _digest,
                      processingVersion: 'v1',
                      initialInspected: const {},
                      persistCoverage: (_, _) async {},
                      onApprove: (_) async => true,
                      viewerBuilder: _testViewer,
                    ),
                  ),
                );
              },
              child: const Text('Open review'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open review'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Pause review and edit blur regions'));
    await tester.pumpAndSettle();
    expect(find.text('Open review'), findsOneWidget);
    expect(result, 'edit');
  });
}

Future<void> _scrollUntilFound(WidgetTester tester, Finder finder) async {
  for (var i = 0; i < 12 && finder.evaluate().isEmpty; i++) {
    await tester.drag(find.byType(ListView), const Offset(0, -600));
    await tester.pumpAndSettle();
  }
  expect(finder, findsOneWidget);
}
