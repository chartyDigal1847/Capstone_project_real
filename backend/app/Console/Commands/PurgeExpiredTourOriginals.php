<?php

namespace App\Console\Commands;

use App\Models\TourNode;
use App\Support\TourPrivacy;
use Illuminate\Console\Command;

class PurgeExpiredTourOriginals extends Command
{
    protected $signature = 'localspot:purge-tour-originals';

    protected $description = 'Delete expired private tour originals; public sanitized derivatives stay';

    public function handle(): int
    {
        $nodes = TourNode::query()
            ->whereNotNull('original_image')
            ->whereNotNull('original_expires_at')
            ->where('original_expires_at', '<=', now())
            ->get();
        foreach ($nodes as $node) {
            TourPrivacy::forgetOriginal($node);
        }
        $this->info("Purged {$nodes->count()} expired tour original(s).");

        return self::SUCCESS;
    }
}
