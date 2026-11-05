<?php

namespace App\Http\Controllers\Api\V1;

use App\Http\Controllers\Controller;
use App\Services\FirestoreService;
use Throwable;

/** Health check — verifies Firestore connectivity instead of MySQL. */
class HealthController extends Controller
{
    public function __construct(private readonly FirestoreService $firestore)
    {
    }

    public function show()
    {
        $database = 'unknown';
        $ok = true;

        try {
            // Attempt a lightweight Firestore read to verify connectivity.
            $this->firestore->all('stores');
            $database = 'up';
        } catch (Throwable) {
            $database = 'down';
            $ok = false;
        }

        return response()->json([
            'data' => [
                'ok' => $ok,
                'app' => 'LocalSpot',
                'env' => config('app.env'),
                'database' => $database,
                'database_type' => 'firestore',
                'routing_configured' => filled(config('localspot.routing_base_url')),
                'map' => 'maplibre_openfreemap',
            ],
        ], $ok ? 200 : 503);
    }
}
