<?php

namespace App\Support;

use Illuminate\Support\Facades\Cache;

/**
 * Catalog cache with distinct TTL policies and invalidation.
 *
 * Cache keys are namespaced by data type so that a write to one type
 * invalidates only the affected cache entries, not everything.
 *
 * Key tracking: prefix-based invalidation uses a tracking set stored in
 * the cache itself. Each put* method records the full key name so that
 * forgetPrefix() can iterate and evict them. This works with the array,
 * database, and Redis cache stores.
 *
 * Policies (per architecture requirement):
 *   - Product taxonomy/categories:  long (1 hour)
 *   - Store profiles:                moderate (10 minutes)
 *   - Product descriptions:          moderate (10 minutes)
 *   - Prices:                         short (3 minutes)
 *   - Stock/availability:            short (2 minutes) or explicit refresh
 *   - Full catalog bootstrap:         short (5 minutes)
 *   - Search results:                 short (2 minutes)
 *
 * Invalidation rules:
 *   - Updating a listing  → invalidate listing, search, nearby, catalog caches
 *   - Updating a store     → invalidate store detail, nearby, catalog, search caches
 *   - Changing a category  → invalidate category, search, catalog caches
 *   - Publishing a promo    → invalidate promotion, store, search, catalog caches
 *   - Admin store approval → invalidate catalog, nearby, search, store caches
 */
class CatalogCache
{
    private const KEY_CATALOG    = 'localspot:catalog:bootstrap';
    private const KEY_NEARBY     = 'localspot:catalog:nearby:';      // + signature
    private const KEY_STORE      = 'localspot:catalog:store:';       // + storeId
    private const KEY_SEARCH     = 'localspot:catalog:search:';      // + signature
    private const KEY_CATEGORIES = 'localspot:catalog:categories';
    private const KEY_PRODUCTS   = 'localspot:catalog:products:all';

    // TTLs in seconds
    public const TTL_CATALOG    = 300;   // 5 minutes
    public const TTL_NEARBY     = 180;   // 3 minutes
    public const TTL_STORE      = 600;   // 10 minutes
    public const TTL_SEARCH     = 120;   // 2 minutes
    public const TTL_CATEGORIES = 3600;  // 1 hour
    public const TTL_PRODUCTS   = 600;   // 10 minutes

    // ── Get / Put ───────────────────────────────────────────────────────

    public static function getCatalog(): ?array
    {
        return self::safeGet(self::KEY_CATALOG);
    }

    public static function putCatalog(array $data): void
    {
        self::safePut(self::KEY_CATALOG, $data, self::TTL_CATALOG);
    }

    public static function getNearby(string $signature): ?array
    {
        return self::safeGet(self::KEY_NEARBY . $signature);
    }

    public static function putNearby(string $signature, array $data): void
    {
        self::safePut(self::KEY_NEARBY . $signature, $data, self::TTL_NEARBY);
        self::trackKey(self::KEY_NEARBY, self::KEY_NEARBY . $signature);
    }

    public static function getStore(int $storeId): ?array
    {
        return self::safeGet(self::KEY_STORE . $storeId);
    }

    public static function putStore(int $storeId, array $data): void
    {
        self::safePut(self::KEY_STORE . $storeId, $data, self::TTL_STORE);
        self::trackKey(self::KEY_STORE, self::KEY_STORE . $storeId);
    }

    public static function getSearch(string $signature): ?array
    {
        return self::safeGet(self::KEY_SEARCH . $signature);
    }

    public static function putSearch(string $signature, array $data): void
    {
        self::safePut(self::KEY_SEARCH . $signature, $data, self::TTL_SEARCH);
        self::trackKey(self::KEY_SEARCH, self::KEY_SEARCH . $signature);
    }

    public static function getCategories(): ?array
    {
        return self::safeGet(self::KEY_CATEGORIES);
    }

    public static function putCategories(array $data): void
    {
        self::safePut(self::KEY_CATEGORIES, $data, self::TTL_CATEGORIES);
    }

    public static function getProducts(): ?array
    {
        return self::safeGet(self::KEY_PRODUCTS);
    }

    public static function putProducts(array $data): void
    {
        self::safePut(self::KEY_PRODUCTS, $data, self::TTL_PRODUCTS);
    }

    // ── Invalidation ─────────────────────────────────────────────────────

    /**
     * Invalidate after a listing is created or updated.
     * Clears search, nearby, and catalog bootstrap caches.
     */
    public static function invalidateListing(?int $storeId = null): void
    {
        self::safeForget(self::KEY_CATALOG);
        self::forgetPrefix(self::KEY_SEARCH);
        self::forgetPrefix(self::KEY_NEARBY);
        if ($storeId !== null) {
            self::safeForget(self::KEY_STORE . $storeId);
        }
    }

    /**
     * Invalidate after a store is created, updated, or approved.
     * Clears store detail, nearby, catalog, and search caches.
     */
    public static function invalidateStore(int $storeId): void
    {
        self::safeForget(self::KEY_STORE . $storeId);
        self::safeForget(self::KEY_CATALOG);
        self::forgetPrefix(self::KEY_NEARBY);
        self::forgetPrefix(self::KEY_SEARCH);
    }

    /**
     * Invalidate after a promotion is created or status changes.
     */
    public static function invalidatePromotion(int $storeId): void
    {
        self::safeForget(self::KEY_CATALOG);
        self::safeForget(self::KEY_STORE . $storeId);
        self::forgetPrefix(self::KEY_SEARCH);
    }

    /**
     * Invalidate after a category changes.
     */
    public static function invalidateCategories(): void
    {
        self::safeForget(self::KEY_CATEGORIES);
        self::forgetPrefix(self::KEY_SEARCH);
        self::safeForget(self::KEY_CATALOG);
    }

    /**
     * Invalidate after a tour is published or updated.
     */
    public static function invalidateTour(int $storeId): void
    {
        self::safeForget(self::KEY_CATALOG);
        self::safeForget(self::KEY_STORE . $storeId);
    }

    /**
     * Invalidate all catalog-related caches.
     */
    public static function invalidateAll(): void
    {
        self::safeForget(self::KEY_CATALOG);
        self::safeForget(self::KEY_CATEGORIES);
        self::safeForget(self::KEY_PRODUCTS);
        self::forgetPrefix(self::KEY_NEARBY);
        self::forgetPrefix(self::KEY_SEARCH);
        self::forgetPrefix(self::KEY_STORE);
    }

    // ── Helpers ──────────────────────────────────────────────────────────

    /**
     * Generate a stable signature for nearby/search query parameters.
     * Includes all filter, location, pagination, and sort parameters
     * so that different queries produce different cache keys.
     */
    public static function signature(array $params): string
    {
        // Remove empty values to normalize signatures.
        $filtered = array_filter($params, fn ($v) => $v !== null && $v !== '');
        ksort($filtered);
        return md5(http_build_query($filtered));
    }

    /**
     * Track a cache key for prefix-based invalidation.
     * Stores the full key name in a tracking set keyed by prefix.
     */
    private static function trackKey(string $prefix, string $fullKey): void
    {
        try {
            $trackingKey = 'localspot:cache_keys:' . $prefix;
            $tracked = Cache::get($trackingKey, []);
            if (!in_array($fullKey, $tracked, true)) {
                $tracked[] = $fullKey;
                Cache::put($trackingKey, $tracked, 3600);
            }
        } catch (\Throwable) {
            // Cache tracking failure is non-fatal — invalidation will
            // simply miss some keys, which will expire by TTL anyway.
        }
    }

    /**
     * Forget all cache keys tracked under a given prefix.
     */
    private static function forgetPrefix(string $prefix): void
    {
        try {
            $trackingKey = 'localspot:cache_keys:' . $prefix;
            $tracked = Cache::get($trackingKey, []);
            foreach ($tracked as $key) {
                Cache::forget($key);
            }
            Cache::forget($trackingKey);
        } catch (\Throwable) {
            // If cache is down, keys will expire by TTL anyway.
        }
    }

    /**
     * Safe cache get — returns null on cache backend failure.
     * This ensures cache outages fall through to Firestore queries.
     */
    private static function safeGet(string $key): ?array
    {
        try {
            return Cache::get($key);
        } catch (\Throwable) {
            return null;
        }
    }

    /**
     * Safe cache put — silently ignores cache backend failures.
     * This ensures cache outages don't break the API.
     */
    private static function safePut(string $key, array $data, int $ttl): void
    {
        try {
            Cache::put($key, $data, $ttl);
        } catch (\Throwable) {
            // Cache write failure is non-fatal.
        }
    }

    /**
     * Safe cache forget — silently ignores cache backend failures.
     */
    private static function safeForget(string $key): void
    {
        try {
            Cache::forget($key);
        } catch (\Throwable) {
            // Cache delete failure is non-fatal.
        }
    }
}
