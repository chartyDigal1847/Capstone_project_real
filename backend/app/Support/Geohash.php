<?php

namespace App\Support;

/**
 * Geohash encoding and bounded nearby query ranges for Firestore.
 *
 * Geohash interleaves latitude and longitude bits into a base32 string.
 * Points sharing a common prefix are geographically close (with cell-boundary
 * edge cases), enabling efficient bounded range queries.
 *
 * Precision vs approximate cell size (equatorial):
 *   1 = 5000 km  |  2 = 1250 km  |  3 = 156 km
 *   4 = 39 km    |  5 = 4.9 km   |  6 = 1.2 km
 *   7 = 153 m    |  8 = 38 m     |  9 = 4.8 m
 *
 * @see https://en.wikipedia.org/wiki/Geohash
 */
class Geohash
{
    private const BASE32 = '0123456789bcdefghjkmnpqrstuvwxyz';

    /**
     * Encode a lat/lng pair to a geohash string.
     *
     * @param int $precision 1–12 chars (default 7 ≈ 153 m accuracy)
     */
    public static function encode(float $lat, float $lng, int $precision = 7): string
    {
        $precision = max(1, min(12, $precision));
        $hash = '';
        $bit = 0;
        $ch = 0;
        $even = true; // start longitude

        $latMin = -90.0;  $latMax = 90.0;
        $lngMin = -180.0; $lngMax = 180.0;

        while (strlen($hash) < $precision) {
            if ($even) {
                $mid = ($lngMin + $lngMax) / 2;
                if ($lng >= $mid) {
                    $ch = ($ch << 1) | 1;
                    $lngMin = $mid;
                } else {
                    $ch <<= 1;
                    $lngMax = $mid;
                }
            } else {
                $mid = ($latMin + $latMax) / 2;
                if ($lat >= $mid) {
                    $ch = ($ch << 1) | 1;
                    $latMin = $mid;
                } else {
                    $ch <<= 1;
                    $latMax = $mid;
                }
            }
            $even = ! $even;

            if (++$bit === 5) {
                $hash .= self::BASE32[$ch];
                $bit = 0;
                $ch = 0;
            }
        }

        return $hash;
    }

    /**
     * Decode a geohash to a lat/lng bounding box [minLat, minLng, maxLat, maxLng].
     *
     * @return array{0: float, 1: float, 2: float, 3: float}
     */
    public static function decode(string $geohash): array
    {
        $latMin = -90.0;  $latMax = 90.0;
        $lngMin = -180.0; $lngMax = 180.0;
        $even = true;

        for ($i = 0, $n = strlen($geohash); $i < $n; $i++) {
            $pos = strpos(self::BASE32, $geohash[$i]);
            if ($pos === false) break;

            for ($bit = 4; $bit >= 0; $bit--) {
                $bitN = ($pos >> $bit) & 1;
                if ($even) {
                    $mid = ($lngMin + $lngMax) / 2;
                    if ($bitN === 1) $lngMin = $mid; else $lngMax = $mid;
                } else {
                    $mid = ($latMin + $latMax) / 2;
                    if ($bitN === 1) $latMin = $mid; else $latMax = $mid;
                }
                $even = ! $even;
            }
        }

        return [$latMin, $lngMin, $latMax, $lngMax];
    }

    /**
     * Get the geohash prefix coverage for a radius search.
     *
     * Returns 9 prefixes (the cell containing the point and its 8 neighbors)
     * at a precision appropriate for the radius. Exact-distance filtering
     * must follow to discard false positives from edge cells.
     *
     * @return string[] Geohash prefixes to query
     */
    public static function queryRanges(float $lat, float $lng, float $radiusKm): array
    {
        // Choose precision so the cell size is smaller than the radius.
        // This ensures the center + 8 neighbors cover the full search area.
        $precision = match (true) {
            $radiusKm <= 0.5  => 7,
            $radiusKm <= 1    => 6,
            $radiusKm <= 6    => 5,
            $radiusKm <= 25   => 4,
            $radiusKm <= 100  => 3,
            $radiusKm <= 600  => 2,
            default           => 1,
        };

        $center = self::encode($lat, $lng, $precision);
        $neighbors = self::neighbors($center);

        return array_values(array_unique([$center, ...$neighbors]));
    }

    /**
     * Compute the 8 adjacent geohash cells in the cardinal and diagonal directions.
     *
     * Uses a pure arithmetic decode-encode approach: decode the bounding box,
     * step one cell in the requested direction, then re-encode. This is
     * simpler and more reliable than lookup-table approaches across all precisions.
     *
     * @return string[] 8 neighbors: n, ne, e, se, s, sw, w, nw
     */
    public static function neighbors(string $geohash): array
    {
        $precision = strlen($geohash);
        [$latMin, $lngMin, $latMax, $lngMax] = self::decode($geohash);

        $latStep = $latMax - $latMin;
        $lngStep = $lngMax - $lngMin;
        $latMid = ($latMin + $latMax) / 2;
        $lngMid = ($lngMin + $lngMax) / 2;

        $clampLat = static fn (float $v) => max(-90.0, min(90.0, $v));
        $clampLng = static fn (float $v) => $v > 180.0 ? $v - 360.0 : ($v < -180.0 ? $v + 360.0 : $v);

        return [
            self::encode($clampLat($latMid + $latStep), $lngMid,                          $precision), // n
            self::encode($clampLat($latMid + $latStep), $clampLng($lngMid + $lngStep),    $precision), // ne
            self::encode($latMid,                        $clampLng($lngMid + $lngStep),    $precision), // e
            self::encode($clampLat($latMid - $latStep), $clampLng($lngMid + $lngStep),    $precision), // se
            self::encode($clampLat($latMid - $latStep), $lngMid,                          $precision), // s
            self::encode($clampLat($latMid - $latStep), $clampLng($lngMid - $lngStep),    $precision), // sw
            self::encode($latMid,                        $clampLng($lngMid - $lngStep),    $precision), // w
            self::encode($clampLat($latMid + $latStep), $clampLng($lngMid - $lngStep),    $precision), // nw
        ];
    }

    /**
     * Check whether a given geohash falls within any of the query range prefixes.
     */
    public static function inRanges(string $geohash, array $ranges): bool
    {
        foreach ($ranges as $prefix) {
            if (str_starts_with($geohash, $prefix)) {
                return true;
            }
        }
        return false;
    }
}
