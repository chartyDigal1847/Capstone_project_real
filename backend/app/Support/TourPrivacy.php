<?php

namespace App\Support;

use App\Models\TourNode;
use Illuminate\Support\Facades\Storage;

class TourPrivacy
{
    public static function retentionDays(): int
    {
        return max(1, (int) config('localspot.tour_original_retention_days', 30));
    }

    public static function stage(string $source, int $nodeId): string
    {
        $key = "tours/originals/{$nodeId}.txt";
        Storage::disk('local')->put($key, $source);

        return $key;
    }

    public static function source(TourNode $node): string
    {
        if (! filled($node->original_image)) {
            return '';
        }
        if (Storage::disk('local')->exists($node->original_image)) {
            return (string) Storage::disk('local')->get($node->original_image);
        }

        return (string) $node->original_image;
    }

    public static function publicUrl(int $nodeId): string
    {
        return '/storage/tours/'.$nodeId.'/sanitized.jpg';
    }

    public static function writeDerivative(TourNode $node): string
    {
        $path = 'tours/'.$node->id.'/sanitized.jpg';
        Storage::disk('public')->put($path, 'LOCALSPOT_SANITIZED_DERIVATIVE');

        return '/storage/'.$path;
    }

    public static function shouldFail(TourNode $node, bool $forceFail = false): bool
    {
        $hay = strtolower($node->title.' '.self::source($node));

        return $forceFail || str_contains($hay, 'fail') || ! filled($node->original_image);
    }

    public static function forgetOriginal(TourNode $node): void
    {
        if (filled($node->original_image) && Storage::disk('local')->exists($node->original_image)) {
            Storage::disk('local')->delete($node->original_image);
        }
        $node->update(['original_image' => null]);
    }
}
