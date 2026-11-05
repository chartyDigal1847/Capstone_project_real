<?php

namespace Tests\Unit;

use App\Services\FirestoreTestService;
use PHPUnit\Framework\TestCase;
use RuntimeException;

/**
 * Unit tests for Firestore data-access layer.
 *
 * Uses FirestoreTestService (in-memory mock) so no gRPC, emulator, or
 * network access is required. These tests verify the service interface
 * and the serialization/deserialization contract expected by controllers.
 *
 * NOTE: FirestoreService.toValue() / fromValue() are tested implicitly
 * through the REST API response shape when real integration tests run.
 * Here we test the in-memory mock's behavior which mirrors the contract.
 */
class FirestoreServiceTest extends TestCase
{
    private FirestoreTestService $firestore;

    protected function setUp(): void
    {
        parent::setUp();
        $this->firestore = new FirestoreTestService();
    }

    // ── CRUD operations ───────────────────────────────────────────────────

    public function test_create_and_get_document(): void
    {
        $docId = $this->firestore->create('stores', [
            'numericId' => 1,
            'name' => 'Test Store',
            'status' => 'approved',
        ]);

        $doc = $this->firestore->get('stores', $docId);

        $this->assertNotNull($doc);
        $this->assertSame('Test Store', $doc['name']);
        $this->assertSame(1, $doc['numericId']);
        $this->assertSame('approved', $doc['status']);
        $this->assertSame($docId, $doc['id']);
    }

    public function test_get_nonexistent_document_returns_null(): void
    {
        $result = $this->firestore->get('stores', 'nonexistent_id');
        $this->assertNull($result);
    }

    public function test_set_overwrites_document(): void
    {
        $this->firestore->set('stores', 'doc_1', [
            'name' => 'Old Name',
            'status' => 'pending',
        ]);

        $this->firestore->set('stores', 'doc_1', [
            'name' => 'New Name',
            'status' => 'approved',
        ]);

        $doc = $this->firestore->get('stores', 'doc_1');
        $this->assertSame('New Name', $doc['name']);
        $this->assertArrayNotHasKey('status', array_diff_key($doc, ['id' => 1, 'name' => 1, 'status' => 1]));
    }

    public function test_merge_adds_and_updates_fields(): void
    {
        $this->firestore->set('stores', 'doc_1', [
            'name' => 'Test Store',
            'status' => 'pending',
            'city' => 'Quezon City',
        ]);

        $this->firestore->merge('stores', 'doc_1', [
            'status' => 'approved',
            'landmark' => 'Near the park',
        ]);

        $doc = $this->firestore->get('stores', 'doc_1');
        $this->assertSame('Test Store', $doc['name']);      // untouched
        $this->assertSame('approved', $doc['status']);      // updated
        $this->assertSame('Quezon City', $doc['city']);     // untouched
        $this->assertSame('Near the park', $doc['landmark']); // added
    }

    public function test_update_modifies_specific_fields(): void
    {
        $this->firestore->set('listings', 'listing_1', [
            'price' => 50.0,
            'quantity' => 10,
            'availability' => 'in_stock',
        ]);

        $this->firestore->update('listings', 'listing_1', [
            'price' => 55.0,
            'quantity' => 8,
        ]);

        $doc = $this->firestore->get('listings', 'listing_1');
        $this->assertSame(55.0, $doc['price']);
        $this->assertSame(8, $doc['quantity']);
        $this->assertSame('in_stock', $doc['availability']); // untouched
    }

    public function test_update_by_numeric_id_returns_true_when_found(): void
    {
        $this->firestore->seed('stores', 'store_a', [
            'numericId' => 42,
            'name' => 'Store A',
            'status' => 'pending',
        ]);

        $result = $this->firestore->updateByNumericId('stores', 42, ['status' => 'approved']);

        $this->assertTrue($result);
        $doc = $this->firestore->findByNumericId('stores', 42);
        $this->assertSame('approved', $doc['status']);
    }

    public function test_update_by_numeric_id_returns_false_when_not_found(): void
    {
        $result = $this->firestore->updateByNumericId('stores', 99999, ['status' => 'approved']);
        $this->assertFalse($result);
    }

    public function test_delete_by_numeric_id(): void
    {
        $this->firestore->seed('products', 'product_1', [
            'numericId' => 100,
            'name' => 'Test Product',
        ]);

        $deleted = $this->firestore->deleteByNumericId('products', 100);
        $this->assertTrue($deleted);
        $this->assertNull($this->firestore->findByNumericId('products', 100));
    }

    public function test_delete_by_numeric_id_returns_false_when_not_found(): void
    {
        $result = $this->firestore->deleteByNumericId('products', 99999);
        $this->assertFalse($result);
    }

    // ── Query operations ──────────────────────────────────────────────────

    public function test_query_equality_filter(): void
    {
        $this->firestore->seed('stores', 'store_1', ['numericId' => 1, 'status' => 'approved', 'name' => 'A']);
        $this->firestore->seed('stores', 'store_2', ['numericId' => 2, 'status' => 'pending', 'name' => 'B']);
        $this->firestore->seed('stores', 'store_3', ['numericId' => 3, 'status' => 'approved', 'name' => 'C']);

        $results = $this->firestore->query('stores', [
            ['field' => 'status', 'op' => '==', 'value' => 'approved'],
        ]);

        $this->assertCount(2, $results);
        $names = array_column($results, 'name');
        $this->assertContains('A', $names);
        $this->assertContains('C', $names);
        $this->assertNotContains('B', $names);
    }

    public function test_query_with_multiple_filters(): void
    {
        $this->firestore->seed('listings', 'l1', ['numericId' => 1, 'storeId' => 10, 'status' => 'active', 'price' => 50.0]);
        $this->firestore->seed('listings', 'l2', ['numericId' => 2, 'storeId' => 10, 'status' => 'archived', 'price' => 30.0]);
        $this->firestore->seed('listings', 'l3', ['numericId' => 3, 'storeId' => 20, 'status' => 'active', 'price' => 80.0]);

        $results = $this->firestore->query('listings', [
            ['field' => 'storeId', 'op' => '==', 'value' => 10],
            ['field' => 'status', 'op' => '==', 'value' => 'active'],
        ]);

        $this->assertCount(1, $results);
        $this->assertSame(1, $results[0]['numericId']);
    }

    public function test_query_returns_empty_when_no_match(): void
    {
        $this->firestore->seed('stores', 'store_1', ['numericId' => 1, 'status' => 'approved']);

        $results = $this->firestore->query('stores', [
            ['field' => 'status', 'op' => '==', 'value' => 'nonexistent'],
        ]);

        $this->assertCount(0, $results);
    }

    public function test_all_returns_all_documents_in_collection(): void
    {
        for ($i = 1; $i <= 5; $i++) {
            $this->firestore->seed('products', "product_$i", ['numericId' => $i, 'name' => "Product $i"]);
        }

        $results = $this->firestore->all('products');
        $this->assertCount(5, $results);
    }

    public function test_all_returns_empty_for_empty_collection(): void
    {
        $results = $this->firestore->all('emptyCollection');
        $this->assertSame([], $results);
    }

    public function test_find_by_numeric_id(): void
    {
        $this->firestore->seed('stores', 'store_x', ['numericId' => 999, 'name' => 'X Store']);

        $doc = $this->firestore->findByNumericId('stores', 999);
        $this->assertNotNull($doc);
        $this->assertSame('X Store', $doc['name']);
        $this->assertSame('store_x', $doc['id']);
    }

    public function test_find_by_numeric_id_returns_null_when_not_found(): void
    {
        $doc = $this->firestore->findByNumericId('stores', 999999);
        $this->assertNull($doc);
    }

    // ── Data types ────────────────────────────────────────────────────────

    public function test_integer_values_preserved_as_integers(): void
    {
        $this->firestore->seed('listings', 'l1', [
            'numericId' => 42,
            'quantity' => 10,
            'storeId' => 1,
        ]);

        $doc = $this->firestore->get('listings', 'l1');
        $this->assertIsInt($doc['numericId']);
        $this->assertIsInt($doc['quantity']);
        $this->assertSame(42, $doc['numericId']);
        $this->assertSame(10, $doc['quantity']);
    }

    public function test_float_values_preserved_as_floats(): void
    {
        $this->firestore->seed('listings', 'l1', ['price' => 99.95, 'lat' => 14.6195]);

        $doc = $this->firestore->get('listings', 'l1');
        $this->assertIsFloat($doc['price']);
        $this->assertSame(99.95, $doc['price']);
        $this->assertEqualsWithDelta(14.6195, $doc['lat'], 0.00001);
    }

    public function test_boolean_values_preserved(): void
    {
        $this->firestore->seed('stores', 's1', ['is_mobile' => true, 'sponsored' => false]);

        $doc = $this->firestore->get('stores', 's1');
        $this->assertIsBool($doc['is_mobile']);
        $this->assertTrue($doc['is_mobile']);
        $this->assertIsBool($doc['sponsored']);
        $this->assertFalse($doc['sponsored']);
    }

    public function test_null_values_preserved(): void
    {
        $this->firestore->seed('products', 'p1', ['barcode' => null, 'image' => null]);

        $doc = $this->firestore->get('products', 'p1');
        $this->assertNull($doc['barcode']);
        $this->assertNull($doc['image']);
    }

    public function test_empty_string_preserved(): void
    {
        $this->firestore->seed('stores', 's1', ['landmark' => '', 'address' => '']);

        $doc = $this->firestore->get('stores', 's1');
        $this->assertSame('', $doc['landmark']);
        $this->assertSame('', $doc['address']);
    }

    public function test_array_values_preserved(): void
    {
        $this->firestore->seed('products', 'p1', [
            'aliases' => ['mango', 'mangga', 'indian mango'],
        ]);

        $doc = $this->firestore->get('products', 'p1');
        $this->assertIsArray($doc['aliases']);
        $this->assertCount(3, $doc['aliases']);
        $this->assertContains('mangga', $doc['aliases']);
    }

    public function test_nested_map_values_preserved(): void
    {
        $this->firestore->seed('products', 'p1', [
            'attributes' => [
                'compatibility' => 'USB-C',
                'length' => '1m',
            ],
        ]);

        $doc = $this->firestore->get('products', 'p1');
        $this->assertIsArray($doc['attributes']);
        $this->assertSame('USB-C', $doc['attributes']['compatibility']);
        $this->assertSame('1m', $doc['attributes']['length']);
    }

    public function test_zero_values_preserved(): void
    {
        $this->firestore->seed('listings', 'l1', ['price' => 0.0, 'quantity' => 0]);

        $doc = $this->firestore->get('listings', 'l1');
        $this->assertSame(0.0, $doc['price']);
        $this->assertSame(0, $doc['quantity']);
    }

    public function test_timestamp_string_preserved(): void
    {
        $now = now()->toIso8601String();
        $this->firestore->seed('listings', 'l1', ['last_confirmed_at' => $now]);

        $doc = $this->firestore->get('listings', 'l1');
        $this->assertSame($now, $doc['last_confirmed_at']);
    }

    // ── Transaction behavior ──────────────────────────────────────────────

    public function test_transaction_executes_callback(): void
    {
        $this->firestore->seed('users', 'user_1', ['role' => 'customer', 'ownedStoreIds' => []]);

        $result = $this->firestore->transaction(function ($fs) {
            $user = $fs->get('users', 'user_1');
            $fs->update('users', 'user_1', ['role' => 'owner', 'ownedStoreIds' => [1]]);
            return $user['role']; // Return original role
        });

        $this->assertSame('customer', $result); // Original value returned
        $updated = $this->firestore->get('users', 'user_1');
        $this->assertSame('owner', $updated['role']);
    }

    // ── Edge cases ────────────────────────────────────────────────────────

    public function test_query_on_nonexistent_collection_returns_empty(): void
    {
        $results = $this->firestore->query('nonexistentCollection', [
            ['field' => 'id', 'op' => '==', 'value' => 1],
        ]);

        $this->assertSame([], $results);
    }

    public function test_seed_allows_direct_document_injection(): void
    {
        $this->firestore->seed('auditLogs', 'audit_1', [
            'numericId' => 1,
            'action' => 'store.approved',
            'userId' => 5,
        ]);

        $doc = $this->firestore->get('auditLogs', 'audit_1');
        $this->assertSame('store.approved', $doc['action']);
    }

    public function test_reset_clears_all_data(): void
    {
        $this->firestore->seed('stores', 'store_1', ['name' => 'Test']);
        $this->firestore->reset();

        $results = $this->firestore->all('stores');
        $this->assertSame([], $results);
    }

    public function test_document_id_is_included_in_result(): void
    {
        $this->firestore->seed('stores', 'my_custom_id', ['name' => 'Test']);

        $doc = $this->firestore->get('stores', 'my_custom_id');
        $this->assertSame('my_custom_id', $doc['id']);
    }

    public function test_create_returns_auto_generated_document_id(): void
    {
        $id1 = $this->firestore->create('stores', ['name' => 'Store 1']);
        $id2 = $this->firestore->create('stores', ['name' => 'Store 2']);

        $this->assertNotSame($id1, $id2);
        $this->assertNotEmpty($id1);
        $this->assertNotEmpty($id2);
    }

    public function test_large_array_field_preserved(): void
    {
        $aliases = array_map(fn ($i) => "alias_$i", range(1, 50));
        $this->firestore->seed('products', 'p1', ['aliases' => $aliases]);

        $doc = $this->firestore->get('products', 'p1');
        $this->assertCount(50, $doc['aliases']);
        $this->assertContains('alias_25', $doc['aliases']);
    }

    public function test_query_with_array_contains_operator(): void
    {
        $this->firestore->seed('users', 'user_1', ['ownedStoreIds' => [1, 2, 3]]);
        $this->firestore->seed('users', 'user_2', ['ownedStoreIds' => [4, 5]]);

        $results = $this->firestore->query('users', [
            ['field' => 'ownedStoreIds', 'op' => 'array-contains', 'value' => 2],
        ]);

        $this->assertCount(1, $results);
        $this->assertSame('user_1', $results[0]['id']);
    }

    public function test_query_with_inequality_operators(): void
    {
        $this->firestore->seed('listings', 'l1', ['numericId' => 1, 'price' => 10.0]);
        $this->firestore->seed('listings', 'l2', ['numericId' => 2, 'price' => 50.0]);
        $this->firestore->seed('listings', 'l3', ['numericId' => 3, 'price' => 100.0]);

        $results = $this->firestore->query('listings', [
            ['field' => 'price', 'op' => '>=', 'value' => 50.0],
        ]);

        $this->assertCount(2, $results);
        $prices = array_column($results, 'price');
        $this->assertContains(50.0, $prices);
        $this->assertContains(100.0, $prices);
        $this->assertNotContains(10.0, $prices);
    }
}
