import 'package:flutter_test/flutter_test.dart';
import 'package:panorama_privacy_prototype/main.dart';

void main() {
  testWidgets('prototype starts without pretending that media is processed', (tester) async {
    await tester.pumpWidget(const PanoramaPrototypeApp());
    expect(find.text('Choose a 2:1 panorama'), findsOneWidget);
    expect(find.textContaining('Local review is not authenticated or sent to Firebase'), findsOneWidget);
    expect(find.textContaining('Local prototype only'), findsOneWidget);
  });
}
