import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:localspot/firebase/product_ai.dart';

void main() {
  test('image data URL validates format and decoded length', () {
    expect(
      ProductAiSuggestionService.decodeImageDataUrl(
        'data:image/jpeg;base64,${base64Encode([1, 2, 3])}',
      ),
      [1, 2, 3],
    );
    expect(
      () => ProductAiSuggestionService.decodeImageDataUrl(
        'data:image/gif;base64,${base64Encode([1])}',
      ),
      throwsFormatException,
    );
    expect(
      () => ProductAiSuggestionService.decodeImageDataUrl(
        'data:image/jpeg;base64,',
      ),
      throwsFormatException,
    );
  });

  test('oversized encoded images are rejected before base64 decoding', () {
    final oversized = 'A' * 2000001;
    expect(
      () => ProductAiSuggestionService.decodeImageDataUrl(
        'data:image/png;base64,$oversized',
      ),
      throwsFormatException,
    );
  });

  test('structured suggestions are bounded and allowlisted', () {
    final result = ProductAiSuggestionService.parseSuggestionResponse(
      jsonEncode({
        'items': [
          {
            'name': ' Steel Clamp ',
            'category': 'Hardware',
            'brand': 'Workshop',
            'attributes': {
              'material': 'steel',
              'price': '999',
              'safety_claim': 'safe',
            },
          },
          {'name': 'Bad category', 'category': 'Something else'},
          {'name': 'Hammer', 'category': 'Hardware'},
          {'name': 'Cable', 'category': 'Electronics'},
          {'name': 'Ignored extra', 'category': 'Hardware'},
        ],
      }),
    );

    expect(result, hasLength(3));
    expect(result.first['name'], 'Steel Clamp');
    expect(result.first['attributes'], {'material': 'steel'});
    expect(result.any((item) => item['name'] == 'Bad category'), isFalse);
    expect(result.any((item) => item['name'] == 'Ignored extra'), isFalse);
  });

  test('malformed structured responses are rejected', () {
    expect(
      () => ProductAiSuggestionService.parseSuggestionResponse('{"items":[]}'),
      throwsFormatException,
    );
    expect(
      () => ProductAiSuggestionService.parseSuggestionResponse('not json'),
      throwsFormatException,
    );
  });
}
