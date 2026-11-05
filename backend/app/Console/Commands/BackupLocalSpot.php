<?php

namespace App\Console\Commands;

use App\Services\FirestoreService;
use Illuminate\Console\Command;
use Illuminate\Support\Facades\File;

/**
 * Export Firestore collections to a JSON snapshot for backup and restore drills.
 * — Firestore-backed (replaces the MySQL table export).
 */
class BackupLocalSpot extends Command
{
    protected $signature = 'localspot:backup {--dir= : Directory to write the backup file}';
    protected $description = 'Export a JSON snapshot of Firestore collections for backup and restore drills';

    public function handle(FirestoreService $firestore): int
    {
        $dir = $this->option('dir') ?: storage_path('app/backups');
        File::ensureDirectoryExists($dir);
        $path = $dir . DIRECTORY_SEPARATOR . 'localspot-' . now()->format('Ymd-His') . '.json';

        $collections = [
            'users', 'stores', 'storeMembers', 'products', 'listings',
            'stockMovements', 'promotions', 'tours', 'vendorSessions',
            'favorites', 'reports', 'feedback', 'auditLogs',
            'productRecognitionJobs', 'mediaAssets',
        ];

        $payload = ['created_at' => now()->toIso8601String(), 'collections' => []];
        foreach ($collections as $collection) {
            $documents = $firestore->all($collection);
            if (! empty($documents)) {
                $payload['collections'][$collection] = $documents;
            }
        }

        File::put($path, json_encode($payload, JSON_PRETTY_PRINT));
        $this->info($path);

        return self::SUCCESS;
    }
}
