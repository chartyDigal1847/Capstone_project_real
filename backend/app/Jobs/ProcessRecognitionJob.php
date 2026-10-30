<?php

namespace App\Jobs;

use App\Models\RecognitionJob;
use App\Support\RecognitionService;
use Illuminate\Contracts\Queue\ShouldQueue;
use Illuminate\Foundation\Queue\Queueable;
use Throwable;

class ProcessRecognitionJob implements ShouldQueue
{
    use Queueable;

    public function __construct(public int $recognitionJobId) {}

    public function handle(RecognitionService $recognition): void
    {
        $job = RecognitionJob::find($this->recognitionJobId);
        if ($job === null || $job->status !== 'pending') {
            return;
        }

        try {
            $analysis = $recognition->analyze($job->hint, $job->barcode);
            $job->update([
                'status' => 'ready',
                'suggestions' => $analysis['suggestions'],
                'objects' => $analysis['objects'],
                'ocr_text' => $analysis['ocr'] ?? $job->ocr_text,
            ]);
        } catch (Throwable) {
            $job->update([
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
