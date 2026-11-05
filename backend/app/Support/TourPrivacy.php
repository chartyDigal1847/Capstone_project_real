<?php

namespace App\Support;

use Illuminate\Support\Facades\Storage;

/**
 * 360° tour privacy processing support — array-based (no Eloquent).
 *
 * In the target architecture, original panoramas are uploaded to private
 * Cloud Storage quarantine paths. Laravel processes them through a queue
 * worker and creates sanitized derivatives. This class provides the
 * transitional local-storage-based implementation; actual ML person/face
 * detection is pending (plan Wave 3).
 *
 * The publication gate in TourController blocks publication until every
 * node has privacy_status='ready' and owner_reviewed=true.
 */
class TourPrivacy
{
    public static function retentionDays(): int
    {
        return max(1, (int) config('localspot.tour_original_retention_days', 30));
    }

    /**
     * Stage an original panorama source (transitional: local storage).
     * Returns the storage key for the original.
     */
    public static function stage(string $source, int $nodeId): string
    {
        $key = "tours/originals/{$nodeId}.txt";
        Storage::disk('local')->put($key, $source);
        return $key;
    }

    /**
     * Read the original source for a node (accepts array-based node data).
     */
    public static function source(array $node): string
    {
        $originalImage = $node['original_image'] ?? null;
        if (! filled($originalImage)) {
            return '';
        }
        if (Storage::disk('local')->exists($originalImage)) {
            return (string) Storage::disk('local')->get($originalImage);
        }
        return (string) $originalImage;
    }

    /**
     * Get the public sanitized derivative URL for a node.
     */
    public static function publicUrl(int $nodeId): string
    {
        return '/storage/tours/' . $nodeId . '/sanitized.jpg';
    }

    /**
     * Write a sanitized derivative (transitional: local public storage).
     * Returns the public path.
     */
    public static function writeDerivative(int $nodeId): string
    {
        $path = 'tours/' . $nodeId . '/sanitized.jpg';
        Storage::disk('public')->put($path, 'LOCALSPOT_SANITIZED_DERIVATIVE');
        return '/storage/' . $path;
    }

    /**
     * Determine if processing should fail for a node (accepts array-based data).
     */
    public static function shouldFail(array $node, bool $forceFail = false): bool
    {
        $hay = strtolower(($node['title'] ?? '') . ' ' . self::source($node));
        return $forceFail || str_contains($hay, 'fail') || ! filled($node['original_image'] ?? null);
    }

    /**
     * Forget (delete) the original for a node (accepts array-based data).
     * Returns the update data to merge into the node.
     */
    public static function forgetOriginal(array $node): array
    {
        $originalImage = $node['original_image'] ?? null;
        if (filled($originalImage) && Storage::disk('local')->exists($originalImage)) {
            Storage::disk('local')->delete($originalImage);
        }
        return ['original_image' => null];
    }
}
