<?php

namespace App\Http\Controllers\Api\V1;

use App\Http\Controllers\Controller;
use App\Services\FirestoreService;
use App\Services\UserResolver;
use App\Support\CatalogCache;
use App\Support\Geohash;
use Illuminate\Http\Request;
use Illuminate\Validation\Rule;

/**
 * Store product (listing) controller — Firestore-backed.
 */
class StoreProductController extends Controller
{
    public function __construct(
        private readonly FirestoreService $firestore,
        private readonly UserResolver $userResolver,
    ) {
    }

    public function store(Request $request, int $storeId)
    {
        $user = $this->userResolver->resolve($request);
        $store = $this->firestore->findByNumericId('stores', $storeId);
        abort_if($store === null, 404, 'Store not found.');
        // Creating a listing requires the inventory grant (or ownership/admin).
        abort_unless($this->userResolver->hasStoreGrant($user, $storeId, 'inventory'), 403, 'Not authorized to manage inventory for this store.');

        $data = $request->validate([
            'product_id' => ['nullable', 'integer'],
            'name' => ['required_without:product_id', 'string', 'max:160'],
            'category' => ['nullable', 'string', 'max:80'],
            'brand' => ['nullable', 'string', 'max:80'],
            'package_size' => ['nullable', 'string', 'max:80'],
            'barcode' => ['nullable', 'string', 'max:64'],
            'aliases' => ['nullable', 'array'],
            'attributes' => ['nullable', 'array'],
            'price' => ['required', 'numeric', 'min:0'],
            'unit' => ['required', 'string', 'max:32'],
            'quantity' => ['required', 'integer', 'min:0'],
            'availability' => ['required', Rule::in(['in_stock', 'low', 'unavailable'])],
        ]);

        $uid = $request->attributes->get('firebase_uid');

        $productId = $data['product_id'] ?? null;
        if ($productId === null) {
            $productId = abs(crc32(uniqid('product', true))) & 0x7fffffff;
            $this->firestore->create('products', [
                'numericId' => $productId,
                'name' => $data['name'],
                'category' => $data['category'] ?? 'Groceries',
                'brand' => $data['brand'] ?? '',
                'package_size' => $data['package_size'] ?? '',
                'aliases' => $data['aliases'] ?? [$data['name']],
                'barcode' => $data['barcode'] ?? null,
                'image' => '',
                'attributes' => $data['attributes'] ?? [],
                'createdByUid' => $uid,
            ]);
        }

        $listingId = abs(crc32(uniqid('listing', true))) & 0x7fffffff;
        // Compute geohash from the store's coordinates for nearby listing queries
        $storeGeohash = $store['geohash'] ?? '';
        if ($storeGeohash === '' && isset($store['lat'], $store['lng'])) {
            $storeGeohash = Geohash::encode((float) $store['lat'], (float) $store['lng']);
        }
        $this->firestore->create('listings', [
            'numericId' => $listingId,
            'storeId' => $storeId,
            'productId' => $productId,
            'price' => (float) $data['price'],
            'unit' => $data['unit'],
            'quantity' => (int) $data['quantity'],
            'availability' => $data['availability'],
            'last_confirmed_at' => now()->toIso8601String(),
            'status' => 'active',
            'ownerUid' => $uid,
            'geohash' => $storeGeohash,
        ]);

        $this->firestore->create('stockMovements', [
            'listingId' => $listingId,
            'kind' => 'add',
            'quantity_delta' => (int) $data['quantity'],
            'note' => 'Owner confirmed listing',
            'created_at' => now()->toIso8601String(),
            'ownerUid' => $uid,
        ]);

        // Invalidate listing, search, and nearby caches.
        CatalogCache::invalidateListing($storeId);

        return response()->json(['data' => ['id' => $listingId]], 201);
    }

    public function update(Request $request, int $listingId)
    {
        $user = $this->userResolver->resolve($request);
        $listing = $this->firestore->findByNumericId('listings', $listingId);
        abort_if($listing === null, 404, 'Listing not found.');

        $store = $this->firestore->findByNumericId('stores', $listing['storeId'] ?? 0);
        // Updating a listing requires the inventory grant (or ownership/admin).
        abort_unless($store !== null && $this->userResolver->hasStoreGrant($user, $store['numericId'], 'inventory'), 403, 'Not authorized to manage inventory for this store.');

        $data = $request->validate([
            'price' => ['sometimes', 'numeric', 'min:0'],
            'unit' => ['sometimes', 'string', 'max:32'],
            'quantity' => ['sometimes', 'integer', 'min:0'],
            'availability' => ['sometimes', Rule::in(['in_stock', 'low', 'unavailable'])],
            'status' => ['sometimes', Rule::in(['active', 'archived', 'unavailable'])],
        ]);

        $uid = $request->attributes->get('firebase_uid');
        $prevQty = (int) ($listing['quantity'] ?? 0);

        $updateData = array_filter($data, fn ($v) => $v !== null, ARRAY_FILTER_USE_BOTH);
        $updateData['last_confirmed_at'] = now()->toIso8601String();

        $this->firestore->updateByNumericId('listings', $listingId, $updateData);

        // Invalidate listing, search, and nearby caches after an update.
        CatalogCache::invalidateListing($store['numericId']);

        // Stock movement
        if (isset($data['quantity'])) {
            $delta = (int) $data['quantity'] - $prevQty;
            $this->firestore->create('stockMovements', [
                'listingId' => $listingId,
                'kind' => ($data['status'] ?? '') === 'archived' ? 'archive' : 'adjust',
                'quantity_delta' => $delta,
                'note' => ($data['status'] ?? '') === 'unavailable' ? 'Marked unavailable' : 'Stock update',
                'created_at' => now()->toIso8601String(),
                'ownerUid' => $uid,
            ]);
        }

        return response()->json(['data' => true]);
    }

    public function movements(int $listingId)
    {
        $movements = $this->firestore->query('stockMovements', [
            ['field' => 'listingId', 'op' => '==', 'value' => $listingId],
        ]);

        usort($movements, fn ($a, $b) => ($b['created_at'] ?? '') <=> ($a['created_at'] ?? ''));

        return response()->json(['data' => array_map(fn ($m) => [
            'kind' => $m['kind'] ?? '',
            'quantity_delta' => $m['quantity_delta'] ?? 0,
            'note' => $m['note'] ?? '',
            'created_at' => $m['created_at'] ?? '',
        ], $movements)]);
    }
}
