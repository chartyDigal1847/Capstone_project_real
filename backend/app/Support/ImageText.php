<?php

namespace App\Support;

class ImageText
{
    public static function extract(?string $hint, ?string $barcode, mixed $image = null): array
    {
        $text = trim(($hint ?? '').' '.($barcode ?? ''));
        $meta = [
            'received' => false,
            'bytes' => 0,
            'mime' => null,
        ];

        if (is_string($image) && $image !== '') {
            $meta['received'] = true;
            if (preg_match('#^data:([^;]+);base64,(.+)$#s', $image, $match) === 1) {
                $binary = base64_decode($match[2], true) ?: '';
                $meta['mime'] = $match[1];
                $meta['bytes'] = strlen($binary);
            } else {
                $meta['bytes'] = strlen($image);
            }
        }

        $source = $text.' '.(is_string($image) ? substr($image, 0, 200) : '');
        if (($barcode === null || $barcode === '') && preg_match('/\d{8,14}/', $source, $digits) === 1) {
            $barcode = $digits[0];
        }

        return [
            'text' => trim($text),
            'barcode' => $barcode ?: null,
            'image' => $meta,
        ];
    }

    public static function objects(string $text): array
    {
        $text = trim($text);
        if ($text === '') {
            return [''];
        }
        $parts = preg_split('/\s*(?:,|&|\band\b)\s+/i', $text) ?: [$text];
        $parts = array_values(array_filter(array_map('trim', $parts), fn ($part) => $part !== ''));

        return $parts === [] ? [$text] : $parts;
    }
}
