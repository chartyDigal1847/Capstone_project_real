<?php

namespace App\Jobs;

use App\Services\FirestoreService;
use Illuminate\Contracts\Queue\ShouldQueue;
use Illuminate\Foundation\Queue\Queueable;

/**
 * Process a 360° tour panorama node for privacy — Firestore-backed.
 * Tours store nodes as an embedded array in the tours collection.
 * No privacy processor is configured yet. This placeholder job always fails
 * closed and must never manufacture a sanitized URL or mark a node ready.
 */
class ProcessTourNodeJob implements ShouldQueue
{
    use Queueable;

    public function __construct(public int $tourId, public int $nodeId) {}

    public function handle(FirestoreService $firestore): void
    {
        $tour = $firestore->findByNumericId('tours', $this->tourId);
        if ($tour === null) {
            return;
        }

        $nodes = $tour['nodes'] ?? [];
        $updated = false;
        foreach ($nodes as &$node) {
            if (($node['id'] ?? 0) === $this->nodeId) {
                $node['privacy_status'] = 'failed';
                $node['image'] = '';
                $node['owner_reviewed'] = false;
                $node['privacy_error'] = 'Privacy processor is not configured.';
                $updated = true;
                break;
            }
        }
        unset($node);

        if ($updated) {
            $firestore->updateByNumericId('tours', $this->tourId, ['nodes' => $nodes]);
        }
    }
}
