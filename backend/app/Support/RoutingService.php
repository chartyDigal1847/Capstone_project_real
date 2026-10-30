<?php

namespace App\Support;

use Illuminate\Support\Facades\Http;
use Illuminate\Support\Facades\Log;

class RoutingService
{
    public function preview(float $originLat, float $originLng, float $destLat, float $destLng): array
    {
        $base = rtrim((string) config('localspot.routing_base_url'), '/');
        if ($base !== '') {
            $routed = $this->fromOsrm($base, $originLat, $originLng, $destLat, $destLng);
            if ($routed !== null) {
                return $routed;
            }
        }

        return $this->straightLine($originLat, $originLng, $destLat, $destLng);
    }

    private function fromOsrm(string $base, float $originLat, float $originLng, float $destLat, float $destLng): ?array
    {
        $url = sprintf(
            '%s/route/v1/driving/%s,%s;%s,%s',
            $base,
            $originLng,
            $originLat,
            $destLng,
            $destLat,
        );

        try {
            $response = Http::timeout(8)->acceptJson()->get($url, [
                'overview' => 'full',
                'geometries' => 'geojson',
            ]);
            if (! $response->successful()) {
                return null;
            }
            $route = $response->json('routes.0');
            if (! is_array($route)) {
                return null;
            }
            $coords = $route['geometry']['coordinates'] ?? [];
            $points = [];
            foreach ($coords as $pair) {
                if (! is_array($pair) || count($pair) < 2) {
                    continue;
                }
                $points[] = [(float) $pair[1], (float) $pair[0]];
            }
            if ($points === []) {
                return null;
            }
            $meters = (float) ($route['distance'] ?? 0);
            $seconds = (float) ($route['duration'] ?? 0);

            return [
                'provider' => 'osrm',
                'fallback' => false,
                'distance_km' => round($meters / 1000, 3),
                'duration_minutes' => $seconds > 0 ? (int) max(1, round($seconds / 60)) : null,
                'coordinates' => $points,
            ];
        } catch (\Throwable $e) {
            Log::warning('Route preview provider failed', ['message' => $e->getMessage()]);

            return null;
        }
    }

    private function straightLine(float $originLat, float $originLng, float $destLat, float $destLng): array
    {
        $steps = 16;
        $points = [];
        for ($i = 0; $i <= $steps; $i++) {
            $t = $i / $steps;
            $points[] = [
                $originLat + ($destLat - $originLat) * $t,
                $originLng + ($destLng - $originLng) * $t,
            ];
        }
        $km = Geo::distanceKm($originLat, $originLng, $destLat, $destLng);

        return [
            'provider' => 'localspot',
            'fallback' => true,
            'distance_km' => round($km, 3),
            'duration_minutes' => $km > 0 ? (int) max(1, round(($km / 20) * 60)) : 1,
            'coordinates' => $points,
        ];
    }
}
