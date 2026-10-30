<?php

namespace App\Console\Commands;

use App\Jobs\ProcessRecognitionJob;
use App\Models\RecognitionJob;
use Illuminate\Console\Command;

class ProcessPendingRecognitionJobs extends Command
{
    protected $signature = 'localspot:process-recognition-jobs';

    protected $description = 'Dispatch pending product-recognition jobs that were not processed by a worker';

    public function handle(): int
    {
        $ids = RecognitionJob::query()->where('status', 'pending')->pluck('id');
        foreach ($ids as $id) {
            ProcessRecognitionJob::dispatch((int) $id);
        }
        $this->info("Dispatched {$ids->count()} recognition job(s).");

        return self::SUCCESS;
    }
}
