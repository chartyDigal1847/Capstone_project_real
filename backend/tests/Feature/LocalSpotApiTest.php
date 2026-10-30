<?php

namespace Tests\Feature;

use App\Models\Store;
use App\Models\TourNode;
use App\Models\User;
use Illuminate\Foundation\Testing\RefreshDatabase;
use Tests\TestCase;

class LocalSpotApiTest extends TestCase
{
    use RefreshDatabase;

    protected function setUp(): void
    {
        parent::setUp();
        $this->seed();
    }

    public function test_public_catalog_hides_pending_stores(): void
    {
        $catalog = $this->getJson('/api/v1/catalog')
            ->assertOk()
            ->assertJsonMissing(['status' => 'pending'])
            ->assertJsonFragment(['name' => "Aling Nena's Sari-Sari"])
            ->json();
        $encoded = json_encode($catalog);
        $this->assertStringNotContainsString('original_image', $encoded);
        $this->assertStringNotContainsString('tours/originals', $encoded);
        $this->assertStringNotContainsString('#sanitized', $encoded);
    }

    public function test_product_search_and_nearby_distance_filter(): void
    {
        $this->getJson('/api/v1/products/search?q=mangga')
            ->assertOk()
            ->assertJsonFragment(['name' => 'Carabao mango']);

        $this->getJson('/api/v1/store-products/search?q=mango&lat=14.6195&lng=121.0568&radius_km=3')
            ->assertOk()
            ->assertJsonFragment(['name' => "Mang Tonyo's Fruit Stall"]);

        $this->getJson('/api/v1/store-products/search?q=mango&lat=14.0&lng=121.0&radius_km=1')
            ->assertOk()
            ->assertJsonPath('data', []);

        $this->getJson('/api/v1/products/search?q=mngo')
            ->assertOk()
            ->assertJsonFragment(['name' => 'Carabao mango']);

        $this->getJson('/api/v1/store-products/search?q=martilyo&lat=14.6195&lng=121.0568&radius_km=3')
            ->assertOk()
            ->assertJsonFragment(['name' => 'Cubao Hardware & Tools']);

        $this->getJson('/api/v1/store-products/search?q=food%20near%20me&lat=14.6195&lng=121.0568&radius_km=3')
            ->assertOk()
            ->assertJsonFragment(['name' => 'Carabao mango']);

        $this->getJson('/api/v1/store-products/search?q=tech&lat=14.6195&lng=121.0568&radius_km=3')
            ->assertOk()
            ->assertJsonFragment(['name' => 'USB-C cable']);

        $this->getJson('/api/v1/store-products/search?q=hardware&lat=14.6195&lng=121.0568&radius_km=3')
            ->assertOk()
            ->assertJsonFragment(['name' => 'Claw hammer']);

        $this->getJson('/api/v1/store-products/search?q=food&lat=14.6195&lng=121.0568&radius_km=3')
            ->assertOk()
            ->assertJsonFragment(['match_type' => 'category']);

        $this->getJson('/api/v1/store-products/search?q=&lat=14.6195&lng=121.0568&radius_km=3&category=family%3Afood')
            ->assertOk()
            ->assertJsonFragment(['name' => 'Carabao mango']);

        $this->getJson('/api/v1/store-products/search?q=&lat=14.6195&lng=121.0568&radius_km=3&category=Hardware')
            ->assertOk()
            ->assertJsonFragment(['name' => 'Claw hammer']);

        $this->getJson('/api/v1/search?q=mango&lat=14.6195&lng=121.0568&radius_km=3&sort=price')
            ->assertOk()
            ->assertJsonFragment(['name' => 'Carabao mango'])
            ->assertJsonPath('meta.current_page', 1);

        $this->getJson('/api/v1/store-products/search?q=USB-C%20charger%20for%20Samsung&lat=14.6195&lng=121.0568&radius_km=3')
            ->assertOk()
            ->assertJsonFragment(['name' => 'USB-C cable'])
            ->assertJsonFragment(['match_type' => 'semantic']);

        $this->getJson('/api/v1/store-products/search?q=4809990123456&lat=14.6195&lng=121.0568&radius_km=3')
            ->assertOk()
            ->assertJsonFragment(['name' => 'USB-C cable'])
            ->assertJsonFragment(['match_type' => 'identifier']);

        $this->postJson('/api/v1/search/by-image', [
            'hint' => 'mango',
            'lat' => 14.6195,
            'lng' => 121.0568,
            'radius_km' => 3,
        ])->assertOk()
            ->assertJsonFragment(['match_type' => 'similar'])
            ->assertJsonFragment(['name' => 'Carabao mango']);

        $this->postJson('/api/v1/search/by-image', [
            'hint' => 'mango and oil',
            'image' => 'data:image/jpeg;base64,ZmFrZQ==',
            'lat' => 14.6195,
            'lng' => 121.0568,
            'radius_km' => 3,
        ])->assertOk()
            ->assertJsonPath('data.image.received', true)
            ->assertJsonPath('data.objects.0.label', 'mango')
            ->assertJsonPath('data.objects.1.label', 'oil')
            ->assertJsonFragment(['name' => 'Carabao mango'])
            ->assertJsonFragment(['name' => 'Cooking oil']);

        $this->getJson('/api/v1/categories')
            ->assertOk()
            ->assertJsonPath('data.families.0.slug', 'food')
            ->assertJsonFragment(['slug' => 'tech']);
        $foodId = \Illuminate\Support\Facades\DB::table('categories')->where('slug', 'food')->value('id');
        $this->getJson('/api/v1/categories?parent_id='.$foodId)
            ->assertOk()
            ->assertJsonFragment(['slug' => 'produce'])
            ->assertJsonMissing(['slug' => 'electronics']);
    }

    public function test_login_issues_expiring_token_and_logout_revokes_it(): void
    {
        $login = $this->postJson('/api/v1/auth/login', [
            'email' => 'nena@localspot.ph',
            'password' => 'demo',
        ])->assertOk();

        $token = $login->json('data.token');
        $this->assertNotEmpty($login->json('data.token_expires_at'));

        $this->withToken($token)->getJson('/api/v1/me')->assertOk();
        $this->withToken($token)->deleteJson('/api/v1/auth/logout')->assertOk();
        $this->app['auth']->forgetGuards();
        $this->withToken($token)->getJson('/api/v1/me')->assertUnauthorized();

        $this->postJson('/api/v1/auth/register', [
            'name' => '',
            'email' => 'not-an-email',
            'password' => 'x',
            'role' => 'customer',
        ])
            ->assertStatus(422)
            ->assertJsonValidationErrors(['name', 'email', 'password']);
    }

    public function test_customer_cannot_write_another_store_inventory(): void
    {
        $storeId = Store::where('name', "Aling Nena's Sari-Sari")->value('id');
        $maria = User::where('email', 'maria@localspot.ph')->first();

        $this->actingAs($maria, 'sanctum')
            ->postJson("/api/v1/stores/$storeId/products", [
                'name' => 'Hack attempt',
                'price' => 1,
                'unit' => 'piece',
                'quantity' => 1,
                'availability' => 'in_stock',
            ])
            ->assertForbidden();
    }

    public function test_owner_can_create_listing_without_barcode(): void
    {
        $nena = User::where('email', 'nena@localspot.ph')->first();
        $storeId = $nena->ownedStores()->value('id');

        $this->actingAs($nena, 'sanctum')
            ->postJson("/api/v1/stores/$storeId/products", [
                'name' => 'White sugar',
                'category' => 'Staples',
                'price' => 68,
                'unit' => 'kilo',
                'quantity' => 9,
                'availability' => 'in_stock',
                'attributes' => ['unit_hint' => 'kilo'],
            ])
            ->assertCreated()
            ->assertJsonPath('data.product.attributes.unit_hint', 'kilo');

        $listingId = $this->actingAs($nena, 'sanctum')
            ->postJson("/api/v1/stores/$storeId/products", [
                'name' => 'Brown sugar',
                'category' => 'Staples',
                'price' => 70,
                'unit' => 'kilo',
                'quantity' => 4,
                'availability' => 'in_stock',
            ])
            ->json('data.id');
        $this->actingAs($nena, 'sanctum')
            ->getJson("/api/v1/store-products/$listingId/movements")
            ->assertOk()
            ->assertJsonFragment(['kind' => 'add']);
        $maria = User::where('email', 'maria@localspot.ph')->first();
        $this->actingAs($maria, 'sanctum')
            ->getJson("/api/v1/store-products/$listingId/movements")
            ->assertForbidden();
        $this->actingAs($maria, 'sanctum')->getJson('/api/v1/admin/audit')->assertForbidden();
        $admin = User::where('email', 'admin@localspot.ph')->first();
        $this->actingAs($admin, 'sanctum')
            ->getJson('/api/v1/admin/audit')
            ->assertOk()
            ->assertJsonFragment(['action' => 'listing.create']);
    }

    public function test_recognition_suggests_catalog_matches_and_unknown_barcodes(): void
    {
        $job = $this->postJson('/api/v1/product-recognition/suggest', ['hint' => 'mango'])
            ->assertOk()
            ->assertJsonPath('data.status', 'ready')
            ->assertJsonFragment(['name' => 'Carabao mango'])
            ->assertJsonFragment(['unknown_fields' => ['price', 'stock', 'compatibility']])
            ->json('data.id');
        $this->getJson("/api/v1/product-recognition/jobs/$job")
            ->assertOk()
            ->assertJsonPath('data.status', 'ready');
        $nena = User::where('email', 'nena@localspot.ph')->first();
        $productId = \App\Models\Product::query()->value('id');
        $this->actingAs($nena, 'sanctum')
            ->postJson("/api/v1/product-recognition/$job/confirm", ['product_id' => $productId])
            ->assertOk()
            ->assertJsonPath('data.status', 'confirmed');

        $this->postJson('/api/v1/product-recognition/suggest', ['barcode' => '0000000000000'])
            ->assertOk()
            ->assertJsonFragment(['label' => 'Unknown barcode · encode manually']);

        $this->postJson('/api/v1/product-recognition/suggest', ['hint' => '0000000000000'])
            ->assertOk()
            ->assertJsonFragment(['label' => 'Unknown barcode · encode manually']);
    }

    public function test_owner_can_update_and_archive_listing(): void
    {
        $nena = User::where('email', 'nena@localspot.ph')->first();
        $storeId = $nena->ownedStores()->value('id');
        $listingId = $this->actingAs($nena, 'sanctum')
            ->postJson("/api/v1/stores/$storeId/products", [
                'name' => 'Calamansi',
                'price' => 5,
                'unit' => 'piece',
                'quantity' => 20,
                'availability' => 'in_stock',
            ])
            ->assertCreated()
            ->json('data.id');

        $this->actingAs($nena, 'sanctum')
            ->patchJson("/api/v1/store-products/$listingId", [
                'price' => 6,
                'quantity' => 12,
                'status' => 'archived',
                'availability' => 'unavailable',
            ])
            ->assertOk()
            ->assertJsonPath('data.status', 'archived');
    }

    public function test_owner_can_publish_connected_tour_and_submit_promotion(): void
    {
        $nena = User::where('email', 'nena@localspot.ph')->first();
        $storeId = $nena->ownedStores()->value('id');

        $tourId = $this->actingAs($nena, 'sanctum')
            ->postJson("/api/v1/stores/$storeId/tours", ['title' => 'New walkthrough'])
            ->assertCreated()
            ->json('data.id');

        $this->actingAs($nena, 'sanctum')
            ->postJson("/api/v1/tours/$tourId/nodes", [
                'title' => 'Door',
                'image' => 'https://example.com/door.jpg',
            ])
            ->assertOk();
        $this->actingAs($nena, 'sanctum')
            ->postJson("/api/v1/tours/$tourId/nodes", [
                'title' => 'Aisle',
                'image' => 'https://example.com/aisle.jpg',
            ])
            ->assertOk();
        $this->actingAs($nena, 'sanctum')
            ->postJson("/api/v1/tours/$tourId/publish")
            ->assertStatus(422);
        foreach (TourNode::where('store_tour_id', $tourId)->get() as $pending) {
            $this->actingAs($nena, 'sanctum')
                ->postJson("/api/v1/tours/$tourId/nodes/{$pending->id}/process")
                ->assertOk()
                ->assertJsonFragment(['privacy_status' => 'ready']);
        }
        $failTour = $this->actingAs($nena, 'sanctum')
            ->postJson("/api/v1/stores/$storeId/tours", ['title' => 'Broken privacy'])
            ->json('data.id');
        $failNode = $this->actingAs($nena, 'sanctum')
            ->postJson("/api/v1/tours/$failTour/nodes", [
                'title' => 'Failed capture',
                'image' => 'https://example.com/fail.jpg',
            ])
            ->json('data.nodes.0.id');
        $this->actingAs($nena, 'sanctum')
            ->postJson("/api/v1/tours/$failTour/nodes/$failNode/process")
            ->assertOk()
            ->assertJsonFragment(['privacy_status' => 'failed']);
        $this->actingAs($nena, 'sanctum')
            ->getJson("/api/v1/tour-media/$failNode/status")
            ->assertOk()
            ->assertJsonPath('data.has_public_derivative', false);
        $firstNode = TourNode::where('store_tour_id', $tourId)->first();
        $this->actingAs($nena, 'sanctum')
            ->postJson("/api/v1/tours/$tourId/nodes/{$firstNode->id}/manual-blurs", [
                'regions' => [['x' => 0.12, 'y' => 0.2, 'w' => 0.25, 'h' => 0.3]],
            ])
            ->assertOk()
            ->assertJsonFragment(['manual_blur' => true])
            ->assertJsonPath('data.nodes.0.blur_regions.0.x', 0.12);
        $failed = TourNode::find($failNode);
        $this->assertNotEmpty($failed->original_image);
        $this->assertSame('', $failed->image);
        $this->actingAs($nena, 'sanctum')
            ->postJson("/api/v1/tours/$failTour/publish")
            ->assertStatus(422);
        $expired = TourNode::where('store_tour_id', $tourId)->first();
        $publicImage = $expired->image;
        $expired->update(['original_expires_at' => now()->subDay()]);
        $this->artisan('localspot:purge-tour-originals')->assertSuccessful();
        $this->assertNull($expired->fresh()->original_image);
        $this->assertSame($publicImage, $expired->fresh()->image);
        foreach (TourNode::where('store_tour_id', $tourId)->get() as $node) {
            $this->actingAs($nena, 'sanctum')
                ->postJson("/api/v1/tours/$tourId/nodes/{$node->id}/review")
                ->assertOk();
        }
        $this->actingAs($nena, 'sanctum')
            ->postJson("/api/v1/tours/$tourId/publish")
            ->assertOk()
            ->assertJsonPath('data.status', 'published');

        $this->actingAs($nena, 'sanctum')
            ->postJson("/api/v1/stores/$storeId/promotions", [
                'title' => 'Mango weekend',
                'offer' => '₱150/kilo',
                'sponsored' => true,
            ])
            ->assertCreated()
            ->assertJsonPath('data.status', 'pending');
    }

    public function test_owner_can_invite_staff_but_staff_and_customers_cannot(): void
    {
        $nena = User::where('email', 'nena@localspot.ph')->first();
        $ana = User::where('email', 'ana@localspot.ph')->first();
        $maria = User::where('email', 'maria@localspot.ph')->first();
        $storeId = $nena->ownedStores()->value('id');

        $this->actingAs($maria, 'sanctum')
            ->postJson("/api/v1/stores/$storeId/staff", ['email' => 'ana@localspot.ph'])
            ->assertForbidden();

        $this->actingAs($ana, 'sanctum')
            ->postJson("/api/v1/stores/$storeId/staff", ['email' => 'maria@localspot.ph'])
            ->assertForbidden();

        $this->actingAs($nena, 'sanctum')
            ->postJson("/api/v1/stores/$storeId/staff", ['email' => 'missing@localspot.ph'])
            ->assertStatus(422);

        $this->actingAs($nena, 'sanctum')
            ->postJson("/api/v1/stores/$storeId/staff", ['email' => 'maria@localspot.ph'])
            ->assertCreated()
            ->assertJsonPath('data.user.role', 'staff');
    }

    public function test_staff_grants_control_inventory_promotions_and_live_location(): void
    {
        $nena = User::where('email', 'nena@localspot.ph')->first();
        $ana = User::where('email', 'ana@localspot.ph')->first();
        $tonyo = User::where('email', 'tonyo@localspot.ph')->first();
        $maria = User::where('email', 'maria@localspot.ph')->first();
        $sari = Store::where('name', "Aling Nena's Sari-Sari")->first();
        $taho = Store::where('name', 'Kuya Ben Mobile Taho')->first();
        $listingId = $sari->listings()->value('id');

        $this->actingAs($ana, 'sanctum')
            ->patchJson("/api/v1/store-products/$listingId", ['price' => 99])
            ->assertOk();

        $this->actingAs($ana, 'sanctum')
            ->postJson("/api/v1/stores/{$sari->id}/promotions", [
                'title' => 'Staff offer',
                'offer' => 'Should be denied',
            ])
            ->assertForbidden();

        $this->actingAs($nena, 'sanctum')
            ->patchJson("/api/v1/stores/{$sari->id}/staff/{$ana->id}", [
                'can_promotions' => true,
            ])
            ->assertOk()
            ->assertJsonFragment(['promotions' => true]);

        $this->actingAs($ana->fresh(), 'sanctum')
            ->postJson("/api/v1/stores/{$sari->id}/promotions", [
                'title' => 'Staff offer',
                'offer' => 'Approved grant',
            ])
            ->assertCreated();

        $this->actingAs($tonyo, 'sanctum')
            ->postJson("/api/v1/stores/{$taho->id}/staff", [
                'email' => 'maria@localspot.ph',
                'can_location' => true,
            ])
            ->assertCreated();

        $this->actingAs($maria->fresh(), 'sanctum')
            ->postJson("/api/v1/stores/{$taho->id}/location-sessions", [
                'lat' => 14.6201,
                'lng' => 121.0572,
            ])
            ->assertCreated();
    }

    public function test_health_endpoint_reports_database_status(): void
    {
        $this->getJson('/api/v1/health')
            ->assertOk()
            ->assertJsonPath('data.ok', true)
            ->assertJsonPath('data.database', 'up')
            ->assertJsonPath('data.routing_configured', false)
            ->assertJsonPath('data.map', 'maplibre_openfreemap');
    }

    public function test_pilot_feedback_is_recorded_and_admin_can_list_it(): void
    {
        $maria = User::where('email', 'maria@localspot.ph')->first();
        $admin = User::where('email', 'admin@localspot.ph')->first();

        $this->actingAs($maria, 'sanctum')
            ->postJson('/api/v1/feedback', [
                'topic' => 'search',
                'body' => 'Mangga search worked in Cubao.',
                'area' => 'Cubao, Quezon City',
            ])
            ->assertCreated();

        $this->actingAs($maria, 'sanctum')->getJson('/api/v1/admin/feedback')->assertForbidden();
        $this->actingAs($admin, 'sanctum')
            ->getJson('/api/v1/admin/feedback')
            ->assertOk()
            ->assertJsonFragment(['body' => 'Mangga search worked in Cubao.']);
    }

    public function test_mobile_vendor_can_update_public_pin(): void
    {
        $tonyo = User::where('email', 'tonyo@localspot.ph')->first();
        $store = Store::where('name', 'Kuya Ben Mobile Taho')->first();

        $this->actingAs($tonyo, 'sanctum')
            ->patchJson('/api/v1/stores/'.$store->id, [
                'lat' => 14.6181,
                'lng' => 121.0544,
            ])
            ->assertOk()
            ->assertJsonPath('data.lat', 14.6181);

        $this->assertDatabaseHas('store_locations', [
            'store_id' => $store->id,
            'kind' => 'current',
        ]);
    }

    public function test_route_preview_returns_in_app_geometry_without_provider_secrets(): void
    {
        $this->postJson('/api/v1/routes/preview', [
            'origin_lat' => 14.6195,
            'origin_lng' => 121.0568,
            'destination_lat' => 14.6171,
            'destination_lng' => 121.0551,
        ])
            ->assertOk()
            ->assertJsonPath('data.fallback', true)
            ->assertJsonMissing(['ROUTING_BASE_URL'])
            ->assertJsonStructure(['data' => ['coordinates', 'distance_km', 'duration_minutes', 'provider']]);
    }

    public function test_mobile_vendor_location_session_is_explicit_and_expires(): void
    {
        $tonyo = User::where('email', 'tonyo@localspot.ph')->first();
        $nena = User::where('email', 'nena@localspot.ph')->first();
        $maria = User::where('email', 'maria@localspot.ph')->first();
        $store = Store::where('name', 'Kuya Ben Mobile Taho')->first();
        $fixed = Store::where('name', "Aling Nena's Sari-Sari")->first();

        $this->actingAs($maria, 'sanctum')
            ->postJson("/api/v1/stores/{$store->id}/location-sessions", [
                'lat' => 14.6201,
                'lng' => 121.0572,
            ])
            ->assertForbidden();

        $this->actingAs($nena, 'sanctum')
            ->postJson("/api/v1/stores/{$fixed->id}/location-sessions", [
                'lat' => 14.6201,
                'lng' => 121.0572,
            ])
            ->assertStatus(422);

        $this->actingAs($tonyo, 'sanctum')
            ->postJson("/api/v1/stores/{$store->id}/location-sessions", [
                'lat' => 14.6201,
                'lng' => 121.0572,
            ])
            ->assertCreated()
            ->assertJsonPath('data.active', true);

        $this->getJson('/api/v1/stores/'.$store->id)
            ->assertOk()
            ->assertJsonPath('data.location_mode', 'live')
            ->assertJsonPath('data.lat', 14.6201);

        $this->actingAs($tonyo, 'sanctum')
            ->patchJson("/api/v1/stores/{$store->id}/location-sessions/current", [
                'lat' => 14.6210,
                'lng' => 121.0580,
            ])
            ->assertOk()
            ->assertJsonPath('data.lat', 14.621);

        $this->actingAs($tonyo, 'sanctum')
            ->deleteJson("/api/v1/stores/{$store->id}/location-sessions/current")
            ->assertOk()
            ->assertJsonPath('data.active', false);

        $this->getJson('/api/v1/stores/'.$store->id)
            ->assertOk()
            ->assertJsonPath('data.location_mode', 'regular');
    }

    public function test_staff_cannot_start_live_location_but_can_update_an_active_session(): void
    {
        $tonyo = User::where('email', 'tonyo@localspot.ph')->first();
        $maria = User::where('email', 'maria@localspot.ph')->first();
        $store = Store::where('name', 'Kuya Ben Mobile Taho')->first();

        $this->actingAs($tonyo, 'sanctum')
            ->postJson("/api/v1/stores/{$store->id}/staff", ['email' => 'maria@localspot.ph'])
            ->assertCreated();

        $this->actingAs($maria->fresh(), 'sanctum')
            ->postJson("/api/v1/stores/{$store->id}/location-sessions", [
                'lat' => 14.6201,
                'lng' => 121.0572,
            ])
            ->assertForbidden();

        $this->actingAs($tonyo, 'sanctum')
            ->postJson("/api/v1/stores/{$store->id}/location-sessions", [
                'lat' => 14.6201,
                'lng' => 121.0572,
            ])
            ->assertCreated();

        $this->actingAs($maria->fresh(), 'sanctum')
            ->patchJson("/api/v1/stores/{$store->id}/location-sessions/current", [
                'lat' => 14.6233,
                'lng' => 121.0599,
            ])
            ->assertOk()
            ->assertJsonPath('data.lat', 14.6233);

        $this->actingAs($maria->fresh(), 'sanctum')
            ->deleteJson("/api/v1/stores/{$store->id}/location-sessions/current")
            ->assertForbidden();
    }

    public function test_expired_vendor_sessions_are_closed_by_scheduler(): void
    {
        $tonyo = User::where('email', 'tonyo@localspot.ph')->first();
        $store = Store::where('name', 'Kuya Ben Mobile Taho')->first();

        $this->actingAs($tonyo, 'sanctum')
            ->postJson("/api/v1/stores/{$store->id}/location-sessions", [
                'lat' => 14.6201,
                'lng' => 121.0572,
            ])
            ->assertCreated();

        $this->travel(3)->hours();
        $this->artisan('localspot:expire-location-sessions')->assertSuccessful();

        $this->getJson('/api/v1/stores/'.$store->id)
            ->assertOk()
            ->assertJsonPath('data.location_mode', 'stale');
    }

    public function test_backup_and_restore_round_trip(): void
    {
        $dir = storage_path('framework/testing/backups');
        if (! is_dir($dir)) {
            mkdir($dir, 0777, true);
        }

        $this->artisan('localspot:backup', ['--dir' => $dir])->assertSuccessful();
        $files = glob($dir.DIRECTORY_SEPARATOR.'*.json');
        $this->assertNotEmpty($files);

        $this->artisan('localspot:restore', ['file' => $files[0], '--force' => true])->assertSuccessful();
        $this->assertDatabaseHas('stores', ['name' => "Aling Nena's Sari-Sari"]);
    }
}
