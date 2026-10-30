<?php

namespace App\Console\Commands;

use Illuminate\Console\Command;
use Illuminate\Support\Facades\DB;
use Illuminate\Support\Facades\File;

class BackupLocalSpot extends Command
{
    protected $signature = 'localspot:backup {--dir= : Directory to write the backup file}';

    protected $description = 'Write a JSON snapshot of LocalSpot tables for backup and restore drills';

    public function handle(): int
    {
        $dir = $this->option('dir') ?: storage_path('app/backups');
        File::ensureDirectoryExists($dir);
        $path = $dir.DIRECTORY_SEPARATOR.'localspot-'.now()->format('Ymd-His').'.json';

        $tables = [
            'users', 'stores', 'store_members', 'categories', 'products', 'product_aliases',
            'store_products', 'stock_movements', 'promotions', 'store_tours', 'tour_nodes',
            'tour_connections', 'tour_hotspots', 'favorites', 'reports', 'audit_logs', 'store_locations',
            'product_images', 'pilot_feedback', 'vendor_location_sessions', 'recognition_jobs',
        ];

        $payload = ['created_at' => now()->toIso8601String(), 'tables' => []];
        foreach ($tables as $table) {
            if (! $this->hasTable($table)) {
                continue;
            }
            $payload['tables'][$table] = DB::table($table)->get()->map(fn ($row) => (array) $row)->all();
        }

        File::put($path, json_encode($payload, JSON_PRETTY_PRINT));
        $this->info($path);

        return self::SUCCESS;
    }

    private function hasTable(string $table): bool
    {
        try {
            DB::table($table)->limit(1)->get();

            return true;
        } catch (\Throwable) {
            return false;
        }
    }
}
