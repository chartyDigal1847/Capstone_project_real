<?php

namespace App\Console\Commands;

use App\Services\FirestoreService;
use Illuminate\Console\Command;

/**
 * Close mobile-vendor public location sessions that have passed their
 * expiry time — Firestore-backed.
 */
class ExpireVendorLocationSessions extends Command
{
    protected $signature = 'localspot:expire-location-sessions';
    protected $description = 'Close expired mobile-vendor public location sessions';

    public function handle(FirestoreService $firestore): int
    {
        $sessions = $firestore->all('vendorSessions');
        $now = now()->toIso8601String();
        $closed = 0;

        foreach ($sessions as $session) {
            $endedAt = $session['ended_at'] ?? null;
            $expiresAt = $session['expires_at'] ?? null;

            if ($endedAt !== null) continue;
            if ($expiresAt !== null && $expiresAt <= $now) {
                $firestore->update('vendorSessions', $session['id'], ['ended_at' => $now]);
                $closed++;
            }
        }

        $this->info("Closed {$closed} expired location session(s).");
        return self::SUCCESS;
    }
}
