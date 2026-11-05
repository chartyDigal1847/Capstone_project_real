<?php

namespace App\Console\Commands;

use App\Services\FirestoreService;
use Illuminate\Console\Command;

/**
 * Delete expired private tour originals; public sanitized derivatives stay.
 * Tours store nodes as an embedded array — this command scans all tours
 * and clears `original_retained` for nodes past their retention period.
 * — Firestore-backed.
 */
class PurgeExpiredTourOriginals extends Command
{
    protected $signature = 'localspot:purge-tour-originals';
    protected $description = 'Delete expired private tour originals; sanitized derivatives stay';

    public function handle(FirestoreService $firestore): int
    {
        $retentionDays = max(1, (int) config('localspot.tour_original_retention_days', 30));
        $cutoff = now()->subDays($retentionDays);
        $tours = $firestore->all('tours');
        $purged = 0;

        foreach ($tours as $tour) {
            $nodes = $tour['nodes'] ?? [];
            $changed = false;
            foreach ($nodes as &$node) {
                if (($node['original_retained'] ?? false) === true) {
                    $created = $node['created_at'] ?? $tour['created_at'] ?? null;
                    if ($created !== null && strtotime($created) <= $cutoff->timestamp) {
                        $node['original_retained'] = false;
                        $changed = true;
                        $purged++;
                    }
                }
            }
            unset($node);
            if ($changed) {
                $firestore->updateByNumericId('tours', $tour['numericId'], ['nodes' => $nodes]);
            }
        }

        $this->info("Purged {$purged} expired tour original(s).");
        return self::SUCCESS;
    }
}
