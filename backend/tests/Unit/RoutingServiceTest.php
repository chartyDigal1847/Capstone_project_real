<?php

namespace Tests\Unit;

use App\Support\RoutingService;
use Illuminate\Support\Facades\Http;
use Tests\TestCase;

/**
 * RoutingService tests — verifies straight-line fallback and
 * OSRM/OpenRouteService provider integration with HTTP fakes.
 */
class RoutingServiceTest extends TestCase
{
    private RoutingService $routing;

    protected function setUp(): void
    {
        parent::setUp();
        $this->routing = new RoutingService();
    }

    // ── Straight-line fallback ────────────────────────────────────────────

    public function test_returns_straight_line_when_no_provider_configured(): void
    {
        config()->set('localspot.routing_base_url', '');

        $result = $this->routing->preview(14.6195, 121.0568, 14.6171, 121.0551);

        $this->assertTrue($result['fallback']);
        $this->assertSame('localspot', $result['provider']);
        $this->assertGreaterThan(0, $result['distance_km']);
        $this->assertGreaterThan(0, $result['duration_minutes']);
        $this->assertNotEmpty($result['coordinates']);
        $this->assertCount(17, $result['coordinates']); // 16 steps + origin
    }

    public function test_straight_line_coordinates_start_and_end_correctly(): void
    {
        config()->set('localspot.routing_base_url', '');

        $result = $this->routing->preview(14.6195, 121.0568, 14.6171, 121.0551);

        $first = $result['coordinates'][0];
        $last = $result['coordinates'][count($result['coordinates']) - 1];

        $this->assertEqualsWithDelta(14.6195, $first[0], 0.0001);
        $this->assertEqualsWithDelta(121.0568, $first[1], 0.0001);
        $this->assertEqualsWithDelta(14.6171, $last[0], 0.0001);
        $this->assertEqualsWithDelta(121.0551, $last[1], 0.0001);
    }

    // ── OSRM provider ─────────────────────────────────────────────────────

    public function test_osrm_provider_returns_real_route_geometry(): void
    {
        config()->set('localspot.routing_base_url', 'http://osrm.test');
        config()->set('localspot.routing_provider', 'osrm');

        Http::fake([
            'osrm.test/*' => Http::response([
                'routes' => [[
                    'geometry' => [
                        'coordinates' => [
                            [121.0568, 14.6195],
                            [121.0560, 14.6185],
                            [121.0551, 14.6171],
                        ],
                    ],
                    'distance' => 350.5,
                    'duration' => 120.0,
                ]],
            ], 200),
        ]);

        $result = $this->routing->preview(14.6195, 121.0568, 14.6171, 121.0551);

        $this->assertFalse($result['fallback']);
        $this->assertSame('osrm', $result['provider']);
        $this->assertEqualsWithDelta(0.351, $result['distance_km'], 0.001);
        $this->assertSame(2, $result['duration_minutes']);
        $this->assertCount(3, $result['coordinates']);
    }

    public function test_osrm_provider_falls_back_on_error(): void
    {
        config()->set('localspot.routing_base_url', 'http://osrm.test');
        config()->set('localspot.routing_provider', 'osrm');

        Http::fake([
            'osrm.test/*' => Http::response([], 500),
        ]);

        $result = $this->routing->preview(14.6195, 121.0568, 14.6171, 121.0551);

        $this->assertTrue($result['fallback']);
        $this->assertSame('localspot', $result['provider']);
    }

    public function test_osrm_provider_falls_back_on_timeout(): void
    {
        config()->set('localspot.routing_base_url', 'http://osrm.test');
        config()->set('localspot.routing_provider', 'osrm');

        Http::fake(function () {
            throw new \Illuminate\Http\Client\ConnectionException('Connection timed out');
        });

        $result = $this->routing->preview(14.6195, 121.0568, 14.6171, 121.0551);

        $this->assertTrue($result['fallback']);
    }

    // ── OpenRouteService provider ─────────────────────────────────────────

    public function test_ors_provider_returns_real_route_when_api_key_set(): void
    {
        config()->set('localspot.routing_base_url', 'https://api.openrouteservice.org/v2');
        config()->set('localspot.routing_provider', 'openrouteservice');
        config()->set('localspot.routing_api_key', 'test-ors-key');

        Http::fake([
            'api.openrouteservice.org/*' => Http::response([
                'features' => [[
                    'geometry' => [
                        'coordinates' => [
                            [121.0568, 14.6195],
                            [121.0560, 14.6185],
                            [121.0551, 14.6171],
                        ],
                    ],
                    'properties' => [
                        'summary' => [
                            'distance' => 350.5,
                            'duration' => 120.0,
                        ],
                    ],
                ]],
            ], 200),
        ]);

        $result = $this->routing->preview(14.6195, 121.0568, 14.6171, 121.0551);

        $this->assertFalse($result['fallback']);
        $this->assertSame('openrouteservice', $result['provider']);
        $this->assertEqualsWithDelta(0.351, $result['distance_km'], 0.001);
        $this->assertSame(2, $result['duration_minutes']);
        $this->assertCount(3, $result['coordinates']);
    }

    public function test_ors_provider_falls_back_without_api_key(): void
    {
        config()->set('localspot.routing_base_url', 'https://api.openrouteservice.org/v2');
        config()->set('localspot.routing_provider', 'openrouteservice');
        config()->set('localspot.routing_api_key', '');

        $result = $this->routing->preview(14.6195, 121.0568, 14.6171, 121.0551);

        $this->assertTrue($result['fallback']);
        $this->assertSame('localspot', $result['provider']);
    }

    public function test_ors_provider_falls_back_on_401(): void
    {
        config()->set('localspot.routing_base_url', 'https://api.openrouteservice.org/v2');
        config()->set('localspot.routing_provider', 'openrouteservice');
        config()->set('localspot.routing_api_key', 'invalid-key');

        Http::fake([
            'api.openrouteservice.org/*' => Http::response(['error' => 'Invalid API key'], 401),
        ]);

        $result = $this->routing->preview(14.6195, 121.0568, 14.6171, 121.0551);

        $this->assertTrue($result['fallback']);
    }

    public function test_ors_provider_falls_back_on_429_rate_limit(): void
    {
        config()->set('localspot.routing_base_url', 'https://api.openrouteservice.org/v2');
        config()->set('localspot.routing_provider', 'openrouteservice');
        config()->set('localspot.routing_api_key', 'valid-but-rate-limited');

        Http::fake([
            'api.openrouteservice.org/*' => Http::response(['error' => 'Rate limit exceeded'], 429),
        ]);

        $result = $this->routing->preview(14.6195, 121.0568, 14.6171, 121.0551);

        $this->assertTrue($result['fallback']);
    }

    // ── Health endpoint routing status ───────────────────────────────────

    public function test_health_reports_routing_not_configured_when_empty(): void
    {
        config()->set('localspot.routing_base_url', '');

        $this->getJson('/api/v1/health')
            ->assertOk()
            ->assertJsonPath('data.routing_configured', false);
    }

    public function test_health_reports_routing_configured_when_set(): void
    {
        config()->set('localspot.routing_base_url', 'http://osrm.test');

        $this->getJson('/api/v1/health')
            ->assertOk()
            ->assertJsonPath('data.routing_configured', true);
    }
}
