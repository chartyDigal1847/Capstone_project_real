<?php

namespace App\Support;

use App\Services\FirestoreService;

/**
 * Product recognition service — Firestore-backed.
 *
 * Uses keyword/alias/barcode catalog scoring against the Firestore products
 * collection. No external vision API. AI outputs are suggestions only;
 * owner confirms before saving.
 */
class RecognitionService
{
    public function __construct(private readonly FirestoreService $firestore)
    {
    }

    public function analyze(?string $hint, ?string $barcode, mixed $image = null): array
    {
        $extracted = ImageText::extract($hint, $barcode, $image);
        $query = $extracted['text'] !== '' ? $extracted['text'] : (string) ($extracted['barcode'] ?? '');
        $parts = ImageText::objects($query);
        $objects = [];
        $flat = [];
        $useBarcode = $extracted['barcode'];
        foreach ($parts as $index => $part) {
            $partBarcode = ($index === 0 && count($parts) === 1) ? $useBarcode : null;
            if ($partBarcode === null && preg_match('/^\d{8,14}$/', $part) === 1) {
                $partBarcode = $part;
            }
            $suggestions = $this->suggestions($part, $partBarcode);
            if ($extracted['text'] !== '' && isset($suggestions[0])) {
                $suggestions[0]['ocr'] = $extracted['text'];
            }
            $objects[] = [
                'label' => $part !== '' ? $part : 'item',
                'suggestions' => $suggestions,
            ];
            foreach ($suggestions as $row) {
                $flat[] = $row;
            }
        }

        return [
            'suggestions' => $flat,
            'objects' => $objects,
            'ocr' => $extracted['text'] !== '' ? $extracted['text'] : null,
            'image' => $extracted['image'],
        ];
    }

    public function suggestions(?string $hint, ?string $barcode): array
    {
        $hint = trim((string) $hint);
        if (empty($barcode) && preg_match('/^\d{8,14}$/', $hint) === 1) {
            $barcode = $hint;
        }

        if (! empty($barcode)) {
            $products = $this->firestore->query('products', [
                ['field' => 'barcode', 'op' => '==', 'value' => $barcode],
            ]);
            if (! empty($products)) {
                $product = $products[0];
                return [[
                    'product' => $this->productJson($product),
                    'label' => 'Barcode match · confirm before saving',
                    'confidence' => 0.94,
                    'ocr' => $barcode,
                    'unknown_fields' => ['price', 'stock'],
                ]];
            }

            return [[
                'product' => null,
                'label' => 'Unknown barcode · encode manually',
                'confidence' => 0.18,
                'unknown_fields' => ['identity', 'price', 'stock'],
            ]];
        }

        $allProducts = $this->firestore->all('products');
        $matched = array_filter($allProducts, function ($product) use ($hint) {
            return SearchText::matches($hint, self::fields($product), $product['category'] ?? null);
        });

        usort($matched, fn ($a, $b) => SearchText::relevance(
            $hint, $a['name'] ?? '', $a['aliases'] ?? [], $a['category'] ?? null, self::fields($a)
        ) <=> SearchText::relevance(
            $hint, $b['name'] ?? '', $b['aliases'] ?? [], $b['category'] ?? null, self::fields($b)
        ));

        $matched = array_slice($matched, 0, 3);

        if (empty($matched)) {
            return [[
                'product' => null,
                'label' => 'Uncertain match · encode manually',
                'confidence' => 0.22,
                'unknown_fields' => ['identity', 'price', 'stock'],
            ]];
        }

        return array_map(fn ($product, $i) => [
            'product' => $this->productJson($product),
            'label' => 'Suggested from catalog · owner confirmation required',
            'confidence' => max(0.4, 0.86 - ($i * 0.15)),
            'ocr' => $product['brand'] ?: $hint,
            'unknown_fields' => ['price', 'stock', 'compatibility'],
        ], array_values($matched), array_keys($matched));
    }

    public static function fields(array $product): array
    {
        return [
            $product['name'] ?? '',
            $product['brand'] ?? '',
            $product['category'] ?? '',
            $product['package_size'] ?? '',
            $product['barcode'] ?? '',
            ...($product['aliases'] ?? []),
            ...array_values($product['attributes'] ?? []),
        ];
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
}
