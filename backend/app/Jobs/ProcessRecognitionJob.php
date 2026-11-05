<?php

namespace App\Jobs;

use App\Services\FirestoreService;
use App\Support\RecognitionService;
use Illuminate\Contracts\Queue\ShouldQueue;
use Illuminate\Foundation\Queue\Queueable;
use Throwable;

/**
 * Process a product-recognition job — Firestore-backed.
 * Reads the job from the productRecognitionJobs collection, runs
 * catalog-based analysis, and updates the job status/suggestions.
 */
class ProcessRecognitionJob implements ShouldQueue
{
    use Queueable;

    public function __construct(public int $recognitionJobId) {}

    public function handle(FirestoreService $firestore, RecognitionService $recognition): void
    {
        $job = $firestore->findByNumericId('productRecognitionJobs', $this->recognitionJobId);
        if ($job === null || ($job['status'] ?? '') !== 'pending') {
            return;
        }

        try {
            $analysis = $recognition->analyze($job['hint'] ?? null, $job['barcode'] ?? null);
            $firestore->updateByNumericId('productRecognitionJobs', $this->recognitionJobId, [
                'status' => 'ready',
                'suggestions' => $analysis['suggestions'],
                'objects' => $analysis['objects'],
                'ocr_text' => $analysis['ocr'] ?? ($job['ocr_text'] ?? null),
            ]);
        } catch (Throwable) {
            $firestore->updateByNumericId('productRecognitionJobs', $this->recognitionJobId, [
                'status' => 'failed',
                'suggestions' => [[
                    'product' => null,
                    'label' => 'Recognition failed · encode manually',
                    'confidence' => 0.1,
                    'unknown_fields' => ['identity', 'price', 'stock'],
                ]],
            ]);
        }
    }
}
