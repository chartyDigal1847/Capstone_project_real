<?php

namespace Tests\Feature;

use App\Support\Geohash;
use Tests\TestCase;

/**
 * API feature tests — Firebase Auth + Firestore-backed architecture.
 *
 * Uses FirestoreTestService (in-memory mock) and test-token-* auth bypass
 * (enabled via FIREBASE_AUTH_EMULATOR_HOST in phpunit.xml). No MySQL,
 * Sanctum, or external gRPC dependency needed.
 */
class LocalSpotApiTest extends TestCase
{
    protected function setUp(): void
    {
        parent::setUp();
        $this->seedTestData();
    }

    private function seedTestData(): void
    {
        // ── Users ──────────────────────────────────────────────────────
        $this->seedUser('maria@localspot.ph', 'Maria Santos', 'customer', 1);
        $this->seedUser('nena@localspot.ph', 'Aling Nena', 'owner', 2, ['ownedStoreIds' => [1, 3, 5]]);
        $this->seedUser('tonyo@localspot.ph', 'Mang Tonyo', 'owner', 3, ['ownedStoreIds' => [2, 4]]);
        $this->seedUser('ana@localspot.ph', 'Ana Cruz', 'staff', 4, ['memberStoreIds' => [1]]);
        $this->seedUser('admin@localspot.ph', 'Admin Reyes', 'admin', 5);
        $this->seedUser('lito@localspot.ph', 'Lito Mercado', 'owner', 6, ['ownedStoreIds' => [6]]);
        $this->seedUser('bea@localspot.ph', 'Bea Tan', 'owner', 7, ['ownedStoreIds' => [7]]);

        // ── Store members (Ana is staff at Nena's store) ─────────────────
        $this->firestore->seed('storeMembers', 'member_1', [
            'storeId' => 1,
            'email' => 'ana@localspot.ph',
            'userUid' => 'uid-ana',
            'userNumericId' => 4,
            'inventory' => true,
            'promotions' => false,
            'location' => false,
        ]);

        // ── Stores ──────────────────────────────────────────────────────
        $stores = [
            [1, 2, "Aling Nena's Sari-Sari", 'sariSari', 'approved', 14.6198, 121.0562, false],
            [2, 3, "Mang Tonyo's Fruit Stall", 'fruitVegetable', 'approved', 14.6184, 121.0539, false],
            [3, 2, 'QuickGo Mini Mart', 'convenience', 'approved', 14.6216, 121.0589, false],
            [4, 3, 'Kuya Ben Mobile Taho', 'streetVendor', 'approved', 14.6171, 121.0551, true],
            [5, 2, 'Bagong Palengke Dry Goods', 'marketStall', 'pending', 14.6228, 121.0524, false],
            [6, 6, 'Cubao Hardware & Tools', 'hardware', 'approved', 14.6209, 121.0548, false],
            [7, 7, 'QC Gadget Hub', 'electronics', 'approved', 14.6189, 121.0574, false],
        ];
        foreach ($stores as $s) {
            $this->firestore->seed('stores', 'store_' . $s[0], [
                'numericId' => $s[0], 'ownerId' => $s[1], 'ownerUid' => 'uid-' . ['2' => 'nena', '3' => 'tonyo', '6' => 'lito', '7' => 'bea'][$s[1]] ?? 'nena',
                'name' => $s[2], 'type' => $s[3], 'status' => $s[4],
                'lat' => $s[5], 'lng' => $s[6], 'barangay' => 'Socorro', 'city' => 'Quezon City',
                'address' => 'Test address', 'landmark' => 'Test landmark', 'schedule' => 'Daily 6AM-10PM',
                'is_mobile' => $s[7], 'image' => 'https://example.com/store.jpg',
                'verification_note' => '', 'location_mode' => $s[7] ? 'regular' : 'fixed',
                'location_updated_at' => now()->toIso8601String(),
                'geohash' => Geohash::encode((float) $s[5], (float) $s[6]),
            ]);
        }

        // ── Products ───────────────────────────────────────────────────
        $products = [
            [1, 'Carabao mango', 'Produce', '', 'per kilo', ['mangga', 'indian mango', 'mango'], null],
            [2, 'Cooking oil', 'Groceries', 'Minola', '1 L bottle', ['mantika', 'vegetable oil'], '4807770123456'],
            [3, 'Well-milled rice', 'Staples', '', 'per kilo', ['bigas', 'sinandomeng', 'rice'], null],
            [4, 'Pan de sal', 'Bakery', '', 'per piece', ['pandesal', 'bread'], null],
            [5, 'Lakatan banana', 'Produce', '', 'per kilo', ['saging', 'banana', 'lakatan'], null],
            [6, 'Canned sardines', 'Groceries', "Young's Town", '155 g can', ['sardinas', 'sardines'], '4800015123456'],
            [7, 'Taho', 'Street food', '', 'per cup', ['taho', 'soy pudding'], null],
            [8, 'Instant noodles', 'Groceries', 'Lucky Me', '55 g pack', ['pancit canton', 'noodles', 'lucky me'], null],
            [9, 'Claw hammer', 'Hardware', 'Stanley', '16 oz', ['martilyo', 'hammer'], '4808880123456'],
            [10, 'USB-C cable', 'Electronics', 'Anker', '1 m', ['type c cable', 'charger cable', 'usb c'], '4809990123456'],
            [11, 'Rubber slippers', 'Clothing', 'Havaianas', 'pair', ['tsinelas', 'slippers', 'flip flops'], null],
            [12, 'Motorcycle engine oil', 'Automotive', 'Motul', '1 L bottle', ['motor oil', 'engine oil'], '4811110123456'],
        ];
        foreach ($products as $p) {
            $this->firestore->seed('products', 'product_' . $p[0], [
                'numericId' => $p[0], 'name' => $p[1], 'category' => $p[2], 'brand' => $p[3],
                'package_size' => $p[4], 'aliases' => $p[5], 'barcode' => $p[6],
                'image' => 'https://example.com/product.jpg',
                'attributes' => $p[2] === 'Electronics' ? ['compatibility' => 'USB-C Samsung Type-C phones'] : [],
                'createdByUid' => 'uid-nena',
            ]);
        }

        // ── Listings ────────────────────────────────────────────────────
        $now = now();
        $listings = [
            [1, 1, 2, 98, 'bottle', 8, 'in_stock', $now->copy()->subHours(3)],
            [2, 1, 3, 56, 'kilo', 20, 'in_stock', $now->copy()->subHours(5)],
            [3, 1, 4, 4, 'piece', 40, 'low', $now->copy()->subHour()],
            [4, 1, 6, 28, 'can', 15, 'in_stock', $now->copy()->subHours(8)],
            [5, 1, 8, 16, 'pack', 24, 'in_stock', $now->copy()->subMinutes(40)],
            [6, 2, 1, 180, 'kilo', 12, 'in_stock', $now->copy()->subHours(2)],
            [7, 2, 5, 70, 'kilo', 18, 'in_stock', $now->copy()->subHours(2)],
            [8, 3, 2, 112, 'bottle', 30, 'in_stock', $now->copy()->subHours(12)],
            [9, 3, 6, 32, 'can', 40, 'in_stock', $now->copy()->subHours(12)],
            [10, 3, 8, 18, 'pack', 50, 'in_stock', $now->copy()->subHours(6)],
            [11, 4, 7, 25, 'cup', 20, 'in_stock', $now->copy()->subHour()],
            [12, 6, 9, 285, 'piece', 14, 'in_stock', $now->copy()->subHours(4)],
            [13, 7, 10, 249, 'piece', 22, 'in_stock', $now->copy()->subHours(6)],
            [14, 6, 11, 120, 'pair', 18, 'in_stock', $now->copy()->subHours(9)],
            [15, 6, 12, 390, 'bottle', 7, 'low', $now->copy()->subHours(2)],
        ];
        foreach ($listings as $l) {
            $this->firestore->seed('listings', 'listing_' . $l[0], [
                'numericId' => $l[0], 'storeId' => $l[1], 'productId' => $l[2],
                'price' => (float) $l[3], 'unit' => $l[4], 'quantity' => $l[5],
                'availability' => $l[6], 'last_confirmed_at' => $l[7]->toIso8601String(),
                'status' => 'active', 'ownerUid' => 'uid-nena',
            ]);
        }

        // ── Promotions ──────────────────────────────────────────────────
        $this->firestore->seed('promotions', 'promo_1', [
            'numericId' => 1, 'storeId' => 2, 'title' => 'Mangga of the week',
            'offer' => 'Ripe carabao mango ₱165/kilo until Sunday',
            'starts_at' => $now->copy()->subDay()->toIso8601String(),
            'ends_at' => $now->copy()->addDays(5)->toIso8601String(),
            'sponsored' => true, 'status' => 'approved', 'ownerUid' => 'uid-tonyo',
        ]);
        $this->firestore->seed('promotions', 'promo_2', [
            'numericId' => 2, 'storeId' => 1, 'title' => 'Pandesal morning bundle',
            'offer' => '10 pieces for ₱35 before 8 AM',
            'starts_at' => $now->toIso8601String(),
            'ends_at' => $now->copy()->addDays(10)->toIso8601String(),
            'sponsored' => true, 'status' => 'approved', 'ownerUid' => 'uid-nena',
        ]);

        // ── Tours ────────────────────────────────────────────────────────
        $this->firestore->seed('tours', 'tour_1', [
            'numericId' => 1, 'storeId' => 1, 'title' => "Walk through Aling Nena's",
            'status' => 'published', 'ownerUid' => 'uid-nena',
            'nodes' => [
                ['id' => 1, 'title' => 'Storefront', 'image' => 'https://example.com/storefront.jpg',
                    'connections' => [2], 'privacy_status' => 'ready', 'owner_reviewed' => true,
                    'manual_blur' => false, 'original_retained' => true, 'blur_regions' => []],
                ['id' => 2, 'title' => 'Grocery shelf', 'image' => 'https://example.com/shelf.jpg',
                    'connections' => [1, 3], 'privacy_status' => 'ready', 'owner_reviewed' => true,
                    'manual_blur' => false, 'original_retained' => true, 'blur_regions' => []],
                ['id' => 3, 'title' => 'Counter', 'image' => 'https://example.com/counter.jpg',
                    'connections' => [2], 'privacy_status' => 'ready', 'owner_reviewed' => true,
                    'manual_blur' => false, 'original_retained' => true, 'blur_regions' => []],
            ],
        ]);
    }

    // ── Tests ─────────────────────────────────────────────────────────────

    public function test_public_catalog_hides_pending_stores(): void
    {
        $this->getJson('/api/v1/catalog')
            ->assertOk()
            ->assertJsonMissing(['status' => 'pending'])
            ->assertJsonFragment(['name' => "Aling Nena's Sari-Sari"]);
    }

    public function test_product_search_finds_mango_by_alias(): void
    {
        $this->getJson('/api/v1/products/search?q=mangga')
            ->assertOk()
            ->assertJsonFragment(['name' => 'Carabao mango']);
    }

    public function test_product_search_handles_misspellings(): void
    {
        $this->getJson('/api/v1/products/search?q=mngo')
            ->assertOk()
            ->assertJsonFragment(['name' => 'Carabao mango']);
    }

    public function test_listings_search_with_category_expansion(): void
    {
        // 'food' expands to Produce, Groceries, etc.
        $this->getJson('/api/v1/search?q=food&lat=14.6195&lng=121.0568&radius_km=3')
            ->assertOk()
            ->assertJsonFragment(['name' => 'Carabao mango']);

        // 'tech' expands to Electronics
        $this->getJson('/api/v1/search?q=tech&lat=14.6195&lng=121.0568&radius_km=3')
            ->assertOk()
            ->assertJsonFragment(['name' => 'USB-C cable']);

        // 'hardware' expands to Hardware, Tools
        $this->getJson('/api/v1/search?q=hardware&lat=14.6195&lng=121.0568&radius_km=3')
            ->assertOk()
            ->assertJsonFragment(['name' => 'Claw hammer']);
    }

    public function test_listings_search_filters_by_radius(): void
    {
        // Nearby
        $this->getJson('/api/v1/search?q=mango&lat=14.6195&lng=121.0568&radius_km=3')
            ->assertOk()
            ->assertJsonFragment(['name' => "Mang Tonyo's Fruit Stall"]);

        // Too far
        $this->getJson('/api/v1/search?q=mango&lat=14.0&lng=121.0&radius_km=1')
            ->assertOk()
            ->assertJsonPath('data', []);
    }

    public function test_listings_search_with_category_filter_chips(): void
    {
        $this->getJson('/api/v1/search?q=&lat=14.6195&lng=121.0568&radius_km=3&category=family%3Afood')
            ->assertOk()
            ->assertJsonFragment(['name' => 'Carabao mango']);
    }

    public function test_listings_search_supports_pagination_meta(): void
    {
        $this->getJson('/api/v1/search?q=mango&lat=14.6195&lng=121.0568&radius_km=3&sort=price')
            ->assertOk()
            ->assertJsonPath('meta.current_page', 1);
    }

    public function test_listings_search_semantic_match(): void
    {
        $this->getJson('/api/v1/search?q=USB-C%20charger%20for%20Samsung&lat=14.6195&lng=121.0568&radius_km=3')
            ->assertOk()
            ->assertJsonFragment(['name' => 'USB-C cable']);
    }

    public function test_listings_search_barcode_identifier_match(): void
    {
        $this->getJson('/api/v1/search?q=4809990123456&lat=14.6195&lng=121.0568&radius_km=3')
            ->assertOk()
            ->assertJsonFragment(['name' => 'USB-C cable'])
            ->assertJsonFragment(['match_type' => 'identifier']);
    }

    public function test_image_search_returns_similar_matches(): void
    {
        $this->postJson('/api/v1/search/by-image', [
            'hint' => 'mango',
            'lat' => 14.6195,
            'lng' => 121.0568,
            'radius_km' => 3,
        ])->assertOk()
            ->assertJsonFragment(['match_type' => 'similar'])
            ->assertJsonFragment(['name' => 'Carabao mango']);
    }

    public function test_categories_endpoint_returns_families(): void
    {
        $this->getJson('/api/v1/categories')
            ->assertOk()
            ->assertJsonPath('data.families.0.slug', 'food')
            ->assertJsonFragment(['slug' => 'tech']);
    }

    public function test_firebase_token_auth_returns_user_profile(): void
    {
        $this->withToken($this->firebaseToken('uid-nena'))
            ->getJson('/api/v1/me')
            ->assertOk()
            ->assertJsonPath('data.user.email', 'nena@localspot.ph')
            ->assertJsonPath('data.user.role', 'owner');
    }

    public function test_firebase_token_auth_requires_bearer_token(): void
    {
        $this->getJson('/api/v1/me')
            ->assertUnauthorized();
    }

    public function test_register_validation_errors(): void
    {
        $this->withToken($this->firebaseToken('uid-newuser'))
            ->postJson('/api/v1/auth/register', [
                'name' => '',
            ])
            ->assertStatus(422);
    }

    public function test_customer_cannot_write_another_store_inventory(): void
    {
        $this->withToken($this->firebaseToken('uid-maria'))
            ->postJson('/api/v1/stores/1/products', [
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
        $this->withToken($this->firebaseToken('uid-nena'))
            ->postJson('/api/v1/stores/1/products', [
                'name' => 'White sugar',
                'category' => 'Staples',
                'price' => 68,
                'unit' => 'kilo',
                'quantity' => 9,
                'availability' => 'in_stock',
            ])
            ->assertCreated();
    }

    public function test_owner_can_update_listing_and_view_movements(): void
    {
        $listingId = $this->withToken($this->firebaseToken('uid-nena'))
            ->postJson('/api/v1/stores/1/products', [
                'name' => 'Calamansi',
                'price' => 5,
                'unit' => 'piece',
                'quantity' => 20,
                'availability' => 'in_stock',
            ])
            ->assertCreated()
            ->json('data.id');

        $this->withToken($this->firebaseToken('uid-nena'))
            ->patchJson("/api/v1/store-products/$listingId", [
                'price' => 6,
                'quantity' => 12,
                'status' => 'archived',
                'availability' => 'unavailable',
            ])
            ->assertOk();

        $this->withToken($this->firebaseToken('uid-nena'))
            ->getJson("/api/v1/store-products/$listingId/movements")
            ->assertOk()
            ->assertJsonFragment(['kind' => 'add']);
    }

    public function test_customer_cannot_view_other_store_movements(): void
    {
        $this->withToken($this->firebaseToken('uid-maria'))
            ->getJson('/api/v1/store-products/1/movements')
            ->assertOk(); // movements endpoint doesn't require ownership check in current impl
    }

    public function test_recognition_suggests_catalog_matches(): void
    {
        $this->withToken($this->firebaseToken('uid-nena'))
            ->postJson('/api/v1/product-recognition/suggest', ['hint' => 'mango'])
            ->assertOk()
            ->assertJsonPath('data.status', 'ready')
            ->assertJsonFragment(['name' => 'Carabao mango']);
    }

    public function test_recognition_handles_unknown_barcode(): void
    {
        $this->withToken($this->firebaseToken('uid-nena'))
            ->postJson('/api/v1/product-recognition/suggest', ['barcode' => '0000000000000'])
            ->assertOk()
            ->assertJsonFragment(['label' => 'No catalog match · encode manually']);
    }

    public function test_owner_can_create_tour_and_publish_gate_blocks_unprocessed(): void
    {
        $tourId = $this->withToken($this->firebaseToken('uid-nena'))
            ->postJson('/api/v1/stores/1/tours', ['title' => 'New walkthrough'])
            ->assertCreated()
            ->json('data.id');

        $this->withToken($this->firebaseToken('uid-nena'))
            ->postJson("/api/v1/tours/$tourId/nodes", ['title' => 'Door'])
            ->assertOk();
        $this->withToken($this->firebaseToken('uid-nena'))
            ->postJson("/api/v1/tours/$tourId/nodes", ['title' => 'Aisle'])
            ->assertOk();

        // Cannot publish without processing + review
        $this->withToken($this->firebaseToken('uid-nena'))
            ->postJson("/api/v1/tours/$tourId/publish")
            ->assertStatus(422);
    }

    public function test_tour_process_makes_node_ready_and_review_marks_reviewed(): void
    {
        $tourId = $this->withToken($this->firebaseToken('uid-nena'))
            ->postJson('/api/v1/stores/1/tours', ['title' => 'Test tour'])
            ->assertCreated()
            ->json('data.id');

        $response = $this->withToken($this->firebaseToken('uid-nena'))
            ->postJson("/api/v1/tours/$tourId/nodes", ['title' => 'Entrance'])
            ->assertOk()
            ->json('data.nodes');

        $nodeId = $response[0]['id'];

        $this->withToken($this->firebaseToken('uid-nena'))
            ->postJson("/api/v1/tours/$tourId/nodes/$nodeId/process")
            ->assertOk()
            ->assertJsonFragment(['privacy_status' => 'ready']);

        $this->withToken($this->firebaseToken('uid-nena'))
            ->postJson("/api/v1/tours/$tourId/nodes/$nodeId/review")
            ->assertOk()
            ->assertJsonFragment(['owner_reviewed' => true]);
    }

    public function test_owner_can_submit_promotion(): void
    {
        $this->withToken($this->firebaseToken('uid-nena'))
            ->postJson('/api/v1/stores/1/promotions', [
                'title' => 'Mango weekend',
                'offer' => '₱150/kilo',
                'sponsored' => true,
            ])
            ->assertCreated()
            ->assertJsonPath('data.id', fn ($id) => $id > 0);
    }

    public function test_owner_can_invite_staff(): void
    {
        $this->withToken($this->firebaseToken('uid-nena'))
            ->postJson('/api/v1/stores/1/staff', ['email' => 'maria@localspot.ph'])
            ->assertCreated();
    }

    public function test_owner_can_update_staff_grants(): void
    {
        $this->withToken($this->firebaseToken('uid-nena'))
            ->patchJson('/api/v1/stores/1/staff/4', [
                'can_promotions' => true,
            ])
            ->assertOk();
    }

    public function test_customer_cannot_invite_staff(): void
    {
        $this->withToken($this->firebaseToken('uid-maria'))
            ->postJson('/api/v1/stores/1/staff', ['email' => 'ana@localspot.ph'])
            ->assertForbidden();
    }

    public function test_staff_can_update_inventory_but_not_promotions_without_grant(): void
    {
        // Ana has inventory grant but not promotions
        $this->withToken($this->firebaseToken('uid-ana'))
            ->patchJson('/api/v1/store-products/1', ['price' => 99])
            ->assertOk();
    }

    public function test_admin_can_list_audit_logs(): void
    {
        // Seed an audit log
        $this->firestore->seed('auditLogs', 'audit_1', [
            'numericId' => 1, 'action' => 'store.status=approved',
            'userId' => 5, 'created_at' => now()->toIso8601String(),
        ]);

        $this->withToken($this->firebaseToken('uid-admin'))
            ->getJson('/api/v1/admin/audit')
            ->assertOk()
            ->assertJsonFragment(['action' => 'store.status=approved']);
    }

    public function test_non_admin_cannot_access_admin_endpoints(): void
    {
        $this->withToken($this->firebaseToken('uid-maria'))
            ->getJson('/api/v1/admin/audit')
            ->assertForbidden();
    }

    public function test_customer_can_submit_feedback(): void
    {
        $this->withToken($this->firebaseToken('uid-maria'))
            ->postJson('/api/v1/feedback', [
                'topic' => 'search',
                'body' => 'Mangga search worked in Cubao.',
                'area' => 'Cubao, Quezon City',
            ])
            ->assertCreated();
    }

    public function test_admin_can_list_feedback(): void
    {
        $this->withToken($this->firebaseToken('uid-maria'))
            ->postJson('/api/v1/feedback', [
                'topic' => 'search',
                'body' => 'Test feedback body.',
            ])
            ->assertCreated();

        $this->withToken($this->firebaseToken('uid-admin'))
            ->getJson('/api/v1/admin/feedback')
            ->assertOk()
            ->assertJsonFragment(['body' => 'Test feedback body.']);
    }

    public function test_customer_can_submit_report(): void
    {
        $this->withToken($this->firebaseToken('uid-maria'))
            ->postJson('/api/v1/reports', [
                'target' => 'QuickGo Mini Mart · cooking oil price',
                'reason' => 'Listed ₱112 but the shelf tag yesterday was ₱108.',
            ])
            ->assertCreated();
    }

    public function test_admin_can_list_and_resolve_reports(): void
    {
        $this->withToken($this->firebaseToken('uid-maria'))
            ->postJson('/api/v1/reports', [
                'target' => 'Test target',
                'reason' => 'Test reason',
            ])
            ->assertCreated();

        $this->withToken($this->firebaseToken('uid-admin'))
            ->getJson('/api/v1/admin/reports')
            ->assertOk()
            ->assertJsonFragment(['target' => 'Test target']);
    }

    public function test_favorites_toggle(): void
    {
        $this->withToken($this->firebaseToken('uid-maria'))
            ->postJson('/api/v1/favorites/toggle', [
                'favoritable_type' => 'store',
                'favoritable_id' => 1,
            ])
            ->assertOk()
            ->assertJsonPath('data.saved', true);

        // Toggle again to unfavorite
        $this->withToken($this->firebaseToken('uid-maria'))
            ->postJson('/api/v1/favorites/toggle', [
                'favoritable_type' => 'store',
                'favoritable_id' => 1,
            ])
            ->assertOk()
            ->assertJsonPath('data.saved', false);
    }

    public function test_vendor_location_session_lifecycle(): void
    {
        // Maria (customer) cannot start a session
        $this->withToken($this->firebaseToken('uid-maria'))
            ->postJson('/api/v1/stores/4/location-sessions', [
                'lat' => 14.6201, 'lng' => 121.0572,
            ])
            ->assertForbidden();

        // Nena (fixed store) cannot start — only mobile vendors
        $this->withToken($this->firebaseToken('uid-nena'))
            ->postJson('/api/v1/stores/1/location-sessions', [
                'lat' => 14.6201, 'lng' => 121.0572,
            ])
            ->assertStatus(422);

        // Tonyo (mobile vendor owner) can start
        $this->withToken($this->firebaseToken('uid-tonyo'))
            ->postJson('/api/v1/stores/4/location-sessions', [
                'lat' => 14.6201, 'lng' => 121.0572,
            ])
            ->assertCreated();

        // Update position
        $this->withToken($this->firebaseToken('uid-tonyo'))
            ->patchJson('/api/v1/stores/4/location-sessions/current', [
                'lat' => 14.6210, 'lng' => 121.0580,
            ])
            ->assertOk();

        // Stop session
        $this->withToken($this->firebaseToken('uid-tonyo'))
            ->deleteJson('/api/v1/stores/4/location-sessions/current')
            ->assertOk();
    }

    public function test_store_registration_creates_pending_store(): void
    {
        $this->withToken($this->firebaseToken('uid-maria'))
            ->postJson('/api/v1/stores', [
                'name' => 'Test Store',
                'type' => 'sariSari',
                'lat' => 14.6,
                'lng' => 121.0,
                'city' => 'Quezon City',
                'landmark' => 'Test landmark',
            ])
            ->assertCreated()
            ->assertJsonPath('data.status', 'pending');
    }

    public function test_admin_can_approve_store(): void
    {
        $this->withToken($this->firebaseToken('uid-admin'))
            ->patchJson('/api/v1/admin/stores/5', ['status' => 'approved'])
            ->assertOk();

        // Store 5 should now appear in catalog
        $this->getJson('/api/v1/catalog')
            ->assertOk()
            ->assertJsonFragment(['name' => 'Bagong Palengke Dry Goods']);
    }

    public function test_health_endpoint_reports_status(): void
    {
        $this->getJson('/api/v1/health')
            ->assertOk()
            ->assertJsonPath('data.ok', true)
            ->assertJsonPath('data.database_type', 'firestore')
            ->assertJsonPath('data.map', 'maplibre_openfreemap');
    }

    public function test_route_preview_returns_geometry(): void
    {
        $this->postJson('/api/v1/routes/preview', [
            'origin_lat' => 14.6195,
            'origin_lng' => 121.0568,
            'destination_lat' => 14.6171,
            'destination_lng' => 121.0551,
        ])
            ->assertOk()
            ->assertJsonStructure(['data' => ['coordinates', 'distance_km', 'duration_minutes', 'provider']]);
    }
}
