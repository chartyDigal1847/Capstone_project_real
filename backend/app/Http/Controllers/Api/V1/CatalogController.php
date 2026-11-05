<?php

namespace App\Http\Controllers\Api\V1;

use App\Http\Controllers\Controller;
use App\Services\FirestoreService;
use App\Support\CatalogCache;
use App\Support\Geo;
use App\Support\Geohash;
use App\Support\RecognitionService;
use App\Support\SearchText;
use Illuminate\Http\Request;

/**
 * Catalog controller — Firestore-backed.
 *
 * All reads go through FirestoreService (official google/cloud-firestore PHP
 * client via IAM/ADC). No Eloquent/MySQL queries. The response format matches
 * the Flutter app's expected JSON shape.
 */
class CatalogController extends Controller
{
    public function __construct(private readonly FirestoreService $firestore)
    {
    }

    public function bootstrap()
    {
        // Try cache first — avoids 6 Firestore collection reads on every bootstrap.
        $cached = CatalogCache::getCatalog();
        if ($cached !== null) {
            return response()->json(['data' => $cached]);
        }

        $stores = $this->firestore->query('stores', [
            ['field' => 'status', 'op' => '==', 'value' => 'approved'],
        ]);

        $approvedStoreIds = array_map(fn ($s) => $s['numericId'] ?? 0, $stores);

        $products = $this->firestore->all('products');
        $listings = $this->firestore->query('listings', [
            ['field' => 'status', 'op' => '==', 'value' => 'active'],
        ]);
        $promotions = $this->firestore->query('promotions', [
            ['field' => 'status', 'op' => '==', 'value' => 'approved'],
        ]);
        $tours = $this->firestore->query('tours', [
            ['field' => 'status', 'op' => '==', 'value' => 'published'],
        ]);
        $sessions = $this->firestore->all('vendorSessions');

        // Index sessions by storeId for quick lookup.
        $sessionMap = [];
        foreach ($sessions as $session) {
            $storeId = $session['storeId'] ?? null;
            if ($storeId !== null && ($session['ended_at'] ?? null) === null) {
                $sessionMap[$storeId] = $session;
            }
        }

        // Filter listings and promotions to approved stores only.
        $listings = array_filter($listings, fn ($l) => in_array($l['storeId'] ?? 0, $approvedStoreIds, true));
        $promotions = array_filter($promotions, fn ($p) => in_array($p['storeId'] ?? 0, $approvedStoreIds, true));
        $tours = array_filter($tours, fn ($t) => in_array($t['storeId'] ?? 0, $approvedStoreIds, true));

        $data = [
            'stores' => array_values(array_map(fn ($s) => $this->storeJson($s, $sessionMap[$s['numericId']] ?? null), $stores)),
            'products' => array_values(array_map(fn ($p) => $this->productJson($p), $products)),
            'listings' => array_values(array_map(fn ($l) => $this->listingJson($l), $listings)),
            'promotions' => array_values(array_map(fn ($p) => $this->promotionJson($p), $promotions)),
            'tours' => array_values(array_map(fn ($t) => $this->tourJson($t), $tours)),
        ];

        // Store in cache (5-minute TTL).
        CatalogCache::putCatalog($data);

        return response()->json(['data' => $data]);
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

        // Try cache first — nearby results change infrequently.
        $sigParams = [
            'lat' => number_format($lat, 4),
            'lng' => number_format($lng, 4),
            'radius' => $radius,
            'type' => $data['type'] ?? '',
        ];
        $sig = CatalogCache::signature($sigParams);
        $cached = CatalogCache::getNearby($sig);
        if ($cached !== null) {
            return response()->json(['data' => $cached]);
        }

        // Compute geohash query ranges for bounded nearby search (plan Wave 2)
        $geohashRanges = Geohash::queryRanges($lat, $lng, $radius);

        $stores = $this->firestore->query('stores', [
            ['field' => 'status', 'op' => '==', 'value' => 'approved'],
        ]);

        // Pre-filter by geohash prefix, then by exact distance
        $stores = array_filter($stores, function ($store) use ($geohashRanges, $lat, $lng, $radius, $data) {
            if (! empty($data['type']) && ($store['type'] ?? '') !== $data['type']) return false;
            // Geohash pre-filter — skip stores outside the cell range
            $storeGeohash = $store['geohash'] ?? '';
            if ($storeGeohash !== '' && ! Geohash::inRanges($storeGeohash, $geohashRanges)) {
                return false;
            }
            return true;
        });

        $sessions = $this->firestore->all('vendorSessions');
        $sessionMap = [];
        foreach ($sessions as $session) {
            $storeId = $session['storeId'] ?? null;
            if ($storeId !== null && ($session['ended_at'] ?? null) === null) {
                $sessionMap[$storeId] = $session;
            }
        }

        $results = [];
        foreach ($stores as $store) {
            $storeLat = (float) ($store['lat'] ?? 0);
            $storeLng = (float) ($store['lng'] ?? 0);
            $dist = Geo::distanceKm($lat, $lng, $storeLat, $storeLng);
            if ($dist <= $radius) {
                $payload = $this->storeJson($store, $sessionMap[$store['numericId']] ?? null);
                $payload['distance_km'] = round($dist, 3);
                $results[] = $payload;
            }
        }

        usort($results, fn ($a, $b) => ($a['distance_km'] ?? 0) <=> ($b['distance_km'] ?? 0));

        $nearbyData = array_values($results);

        // Store in cache (3-minute TTL).
        CatalogCache::putNearby($sig, $nearbyData);

        return response()->json(['data' => $nearbyData]);
    }

    public function searchProducts(Request $request)
    {
        $q = strtolower(trim((string) $request->query('q', '')));

        // Try cache for product search results.
        $productSig = CatalogCache::signature(['q' => $q, 'type' => 'products']);
        $cached = CatalogCache::getSearch($productSig);
        if ($cached !== null) {
            return response()->json(['data' => $cached]);
        }

        $products = $this->firestore->all('products');

        $matched = array_filter($products, function ($product) use ($q) {
            $fields = $this->productFields($product);
            return SearchText::matches($q, $fields, $product['category'] ?? null);
        });

        usort($matched, fn ($a, $b) => SearchText::relevance(
            $q, $a['name'] ?? '', $a['aliases'] ?? [], $a['category'] ?? null, $this->productFields($a)
        ) <=> SearchText::relevance(
            $q, $b['name'] ?? '', $b['aliases'] ?? [], $b['category'] ?? null, $this->productFields($b)
        ));

        $productResults = array_values(array_map(fn ($p) => $this->productJson($p), $matched));

        // Store in cache (2-minute TTL).
        CatalogCache::putSearch($productSig, $productResults);

        return response()->json(['data' => $productResults]);
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

        // Try cache first — search signatures include all filters + pagination
        // so different queries, pages, and sort orders get distinct cache keys.
        $searchSig = CatalogCache::signature([
            'q' => $q,
            'lat' => number_format($lat, 4),
            'lng' => number_format($lng, 4),
            'radius' => $radius,
            'type' => $data['type'] ?? '',
            'category' => $data['category'] ?? '',
            'sort' => $data['sort'] ?? 'relevance',
            'page' => $data['page'] ?? 1,
            'per_page' => $data['per_page'] ?? 20,
            'product_id' => $data['product_id'] ?? '',
        ]);
        $cached = CatalogCache::getSearch($searchSig);
        if ($cached !== null) {
            return response()->json([
                'data' => $cached['data'],
                'meta' => $cached['meta'],
            ]);
        }

        // Compute geohash query ranges for bounded nearby search (plan Wave 2)
        $geohashRanges = Geohash::queryRanges($lat, $lng, $radius);

        $stores = $this->firestore->query('stores', [
            ['field' => 'status', 'op' => '==', 'value' => 'approved'],
        ]);

        // Pre-filter stores by geohash to bound the search area
        $stores = array_filter($stores, function ($store) use ($geohashRanges, $data) {
            if (! empty($data['type']) && ($store['type'] ?? '') !== $data['type']) return false;
            $storeGeohash = $store['geohash'] ?? '';
            if ($storeGeohash !== '' && ! Geohash::inRanges($storeGeohash, $geohashRanges)) {
                return false;
            }
            return true;
        });

        $storeMap = [];
        foreach ($stores as $store) {
            $storeMap[$store['numericId'] ?? 0] = $store;
        }

        $listings = $this->firestore->query('listings', [
            ['field' => 'status', 'op' => '==', 'value' => 'active'],
        ]);

        $products = $this->firestore->all('products');
        $productMap = [];
        foreach ($products as $product) {
            $productMap[$product['numericId'] ?? 0] = $product;
        }

        $sessions = $this->firestore->all('vendorSessions');
        $sessionMap = [];
        foreach ($sessions as $session) {
            $storeId = $session['storeId'] ?? null;
            if ($storeId !== null && ($session['ended_at'] ?? null) === null) {
                $sessionMap[$storeId] = $session;
            }
        }

        $results = [];
        foreach ($listings as $listing) {
            $store = $storeMap[$listing['storeId'] ?? 0] ?? null;
            if ($store === null) continue;

            if (! empty($data['type']) && ($store['type'] ?? '') !== $data['type']) continue;

            $product = $productMap[$listing['productId'] ?? 0] ?? null;
            if ($product === null) continue;

            if (! empty($data['product_id']) && ($listing['productId'] ?? 0) !== (int) $data['product_id']) continue;

            if (! SearchText::matchesCategoryFilter($product['category'] ?? null, $data['category'] ?? null)) continue;

            $fields = $this->productFields($product);
            if ($q !== '' && ! SearchText::matches($q, $fields, $product['category'] ?? null)) continue;

            $storeLat = (float) ($store['lat'] ?? 0);
            $storeLng = (float) ($store['lng'] ?? 0);
            $distance = Geo::distanceKm($lat, $lng, $storeLat, $storeLng);
            if ($distance > $radius) continue;

            $relevance = SearchText::relevance($q, $product['name'] ?? '', $product['aliases'] ?? [], $product['category'] ?? null, $fields);

            $results[] = [
                'listing' => $this->listingJson($listing),
                'store' => $this->storeJson($store, $sessionMap[$store['numericId']] ?? null),
                'product' => $this->productJson($product),
                'distance_km' => round($distance, 3),
                'relevance' => $relevance,
                'match_type' => $q === '' ? 'exact' : SearchText::matchKind($q, $fields, $product['category'] ?? null, $relevance),
            ];
        }

        // Sort
        usort($results, function ($a, $b) use ($data) {
            return match ($data['sort'] ?? 'relevance') {
                'price' => [($a['listing']['price'] ?? 0), ($a['distance_km'] ?? 0)] <=> [($b['listing']['price'] ?? 0), ($b['distance_km'] ?? 0)],
                'freshness' => [-(strtotime((string) ($a['listing']['last_confirmed_at'] ?? 'now')) ?: 0), ($a['distance_km'] ?? 0)] <=> [-(strtotime((string) ($b['listing']['last_confirmed_at'] ?? 'now')) ?: 0), ($b['distance_km'] ?? 0)],
                'distance' => [($a['distance_km'] ?? 0)] <=> [($b['distance_km'] ?? 0)],
                default => [($a['relevance'] ?? 0), ($a['distance_km'] ?? 0)] <=> [($b['relevance'] ?? 0), ($b['distance_km'] ?? 0)],
            };
        });

        // Remove internal relevance field
        $results = array_map(function ($row) {
            unset($row['relevance']);
            return $row;
        }, $results);

        // Paginate
        $page = (int) ($data['page'] ?? 1);
        $perPage = (int) ($data['per_page'] ?? 20);
        $total = count($results);
        $paged = array_slice($results, ($page - 1) * $perPage, $perPage);

        $meta = [
            'current_page' => $page,
            'per_page' => $perPage,
            'total' => $total,
            'last_page' => max(1, (int) ceil($total / $perPage)),
        ];

        $responseData = array_values($paged);

        // Store in cache (2-minute TTL). The cache includes both data and meta
        // so the full pagination envelope is preserved.
        CatalogCache::putSearch($searchSig, ['data' => $responseData, 'meta' => $meta]);

        return response()->json([
            'data' => $responseData,
            'meta' => $meta,
        ]);
    }

    public function searchByImage(Request $request)
    {
        $data = $request->validate([
            'hint' => ['nullable', 'string'],
            'barcode' => ['nullable', 'string'],
            'image' => ['nullable', 'string', 'max:2000000'],
            'lat' => ['required', 'numeric'],
            'lng' => ['required', 'numeric'],
            'radius_km' => ['nullable', 'numeric'],
        ]);

        $products = $this->firestore->all('products');
        $hint = strtolower(trim((string) ($data['hint'] ?? '')));
        $barcode = trim((string) ($data['barcode'] ?? ''));

        // Score products (same logic as the Flutter prototype)
        $scored = [];
        foreach ($products as $product) {
            $score = $this->scoreProduct($product, $hint, $barcode);
            if ($score < 100) $scored[] = [$score, $product];
        }
        usort($scored, fn ($a, $b) => $a[0] <=> $b[0]);

        $suggestions = [];
        foreach (array_slice($scored, 0, 4) as [$score, $product]) {
            $confidence = $score === 0 ? 0.92 : ($score <= 3 ? 0.75 : 0.45);
            $suggestions[] = [
                'product' => $this->productJson($product),
                'label' => ($product['name'] ?? '') . ' · ' . ($product['category'] ?? ''),
                'confidence' => $confidence,
                'unknown_fields' => ['price', 'stock'],
                'ocr' => $barcode !== '' ? "barcode: $barcode" : null,
            ];
        }
        if (empty($suggestions)) {
            $suggestions[] = [
                'product' => null,
                'label' => 'No catalog match · encode manually',
                'confidence' => 0.0,
                'unknown_fields' => ['identity', 'price', 'stock'],
                'ocr' => null,
            ];
        }

        $suggestedIds = array_filter(array_map(fn ($s) => $s['product']['id'] ?? null, $suggestions));

        // Find nearby listings for suggested products
        $stores = $this->firestore->query('stores', [
            ['field' => 'status', 'op' => '==', 'value' => 'approved'],
        ]);
        $storeMap = [];
        foreach ($stores as $store) {
            $storeMap[$store['numericId'] ?? 0] = $store;
        }

        $listings = $this->firestore->query('listings', [
            ['field' => 'status', 'op' => '==', 'value' => 'active'],
        ]);

        // Build product map for hit enrichment
        $productMap = [];
        foreach ($products as $product) {
            $productMap[$product['numericId'] ?? 0] = $product;
        }

        $radius = (float) ($data['radius_km'] ?? 3);
        $lat = (float) $data['lat'];
        $lng = (float) $data['lng'];
        $sessions = $this->firestore->all('vendorSessions');
        $sessionMap = [];
        foreach ($sessions as $session) {
            $storeId = $session['storeId'] ?? null;
            if ($storeId !== null && ($session['ended_at'] ?? null) === null) {
                $sessionMap[$storeId] = $session;
            }
        }

        $hits = [];
        foreach ($listings as $listing) {
            if (! in_array($listing['productId'] ?? 0, $suggestedIds, true)) continue;
            $store = $storeMap[$listing['storeId'] ?? 0] ?? null;
            if ($store === null) continue;
            $product = $productMap[$listing['productId'] ?? 0] ?? null;
            if ($product === null) continue;

            $storeLat = (float) ($store['lat'] ?? 0);
            $storeLng = (float) ($store['lng'] ?? 0);
            $distance = Geo::distanceKm($lat, $lng, $storeLat, $storeLng);
            if ($distance > $radius) continue;

            $hits[] = [
                'listing' => $this->listingJson($listing),
                'store' => $this->storeJson($store, $sessionMap[$store['numericId']] ?? null),
                'product' => $this->productJson($product),
                'distance_km' => round($distance, 3),
                'match_type' => 'similar',
            ];
        }

        usort($hits, fn ($a, $b) => ($a['distance_km'] ?? 0) <=> ($b['distance_km'] ?? 0));

        return response()->json([
            'data' => [
                'suggestions' => $suggestions,
                'objects' => [],
                'ocr' => $barcode !== '' ? "barcode: $barcode" : null,
                'image' => null,
                'hits' => array_values($hits),
                'uncertain' => collect($suggestions)->every(fn ($row) => empty($row['product']) || ($row['confidence'] ?? 0) < 0.5),
            ],
        ]);
    }

    public function showStore(int $store)
    {
        // Try cache first for store detail.
        $cached = CatalogCache::getStore($store);
        if ($cached !== null) {
            return response()->json(['data' => $cached]);
        }

        $storeData = $this->firestore->findByNumericId('stores', $store);
        abort_if($storeData === null, 404, 'Store not found.');

        $sessions = $this->firestore->query('vendorSessions', [
            ['field' => 'storeId', 'op' => '==', 'value' => $storeData['numericId']],
        ]);
        $activeSession = null;
        foreach ($sessions as $session) {
            if (($session['ended_at'] ?? null) === null) {
                $activeSession = $session;
                break;
            }
        }

        $storeJson = $this->storeJson($storeData, $activeSession);

        // Store in cache (10-minute TTL).
        CatalogCache::putStore($store, $storeJson);

        return response()->json(['data' => $storeJson]);
    }

    public function categories(Request $request)
    {
        // Try cache first — categories rarely change (1-hour TTL).
        $cached = CatalogCache::getCategories();
        if ($cached !== null) {
            return response()->json(['data' => $cached]);
        }

        // Categories from Firestore (if seeded) or from the SearchText families.
        $categories = $this->firestore->all('categories');
        $items = array_map(fn ($c) => [
            'id' => $c['numericId'] ?? 0,
            'slug' => $c['slug'] ?? '',
            'name' => $c['name'] ?? '',
            'parent_id' => $c['parentId'] ?? null,
            'kind' => $c['kind'] ?? 'product',
        ], $categories);

        $families = [];
        foreach (SearchText::FAMILIES as $slug => $children) {
            $families[] = [
                'slug' => $slug,
                'name' => ucfirst($slug),
                'categories' => $children,
            ];
        }

        $data = [
            'families' => $families,
            'synonyms' => SearchText::SYNONYMS,
            'items' => $items,
        ];

        // Store in cache (1-hour TTL).
        CatalogCache::putCategories($data);

        return response()->json(['data' => $data]);
    }

    // ── JSON converters ──────────────────────────────────────────────────

    private function storeJson(array $data, ?array $session = null): array
    {
        return [
            'id' => $data['numericId'] ?? 0,
            'owner_id' => $data['ownerId'] ?? 0,
            'name' => $data['name'] ?? '',
            'type' => $data['type'] ?? 'other',
            'status' => $data['status'] ?? 'pending',
            'lat' => $data['lat'] ?? 0.0,
            'lng' => $data['lng'] ?? 0.0,
            'barangay' => $data['barangay'] ?? '',
            'city' => $data['city'] ?? '',
            'address' => $data['address'] ?? '',
            'landmark' => $data['landmark'] ?? '',
            'schedule' => $data['schedule'] ?? '',
            'is_mobile' => $data['is_mobile'] ?? false,
            'image' => $data['image'] ?? null,
            'verification_note' => $data['verification_note'] ?? '',
            'location_mode' => $data['location_mode'] ?? 'fixed',
            'location_updated_at' => $data['location_updated_at'] ?? null,
            'geohash' => $data['geohash'] ?? null,
            'live_session' => $session,
        ];
    }

    private function productJson(array $data): array
    {
        // aliases must always be a JSON array [].
        $aliases = $data['aliases'] ?? [];
        $aliasArray = is_array($aliases) ? array_values($aliases) : [];

        // attributes must always be a JSON object {}, never an array [].
        // Firestore returns [] for empty map fields; we force it to {} here
        // by using json_encode with JSON_FORCE_OBJECT on the cast result.
        // This avoids stdClass which breaks array_values() elsewhere.
        $attrs = $data['attributes'] ?? [];
        $attrsArray = (is_array($attrs) && !array_is_list($attrs)) ? $attrs : [];

        return [
            'id' => $data['numericId'] ?? 0,
            'name' => $data['name'] ?? '',
            'category' => $data['category'] ?? '',
            'brand' => $data['brand'] ?? '',
            'package_size' => $data['package_size'] ?? '',
            'aliases' => $aliasArray,
            'barcode' => $data['barcode'] ?? null,
            'image' => $data['image'] ?? '',
            // Cast to object so Laravel serialises as {} not [] when empty.
            'attributes' => (object) $attrsArray,
        ];
    }

    private function listingJson(array $data): array
    {
        return [
            'id' => $data['numericId'] ?? 0,
            'store_id' => $data['storeId'] ?? 0,
            'product_id' => $data['productId'] ?? 0,
            'price' => $data['price'] ?? 0.0,
            'unit' => $data['unit'] ?? 'piece',
            'quantity' => $data['quantity'] ?? 0,
            'availability' => $data['availability'] ?? 'in_stock',
            'last_confirmed_at' => $data['last_confirmed_at'] ?? null,
            'status' => $data['status'] ?? 'active',
        ];
    }

    private function promotionJson(array $data): array
    {
        return [
            'id' => $data['numericId'] ?? 0,
            'store_id' => $data['storeId'] ?? 0,
            'title' => $data['title'] ?? '',
            'offer' => $data['offer'] ?? '',
            'starts_at' => $data['starts_at'] ?? null,
            'ends_at' => $data['ends_at'] ?? null,
            'sponsored' => $data['sponsored'] ?? false,
            'status' => $data['status'] ?? 'pending',
        ];
    }

    private function tourJson(array $data): array
    {
        // nodes must always be a JSON array []. Guard against non-array values.
        $nodes = $data['nodes'] ?? [];
        $nodesArray = is_array($nodes) ? array_values($nodes) : [];

        return [
            'id' => $data['numericId'] ?? 0,
            'store_id' => $data['storeId'] ?? 0,
            'title' => $data['title'] ?? '',
            'status' => $data['status'] ?? 'draft',
            'nodes' => $nodesArray,
        ];
    }

    private function productFields(array $product): array
    {
        return array_filter([
            $product['name'] ?? '',
            $product['brand'] ?? '',
            $product['category'] ?? '',
            $product['package_size'] ?? '',
            $product['barcode'] ?? '',
            ...($product['aliases'] ?? []),
            ...array_values((array) ($product['attributes'] ?? [])),
        ]);
    }

    private function scoreProduct(array $product, string $hint, string $barcode): int
    {
        if ($barcode !== '') {
            $bc = strtolower((string) ($product['barcode'] ?? ''));
            if ($bc === strtolower($barcode)) return 0;
        }
        if ($hint === '') return 100;
        $name = strtolower((string) ($product['name'] ?? ''));
        $category = strtolower((string) ($product['category'] ?? ''));
        $brand = strtolower((string) ($product['brand'] ?? ''));
        $aliases = array_map(fn ($a) => strtolower((string) $a), $product['aliases'] ?? []);
        if ($name === $hint) return 0;
        if (str_starts_with($name, $hint)) return 1;
        if (str_contains($name, $hint)) return 2;
        if (in_array($hint, $aliases) || collect($aliases)->contains(fn ($a) => str_contains($a, $hint))) return 3;
        if (str_contains($brand, $hint)) return 4;
        if (str_contains($category, $hint)) return 5;
        $hintTokens = array_filter(preg_split('/\s+/', $hint) ?: [], fn ($t) => strlen($t) >= 2);
        $productTokens = array_filter(
            preg_split('/[^a-z0-9]+/', "$name $category $brand " . implode(' ', $aliases)) ?: [],
            fn ($t) => strlen($t) >= 2
        );
        $overlap = count(array_intersect($hintTokens, $productTokens));
        if ($overlap > 0) return 6 + (count($hintTokens) - $overlap);
        return 100;
    }
}
