<?php

namespace App\Http\Controllers\Api\V1;

use App\Http\Controllers\Controller;
use Illuminate\Support\Facades\DB;
use Throwable;

class HealthController extends Controller
{
    public function show()
    {
        try {
            DB::select('select 1');
            $database = 'up';
            $ok = true;
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
                'routing_configured' => filled(config('localspot.routing_base_url')),
                'map' => 'maplibre_openfreemap',
            ],
        ], $ok ? 200 : 503);
    }
}
