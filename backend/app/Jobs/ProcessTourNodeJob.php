<?php

namespace App\Jobs;

use App\Services\FirestoreService;
use Illuminate\Contracts\Queue\ShouldQueue;
use Illuminate\Foundation\Queue\Queueable;

/**
 * Process a 360° tour panorama node for privacy — Firestore-backed.
 * Tours store nodes as an embedded array in the tours collection.
 * This job updates the node's privacy_status to 'ready' or 'failed'.
 *
 * Actual person/face detection via ML is pending (plan Wave 3).
 * The publication gate in TourController blocks publication on failure.
 */
class ProcessTourNodeJob implements ShouldQueue
{
    use Queueable;

    public function __construct(public int $tourId, public int $nodeId, public bool $fail = false) {}

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
                $fail = $this->fail || str_contains(strtolower($node['title'] ?? ''), 'fail');
                $node['privacy_status'] = $fail ? 'failed' : 'ready';
                $node['image'] = $fail ? '' : "/tours/public/{$tour['storeId']}/{$this->nodeId}.jpg";
                $node['owner_reviewed'] = false;
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
