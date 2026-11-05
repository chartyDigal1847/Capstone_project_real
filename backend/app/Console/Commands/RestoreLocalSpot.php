<?php

namespace App\Console\Commands;

use App\Services\FirestoreService;
use Illuminate\Console\Command;
use Illuminate\Support\Facades\File;

/**
 * Restore a Firestore JSON backup snapshot.
 * — Firestore-backed (replaces the MySQL table restore).
 */
class RestoreLocalSpot extends Command
{
    protected $signature = 'localspot:restore {file : Backup JSON path} {--force : Replace current documents}';
    protected $description = 'Restore a Firestore JSON backup after an approved rollback';

    public function handle(FirestoreService $firestore): int
    {
        $file = $this->argument('file');
        if (! File::exists($file)) {
            $this->error('Backup file not found.');
            return self::FAILURE;
        }

        if (! $this->option('force') && ! $this->confirm('This replaces Firestore documents. Continue?')) {
            return self::FAILURE;
        }

        $payload = json_decode(File::get($file), true);
        if (! is_array($payload) || ! isset($payload['collections']) || ! is_array($payload['collections'])) {
            $this->error('Invalid backup file.');
            return self::FAILURE;
        }

        $restored = 0;
        foreach ($payload['collections'] as $collection => $documents) {
            foreach ($documents as $doc) {
                $docId = $doc['id'] ?? null;
                $data = $doc;
                unset($data['id']);
                if ($docId !== null) {
                    $firestore->set($collection, $docId, $data);
                } else {
                    $firestore->create($collection, $data);
                }
                $restored++;
            }
        }

        $this->info("Restored {$restored} document(s) from {$file}");
        return self::SUCCESS;
    }
}
