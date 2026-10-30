<?php

namespace App\Http\Controllers\Api\V1;

use App\Http\Controllers\Controller;
use App\Models\Product;
use App\Models\ProductAlias;
use App\Models\StockMovement;
use App\Models\Store;
use App\Models\StoreProduct;
use App\Support\Audit;
use Illuminate\Http\Request;
use Illuminate\Validation\Rule;

class StoreProductController extends Controller
{
    public function store(Request $request, Store $store)
    {
        $this->authorize('create', [StoreProduct::class, $store]);

        $data = $request->validate([
            'product_id' => ['nullable', 'integer', 'exists:products,id'],
            'name' => ['required_without:product_id', 'string', 'max:160'],
            'category' => ['nullable', 'string', 'max:80'],
            'brand' => ['nullable', 'string', 'max:80'],
            'package_size' => ['nullable', 'string', 'max:80'],
            'barcode' => ['nullable', 'string', 'max:64'],
            'image' => ['nullable', 'string'],
            'aliases' => ['nullable', 'array'],
            'attributes' => ['nullable', 'array'],
            'price' => ['required', 'numeric', 'min:0'],
            'unit' => ['required', 'string', 'max:32'],
            'quantity' => ['required', 'integer', 'min:0'],
            'availability' => ['required', Rule::in(['in_stock', 'low', 'unavailable'])],
        ]);

        $product = isset($data['product_id'])
            ? Product::findOrFail($data['product_id'])
            : Product::create([
                'name' => $data['name'],
                'category' => $data['category'] ?? 'Other',
                'brand' => $data['brand'] ?? '',
                'package_size' => $data['package_size'] ?? '',
                'barcode' => $data['barcode'] ?? null,
                'image' => $data['image'] ?? null,
                'status' => 'active',
                'specs' => $data['attributes'] ?? [],
            ]);

        if (! isset($data['product_id'])) {
            foreach ($data['aliases'] ?? [$product->name] as $alias) {
                ProductAlias::create(['product_id' => $product->id, 'alias' => $alias]);
            }
        }

        $listing = StoreProduct::create([
            'store_id' => $store->id,
            'product_id' => $product->id,
            'price' => $data['price'],
            'unit' => $data['unit'],
            'quantity' => $data['quantity'],
            'availability' => $data['availability'],
            'status' => 'active',
            'last_confirmed_at' => now(),
        ]);

        StockMovement::create([
            'store_product_id' => $listing->id,
            'user_id' => $request->user()->id,
            'kind' => 'add',
            'quantity_delta' => $data['quantity'],
            'note' => 'Owner confirmed listing',
        ]);

        Audit::record($request->user(), 'listing.create', StoreProduct::class, $listing->id, [
            'store_id' => $store->id,
            'product_id' => $product->id,
        ]);

        return response()->json([
            'data' => [
                ...$listing->toApi(),
                'product' => $product->fresh('aliases')->toApi(),
            ],
        ], 201);
    }

    public function update(Request $request, StoreProduct $storeProduct)
    {
        $this->authorize('update', $storeProduct);

        $data = $request->validate([
            'price' => ['sometimes', 'numeric', 'min:0'],
            'unit' => ['sometimes', 'string', 'max:32'],
            'quantity' => ['sometimes', 'integer', 'min:0'],
            'availability' => ['sometimes', Rule::in(['in_stock', 'low', 'unavailable'])],
            'status' => ['sometimes', Rule::in(['active', 'archived', 'unavailable'])],
        ]);

        if (isset($data['quantity'])) {
            StockMovement::create([
                'store_product_id' => $storeProduct->id,
                'user_id' => $request->user()->id,
                'kind' => 'adjust',
                'quantity_delta' => $data['quantity'] - $storeProduct->quantity,
            ]);
        }

        $storeProduct->fill($data);
        $storeProduct->last_confirmed_at = now();
        $storeProduct->save();
        Audit::record($request->user(), 'listing.update', StoreProduct::class, $storeProduct->id, $data);

        return response()->json(['data' => $storeProduct->fresh()->toApi()]);
    }

    public function movements(StoreProduct $storeProduct)
    {
        $this->authorize('update', $storeProduct);

        return response()->json([
            'data' => $storeProduct->movements()->orderByDesc('id')->get()->map->toApi(),
        ]);
    }
}
