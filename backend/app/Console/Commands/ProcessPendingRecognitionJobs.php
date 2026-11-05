<?php

namespace App\Console\Commands;

use App\Jobs\ProcessRecognitionJob;
use App\Services\FirestoreService;
use Illuminate\Console\Command;

/**
 * Dispatch pending product-recognition jobs that were not processed by a worker.
 * — Firestore-backed.
 */
class ProcessPendingRecognitionJobs extends Command
{
    protected $signature = 'localspot:process-recognition-jobs';
    protected $description = 'Dispatch pending product-recognition jobs';

    public function handle(FirestoreService $firestore): int
    {
        $jobs = $firestore->query('productRecognitionJobs', [
            ['field' => 'status', 'op' => '==', 'value' => 'pending'],
        ]);

        foreach ($jobs as $job) {
            ProcessRecognitionJob::dispatch((int) ($job['numericId'] ?? 0));
        }

        $this->info("Dispatched " . count($jobs) . " recognition job(s).");
        return self::SUCCESS;
    }
}
