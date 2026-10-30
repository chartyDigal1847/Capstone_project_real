<?php

namespace App\Jobs;

use App\Models\TourNode;
use App\Support\TourPrivacy;
use Illuminate\Contracts\Queue\ShouldQueue;
use Illuminate\Foundation\Queue\Queueable;

class ProcessTourNodeJob implements ShouldQueue
{
    use Queueable;

    public function __construct(public int $tourNodeId, public bool $fail = false) {}

    public function handle(): void
    {
        $node = TourNode::find($this->tourNodeId);
        if ($node === null) {
            return;
        }

        if (TourPrivacy::shouldFail($node, $this->fail)) {
            $node->update([
                'privacy_status' => 'failed',
                'image' => '',
                'owner_reviewed' => false,
            ]);

            return;
        }

        $node->update([
            'privacy_status' => 'ready',
            'image' => TourPrivacy::writeDerivative($node),
        ]);
    }
}
