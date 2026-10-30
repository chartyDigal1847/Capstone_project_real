<?php

namespace App\Console\Commands;

use App\Models\VendorLocationSession;
use Illuminate\Console\Command;

class ExpireVendorLocationSessions extends Command
{
    protected $signature = 'localspot:expire-location-sessions';

    protected $description = 'Close mobile-vendor public location sessions that have passed their expiry time';

    public function handle(): int
    {
        $closed = VendorLocationSession::query()
            ->whereNull('ended_at')
            ->where('expires_at', '<=', now())
            ->update(['ended_at' => now()]);

        $this->info("Closed {$closed} expired location session(s).");

        return self::SUCCESS;
    }
}
