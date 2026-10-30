<?php

namespace App\Support;

use App\Models\Product;

class RecognitionService
{
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
            $exact = Product::with('aliases')->where('barcode', $barcode)->first();
            if ($exact) {
                return [[
                    'product' => $exact->toApi(),
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

        $matches = Product::with('aliases')->get()->filter(function (Product $product) use ($hint) {
            return SearchText::matches($hint, self::fields($product), $product->category);
        })->sortBy(fn (Product $product) => SearchText::relevance(
            $hint,
            (string) $product->name,
            $product->aliases->pluck('alias')->all(),
            $product->category,
            self::fields($product),
        ))->take(3)->values();

        if ($matches->isEmpty()) {
            return [[
                'product' => null,
                'label' => 'Uncertain match · encode manually',
                'confidence' => 0.22,
                'unknown_fields' => ['identity', 'price', 'stock'],
            ]];
        }

        return $matches->map(fn (Product $product, $i) => [
            'product' => $product->toApi(),
            'label' => 'Suggested from catalog · owner confirmation required',
            'confidence' => max(0.4, 0.86 - ($i * 0.15)),
            'ocr' => $product->brand ?: $hint,
            'unknown_fields' => ['price', 'stock', 'compatibility'],
        ])->all();
    }

    public static function fields(Product $product): array
    {
        return [
            $product->name,
            $product->brand,
            $product->category,
            $product->package_size,
            $product->barcode,
            ...$product->aliases->pluck('alias')->all(),
            ...array_values($product->specs ?? []),
        ];
    }
}
