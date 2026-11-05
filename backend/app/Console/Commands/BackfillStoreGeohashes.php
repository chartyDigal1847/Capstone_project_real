<?php

namespace App\Console\Commands;

use App\Services\FirestoreService;
use App\Support\CatalogCache;
use App\Support\Geohash;
use Illuminate\Console\Command;

class BackfillStoreGeohashes extends Command
{
    protected $signature = 'localspot:backfill-store-geohashes {--apply : Write missing geohash fields to Firestore}';

    protected $description = 'Preview or backfill geohash fields for stores with valid coordinates';

    public function handle(FirestoreService $firestore): int
    {
        $stores = $firestore->all('stores');
        $pending = [];

        foreach ($stores as $store) {
            if (! empty($store['geohash'])) {
                continue;
            }

            if (! isset($store['id'], $store['lat'], $store['lng'])) {
                $this->warn('Skipping store without document ID or coordinates.');
                continue;
            }

            $lat = (float) $store['lat'];
            $lng = (float) $store['lng'];
            if ($lat < -90 || $lat > 90 || $lng < -180 || $lng > 180) {
                $this->warn('Skipping store with invalid coordinates.');
                continue;
            }

            $pending[] = [
                'id' => (string) $store['id'],
                'geohash' => Geohash::encode($lat, $lng),
            ];
        }

        if (! $this->option('apply')) {
            $this->info(count($pending) . ' store geohash field(s) need backfilling. No data was changed.');
            $this->line('Run with --apply to write these derived fields.');
            return self::SUCCESS;
        }

        foreach ($pending as $store) {
            $firestore->update('stores', $store['id'], ['geohash' => $store['geohash']]);
        }

        if ($pending !== []) {
            CatalogCache::invalidateAll();
        }

        $this->info('Backfilled ' . count($pending) . ' store geohash field(s).');
        return self::SUCCESS;
    }
}
