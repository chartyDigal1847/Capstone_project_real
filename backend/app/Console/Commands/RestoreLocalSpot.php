<?php

namespace App\Console\Commands;

use Illuminate\Console\Command;
use Illuminate\Support\Facades\DB;
use Illuminate\Support\Facades\File;
use Illuminate\Support\Facades\Schema;

class RestoreLocalSpot extends Command
{
    protected $signature = 'localspot:restore {file : Backup JSON path} {--force : Replace current rows}';

    protected $description = 'Restore a LocalSpot JSON backup into a separate drill or after an approved rollback';

    public function handle(): int
    {
        $file = $this->argument('file');
        if (! File::exists($file)) {
            $this->error('Backup file not found.');

            return self::FAILURE;
        }
        if (! $this->option('force') && ! $this->confirm('This replaces LocalSpot table rows. Continue?')) {
            return self::FAILURE;
        }

        $payload = json_decode(File::get($file), true);
        if (! is_array($payload) || ! isset($payload['tables']) || ! is_array($payload['tables'])) {
            $this->error('Invalid backup file.');

            return self::FAILURE;
        }

        Schema::disableForeignKeyConstraints();
        foreach (array_reverse(array_keys($payload['tables'])) as $table) {
            if (Schema::hasTable($table)) {
                DB::table($table)->delete();
            }
        }
        foreach ($payload['tables'] as $table => $rows) {
            if (! Schema::hasTable($table)) {
                continue;
            }
            foreach ($rows as $row) {
                DB::table($table)->insert($row);
            }
        }
        Schema::enableForeignKeyConstraints();
        $this->info('Restore completed from '.$file);

        return self::SUCCESS;
    }
}
