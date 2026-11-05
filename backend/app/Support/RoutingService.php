<?php

namespace App\Support;

use Illuminate\Support\Facades\Http;
use Illuminate\Support\Facades\Log;

/**
 * Road-route preview service.
 *
 * Supports two providers:
 *   - osrm (default): standard OSRM HTTP API — set ROUTING_BASE_URL to an
 *     OSRM server, e.g. http://localhost:5000 for self-hosted.
 *   - openrouteservice: OpenRouteService API — set ROUTING_BASE_URL to
 *     https://api.openrouteservice.org/v2 and ROUTING_API_KEY to your ORS key.
 *     Coverage: Philippines road network supported.
 *
 * When ROUTING_BASE_URL is empty, returns a straight-line fallback with
 * routing_configured=false on the health endpoint. This is the default
 * for development until a provider is configured.
 *
 * Provider API key (ROUTING_API_KEY) must never be returned to the Flutter
 * client — Laravel proxies the request and returns only the geometry.
 */
class RoutingService
{
    public function preview(float $originLat, float $originLng, float $destLat, float $destLng): array
    {
        $base = rtrim((string) config('localspot.routing_base_url'), '/');
        $provider = (string) config('localspot.routing_provider', 'osrm');

        if ($base !== '') {
            $routed = match ($provider) {
                'openrouteservice' => $this->fromOpenRouteService($base, $originLat, $originLng, $destLat, $destLng),
                default            => $this->fromOsrm($base, $originLat, $originLng, $destLat, $destLng),
            };

            if ($routed !== null) {
                return $routed;
            }
        }

        return $this->straightLine($originLat, $originLng, $destLat, $destLng);
    }

    /**
     * OSRM HTTP API (standard format).
     * URL pattern: {base}/route/v1/driving/{lng},{lat};{lng},{lat}?overview=full&geometries=geojson
     */
    private function fromOsrm(string $base, float $originLat, float $originLng, float $destLat, float $destLng): ?array
    {
        $url = sprintf(
            '%s/route/v1/driving/%s,%s;%s,%s',
            $base,
            $originLng, $originLat,
            $destLng, $destLat,
        );

        try {
            $response = Http::timeout(8)->acceptJson()->get($url, [
                'overview' => 'full',
                'geometries' => 'geojson',
            ]);

            if (! $response->successful()) {
                Log::warning('OSRM routing failed', [
                    'status' => $response->status(),
                    'url' => $url,
                ]);
                return null;
            }

            $route = $response->json('routes.0');
            return $this->parseOsrmRoute($route, 'osrm');
        } catch (\Throwable $e) {
            Log::warning('OSRM routing exception', ['message' => $e->getMessage()]);
            return null;
        }
    }

    /**
     * OpenRouteService API.
     * URL pattern: {base}/directions/driving-car
     * Authentication: Authorization: Bearer <api-key>
     * Response format compatible with OSRM geometry shape.
     * @see https://openrouteservice.org/dev/#/api-docs/v2/directions/{profile}/get
     */
    private function fromOpenRouteService(string $base, float $originLat, float $originLng, float $destLat, float $destLng): ?array
    {
        $apiKey = (string) config('localspot.routing_api_key', '');
        if ($apiKey === '') {
            Log::warning('OpenRouteService routing: ROUTING_API_KEY is not configured.');
            return null;
        }

        $url = $base . '/directions/driving-car';

        try {
            $response = Http::timeout(10)
                ->withHeaders([
                    'Authorization' => "Bearer $apiKey",
                    'Accept' => 'application/json',
                    'Content-Type' => 'application/json',
                ])
                ->post($url, [
                    'coordinates' => [
                        [$originLng, $originLat],
                        [$destLng,   $destLat],
                    ],
                    'format' => 'geojson',
                ]);

            if ($response->status() === 401) {
                Log::warning('OpenRouteService routing: API key is invalid or expired.');
                return null;
            }

            if ($response->status() === 429) {
                Log::warning('OpenRouteService routing: rate limit exceeded.');
                return null;
            }

            if (! $response->successful()) {
                Log::warning('OpenRouteService routing failed', [
                    'status' => $response->status(),
                    'body' => substr((string) $response->body(), 0, 200),
                ]);
                return null;
            }

            // ORS GeoJSON response: features[0].properties has distance/duration,
            // features[0].geometry.coordinates has the route coordinates.
            $features = $response->json('features');
            if (empty($features)) {
                return null;
            }

            $feature = $features[0];
            $coords = $feature['geometry']['coordinates'] ?? [];
            $summary = $feature['properties']['summary'] ?? [];

            $points = [];
            foreach ($coords as $pair) {
                if (is_array($pair) && count($pair) >= 2) {
                    $points[] = [(float) $pair[1], (float) $pair[0]]; // [lat, lng]
                }
            }

            if (empty($points)) {
                return null;
            }

            $meters  = (float) ($summary['distance'] ?? 0);
            $seconds = (float) ($summary['duration'] ?? 0);

            return [
                'provider'          => 'openrouteservice',
                'fallback'          => false,
                'distance_km'       => round($meters / 1000, 3),
                'duration_minutes'  => $seconds > 0 ? (int) max(1, round($seconds / 60)) : null,
                'coordinates'       => $points,
            ];
        } catch (\Throwable $e) {
            Log::warning('OpenRouteService routing exception', ['message' => $e->getMessage()]);
            return null;
        }
    }

    private function parseOsrmRoute(?array $route, string $providerName): ?array
    {
        if (! is_array($route)) {
            return null;
        }

        $coords = $route['geometry']['coordinates'] ?? [];
        $points = [];
        foreach ($coords as $pair) {
            if (is_array($pair) && count($pair) >= 2) {
                $points[] = [(float) $pair[1], (float) $pair[0]]; // [lat, lng]
            }
        }

        if (empty($points)) {
            return null;
        }

        $meters  = (float) ($route['distance'] ?? 0);
        $seconds = (float) ($route['duration'] ?? 0);

        return [
            'provider'         => $providerName,
            'fallback'         => false,
            'distance_km'      => round($meters / 1000, 3),
            'duration_minutes' => $seconds > 0 ? (int) max(1, round($seconds / 60)) : null,
            'coordinates'      => $points,
        ];
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
            'provider'         => 'localspot',
            'fallback'         => true,
            'distance_km'      => round($km, 3),
            'duration_minutes' => $km > 0 ? (int) max(1, round(($km / 20) * 60)) : 1,
            'coordinates'      => $points,
        ];
    }
}
