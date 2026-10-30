<?php

namespace App\Http\Controllers\Api\V1;

use App\Http\Controllers\Controller;
use App\Models\Product;
use App\Models\Promotion;
use App\Models\Store;
use App\Models\StoreProduct;
use App\Models\StoreTour;
use App\Support\Geo;
use App\Support\RecognitionService;
use App\Support\SearchText;
use Illuminate\Http\Request;

class CatalogController extends Controller
{
    public function bootstrap()
    {
        $approvedIds = Store::query()->where('status', 'approved')->pluck('id');
        $products = Product::with('aliases')->orderBy('name')->get()->map->toApi();
        $stores = Store::query()->where('status', 'approved')->with('locationSessions')->orderBy('name')->get()->map->toApi();
        $listings = StoreProduct::query()->whereIn('store_id', $approvedIds)->where('status', 'active')->orderBy('id')->get()->map->toApi();
        $promotions = Promotion::query()->where('status', 'approved')->whereIn('store_id', $approvedIds)->orderBy('id')->get()->map->toApi();
        $tours = StoreTour::with(['nodes.outgoing', 'nodes.hotspots.product'])->where('status', 'published')->whereIn('store_id', $approvedIds)->orderBy('id')->get()->map(fn (StoreTour $tour) => $tour->toApi(true));

        return response()->json([
            'data' => [
                'stores' => $stores,
                'products' => $products,
                'listings' => $listings,
                'promotions' => $promotions,
                'tours' => $tours,
            ],
        ]);
    }

    public function nearbyStores(Request $request)
    {
        $data = $request->validate([
            'lat' => ['required', 'numeric'],
            'lng' => ['required', 'numeric'],
            'radius_km' => ['nullable', 'numeric', 'min:0.1', 'max:50'],
            'type' => ['nullable', 'string'],
        ]);
        $radius = (float) ($data['radius_km'] ?? 3);
        $lat = (float) $data['lat'];
        $lng = (float) $data['lng'];

        $stores = Store::query()
            ->where('status', 'approved')
            ->with('locationSessions')
            ->when($request->filled('type'), fn ($q) => $q->where('type', $data['type']))
            ->get()
            ->map(function (Store $store) use ($lat, $lng) {
                $payload = $store->toApi();
                $payload['distance_km'] = round(Geo::distanceKm($lat, $lng, $payload['lat'], $payload['lng']), 3);

                return $payload;
            })
            ->filter(fn ($row) => $row['distance_km'] <= $radius)
            ->sortBy('distance_km')
            ->values();

        return response()->json(['data' => $stores]);
    }

    public function searchProducts(Request $request)
    {
        $q = strtolower(trim((string) $request->query('q', '')));
        $products = Product::with('aliases')->get()->filter(function (Product $product) use ($q) {
            return SearchText::matches($q, RecognitionService::fields($product), $product->category);
        })->sortBy(fn (Product $product) => SearchText::relevance(
            $q,
            $product->name,
            $product->aliases->pluck('alias')->all(),
            $product->category,
            RecognitionService::fields($product),
        ))
            ->values()
            ->map->toApi();

        return response()->json(['data' => $products]);
    }

    public function searchListings(Request $request)
    {
        $data = $request->validate([
            'q' => ['nullable', 'string'],
            'product_id' => ['nullable', 'integer'],
            'lat' => ['required', 'numeric'],
            'lng' => ['required', 'numeric'],
            'radius_km' => ['nullable', 'numeric'],
            'type' => ['nullable', 'string'],
            'category' => ['nullable', 'string'],
            'sort' => ['nullable', 'string', 'in:relevance,distance,price,freshness'],
            'page' => ['nullable', 'integer', 'min:1'],
            'per_page' => ['nullable', 'integer', 'min:1', 'max:50'],
        ]);

        $q = strtolower(trim((string) ($data['q'] ?? '')));
        $radius = (float) ($data['radius_km'] ?? 3);
        $lat = (float) $data['lat'];
        $lng = (float) $data['lng'];

        $listings = StoreProduct::query()
            ->with(['store.locationSessions', 'product.aliases'])
            ->where('status', 'active')
            ->whereHas('store', function ($query) use ($data) {
                $query->where('status', 'approved');
                if (! empty($data['type'])) {
                    $query->where('type', $data['type']);
                }
            })
            ->when(! empty($data['product_id']), fn ($query) => $query->where('product_id', $data['product_id']))
            ->get()
            ->map(function (StoreProduct $listing) use ($lat, $lng, $q, $radius, $data) {
                $product = $listing->product;
                $aliases = $product?->aliases->pluck('alias')->all() ?? [];
                if (! SearchText::matchesCategoryFilter($product?->category, $data['category'] ?? null)) {
                    return null;
                }
                $fields = $product ? RecognitionService::fields($product) : $aliases;
                if ($q !== '' && ! SearchText::matches($q, $fields, $product?->category)) {
                    return null;
                }
                $point = $listing->store->publicLocation();
                $distance = Geo::distanceKm($lat, $lng, $point['lat'], $point['lng']);
                if ($distance > $radius) {
                    return null;
                }

                $relevance = SearchText::relevance($q, (string) $product?->name, $aliases, $product?->category, $fields);

                return [
                    'listing' => $listing->toApi(),
                    'store' => $listing->store->toApi(),
                    'product' => $product->toApi(),
                    'distance_km' => round($distance, 3),
                    'relevance' => $relevance,
                    'match_type' => $q === '' ? 'exact' : SearchText::matchKind($q, $fields, $product?->category, $relevance),
                ];
            })
            ->filter()
            ->sortBy(function ($row) use ($data) {
                return match ($data['sort'] ?? 'relevance') {
                    'price' => [$row['listing']['price'] ?? 0, $row['distance_km']],
                    'freshness' => [-(strtotime((string) ($row['listing']['last_confirmed_at'] ?? 'now')) ?: 0), $row['distance_km']],
                    'distance' => [$row['distance_km']],
                    default => [$row['relevance'] ?? 0, $row['distance_km']],
                };
            })
            ->map(function ($row) {
                unset($row['relevance']);

                return $row;
            })
            ->values();

        $page = (int) ($data['page'] ?? 1);
        $perPage = (int) ($data['per_page'] ?? 20);
        $total = $listings->count();
        $paged = $listings->forPage($page, $perPage)->values();

        return response()->json([
            'data' => $paged,
            'meta' => [
                'current_page' => $page,
                'per_page' => $perPage,
                'total' => $total,
                'last_page' => max(1, (int) ceil($total / $perPage)),
            ],
        ]);
    }

    public function searchByImage(Request $request, RecognitionService $recognition)
    {
        $data = $request->validate([
            'hint' => ['nullable', 'string'],
            'barcode' => ['nullable', 'string'],
            'image' => ['nullable', 'string', 'max:2000000'],
            'lat' => ['required', 'numeric'],
            'lng' => ['required', 'numeric'],
            'radius_km' => ['nullable', 'numeric'],
        ]);
        $analysis = $recognition->analyze($data['hint'] ?? null, $data['barcode'] ?? null, $data['image'] ?? null);
        $suggestions = $analysis['suggestions'];
        $productIds = collect($suggestions)->pluck('product.id')->filter()->all();
        $radius = (float) ($data['radius_km'] ?? 3);
        $lat = (float) $data['lat'];
        $lng = (float) $data['lng'];
        $hits = StoreProduct::query()
            ->with(['store.locationSessions', 'product.aliases'])
            ->where('status', 'active')
            ->whereIn('product_id', $productIds)
            ->whereHas('store', fn ($query) => $query->where('status', 'approved'))
            ->get()
            ->map(function (StoreProduct $listing) use ($lat, $lng, $radius) {
                $point = $listing->store->publicLocation();
                $distance = Geo::distanceKm($lat, $lng, $point['lat'], $point['lng']);
                if ($distance > $radius) {
                    return null;
                }

                return [
                    'listing' => $listing->toApi(),
                    'store' => $listing->store->toApi(),
                    'product' => $listing->product->toApi(),
                    'distance_km' => round($distance, 3),
                    'match_type' => 'similar',
                ];
            })
            ->filter()
            ->sortBy('distance_km')
            ->values();

        return response()->json([
            'data' => [
                'suggestions' => $suggestions,
                'objects' => $analysis['objects'],
                'ocr' => $analysis['ocr'],
                'image' => $analysis['image'],
                'hits' => $hits,
                'uncertain' => collect($suggestions)->every(fn ($row) => empty($row['product']) || ($row['confidence'] ?? 0) < 0.5),
            ],
        ]);
    }

    public function showStore(Store $store)
    {
        $store->load('locationSessions');

        return response()->json(['data' => $store->toApi()]);
    }

    public function categories(Request $request)
    {
        $kind = $request->query('kind');
        $parentId = $request->query('parent_id');
        $items = \Illuminate\Support\Facades\DB::table('categories')
            ->when($kind, fn ($query) => $query->where('kind', $kind))
            ->when($parentId !== null && $parentId !== '', fn ($query) => $query->where('parent_id', $parentId))
            ->orderBy('kind')
            ->orderBy('name')
            ->get();
        $families = [];
        foreach (SearchText::FAMILIES as $slug => $children) {
            $families[] = [
                'slug' => $slug,
                'name' => ucfirst($slug),
                'categories' => $children,
            ];
        }

        return response()->json([
            'data' => [
                'families' => $families,
                'synonyms' => SearchText::SYNONYMS,
                'items' => $items,
            ],
        ]);
    }
}
