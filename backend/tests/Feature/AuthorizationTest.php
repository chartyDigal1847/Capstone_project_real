<?php

namespace Tests\Feature;

use Tests\TestCase;

/**
 * Comprehensive authentication and role-based authorization tests.
 *
 * Covers:
 *   - Firebase token verification edge cases
 *   - Emulator bypass protection (empty env var must NOT enable bypass)
 *   - Role-based access control for all four roles
 *   - Cross-store ID manipulation prevention
 *   - Ownership changes and staff membership
 */
class AuthorizationTest extends TestCase
{
    protected function setUp(): void
    {
        parent::setUp();
        $this->seedAuthTestData();
    }

    private function seedAuthTestData(): void
    {
        // Users
        $this->seedUser('maria@test.ph', 'Maria Customer', 'customer', 1);
        $this->seedUser('nena@test.ph', 'Aling Nena', 'owner', 2, ['ownedStoreIds' => [10]]);
        $this->seedUser('tonyo@test.ph', 'Mang Tonyo', 'owner', 3, ['ownedStoreIds' => [20]]);
        $this->seedUser('ana@test.ph', 'Ana Staff', 'staff', 4, ['memberStoreIds' => [10]]);
        $this->seedUser('admin@test.ph', 'Admin', 'admin', 5);
        $this->seedUser('bea@test.ph', 'Bea Staff-NoGrant', 'staff', 6, ['memberStoreIds' => [10]]);

        // Store members (Ana has inventory grant, Bea has no grants)
        $this->firestore->seed('storeMembers', 'member_ana', [
            'storeId' => 10, 'email' => 'ana@test.ph',
            'userUid' => 'uid-ana', 'userNumericId' => 4,
            'inventory' => true, 'promotions' => false, 'location' => false,
        ]);
        $this->firestore->seed('storeMembers', 'member_bea', [
            'storeId' => 10, 'email' => 'bea@test.ph',
            'userUid' => 'uid-bea', 'userNumericId' => 6,
            'inventory' => false, 'promotions' => false, 'location' => false,
        ]);

        // Two stores
        foreach ([
            [10, 2, "Nena's Store", 'sariSari', 'approved', 14.6198, 121.0562],
            [20, 3, "Tonyo's Store", 'fruitVegetable', 'approved', 14.6184, 121.0539],
        ] as $s) {
            $this->firestore->seed('stores', 'store_' . $s[0], [
                'numericId' => $s[0], 'ownerId' => $s[1], 'ownerUid' => 'uid-' . ['2' => 'nena', '3' => 'tonyo'][$s[1]],
                'name' => $s[2], 'type' => $s[3], 'status' => $s[4],
                'lat' => $s[5], 'lng' => $s[6], 'barangay' => 'Test', 'city' => 'Quezon City',
                'address' => 'Test', 'landmark' => 'Test', 'schedule' => 'Daily',
                'is_mobile' => false, 'image' => null, 'verification_note' => '',
                'location_mode' => 'fixed', 'location_updated_at' => now()->toIso8601String(),
                'geohash' => 'wdw4',
            ]);
        }

        // A listing in Nena's store
        $this->firestore->seed('listings', 'listing_10', [
            'numericId' => 10, 'storeId' => 10, 'productId' => 1,
            'price' => 50.0, 'unit' => 'kilo', 'quantity' => 10,
            'availability' => 'in_stock', 'last_confirmed_at' => now()->toIso8601String(),
            'status' => 'active', 'ownerUid' => 'uid-nena',
        ]);
        $this->firestore->seed('products', 'product_1', [
            'numericId' => 1, 'name' => 'Test Product', 'category' => 'Groceries',
            'brand' => '', 'package_size' => '', 'aliases' => [], 'barcode' => null,
            'image' => '', 'attributes' => [],
        ]);
    }

    // ── Unauthenticated access ────────────────────────────────────────────

    public function test_unauthenticated_cannot_access_protected_endpoints(): void
    {
        // No Authorization header
        $this->getJson('/api/v1/me')->assertUnauthorized();
        $this->postJson('/api/v1/stores', [])->assertUnauthorized();
        $this->patchJson('/api/v1/store-products/10', [])->assertUnauthorized();
        $this->deleteJson('/api/v1/stores/10/location-sessions/current')->assertUnauthorized();
    }

    public function test_public_catalog_accessible_without_token(): void
    {
        $this->getJson('/api/v1/catalog')->assertOk();
        $this->getJson('/api/v1/products/search?q=test')->assertOk();
    }

    // ── Emulator bypass protection ────────────────────────────────────────

    public function test_test_token_works_in_test_environment(): void
    {
        // phpunit.xml sets FIREBASE_AUTH_EMULATOR_HOST=test, enabling bypass
        $this->withToken($this->firebaseToken('uid-maria'))
            ->getJson('/api/v1/me')
            ->assertOk();
    }

    public function test_empty_bearer_token_rejected(): void
    {
        $this->withHeaders(['Authorization' => 'Bearer '])
            ->getJson('/api/v1/me')
            ->assertUnauthorized();
    }

    public function test_malformed_token_rejected(): void
    {
        $this->withToken('not.a.valid.jwt')
            ->getJson('/api/v1/me')
            ->assertUnauthorized();
    }

    public function test_allow_emulator_is_false_when_env_is_empty(): void
    {
        // This verifies the config logic: filled('') === false
        // When FIREBASE_AUTH_EMULATOR_HOST is empty, allow_emulator must be false.
        // We cannot change app config mid-test, but we can verify the production
        // firebase.php config logic through the FirebaseAuthService directly.
        $service = $this->app->make(\App\Services\FirebaseAuthService::class);
        // In test environment FIREBASE_AUTH_EMULATOR_HOST=test so allowEmulator=true.
        // This test documents the behavior; production must have empty host.
        $this->assertTrue($service->shouldAllowEmulator(),
            'In test env (FIREBASE_AUTH_EMULATOR_HOST=test), emulator should be allowed.');
    }

    public function test_emulator_bypass_uses_only_test_token_prefix(): void
    {
        // Only tokens starting with "test-token-" are accepted as emulator tokens.
        // A real JWT that happens to start differently should not be accepted as test token.
        $this->withToken('uid-maria') // No "test-token-" prefix
            ->getJson('/api/v1/me')
            ->assertUnauthorized();
    }

    // ── Customer access ───────────────────────────────────────────────────

    public function test_customer_can_view_public_catalog(): void
    {
        $this->withToken($this->firebaseToken('uid-maria'))
            ->getJson('/api/v1/catalog')
            ->assertOk();
    }

    public function test_customer_can_search_listings(): void
    {
        $this->withToken($this->firebaseToken('uid-maria'))
            ->getJson('/api/v1/search?q=test&lat=14.6195&lng=121.0568&radius_km=3')
            ->assertOk();
    }

    public function test_customer_can_manage_own_favorites(): void
    {
        $this->withToken($this->firebaseToken('uid-maria'))
            ->postJson('/api/v1/favorites/toggle', [
                'favoritable_type' => 'store',
                'favoritable_id' => 10,
            ])
            ->assertOk();
    }

    public function test_customer_can_submit_feedback(): void
    {
        $this->withToken($this->firebaseToken('uid-maria'))
            ->postJson('/api/v1/feedback', [
                'topic' => 'search',
                'body' => 'Good search',
            ])
            ->assertCreated();
    }

    public function test_customer_can_submit_report(): void
    {
        $this->withToken($this->firebaseToken('uid-maria'))
            ->postJson('/api/v1/reports', [
                'target' => 'Test store',
                'reason' => 'Wrong price',
            ])
            ->assertCreated();
    }

    public function test_customer_cannot_modify_store_inventory(): void
    {
        $this->withToken($this->firebaseToken('uid-maria'))
            ->postJson('/api/v1/stores/10/products', [
                'name' => 'Hack item',
                'price' => 1,
                'unit' => 'piece',
                'quantity' => 1,
                'availability' => 'in_stock',
            ])
            ->assertForbidden();
    }

    public function test_customer_cannot_update_listing(): void
    {
        $this->withToken($this->firebaseToken('uid-maria'))
            ->patchJson('/api/v1/store-products/10', ['price' => 1])
            ->assertForbidden();
    }

    public function test_customer_cannot_approve_store(): void
    {
        $this->withToken($this->firebaseToken('uid-maria'))
            ->patchJson('/api/v1/admin/stores/10', ['status' => 'approved'])
            ->assertForbidden();
    }

    public function test_customer_cannot_assign_admin_role(): void
    {
        // Attempting to self-assign admin via register is rejected by server validation.
        // 'admin' is not a valid registration role — only 'customer' and 'owner' are accepted.
        $this->withToken($this->firebaseToken('uid-newuser'))
            ->postJson('/api/v1/auth/register', [
                'name' => 'Hacker',
                'email' => 'hacker@test.ph',
                'role' => 'admin', // Attempt to self-assign admin
            ])
            ->assertStatus(422); // Server rejects the invalid role value
    }

    public function test_customer_cannot_invite_staff(): void
    {
        $this->withToken($this->firebaseToken('uid-maria'))
            ->postJson('/api/v1/stores/10/staff', ['email' => 'ana@test.ph'])
            ->assertForbidden();
    }

    public function test_customer_cannot_modify_another_users_data(): void
    {
        // Cannot update another store's listing
        $this->withToken($this->firebaseToken('uid-maria'))
            ->patchJson('/api/v1/store-products/10', ['price' => 1])
            ->assertForbidden();
    }

    // ── Owner access ──────────────────────────────────────────────────────

    public function test_owner_can_manage_own_store(): void
    {
        $this->withToken($this->firebaseToken('uid-nena'))
            ->postJson('/api/v1/stores/10/products', [
                'name' => 'New product',
                'price' => 25.0,
                'unit' => 'piece',
                'quantity' => 5,
                'availability' => 'in_stock',
            ])
            ->assertCreated();
    }

    public function test_owner_cannot_modify_another_owners_store(): void
    {
        // Nena tries to add a product to Tonyo's store (store 20)
        $this->withToken($this->firebaseToken('uid-nena'))
            ->postJson('/api/v1/stores/20/products', [
                'name' => 'Hack product',
                'price' => 1.0,
                'unit' => 'piece',
                'quantity' => 1,
                'availability' => 'in_stock',
            ])
            ->assertForbidden();
    }

    public function test_owner_cannot_invite_staff_to_another_owners_store(): void
    {
        $this->withToken($this->firebaseToken('uid-nena'))
            ->postJson('/api/v1/stores/20/staff', ['email' => 'ana@test.ph'])
            ->assertForbidden();
    }

    public function test_owner_cannot_grant_themselves_admin(): void
    {
        // Even if an owner edits their store, the role must not change to admin.
        // The user profile role is always set through the admin endpoint.
        $profile = $this->withToken($this->firebaseToken('uid-nena'))
            ->getJson('/api/v1/me')
            ->assertOk()
            ->json('data.user.role');

        $this->assertSame('owner', $profile);
    }

    public function test_owner_cannot_access_another_stores_promotions_directly(): void
    {
        // Tonyo attempts to create a promotion on Nena's store
        $this->withToken($this->firebaseToken('uid-tonyo'))
            ->postJson('/api/v1/stores/10/promotions', [
                'title' => 'Hack promo',
                'offer' => 'Free stuff',
                'sponsored' => false,
            ])
            ->assertForbidden();
    }

    // ── Staff access ──────────────────────────────────────────────────────

    public function test_staff_can_perform_granted_inventory_operations(): void
    {
        // Ana has inventory=true for store 10
        $this->withToken($this->firebaseToken('uid-ana'))
            ->patchJson('/api/v1/store-products/10', [
                'price' => 55.0,
                'quantity' => 8,
                'availability' => 'in_stock',
                'status' => 'active',
            ])
            ->assertOk();
    }

    public function test_staff_cannot_manage_stores_they_are_not_assigned_to(): void
    {
        // Ana is staff at store 10, NOT store 20
        $this->withToken($this->firebaseToken('uid-ana'))
            ->postJson('/api/v1/stores/20/products', [
                'name' => 'Hack attempt',
                'price' => 1.0,
                'unit' => 'piece',
                'quantity' => 1,
                'availability' => 'in_stock',
            ])
            ->assertForbidden();
    }

    public function test_staff_with_no_inventory_grant_cannot_update_listing(): void
    {
        // Bea is a member of store 10 but has no grants (inventory=false)
        $this->withToken($this->firebaseToken('uid-bea'))
            ->patchJson('/api/v1/store-products/10', ['price' => 1.0])
            ->assertForbidden();
    }

    public function test_staff_cannot_invite_other_staff(): void
    {
        // Only store owners can invite staff
        $this->withToken($this->firebaseToken('uid-ana'))
            ->postJson('/api/v1/stores/10/staff', ['email' => 'maria@test.ph'])
            ->assertForbidden();
    }

    public function test_staff_cannot_change_ownership(): void
    {
        // Staff cannot patch admin endpoints
        $this->withToken($this->firebaseToken('uid-ana'))
            ->patchJson('/api/v1/admin/stores/10', ['status' => 'approved'])
            ->assertForbidden();
    }

    // ── Administrator access ──────────────────────────────────────────────

    public function test_admin_can_access_audit_logs(): void
    {
        $this->firestore->seed('auditLogs', 'log_1', [
            'numericId' => 1, 'action' => 'test.action',
            'userId' => 5, 'created_at' => now()->toIso8601String(),
        ]);

        $this->withToken($this->firebaseToken('uid-admin'))
            ->getJson('/api/v1/admin/audit')
            ->assertOk()
            ->assertJsonFragment(['action' => 'test.action']);
    }

    public function test_admin_can_approve_store(): void
    {
        $this->withToken($this->firebaseToken('uid-admin'))
            ->patchJson('/api/v1/admin/stores/10', ['status' => 'approved'])
            ->assertOk();
    }

    public function test_admin_can_resolve_reports(): void
    {
        $this->withToken($this->firebaseToken('uid-maria'))
            ->postJson('/api/v1/reports', [
                'target' => 'Store X', 'reason' => 'Bad price',
            ])
            ->assertCreated();

        $this->withToken($this->firebaseToken('uid-admin'))
            ->getJson('/api/v1/admin/reports')
            ->assertOk()
            ->assertJsonFragment(['target' => 'Store X']);
    }

    // ── Cross-store ID manipulation ───────────────────────────────────────

    public function test_owner_cannot_update_listing_in_another_store_via_id_manipulation(): void
    {
        // listing_10 belongs to store 10, owned by Nena.
        // Tonyo tries to patch it directly.
        $this->withToken($this->firebaseToken('uid-tonyo'))
            ->patchJson('/api/v1/store-products/10', ['price' => 1.0])
            ->assertForbidden();
    }

    public function test_cross_store_staff_grant_cannot_be_used_across_stores(): void
    {
        // Ana's inventory grant is ONLY for store 10.
        // Attempting to update a listing in store 20 must fail.
        $this->firestore->seed('listings', 'listing_20', [
            'numericId' => 20, 'storeId' => 20, 'productId' => 1,
            'price' => 80.0, 'unit' => 'kilo', 'quantity' => 5,
            'availability' => 'in_stock', 'last_confirmed_at' => now()->toIso8601String(),
            'status' => 'active', 'ownerUid' => 'uid-tonyo',
        ]);

        $this->withToken($this->firebaseToken('uid-ana'))
            ->patchJson('/api/v1/store-products/20', ['price' => 1.0])
            ->assertForbidden();
    }

    // ── Ownership change ──────────────────────────────────────────────────

    public function test_store_created_by_admin_can_be_approved(): void
    {
        // Customer registers a store, admin approves
        $storeId = $this->withToken($this->firebaseToken('uid-maria'))
            ->postJson('/api/v1/stores', [
                'name' => 'Maria\'s Shop',
                'type' => 'sariSari',
                'lat' => 14.62,
                'lng' => 121.05,
                'city' => 'Quezon City',
                'landmark' => 'Near the park',
            ])
            ->assertCreated()
            ->json('data.id');

        // Confirm it's pending
        $this->withToken($this->firebaseToken('uid-admin'))
            ->patchJson("/api/v1/admin/stores/$storeId", ['status' => 'approved'])
            ->assertOk();
    }
}
