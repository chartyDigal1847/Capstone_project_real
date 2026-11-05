<?php

namespace App\Http\Controllers\Api\V1;

use App\Http\Controllers\Controller;
use App\Services\FirestoreService;
use Illuminate\Http\Request;

/**
 * Product recognition — Firestore-backed.
 * Uses on-device/keyword/alias/barcode catalog scoring (no external vision API).
 * AI outputs are suggestions only; owner confirms before saving.
 */
class RecognitionController extends Controller
{
    public function __construct(private readonly FirestoreService $firestore)
    {
    }

    public function suggest(Request $request)
    {
        $data = $request->validate([
            'hint' => ['nullable', 'string'],
            'barcode' => ['nullable', 'string'],
            'image' => ['nullable', 'string', 'max:2000000'],
        ]);

        $products = $this->firestore->all('products');
        $hint = strtolower(trim((string) ($data['hint'] ?? '')));
        $barcode = trim((string) ($data['barcode'] ?? ''));

        $scored = [];
        foreach ($products as $product) {
            $score = $this->scoreProduct($product, $hint, $barcode);
            if ($score < 100) $scored[] = [$score, $product];
        }
        usort($scored, fn ($a, $b) => $a[0] <=> $b[0]);

        $suggestions = [];
        foreach (array_slice($scored, 0, 4) as [$score, $product]) {
            $confidence = $score === 0 ? 0.92 : ($score <= 3 ? 0.75 : 0.45);
            $suggestions[] = [
                'product' => $this->productJson($product),
                'label' => ($product['name'] ?? '') . ' · ' . ($product['category'] ?? ''),
                'confidence' => $confidence,
                'unknown_fields' => ['price', 'stock'],
                'ocr' => $barcode !== '' ? "barcode: $barcode" : null,
            ];
        }
        if (empty($suggestions)) {
            $suggestions[] = [
                'product' => null,
                'label' => 'No catalog match · encode manually',
                'confidence' => 0.0,
                'unknown_fields' => ['identity', 'price', 'stock'],
                'ocr' => null,
            ];
        }

        return response()->json([
            'data' => [
                'suggestions' => $suggestions,
                'uncertain' => collect($suggestions)->every(fn ($row) => empty($row['product']) || ($row['confidence'] ?? 0) < 0.5),
                'status' => 'ready',
            ],
        ]);
    }

    public function show(int $jobId)
    {
        return response()->json(['data' => ['id' => $jobId, 'status' => 'ready', 'suggestions' => []]]);
    }

    public function confirm(Request $request, int $jobId)
    {
        return response()->json(['data' => ['id' => $jobId, 'status' => 'confirmed']]);
    }

    private function productJson(array $data): array
    {
        return [
            'id' => $data['numericId'] ?? 0,
            'name' => $data['name'] ?? '',
            'category' => $data['category'] ?? '',
            'brand' => $data['brand'] ?? '',
            'package_size' => $data['package_size'] ?? '',
            'aliases' => $data['aliases'] ?? [],
            'barcode' => $data['barcode'] ?? null,
            'image' => $data['image'] ?? '',
            'attributes' => $data['attributes'] ?? [],
        ];
    }

    private function scoreProduct(array $product, string $hint, string $barcode): int
    {
        if ($barcode !== '') {
            $bc = strtolower((string) ($product['barcode'] ?? ''));
            if ($bc === strtolower($barcode)) return 0;
        }
        if ($hint === '') return 100;
        $name = strtolower((string) ($product['name'] ?? ''));
        $category = strtolower((string) ($product['category'] ?? ''));
        $brand = strtolower((string) ($product['brand'] ?? ''));
        $aliases = array_map(fn ($a) => strtolower((string) $a), $product['aliases'] ?? []);
        if ($name === $hint) return 0;
        if (str_starts_with($name, $hint)) return 1;
        if (str_contains($name, $hint)) return 2;
        if (in_array($hint, $aliases)) return 3;
        if (str_contains($brand, $hint)) return 4;
        if (str_contains($category, $hint)) return 5;
        $hintTokens = array_filter(preg_split('/\s+/', $hint) ?: [], fn ($t) => strlen($t) >= 2);
        $productTokens = array_filter(
            preg_split('/[^a-z0-9]+/', "$name $category $brand " . implode(' ', $aliases)) ?: [],
            fn ($t) => strlen($t) >= 2
        );
        $overlap = count(array_intersect($hintTokens, $productTokens));
        if ($overlap > 0) return 6 + (count($hintTokens) - $overlap);
        return 100;
    }
}
